import Foundation

/// 思考参数的协议风格：不同供应商用不同字段控制“是否思考”。
/// auto 按接口地址判断；也可对单个端点手动指定。
enum ThinkingStyle: String, Codable, CaseIterable {
    case auto
    case reasoningEffort = "reasoning_effort" // OpenAI gpt-5/o 系、多数兼容网关
    case glmThinking = "glm_thinking" // GLM：thinking.type
    case deepseekThinking = "deepseek_thinking" // DeepSeek：thinking.type + reasoning_effort
    case qwenThinking = "qwen_thinking" // Qwen：enable_thinking
    case off // 不发思考参数（模型自身决定）

    var label: String {
        switch self {
        case .auto: return "自动（按接口地址）"
        case .reasoningEffort: return "reasoning_effort"
        case .glmThinking: return "thinking.type（GLM）"
        case .deepseekThinking: return "thinking.type（DeepSeek）"
        case .qwenThinking: return "enable_thinking（Qwen）"
        case .off: return "不发送"
        }
    }
}

/// 深度思考强度。DeepSeek 认 low/high/max（无 medium，自动折算为 high）；
/// OpenAI 认 low/medium/high（无 max，自动折算为 high）。
enum ThinkingEffort: String, Codable, CaseIterable {
    case low, medium, high, max

    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .max: return "最高"
        }
    }
}

/// 单个模型的完整端点配置（快速/深度各一份，可指向不同供应商）。
struct EndpointConfig: Codable, Equatable {
    var baseURL = "https://api.openai.com/v1"
    var apiKey = "" // 可空（Ollama 等本地服务）
    var model = "gpt-4o-mini"
    var thinkingStyle: ThinkingStyle = .auto

    /// 足以发起请求的最小字段。
    var isConfigured: Bool {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !base.isEmpty && !name.isEmpty && OpenAICompatibleAgent.endpoint(for: base) != nil
    }
}

extension EndpointConfig {
    private enum CodingKeys: String, CodingKey {
        case baseURL, apiKey, model, thinkingStyle
    }

    /// 兼容缺字段的旧配置（thinkingStyle 缺省为 auto）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EndpointConfig()
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        thinkingStyle = try c.decodeIfPresent(ThinkingStyle.self, forKey: .thinkingStyle) ?? .auto
    }
}

/// 全局配置：快速响应模型 + 深度思考模型（级联），持久化到 UserDefaults。
struct ModelConfig: Codable, Equatable {
    var useLLM = false
    var fast = EndpointConfig(model: "gpt-4o-mini")
    var thinking = EndpointConfig(model: "gpt-4o")
    var enableThinking = true // 离线演示模式同样生效
    var thinkingEffort: ThinkingEffort = .high
    var enableWebTools = false // 深度模型 ReAct 工具调用（网络搜索 + 网页阅读）
    var toolAPIKey = "" // 智谱 BigModel 工具 API Key；空则回退 DuckDuckGo 免费搜索
    var streamOutput = true // 流式输出：LLM 走 SSE，离线演示为打字机效果
    var systemPrompt = "你是剪贴板助手。用户会给你一段刚复制的文本，请用一至两句话给出简短、有用的回应（摘要、解释、翻译要点或提醒），不要赘述。"

    private enum CodingKeys: String, CodingKey {
        case useLLM, fast, thinking, enableThinking, thinkingEffort
        case enableWebTools, toolAPIKey, streamOutput, systemPrompt
    }

    /// v1 单模型配置的字段名，仅用于解码迁移。
    private enum LegacyKeys: String, CodingKey {
        case baseURL, apiKey, model
    }

    init() {}

    /// 向后兼容 v1（单模型）配置：旧 baseURL/apiKey/systemPrompt 迁到 fast 端点，旧 model 作为快速模型名。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let defaults = ModelConfig()
        useLLM = try c.decodeIfPresent(Bool.self, forKey: .useLLM) ?? defaults.useLLM
        enableThinking = try c.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? defaults.enableThinking
        thinkingEffort = try c.decodeIfPresent(ThinkingEffort.self, forKey: .thinkingEffort) ?? defaults.thinkingEffort
        enableWebTools = try c.decodeIfPresent(Bool.self, forKey: .enableWebTools) ?? defaults.enableWebTools
        toolAPIKey = try c.decodeIfPresent(String.self, forKey: .toolAPIKey) ?? defaults.toolAPIKey
        streamOutput = try c.decodeIfPresent(Bool.self, forKey: .streamOutput) ?? defaults.streamOutput
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt

        if let fast = try c.decodeIfPresent(EndpointConfig.self, forKey: .fast) {
            self.fast = fast
        } else {
            let legacyBase = try legacy.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.fast.baseURL
            let legacyKey = try legacy.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
            let legacyModel = try legacy.decodeIfPresent(String.self, forKey: .model) ?? defaults.fast.model
            fast = EndpointConfig(baseURL: legacyBase, apiKey: legacyKey, model: legacyModel)
        }
        thinking = try c.decodeIfPresent(EndpointConfig.self, forKey: .thinking) ?? defaults.thinking
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
                logInfo(config.useLLM ? "已切换到 LLM 模式（快速：\(config.fast.model)，深度：\(config.enableThinking ? config.thinking.model : "未启用")）" : "已切换到离线演示模式")
            }
        }
    }

    /// 当前生效的级联组合：
    /// - LLM 模式：两端点各自实例化（深度超时 30s）；fast 配置不完整回退离线演示，thinking 配置不完整则不启用
    /// - 离线模式：快速识别 + 延迟更长的“深度分析”演示，同样受 enableThinking 控制
    var currentAgents: AgentPair {
        if config.useLLM {
            let fastAgent: any AgentService = config.fast.isConfigured
                ? OpenAICompatibleAgent(endpoint: config.fast, systemPrompt: config.systemPrompt, role: .fast)
                : SimulatedAgent()
            let thinkingAgent: (any AgentService)?
            if config.enableThinking && config.thinking.isConfigured {
                // 深度模型统一附加“意图分析 + 操作推荐”指令
                let deepPrompt = config.systemPrompt + "\n\n" + DeepBehavior.intentHint
                let base = OpenAICompatibleAgent(
                    endpoint: config.thinking,
                    systemPrompt: deepPrompt,
                    role: .deep,
                    effort: config.thinkingEffort,
                    timeout: 30
                )
                thinkingAgent = config.enableWebTools
                    ? ToolLoopAgent(base: base, glmKey: config.toolAPIKey)
                    : base
            } else {
                thinkingAgent = nil
            }
            return AgentPair(fast: fastAgent, thinking: thinkingAgent)
        }
        return AgentPair(
            fast: SimulatedAgent(),
            thinking: config.enableThinking ? SimulatedDeepAgent() : nil
        )
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
