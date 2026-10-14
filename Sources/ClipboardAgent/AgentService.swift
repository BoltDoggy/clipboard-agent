import Foundation

/// 流式事件的增量类型：思考过程 / 工具步骤 / 正式回复。
enum StreamEvent: Sendable, Equatable {
    case reasoning(String)
    case step(String) // ReAct 工具动作（如 🔍 搜索 / 📄 读取），只作展示
    case content(String)

    var reasoningText: String {
        if case .reasoning(let s) = self { s } else { "" }
    }

    var stepText: String? {
        if case .step(let s) = self { s } else { nil }
    }

    var contentText: String {
        if case .content(let s) = self { s } else { "" }
    }
}

/// 气泡里展示的“Agent”。实现这个协议即可接入真实模型（LLM API、本地脚本……）。
/// `onDelta` 非 nil 时实现方应尽量流式输出（SSE / 打字机），否则一次性返回。
protocol AgentService: Sendable {
    var displayName: String { get }
    /// 针对复制内容生成回复。调用方已在后台执行，可以做网络请求。
    /// 增量片段（思考过程与正式回复）通过 onDelta 回调（任意线程），返回值为完整回复。
    func respond(to text: String, onDelta: (@Sendable (StreamEvent) -> Void)?) async throws -> String
}

/// 一次 Agent 调用的结果（成功回复 / 失败原因），气泡状态槽直接消费。
enum AgentOutcome: Equatable {
    case ok(String)
    case failed(String)

    var message: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

/// 一次复制事件的级联编排输入：快速模型必选；裁判（决策模型）与深度模型可选。
/// 有裁判时编排为 串行（快速 → 判决 → 按需深度），无裁判时 快速/深度并行。
struct CascadeBundle {
    let fast: any AgentService
    let decider: (any DecisionService)?
    let thinking: (any AgentService)?
}

/// 统一跑一次 Agent 并把结果/异常折叠成 AgentOutcome；
/// onDelta 在 MainActor 上回调，方便直接写入气泡状态槽。
@MainActor
func runAgent(
    _ agent: any AgentService,
    _ text: String,
    onDelta: (@MainActor (StreamEvent) -> Void)? = nil
) async -> AgentOutcome {
    // 网络层在后台线程回调，这里桥回主线程（Task 入队保持顺序）
    var sendableDelta: (@Sendable (StreamEvent) -> Void)?
    if let callback = onDelta {
        sendableDelta = { event in Task { @MainActor in callback(event) } }
    }
    do {
        return .ok(try await agent.respond(to: text, onDelta: sendableDelta))
    } catch is CancellationError {
        return .failed("已取消")
    } catch {
        return .failed(error.localizedDescription)
    }
}

/// 深度模型的行为指令：意图分析 + 操作推荐。
/// 模型在正文之后输出 <<ACTIONS>> 结构化块，应用解析为可点击操作。
enum DeepBehavior {
    static let intentHint = """
    完成正文回答后，请分析用户复制这段文本的可能意图，并在最后严格按以下格式附加操作推荐 \
    （此块内容不会展示给用户，会被解析成按钮）：
    <<ACTIONS>>
    {"intent":"一句话概括用户意图","actions":[{"label":"按钮文案（≤6字）","type":"操作类型","arg":"参数"}]}
    <<END>>
    操作类型只能是这三种：search（arg 为搜索词，跳转搜索引擎）、open_url（arg 为完整 URL，\
    打开网页）、copy（arg 为要写入剪贴板的文本，如翻译结果/摘要/润色稿）。\
    actions 最多 3 个、按可能有用程度排序；没有值得推荐的给空数组。不要输出此块以外的任何标记。
    """
}

/// 深度模型推荐的一个操作（由 <<ACTIONS>> 块解析而来）。
struct RecommendedAction: Equatable {
    let label: String
    let type: String // search / open_url / copy
    let arg: String
}

/// 把一段文本切成小块，供离线演示的打字机效果使用。
private func typingChunks(_ text: String, size: Int = 3) -> [String] {
    var chunks: [String] = []
    var current = ""
    for grapheme in text {
        current.append(grapheme)
        if current.count >= size {
            chunks.append(current)
            current = ""
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

/// 离线演示 Agent：识别文本类型（链接 / JSON / 提问 / 长文），给一段模拟回复。
/// 在级联里扮演“快速响应模型”（禁用思考，只有正式回复），带打字机效果。
struct SimulatedAgent: AgentService {
    let displayName = "Clip Agent"

    func respond(to text: String, onDelta: (@Sendable (StreamEvent) -> Void)? = nil) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...800_000_000))
        let reply = Self.analyze(text)
        try await Self.typeOut(reply, onDelta: onDelta)
        return reply
    }

    /// 按 onDelta 是否存在决定打字机或直接返回。
    static func typeOut(_ reply: String, onDelta: (@Sendable (StreamEvent) -> Void)?) async throws {
        guard let onDelta else { return }
        for chunk in typingChunks(reply) {
            try Task.checkCancellation()
            onDelta(.content(chunk))
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    static func analyze(_ text: String) -> String {
        let chars = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        let preview = String(text.prefix(30)).replacingOccurrences(of: "\n", with: " ⏎ ")
        let lowered = text.lowercased()

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.") {
            let normalized = lowered.hasPrefix("www.") ? "https://\(text)" : text
            let host = URL(string: normalized)?.host ?? normalized
            return "识别到链接（\(host)）。接入真实模型后，这里可以自动抓取并摘要网页内容。"
        }

        if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) {
            let isJSON = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
            return isJSON
                ? "这是一段格式合法的 JSON（\(chars) 字符）。可以交给真实模型做清洗、生成解析代码或写接口文档。"
                : "这段文本看起来想写成 JSON，但解析失败了——检查一下引号或逗号？"
        }

        if text.contains("？") || text.contains("?") {
            return "检测到一个问题（共 \(chars) 字）：「\(preview)」。演示 Agent 无法真正回答；在 AgentService.swift 里接上 LLM 即可。"
        }

        if chars > 140 {
            return "长文本：\(chars) 字符 / \(words) 词，开头是「\(preview)…」。真实 Agent 场景下这里可以做摘要、翻译或提取要点。"
        }

        return "收到 \(chars) 个字符（\(words) 词）：「\(preview)」。这是演示 Agent 的模拟回复——把它换成真实 LLM 调用即可获得智能回复。"
    }
}

/// 离线演示的“深度思考模型”：先流出思考过程，再流出正式回复，演示级联第二阶段。
struct SimulatedDeepAgent: AgentService {
    let displayName = "深度分析（演示）"

    func respond(to text: String, onDelta: (@Sendable (StreamEvent) -> Void)? = nil) async throws -> String {
        try await Task.sleep(nanoseconds: 600_000_000)

        // 思考过程流（灰色块）
        let reasoning = "先判断文本类型与语言，统计字符与句子数；再提取关键词、猜测复制意图；最后按「结论—要点—建议」组织回复。"
        if let onDelta {
            for chunk in typingChunks(reasoning) {
                try Task.checkCancellation()
                onDelta(.reasoning(chunk))
                try await Task.sleep(nanoseconds: 35_000_000)
            }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        let reply = Self.analyzeDeep(text)
        try await SimulatedAgent.typeOut(reply, onDelta: onDelta)
        return reply
    }

    static func analyzeDeep(_ text: String) -> String {
        let chars = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        let hasCJK = text.unicodeScalars.contains(where: { $0.properties.isIdeographic })
        let language = hasCJK ? "中文为主" : "西文为主"
        let sentences = text.split(whereSeparator: { "。！？.!?\n".contains($0) }).count

        return """
        深度分析（演示）：这段文本共 \(chars) 字符 / \(words) 词 / 约 \(max(sentences, 1)) 句，\(language)。\
        真实深度模型会在这里给出结构化结论：主题概括、要点提取、潜在风险或可执行建议。\
        在「模型配置」中为快速/深度两个阶段分别填入 API 地址与模型名即可体验真实级联。
        <<ACTIONS>>
        {"intent":"想了解这段文本的含义并深入处理","actions":[{"label":"搜索相关资料","type":"search","arg":"\(previewKeyword(text))"},{"label":"复制全文摘要","type":"copy","arg":"摘要（演示）：\(language)文本，\(chars) 字符，约 \(max(sentences, 1)) 句。"}]}
        <<END>>
        """
    }

    /// 离线演示的搜索词：取前几个非空白字符。
    private static func previewKeyword(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        return String(cleaned.prefix(12))
    }
}
