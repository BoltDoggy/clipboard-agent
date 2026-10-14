import SwiftUI

/// 气泡尺寸统一出处。宽度固定；高度自适应内容（NSHostingController 的
/// preferredContentSize 驱动窗口），clamp 在 [minHeight, 屏幕可用高度]。
enum BubbleMetrics {
    static let width: CGFloat = 380
    static let minHeight: CGFloat = 240
    static let maxHeight: CGFloat = 1600 // 纯保险值；实际约束是屏幕可用高度
    static let cornerRadius: CGFloat = 18
}

@MainActor
final class BubbleModel: ObservableObject {
    /// 一个回复槽的生命周期：等待 → 流式（思考/工具步骤/正文累积）→ 完成（思考与步骤保留展示）。
    enum ReplyState: Equatable {
        case pending
        case streaming(reasoning: String, steps: [String], content: String)
        case finished(AgentOutcome, reasoning: String, steps: [String])
    }

    /// 深度槽多一个“未启用”态。
    enum DeepSlot: Equatable {
        case off
        case active(ReplyState)
    }

    /// 🧭 裁判槽：快速回复完成后是否需要深度。
    enum DecisionSlot: Equatable {
        case off
        case idle // 已启用裁判，等快速回复完成
        case pending
        case decided(CascadeDecision, confidence: Double?)
        case failed(String)
    }

    /// 一次复制事件的两个独立状态槽，各自演进、互不覆盖（两段都保留展示）。
    @Published var copiedText: String?
    @Published var fastName = "Clip Agent"
    @Published var deepName: String?
    @Published var fastSlot: ReplyState = .pending
    @Published var deepSlot: DeepSlot = .off
    @Published var decisionSlot: DecisionSlot = .off

    /// 裁决模式：判决 need_deep 后激活深度段。
    func activateDeep(name: String) {
        guard case .off = deepSlot else { return }
        deepName = name
        deepRawContent = ""
        deepSlot = .active(.pending)
    }

    /// 深度模型的意图分析与推荐操作（从 <<ACTIONS>> 块解析）。
    @Published var intentSummary: String?
    @Published var recommendedActions: [RecommendedAction] = []

    /// 深度回复的原始累积（含 <<ACTIONS>> 标记块；展示时剥离）。
    private var deepRawContent = ""

    func begin(copied: String, fastName: String, deepName: String?) {
        self.fastName = fastName
        self.deepName = deepName
        copiedText = copied
        fastSlot = .pending
        deepSlot = deepName == nil ? .off : .active(.pending)
        decisionSlot = .off
        deepRawContent = ""
        intentSummary = nil
        recommendedActions = []
    }

    func reset() {
        copiedText = nil
        fastSlot = .pending
        deepSlot = .off
        decisionSlot = .off
        deepRawContent = ""
        intentSummary = nil
        recommendedActions = []
    }

    // 流式增量写入（在 MainActor 上由 runAgent 的桥回调触发）

    func appendFast(_ event: StreamEvent) {
        fastSlot = Self.appended(event, to: fastSlot)
    }

    func appendDeep(_ event: StreamEvent) {
        guard case .active(let state) = deepSlot else { return }
        // 深度正文先累积原始串（含 <<ACTIONS>> 块），展示时剥离并解析意图/操作
        if !event.contentText.isEmpty {
            deepRawContent += event.contentText
            let parsed = Self.splitActions(deepRawContent)
            applyParsedActions(parsed)
            deepSlot = .active(.streaming(
                reasoning: reasoningText(of: state) + event.reasoningText,
                steps: stepList(of: state) + (event.stepText.map { [$0] } ?? []),
                content: parsed.visible
            ))
            return
        }
        deepSlot = .active(Self.appended(event, to: state))
    }

    func finishDeep(_ outcome: AgentOutcome) {
        guard case .active = deepSlot else { return }
        if case .ok(let raw) = outcome {
            let parsed = Self.splitActions(raw)
            applyParsedActions(parsed)
            let corrected = AgentOutcome.ok(parsed.visible)
            deepSlot = .active(.finished(corrected, reasoning: Self.reasoningOf(deepSlotState), steps: Self.stepsOf(deepSlotState)))
            return
        }
        deepSlot = .active(.finished(outcome, reasoning: Self.reasoningOf(deepSlotState), steps: Self.stepsOf(deepSlotState)))
    }

    private var deepSlotState: ReplyState {
        if case .active(let s) = deepSlot { return s }
        return .pending
    }

    private func reasoningText(of state: ReplyState) -> String {
        if case .streaming(let r, _, _) = state { return r }
        return ""
    }

    private func stepList(of state: ReplyState) -> [String] {
        if case .streaming(_, let s, _) = state { return s }
        return []
    }

    private func applyParsedActions(_ parsed: (visible: String, intent: String?, actions: [RecommendedAction])) {
        if let intent = parsed.intent, !intent.isEmpty { intentSummary = intent }
        if !parsed.actions.isEmpty { recommendedActions = parsed.actions }
    }

    /// 把含 <<ACTIONS>>…<<END>> 标记块的原始输出拆成：可见正文 + 意图 + 推荐操作。
    /// 流式期间块未闭合时，标记起的内容一律不进入可见正文。
    static func splitActions(_ raw: String) -> (visible: String, intent: String?, actions: [RecommendedAction]) {
        guard let start = raw.range(of: "<<ACTIONS>>") else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil, [])
        }
        let visible = String(raw[raw.startIndex..<start.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = raw[start.upperBound...]
        let payload: String
        if let end = after.range(of: "<<END>>") {
            payload = String(after[after.startIndex..<end.lowerBound])
        } else {
            payload = String(after) // 块还在流式中，只解析已到达的部分
        }

        guard let data = payload.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (visible, nil, [])
        }
        let intent = obj["intent"] as? String
        var actions: [RecommendedAction] = []
        for item in (obj["actions"] as? [[String: Any]] ?? []).prefix(3) {
            guard let label = item["label"] as? String,
                  let type = item["type"] as? String,
                  let arg = item["arg"] as? String else { continue }
            actions.append(RecommendedAction(label: label, type: type.lowercased(), arg: arg))
        }
        return (visible, intent, actions)
    }

    private static func appended(_ event: StreamEvent, to state: ReplyState) -> ReplyState {
        switch state {
        case .pending:
            return .streaming(
                reasoning: event.reasoningText,
                steps: event.stepText.map { [$0] } ?? [],
                content: event.contentText
            )
        case .streaming(let reasoning, let steps, let content):
            return .streaming(
                reasoning: reasoning + event.reasoningText,
                steps: event.stepText.map { steps + [$0] } ?? steps,
                content: content + event.contentText
            )
        case .finished:
            return state
        }
    }

    func finishFast(_ outcome: AgentOutcome) {
        fastSlot = .finished(outcome, reasoning: Self.reasoningOf(fastSlot), steps: Self.stepsOf(fastSlot))
    }

    private static func reasoningOf(_ state: ReplyState) -> String {
        switch state {
        case .pending, .finished:
            return ""
        case .streaming(let reasoning, _, _):
            return reasoning
        }
    }

    private static func stepsOf(_ state: ReplyState) -> [String] {
        switch state {
        case .pending, .finished:
            return []
        case .streaming(_, let steps, _):
            return steps
        }
    }

    /// 两段回复的总字数，用于动态自动关闭时长（内容越多给越多阅读时间）。
    var totalReplyLength: Int {
        func contentLength(_ state: ReplyState) -> Int {
            switch state {
            case .pending:
                return 0
            case .streaming(_, _, let content):
                return content.count
            case .finished(let outcome, _, _):
                if case .ok(let reply) = outcome { return reply.count }
                return 0
            }
        }
        let deep: Int
        if case .active(let state) = deepSlot {
            deep = contentLength(state)
        } else {
            deep = 0
        }
        return contentLength(fastSlot) + deep
    }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    var onCopyReply: (String) -> Void
    var onClose: () -> Void
    var onAction: (RecommendedAction) -> Void = { _ in }

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let copied = model.copiedText {
                copiedBlock(copied)
            }

            fastSection

            if shouldShowDecisionRow {
                decisionRow
            }

            deepSection

            if model.intentSummary != nil || !model.recommendedActions.isEmpty {
                actionsBar
            }

            footer
        }
        .padding(16)
        // 实心底色：92% 不透明度的窗口底色压在毛玻璃之上，只留极轻材质质感——
        // 单靠 popover 材质依然偏透，背景复杂时文字受干扰
        .background(
            RoundedRectangle(cornerRadius: BubbleMetrics.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
        // 宽度固定、高度完全交给自然内容：preferredContentSize 可能很大，
        // 由控制器把窗口 clamp 到屏幕可用高度——窗口受限后内层 ScrollView 自动压缩滚动
        .frame(width: BubbleMetrics.width, alignment: .top)
        .overlay(
            RoundedRectangle(cornerRadius: BubbleMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        // 毛玻璃背景和阴影由 AppKit 层提供（NSVisualEffectView + 圆角 maskImage + 窗口阴影），
        // 这里不再画 .background / .shadow，避免圆角外出现矩形底色。
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 30)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appeared = true }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [.indigo, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("ClipboardAgent")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitle: String {
        // 裁决进行中优先展示判决状态
        if case .pending = model.decisionSlot { return "⚡ 已回复 · 🧭 判决中…" }
        if case .decided(.fastSuffices, _) = model.decisionSlot { return "⚡🧭 已完成 · 无需深度" }

        switch model.fastSlot {
        case .pending:
            return "正在分析…"
        case .streaming:
            return model.deepSlot == .off ? "⚡ 回复中…" : "⚡ 回复中 · 🧠 思考中…"
        case .finished:
            switch model.deepSlot {
            case .active(.pending), .active(.streaming):
                return "⚡ 已回复 · 🧠 深度思考中…"
            case .off:
                return "已完成 · 稍后自动关闭"
            case .active(.finished):
                return "⚡🧠 均已完成 · 稍后自动关闭"
            }
        }
    }

    // MARK: - 复制内容预览

    private func copiedBlock(_ copied: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("复制的文本")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(copied)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
    }

    // MARK: - 🧭 裁决行

    private var shouldShowDecisionRow: Bool {
        switch model.decisionSlot {
        case .off, .idle:
            return false
        default:
            return true
        }
    }

    @ViewBuilder
    private var decisionRow: some View {
        switch model.decisionSlot {
        case .off, .idle:
            EmptyView()
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("🧭 判决中：评估是否需要深度分析…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        case .decided(let decision, let confidence):
            let pct = confidence.map { String(format: "（置信度 %.2f）", $0) } ?? ""
            Text(decision == .fastSuffices
                ? "🧭 判定：快速回复足够\(pct)，已跳过深度"
                : "🧭 判定：需要深度分析\(pct)")
                .font(.system(size: 10.5))
                .foregroundStyle(decision == .fastSuffices ? .secondary : Color(nsColor: .systemBlue))
                .lineLimit(2)
        case .failed(let message):
            Text("🧭 判决失败：\(message)（已直接触发深度）")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: - ⚡ 快速响应段

    private var fastSection: some View {
        section(badge: "⚡", name: model.fastName) {
            replyBody(model.fastSlot, small: false)
        }
        // 快速段高度只取内容自然值：不随深度段的增长被贪婪拉伸/压缩，
        // 空间协商全部交给深度段（唯一负责吸收增长的区域）
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 🧠 深度思考段

    @ViewBuilder
    private var deepSection: some View {
        if case .active(let state) = model.deepSlot {
            section(badge: "🧠", name: model.deepName ?? "深度思考") {
                replyBody(state, small: true)
            }
        }
    }

    // MARK: - 复用组件

    private func section<Content: View>(
        badge: String,
        name: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(badge).font(.system(size: 10))
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func replyBody(_ state: BubbleModel.ReplyState, small: Bool) -> some View {
        switch state {
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(small ? "深度思考中…" : "\(model.fastName) 正在分析…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .streaming(let reasoning, let steps, let content):
            VStack(alignment: .leading, spacing: 6) {
                if !reasoning.isEmpty {
                    reasoningBlock(reasoning, live: content.isEmpty && steps.isEmpty, maxHeight: small ? 64 : 48)
                }
                if !steps.isEmpty {
                    stepsBlock(steps)
                }
                if !content.isEmpty {
                    // 上限给很大值：正常内容自然顶开气泡，极端超长交给窗口 clamp 后滚动
                    StreamingText(text: content, fontSize: small ? 11.5 : 12, maxHeight: small ? 4000 : 120)
                }
            }
        case .finished(let outcome, let reasoning, let steps):
            switch outcome {
            case .ok(let reply):
                VStack(alignment: .leading, spacing: 6) {
                    if !reasoning.isEmpty {
                        reasoningBlock(reasoning, live: false, maxHeight: small ? 64 : 48)
                    }
                    if !steps.isEmpty {
                        stepsBlock(steps)
                    }
                    ScrollView(.vertical) {
                        Text(reply)
                            .font(.system(size: small ? 11.5 : 12))
                            .lineSpacing(2.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: small ? 4000 : 120)
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(small ? 2 : 3)
            }
        }
    }

    /// ReAct 工具步骤行（🔍 搜索 / 📄 读取），最多显示最近 4 条。
    private func stepsBlock(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(steps.suffix(4).enumerated()), id: \.offset) { _, step in
                Text(step)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 思考过程块：灰色小字斜体；live 时末尾带光标、自动滚底。
    private func reasoningBlock(_ text: String, live: Bool, maxHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 3) {
                    Text("💭 思考过程")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Text(live ? text + "\u{258D}" : text)
                        .font(.system(size: 10.5))
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("reasoning-bottom")
                        .onChange(of: text) { _, _ in
                            if live {
                                proxy.scrollTo("reasoning-bottom", anchor: .bottom)
                            }
                        }
                }
            }
        }
        .frame(maxHeight: maxHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .fixedSize(horizontal: false, vertical: true) // 思考块同样不参与空间协商
    }

    /// 意图分析 + 推荐操作条（深度模型 <<ACTIONS>> 块解析而来）。
    private var actionsBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let intent = model.intentSummary {
                Text("🎯 \(intent)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !model.recommendedActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(model.recommendedActions.enumerated()), id: \.offset) { _, action in
                        Button {
                            onAction(action)
                        } label: {
                            Label(action.label, systemImage: iconName(for: action.type))
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true) // 不参与空间协商
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "search": return "magnifyingglass"
        case "open_url": return "safari"
        case "copy": return "doc.on.doc"
        default: return "arrow.right.circle"
        }
    }

    // MARK: - 底部操作

    /// 当前展示的"主回复"：深度完成取深度，否则取快速（复制按钮的对象）。
    private var primaryReply: String? {
        if case .active(.finished(.ok(let reply), _, _)) = model.deepSlot { return reply }
        if case .finished(.ok(let reply), _, _) = model.fastSlot { return reply }
        return nil
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("复制任意文字即可触发")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("复制回复") {
                if let reply = primaryReply { onCopyReply(reply) }
            }
            .controlSize(.small)
            .disabled(primaryReply == nil)
            Button("关闭", action: onClose)
                .controlSize(.small)
        }
    }
}

/// 流式文本：末尾带光标，随内容增长自动滚到底部。
private struct StreamingText: View {
    let text: String
    let fontSize: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.vertical) {
            ScrollViewReader { proxy in
                Text(text + "\u{258D}")
                    .font(.system(size: fontSize))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("stream-bottom")
                    .onChange(of: text) { _, _ in
                        proxy.scrollTo("stream-bottom", anchor: .bottom)
                    }
            }
        }
        .frame(maxHeight: maxHeight)
    }
}
