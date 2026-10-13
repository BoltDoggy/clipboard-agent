import Foundation

/// 模型配置（Codable，持久化到 UserDefaults）。
struct ModelConfig: Codable, Equatable {
    var useLLM = false
    var baseURL = "https://api.openai.com/v1"
    var apiKey = ""
    var model = "gpt-4o-mini"
    var systemPrompt = "你是剪贴板助手。用户会给你一段刚复制的文本，请用一至两句话给出简短、有用的回应（摘要、解释、翻译要点或提醒），不要赘述。"
}

extension ModelConfig {
    /// 足以发起请求的最小字段（API Key 允许为空，适配 Ollama 等本地服务）。
    var isLLMConfigured: Bool {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isEmpty && !name.isEmpty && OpenAICompatibleAgent.endpoint(for: base) != nil
    }
}

/// 全局配置：@Published 驱动设置界面，变更即自动持久化。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let storageKey = "ClipboardAgent.ModelConfig"

    @Published var config: ModelConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
            if oldValue.useLLM != config.useLLM {
                logInfo(config.useLLM ? "已切换到 LLM Agent：\(config.model)" : "已切换到离线演示 Agent")
            }
        }
    }

    /// 当前生效的 Agent：选择 LLM 但配置不完整时，自动回退到离线演示。
    var currentAgent: any AgentService {
        config.useLLM && config.isLLMConfigured
            ? OpenAICompatibleAgent(config: config)
            : SimulatedAgent()
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(ModelConfig.self, from: data) {
            config = saved
        } else {
            config = ModelConfig()
        }
    }
}
