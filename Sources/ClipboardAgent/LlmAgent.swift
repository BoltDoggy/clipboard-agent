import Foundation

/// 一次模型请求中的工具调用（function calling）。
struct ToolCall: Equatable {
    let id: String
    let name: String
    let arguments: String // JSON 字符串
}

/// 一轮对话（单次请求）的完整产物，供工具循环复用。
struct ChatTurn {
    var content = ""
    var reasoning = ""
    var toolCalls: [ToolCall] = []
    var finishReason: String?

    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

/// OpenAI Chat Completions 协议兼容的 Agent。
/// OpenAI、DeepSeek、GLM、通义、Moonshot、Ollama 等均可直连。
struct OpenAICompatibleAgent: AgentService {
    /// 级联中的角色：fast 固定禁用思考，deep 按配置的强度思考。
    enum Role {
        case fast
        case deep
    }

    let displayName: String
    let systemPrompt: String // internal：ToolLoopAgent 会追加工具使用指引

    private let endpoint: EndpointConfig
    private let role: Role
    private let effort: ThinkingEffort
    private let timeout: TimeInterval

    init(
        endpoint: EndpointConfig,
        systemPrompt: String,
        role: Role = .fast,
        effort: ThinkingEffort = .high,
        timeout: TimeInterval = 60
    ) {
        self.endpoint = endpoint
        self.systemPrompt = systemPrompt
        self.role = role
        self.effort = effort
        self.timeout = timeout
        let name = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.isEmpty ? "LLM Agent" : name
    }

    // MARK: - AgentService（单轮便捷封装）

    func respond(to text: String, onDelta: (@Sendable (StreamEvent) -> Void)? = nil) async throws -> String {
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text],
        ]
        let turn = try await chatTurn(messages: messages, tools: nil, stream: onDelta != nil, onEvent: onDelta)
        return turn.content
    }

    // MARK: - 核心单轮调用（ReAct 工具循环的底层）

    /// 发送一组消息（可带工具 schema），流式时增量通过 onEvent 回调，
    /// 返回该轮完整产物（正文 / 思考过程 / 工具调用）。
    func chatTurn(
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        stream: Bool,
        onEvent: (@Sendable (StreamEvent) -> Void)?
    ) async throws -> ChatTurn {
        let request = try buildRequest(messages: messages, tools: tools, stream: stream)
        if stream, let onEvent {
            return try await streamTurn(request, onEvent: onEvent)
        }
        return try await onceTurn(request)
    }

    // MARK: - 思考参数映射

    /// 按接口地址猜测思考参数风格（用户显式指定时不走这里）。
    /// DeepSeek（V3.2+ / deepseek-flash）思考默认开启：fast 必须显式 disabled，
    /// deep 用 enabled + reasoning_effort（low/high/max，无 medium）。
    static func detectThinkingStyle(baseURL: String) -> ThinkingStyle {
        let lower = baseURL.lowercased()
        if lower.contains("deepseek") { return .deepseekThinking }
        if lower.contains("bigmodel") || lower.contains("z.ai") { return .glmThinking }
        if lower.contains("dashscope") || lower.contains("aliyuncs") { return .qwenThinking }
        return .reasoningEffort
    }

    /// fast：显式禁用思考；deep：启用并携带强度。
    /// DeepSeek 的 effort 只认 low/high/max——medium 在客户端先折算成 high。
    private func applyThinkingControl(to body: inout [String: Any]) {
        let style = endpoint.thinkingStyle == .auto
            ? Self.detectThinkingStyle(baseURL: endpoint.baseURL)
            : endpoint.thinkingStyle
        let wantThinking = role == .deep
        switch style {
        case .auto: // 上面的三元已把 auto 解析成具体风格，不会走到这里
            break
        case .reasoningEffort:
            // OpenAI 无 max 档，折算为 high
            body["reasoning_effort"] = wantThinking
                ? (effort == .max ? "high" : effort.rawValue)
                : "none"
        case .glmThinking:
            body["thinking"] = ["type": wantThinking ? "enabled" : "disabled"]
        case .deepseekThinking:
            body["thinking"] = ["type": wantThinking ? "enabled" : "disabled"]
            if wantThinking {
                // DeepSeek 只有 low/high/max，medium 折算为 high
                body["reasoning_effort"] = effort == .medium ? "high" : effort.rawValue
            }
        case .qwenThinking:
            body["enable_thinking"] = wantThinking
        case .off:
            break
        }
    }

    // MARK: - 流式（SSE）

    private func streamTurn(
        _ request: URLRequest,
        onEvent: @escaping @Sendable (StreamEvent) -> Void
    ) async throws -> ChatTurn {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AgentError.http(status: http.statusCode, message: AgentError.extractMessage(from: Data(body.utf8)))
        }

        var turn = ChatTurn()
        var toolAcc: [Int: ToolCallAcc] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else {
                // 个别网关不支持 SSE，直接回了完整 JSON——按非流式兜底解析
                if let content = Self.decodeFullResponse(line) {
                    onEvent(.content(content))
                    turn.content = content
                    return turn
                }
                continue
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices.first else { continue }

            if let finish = choice.finishReason, !finish.isEmpty {
                turn.finishReason = finish
            }
            guard let delta = choice.delta else { continue }

            // 思考过程增量（DeepSeek/GLM/Qwen 用 reasoning_content，OpenAI 用 reasoning）
            if let reasoning = delta.reasoning ?? delta.reasoningContent, !reasoning.isEmpty {
                turn.reasoning += reasoning
                onEvent(.reasoning(reasoning))
            }
            // 工具调用增量：按 index 累积拼装 id / name / arguments
            for tc in delta.toolCalls ?? [] {
                let idx = tc.index ?? 0
                var acc = toolAcc[idx] ?? ToolCallAcc()
                if let id = tc.id, !id.isEmpty { acc.id = id }
                if let name = tc.function?.name, !name.isEmpty { acc.name = name }
                if let args = tc.function?.arguments { acc.arguments += args }
                toolAcc[idx] = acc
            }
            if let content = delta.content, !content.isEmpty {
                turn.content += content
                onEvent(.content(content))
            }
        }

        turn.toolCalls = toolAcc
            .sorted(by: { $0.key < $1.key })
            .compactMap { _, acc in
                acc.name.isEmpty ? nil : ToolCall(id: acc.id, name: acc.name, arguments: acc.arguments)
            }
        return turn
    }

    private struct ToolCallAcc {
        var id = ""
        var name = ""
        var arguments = ""
    }

    // MARK: - 非流式

    private func onceTurn(_ request: URLRequest) async throws -> ChatTurn {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(status: http.statusCode, message: AgentError.extractMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let message = decoded.choices.first?.message else { throw AgentError.emptyResponse }

        var turn = ChatTurn()
        turn.finishReason = decoded.choices.first?.finishReason
        turn.content = message.content ?? ""
        turn.reasoning = message.reasoningContent ?? ""
        turn.toolCalls = (message.toolCalls ?? []).compactMap { tc in
            guard let name = tc.function?.name, !name.isEmpty else { return nil }
            return ToolCall(
                id: tc.id ?? "",
                name: name,
                arguments: tc.function?.arguments ?? "{}"
            )
        }

        let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !turn.hasToolCalls {
            guard !trimmed.isEmpty else { throw AgentError.emptyResponse }
        }
        return turn
    }

    // MARK: - 请求构造

    private func buildRequest(
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = Self.endpoint(for: endpoint.baseURL) else { throw AgentError.badBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": messages,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }
        applyThinkingControl(to: &body)
        if stream {
            body["stream"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 容错拼接端点：接口地址可以填到 /v1、带尾斜杠，或完整的 /chat/completions。
    static func endpoint(for baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        return URL(string: base + "/chat/completions")
    }



    /// 非 SSE 单行 JSON 的兜底解析：是完整 Chat Completions 响应则返回 content。
    private static func decodeFullResponse(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = decoded.choices.first?.message.content else { return nil }
        return content
    }
}

// MARK: - 响应 / 错误模型

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ToolCallSpec: Decodable {
                let id: String?
                struct Fn: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let function: Fn?
            }
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallSpec]?

            enum CodingKeys: String, CodingKey {
                case content, toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
            }
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
            }
        }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct ToolCallDelta: Decodable {
    let index: Int?
    let id: String?
    struct Fn: Decodable {
        let name: String?
        let arguments: String?
    }
    let function: Fn?
}

enum AgentError: LocalizedError {
    /// 从错误响应体提取人类可读信息。
    /// 兼容两种格式：OpenAI 的 {"error":{"message":…}} 与 Jev 的 {"code":…,"message":…}
    static func extractMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = json["error"] as? [String: Any],
               let message = nested["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    case badBaseURL
    case badResponse
    case http(status: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badBaseURL:
            return "接口地址无法解析，请检查格式（如 https://api.openai.com/v1）"
        case .badResponse:
            return "服务返回了无法识别的响应"
        case .http(let status, let message):
            let hint: String
            switch status {
            case 401, 403: hint = "API Key 无效或无权限"
            case 402: hint = "账户积分/余额不足"
            case 404: hint = "路径不存在，请检查接口地址是否包含 /v1"
            case 429: hint = "请求过于频繁或额度不足"
            default: hint = "服务端错误"
            }
            return "HTTP \(status)（\(hint)）\(message.isEmpty ? "" : "：\(message)")"
        case .emptyResponse:
            return "模型返回了空内容"
        }
    }
}
