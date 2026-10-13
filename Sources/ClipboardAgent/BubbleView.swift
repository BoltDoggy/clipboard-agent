import SwiftUI

@MainActor
final class BubbleModel: ObservableObject {
    enum Phase {
        case idle
        case thinking(String)
        case replied(copied: String, reply: String)

        var copiedText: String? {
            switch self {
            case .idle: nil
            case .thinking(let text), .replied(let text, _): text
            }
        }

        var replyText: String? {
            if case .replied(_, let reply) = self { reply } else { nil }
        }
    }

    /// 当前 Agent 的展示名（离线为 Clip Agent，LLM 为模型名）。
    @Published var agentName = "Clip Agent"
    @Published var phase: Phase = .idle
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    var onCopyReply: (String) -> Void
    var onClose: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let copied = model.phase.copiedText {
                copiedBlock(copied)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(16)
        .frame(width: 380, height: 240)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                Text(model.agentName)
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
        switch model.phase {
        case .idle: ""
        case .thinking: "正在分析复制的文本…"
        case .replied: "分析完成 · 稍后自动关闭"
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
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
    }

    // MARK: - Agent 回复区

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .thinking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("\(model.agentName) 正在分析…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .replied(_, let reply):
            ScrollView(.vertical) {
                Text(reply)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 8) {
            Text("复制任意文字即可触发")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("复制回复") {
                if let reply = model.phase.replyText { onCopyReply(reply) }
            }
            .controlSize(.small)
            .disabled(model.phase.replyText == nil)
            Button("关闭", action: onClose)
                .controlSize(.small)
        }
    }
}
