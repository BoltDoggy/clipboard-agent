import SwiftUI

/// 气泡尺寸统一出处：NSPanel 与 SwiftUI 根视图共用。
enum BubbleMetrics {
    static let size = NSSize(width: 380, height: 480)
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

    /// 一次复制事件的两个独立状态槽，各自演进、互不覆盖（两段都保留展示）。
    @Published var copiedText: String?
    @Published var fastName = "Clip Agent"
    @Published var deepName: String?
    @Published var fastSlot: ReplyState = .pending
    @Published var deepSlot: DeepSlot = .off

    func begin(copied: String, fastName: String, deepName: String?) {
        self.fastName = fastName
        self.deepName = deepName
        copiedText = copied
        fastSlot = .pending
        deepSlot = deepName == nil ? .off : .active(.pending)
    }

    func reset() {
        copiedText = nil
        fastSlot = .pending
        deepSlot = .off
    }

    // 流式增量写入（在 MainActor 上由 runAgent 的桥回调触发）

    func appendFast(_ event: StreamEvent) {
        fastSlot = Self.appended(event, to: fastSlot)
    }

    func appendDeep(_ event: StreamEvent) {
        guard case .active(let state) = deepSlot else { return }
        deepSlot = .active(Self.appended(event, to: state))
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

    func finishDeep(_ outcome: AgentOutcome) {
        guard case .active(let state) = deepSlot else { return }
        deepSlot = .active(.finished(outcome, reasoning: Self.reasoningOf(state), steps: Self.stepsOf(state)))
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
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    var onCopyReply: (String) -> Void
    var onClose: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let copied = model.copiedText {
                copiedBlock(copied)
            }

            fastSection
            deepSection

            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: BubbleMetrics.size.width, height: BubbleMetrics.size.height)
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

    // MARK: - ⚡ 快速响应段

    private var fastSection: some View {
        section(badge: "⚡", name: model.fastName) {
            replyBody(model.fastSlot, small: false)
        }
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
                    reasoningBlock(reasoning, live: content.isEmpty && steps.isEmpty, maxHeight: small ? 54 : 40)
                }
                if !steps.isEmpty {
                    stepsBlock(steps)
                }
                if !content.isEmpty {
                    StreamingText(text: content, fontSize: small ? 11.5 : 12, maxHeight: small ? 74 : 60)
                }
            }
        case .finished(let outcome, let reasoning, let steps):
            switch outcome {
            case .ok(let reply):
                VStack(alignment: .leading, spacing: 6) {
                    if !reasoning.isEmpty {
                        reasoningBlock(reasoning, live: false, maxHeight: small ? 54 : 40)
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
                    .frame(maxHeight: small ? 74 : 60)
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
