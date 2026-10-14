import Foundation

/// OpenAI Chat Completions 协议兼容的 Agent。
/// OpenAI、DeepSeek、GLM、通义、Moonshot、Ollama 等均可直连。
struct OpenAICompatibleAgent: AgentService {
    /// 级联中的角色：fast 固定禁用思考，deep 按配置的强度思考。
    enum Role {
        case fast
        case deep
    }

    let displayName: String

    private let endpoint: EndpointConfig
    private let systemPrompt: String
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

    func respond(to text: String, onDelta: (@Sendable (StreamEvent) -> Void)? = nil) async throws -> String {
        if let onDelta {
            return try await respondStreaming(text, onDelta: onDelta)
        }
        return try await respondOnce(text)
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

    private func respondStreaming(_ text: String, onDelta: (@Sendable (StreamEvent) -> Void)) async throws -> String {
        let request = try buildRequest(for: text, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AgentError.http(status: http.statusCode, message: Self.errorMessage(from: Data(body.utf8)))
        }

        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else {
                // 个别网关不支持 SSE，直接回了完整 JSON——按非流式兜底解析
                if let content = Self.decodeFullResponse(line) {
                    onDelta(.content(content))
                    return content
                }
                continue
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices.first else { continue }

            // 思考过程增量（DeepSeek/GLM/Qwen 用 reasoning_content，OpenAI 用 reasoning）
            if let reasoning = choice.delta.reasoning ?? choice.delta.reasoningContent, !reasoning.isEmpty {
                onDelta(.reasoning(reasoning))
            }
            if let delta = choice.delta.content, !delta.isEmpty {
                full += delta
                onDelta(.content(delta))
            }
        }

        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentError.emptyResponse }
        return trimmed
    }

    /// 非 SSE 单行 JSON 的兜底解析：是完整 Chat Completions 响应则返回 content。
    private static func decodeFullResponse(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = decoded.choices.first?.message.content else { return nil }
        return content
    }

    // MARK: - 非流式

    private func respondOnce(_ text: String) async throws -> String {
        let request = try buildRequest(for: text, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildRequest(for text: String, stream: Bool) throws -> URLRequest {
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
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
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

    private static func errorMessage(from data: Data) -> String {
        if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data), let message = body.error?.message {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }
}

// MARK: - 响应 / 错误模型

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

/// SSE 增量块：choices[0].delta.content / .reasoning_content / .reasoning
private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning: String? // OpenAI 风格
            let reasoningContent: String? // DeepSeek/GLM/Qwen 风格（reasoning_content）

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
            }
        }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct APIErrorBody: Decodable {
    struct Payload: Decodable { let message: String? }
    let error: Payload?
}

enum AgentError: LocalizedError {
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
