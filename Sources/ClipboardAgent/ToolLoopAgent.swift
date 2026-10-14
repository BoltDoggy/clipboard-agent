import Foundation

/// ReAct 工具循环 Agent：思考 → 调用工具（搜索/阅读）→ 观察结果 → 再思考，
/// 直到模型给出最终回复（最多 maxRounds 轮工具调用）。
/// 底层单轮请求复用 OpenAICompatibleAgent.chatTurn（原生 function calling）。
struct ToolLoopAgent: AgentService {
    let displayName: String

    private let base: OpenAICompatibleAgent
    private let glmKey: String // 智谱工具 API Key，空则搜索回退 DuckDuckGo
    private let maxToolRounds = 4

    init(base: OpenAICompatibleAgent, glmKey: String) {
        self.base = base
        self.glmKey = glmKey
        self.displayName = base.displayName
    }

    func respond(to text: String, onDelta: (@Sendable (StreamEvent) -> Void)? = nil) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "system", "content": base.systemPrompt + "\n\n" + WebTools.systemHint],
            ["role": "user", "content": text],
        ]

        for _ in 0..<maxToolRounds {
            let turn = try await base.chatTurn(
                messages: messages,
                tools: WebTools.schemas,
                stream: onDelta != nil,
                onEvent: onDelta
            )
            guard turn.hasToolCalls else { return turn.content }

            // 回传 assistant 工具调用消息。
            // DeepSeek 思考模式 + tools 要求完整回传 reasoning_content，否则 400。
            messages.append([
                "role": "assistant",
                "content": turn.content,
                "reasoning_content": turn.reasoning,
                "tool_calls": turn.toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments,
                        ],
                    ] as [String: Any]
                },
            ])

            for call in turn.toolCalls {
                onDelta?(.step(Self.stepLabel(call)))
                let result = await WebTools.execute(call, glmKey: glmKey)
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result,
                ])
            }
        }

        // 达到轮次上限：撤掉工具，收敛出最终回复
        let final = try await base.chatTurn(
            messages: messages,
            tools: nil,
            stream: onDelta != nil,
            onEvent: onDelta
        )
        return final.content
    }

    /// 气泡步骤行的展示文案。
    static func stepLabel(_ call: ToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "web_search":
            return "🔍 搜索「\(args["query"] as? String ?? "")」"
        case "read_webpage":
            let url = args["url"] as? String ?? ""
            let host = URL(string: url)?.host ?? url
            return "📄 读取 \(host)"
        default:
            return "🔧 \(call.name)"
        }
    }
}
