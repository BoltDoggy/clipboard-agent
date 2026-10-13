import Foundation

/// 气泡里展示的“Agent”。实现这个协议即可接入真实模型（LLM API、本地脚本……）。
protocol AgentService: Sendable {
    var displayName: String { get }
    /// 针对复制内容生成回复。调用方已在后台执行，可以做网络请求。
    func respond(to text: String) async throws -> String
}

/// 离线演示 Agent：识别文本类型（链接 / JSON / 提问 / 长文），给一段模拟回复。
struct SimulatedAgent: AgentService {
    let displayName = "Clip Agent"

    func respond(to text: String) async throws -> String {
        // 模拟网络与推理延迟
        try await Task.sleep(nanoseconds: UInt64.random(in: 600_000_000...1_400_000_000))
        return Self.analyze(text)
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
