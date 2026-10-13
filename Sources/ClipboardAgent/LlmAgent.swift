import Foundation

/// OpenAI Chat Completions 协议兼容的 Agent。
/// OpenAI、DeepSeek、GLM、通义、Moonshot、Ollama 等均可直连。
struct OpenAICompatibleAgent: AgentService {
    let displayName: String

    private let config: ModelConfig
    private let timeout: TimeInterval

    init(config: ModelConfig, timeout: TimeInterval = 60) {
        self.config = config
        self.timeout = timeout
        let name = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.isEmpty ? "LLM Agent" : name
    }

    func respond(to text: String) async throws -> String {
        let request = try buildRequest(for: text)
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

    private func buildRequest(for text: String) throws -> URLRequest {
        guard let url = Self.endpoint(for: config.baseURL) else { throw AgentError.badBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
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
