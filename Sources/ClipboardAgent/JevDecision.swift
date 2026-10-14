import Foundation

/// 级联判决结果：快速回复足够收尾，还是需要触发深度思考。
enum CascadeDecision: Equatable {
    case fastSuffices
    case needDeep
}

/// 判决 + 置信度（气泡展示用）。
struct DecisionVerdict: Equatable {
    let decision: CascadeDecision
    let confidence: Double?
}

/// 级联裁判：在快速模型答完后判断是否需要升级到深度模型。
protocol DecisionService: Sendable {
    /// 输入复制原文、快速回复与深度模型是否具备联网工具，返回级联判决（含置信度）。
    func decide(copied: String, fastReply: String, deepHasTools: Bool) async throws -> DecisionVerdict
}

/// 判断文本是否本质上是一个 URL（这类内容快速模型无法读取，几乎总需要深度）。
private func isURLish(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    guard !trimmed.contains("\n"), trimmed.count < 300 else { return false } // 纯链接，不是长文
    return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.")
}

/// Jev AI 决策模型接入（POST https://thejevai.com/v1/systemone）。
/// 用一道 choice 题（fast_suffices / need_deep）拿结构化判决与置信度。
struct JevDecisionService: DecisionService {
    static let defaultEndpoint = "https://thejevai.com/v1/systemone"

    let apiKey: String
    let model: String
    let baseURL: String // 可指向自建网关；默认官方地址

    init(apiKey: String, model: String, baseURL: String = JevDecisionService.defaultEndpoint) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    func decide(copied: String, fastReply: String, deepHasTools: Bool) async throws -> DecisionVerdict {
        // 硬规则：纯 URL 且深度模型有网页读取工具 → 必须深度（快速模型读不了页面）
        if deepHasTools && isURLish(copied) {
            return DecisionVerdict(decision: .needDeep, confidence: 1.0)
        }
        do {
            return try await decideOnce(copied: copied, fastReply: fastReply, deepHasTools: deepHasTools)
        } catch AgentError.http(let status, _) where status == 429 || status >= 500 {
            // 网关类临时错误（429/5xx）按官方建议退避后重试一次；
            // 重试成功不计入熔断，仍失败才抛给编排层
            try await Task.sleep(nanoseconds: 600_000_000)
            return try await decideOnce(copied: copied, fastReply: fastReply, deepHasTools: deepHasTools)
        }
    }

    private func decideOnce(copied: String, fastReply: String, deepHasTools: Bool) async throws -> DecisionVerdict {
        guard let url = URL(string: baseURL) else { throw AgentError.badBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let toolNote = deepHasTools
            ? "注意：深度模型可调用网页阅读与网络搜索工具，能读取 URL 内容、获取实时信息——这些是快速模型做不到的。"
            : ""
        let body: [String: Any] = [
            "state": [
                "copied_text": String(copied.prefix(2000)),
                "fast_reply": String(fastReply.prefix(1000)),
            ] as [String: Any],
            "model": model,
            "questions": [
                "cascade": [
                    "type": "choice",
                    "instructions": "用户复制了一段文本，快速模型已给出简短回复（快速模型没有任何工具）。判断仅凭快速回复是否足以满足用户处理这段文本的需求。\(toolNote)",
                    "criteria": [
                        "fast_suffices": "内容简单（短句、格式识别、闲聊常识），且快速回复已经完成了用户的意图",
                        "need_deep": "满足任一：文本含 URL/链接且快速回复未能读取其内容；需要实时或外部信息；快速回复承认无法完成（如无法访问网页、无法查询）；需要推理、检索或多角度深入分析",
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(
                status: http.statusCode,
                message: AgentError.extractMessage(from: data)
            )
        }

        struct JevResponse: Decodable {
            struct Answer: Decodable {
                let choice: String?
                let confidence: Double?
            }
            // 真实响应：{"code":0,"data":{"result":{"answers":{…}}}}；
            // 文档示例为顶层 answers —— 两级都兼容
            struct DataLevel: Decodable {
                struct ResultLevel: Decodable {
                    let answers: [String: Answer]?
                }
                let result: ResultLevel?
            }
            let data: DataLevel?
            let answers: [String: Answer]?
        }
        let decoded = try JSONDecoder().decode(JevResponse.self, from: data)
        let answers = decoded.data?.result?.answers ?? decoded.answers
        guard let answer = answers?["cascade"], let choice = answer.choice else {
            throw AgentError.emptyResponse
        }
        return DecisionVerdict(
            decision: choice == "fast_suffices" ? .fastSuffices : .needDeep,
            confidence: answer.confidence
        )
    }
}

/// 离线演示裁判：URL（有工具时）、长文本、问号、代码判为需要深度，否则快速回复足够。
struct SimulatedDecisionService: DecisionService {
    func decide(copied: String, fastReply: String, deepHasTools: Bool) async throws -> DecisionVerdict {
        try await Task.sleep(nanoseconds: 400_000_000)
        if deepHasTools && isURLish(copied) {
            return DecisionVerdict(decision: .needDeep, confidence: 1.0)
        }
        let lowered = copied.lowercased()
        let complex = copied.count > 60
            || copied.contains("？") || copied.contains("?")
            || lowered.hasPrefix("http") || lowered.hasPrefix("www.")
            || copied.contains("{") || copied.contains("[")
        return DecisionVerdict(decision: complex ? .needDeep : .fastSuffices, confidence: 0.85)
    }
}
