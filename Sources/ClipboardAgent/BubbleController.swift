import AppKit
import SwiftUI

/// 无边框、非激活的悬浮面板：可点击但不抢焦点，显示在所有空间之上。
final class BubblePanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        hasShadow = true // 系统窗口阴影，跟随 maskImage 的圆角形状
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 气泡的生命周期管理：显示 / 级联编排（⚡快速 → 🧠深度）/ 自动关闭。
@MainActor
final class BubbleController {
    private let model = BubbleModel()
    private let panel = BubblePanel()
    private var replyTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    /// 每次触发时取当前生效的级联组合（由 AppDelegate 注入，随配置切换）。
    var agentProvider: () -> AgentPair = { AgentPair(fast: SimulatedAgent(), thinking: nil) }

    /// “复制回复”的落地动作，由 AppDelegate 注入（写剪贴板前会抑制下一次触发）。
    var copyHandler: (String) -> Void = { _ in }

    private let margin: CGFloat = 18

    init() {
        // 先把窗口内容尺寸定下来再装内容视图：
        // 若在零尺寸窗口上装 contentView，子视图 autoresizing 会按负边距计算，
        // 窗口变成目标尺寸后 hosting view 会被拉伸到两倍大，布局全错。
        panel.setContentSize(BubbleMetrics.size)

        let host = NSHostingView(rootView: BubbleView(
            model: model,
            onCopyReply: { [weak self] reply in self?.copyReply(reply) },
            onClose: { [weak self] in self?.dismissNow() }
        ))

        // 毛玻璃背景放在 AppKit 层：NSVisualEffectView + 圆角 maskImage。
        // 直接在 SwiftUI 里写 .background(.ultraThinMaterial, in: shape) 的话，
        // NSHostingView 会在圆角之外渲染出一圈矩形背景色。
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMaskImage(
            size: BubbleMetrics.size,
            cornerRadius: BubbleMetrics.cornerRadius
        )

        // hosting view 用约束钉满四边，不依赖 autoresizing 的相对边距
        effect.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
    }

    /// 圆角遮罩：黑色区域 = 毛玻璃可见区域，圆角外完全透明。
    private static func roundedMaskImage(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 对外

    /// 复制事件发生：弹出气泡，⚡快速模型先回、🧠深度模型并行思考完成后追加。
    /// 两段各自写入独立状态槽（互不覆盖）；async let 使深度请求随父任务取消而取消。
    func present(copied text: String) {
        dismissTask?.cancel()
        replyTask?.cancel()

        let agents = agentProvider()

        // 超长文本只截断展示，分析仍用全文
        let displayText = text.count > 2000 ? String(text.prefix(2000)) + " …" : text
        model.begin(
            copied: displayText,
            fastName: agents.fast.displayName,
            deepName: agents.thinking?.displayName
        )
        logInfo("复制了 \(text.count) 字符，气泡已触发（快速：\(agents.fast.displayName)，深度：\(agents.thinking?.displayName ?? "未启用")）")
        showPanel()

        replyTask = Task { [weak self] in
            guard let self else { return }

            // 流式开关：关闭时 Agent 收不到 onDelta，走一次性请求/响应
            let streaming = AppSettings.shared.config.streamOutput
            let fastAppend = Self.streamAppender(streaming) { [weak self] event in
                self?.model.appendFast(event)
            }
            let deepAppend = Self.streamAppender(streaming) { [weak self] event in
                self?.model.appendDeep(event)
            }

            // 深度请求先启动（后台并行），快速请求先行展示
            let deepAgent = agents.thinking
            async let deepOutcome: AgentOutcome? = Self.runOpt(deepAgent, text, onDelta: deepAppend)

            let fastOutcome = await runAgent(agents.fast, text, onDelta: fastAppend)
            guard !Task.isCancelled else { return }
            model.finishFast(fastOutcome)
            switch fastOutcome {
            case .ok:
                logInfo("快速回复完成（\(agents.fast.displayName)）")
            case .failed:
                logInfo("快速模型失败：\(fastOutcome.message ?? "")")
            }
            if deepAgent == nil {
                scheduleAutoDismiss(after: 8)
                return
            }

            // 等深度思考收尾（快于快速模型时这里立即返回）
            if let outcome = await deepOutcome {
                guard !Task.isCancelled else { return }
                model.finishDeep(outcome)
                switch outcome {
                case .ok:
                    logInfo("深度思考完成（\(deepAgent?.displayName ?? "")）")
                case .failed:
                    logInfo("深度思考失败：\(outcome.message ?? "")")
                }
            }
            scheduleAutoDismiss(after: 8)
        }
    }

    /// 立即关闭（关闭按钮 / 暂停监听时）。
    func dismissNow() {
        dismissTask?.cancel()
        dismissTask = nil
        replyTask?.cancel()
        animateOut()
    }

    private func copyReply(_ reply: String) {
        copyHandler(reply)
        logInfo("回复已复制回剪贴板（不会再次触发气泡）")
    }

    /// 可选 Agent 的包装：nil 直接返回 nil，供 async let 使用。
    private static func runOpt(
        _ agent: (any AgentService)?,
        _ text: String,
        onDelta: (@MainActor (StreamEvent) -> Void)? = nil
    ) async -> AgentOutcome? {
        guard let agent else { return nil }
        return await runAgent(agent, text, onDelta: onDelta)
    }

    /// 流式开关开启时返回写入闭包，关闭时返回 nil（Agent 收到 nil 就不发流式请求）。
    private static func streamAppender<T>(
        _ streaming: Bool,
        _ apply: @escaping (T) -> Void
    ) -> (@MainActor (T) -> Void)? {
        guard streaming else { return nil }
        return { value in apply(value) }
    }

    // MARK: - 显示与定位

    private func showPanel() {
        panel.setFrameOrigin(bottomRightOrigin())
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    /// 锚定在当前主屏幕可见区域的右下角（自动避开 Dock 和菜单栏）。
    private func bottomRightOrigin() -> NSPoint {
        let visible: NSRect
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            visible = screen.visibleFrame
        } else {
            visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
        return NSPoint(
            x: visible.maxX - BubbleMetrics.size.width - margin,
            y: visible.minY + margin
        )
    }

    // MARK: - 自动关闭

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.animateOut()
        }
    }

    private func animateOut() {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, panel.alphaValue < 0.05 else { return } // 淡出期间又有新复制则不关
            panel.orderOut(nil)
            panel.alphaValue = 1
            model.reset()
        }
    }
}
