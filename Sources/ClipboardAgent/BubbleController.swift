import AppKit
import Combine
import SwiftUI

/// 无边框、非激活的悬浮面板：可点击但不抢焦点，显示在所有空间之上。
final class BubblePanel: NSPanel {
    /// 鼠标进入/离开气泡（true/false），由 tracking area 驱动。
    var onMouseHover: ((Bool) -> Void)?

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
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseEntered(with event: NSEvent) { onMouseHover?(true) }
    override func mouseExited(with event: NSEvent) { onMouseHover?(false) }
}

/// 气泡的生命周期管理：显示 / 级联编排（⚡快速 → 🧠深度）/ 自适应高度 / 自动关闭。
@MainActor
final class BubbleController {
    private let model = BubbleModel()
    private let panel = BubblePanel()
    private var replyTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var isHovering = false // 鼠标悬停在气泡上时暂停自动关闭

    // 高度自适应：离屏测量副本（不进窗口层级，preferredContentSize 不受显示视口影响，
    // 否则会随当前窗口尺寸“自锁”）；model 变化节流后测量并调整窗口
    private var hostController: NSHostingController<BubbleView>!
    private var measuringController: NSHostingController<BubbleView>!
    private var modelSink: AnyCancellable?
    private var measureTask: Task<Void, Never>?

    /// 每次触发时取当前生效的级联组合（由 AppDelegate 注入，随配置切换）。
    var agentProvider: () -> AgentPair = { AgentPair(fast: SimulatedAgent(), thinking: nil) }

    /// “复制回复”的落地动作，由 AppDelegate 注入（写剪贴板前会抑制下一次触发）。
    var copyHandler: (String) -> Void = { _ in }

    private let margin: CGFloat = 18

    init() {
        hostController = NSHostingController(rootView: BubbleView(
            model: model,
            onCopyReply: { [weak self] reply in self?.copyReply(reply) },
            onClose: { [weak self] in self?.dismissNow() },
            onAction: { [weak self] action in self?.performAction(action) }
        ))
        // 离屏测量副本：共享同一个 model，视图结构相同但从不显示，
        // 其 preferredContentSize 始终反映内容自然高度
        measuringController = NSHostingController(rootView: BubbleView(
            model: model,
            onCopyReply: { _ in },
            onClose: { }
        ))
        // preferredContentSize 随 SwiftUI 内容自然高度更新（self-sizing 通道）
        measuringController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]

        // 先把窗口内容尺寸定下来再装内容视图：
        // 若在零尺寸窗口上装 contentView，子视图 autoresizing 会按负边距计算，
        // 窗口变成目标尺寸后 hosting view 会被拉伸到两倍大，布局全错。
        panel.setContentSize(NSSize(width: BubbleMetrics.width, height: BubbleMetrics.minHeight))
        // 注意：不能用 contentViewController 装载——NSWindow 会自动 adopt 其
        // preferredContentSize 且按“顶部锚定”调整，把窗口 origin 不断下压出屏。
        // 显示副本只作为普通 contentView，尺寸由离屏测量手动驱动。
        hostController.sizingOptions = []
        panel.contentView = hostController.view

        // 毛玻璃背景放在 AppKit 层：NSVisualEffectView + 圆角 maskImage。
        // 直接在 SwiftUI 里写 .background(.ultraThinMaterial, in: shape) 的话，
        // NSHostingView 会在圆角之外渲染出一圈矩形背景色。
        // popover 材质不透明度高（系统浮层的标准材质），文字对比清晰；
        // 之前用的 underWindowBackground 太透，背景复杂时文字发虚。
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.maskImage = Self.roundedMaskImage(cornerRadius: BubbleMetrics.cornerRadius)
        effect.autoresizingMask = [.width, .height]
        hostController.view.addSubview(effect, positioned: .below, relativeTo: nil)

        // 悬停跟踪：进入气泡暂停自动关闭，移开重新计时
        hostController.view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: panel,
            userInfo: nil
        ))
        panel.onMouseHover = { [weak self] hovering in
            self?.handleHover(hovering)
        }

        // 内容自然高度变化 → 节流后强制离屏测量并调整窗口。
        // 离屏视图不在窗口层级不会自动布局：每次 model 变化后手动
        // setNeedsLayout + layoutSubtreeIfNeeded，再读 preferredContentSize
        modelSink = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleMeasure()
            }
        }
    }

    /// 节流合并流式期间的高频内容变化（150ms 后测量一次）。
    private func scheduleMeasure() {
        measureTask?.cancel()
        measureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            let probe = measuringController.view
            probe.needsLayout = true
            probe.layoutSubtreeIfNeeded()
            applyResize(contentHeight: measuringController.preferredContentSize.height)
        }
    }

    /// 圆角遮罩：黑色区域 = 毛玻璃可见区域，圆角外完全透明。
    /// capInsets 固定四角，窗口高度变化时中心拉伸、圆角不变形。
    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2
        let size = NSSize(width: edge + 2, height: edge + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.isTemplate = true
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - 对外

    /// 复制事件发生：弹出气泡，⚡快速模型先回、🧠深度模型并行思考完成后追加。
    /// 两段各自写入独立状态槽（互不覆盖）；async let 使深度请求随父任务取消而取消。
    func present(copied text: String) {
        dismissTask?.cancel()
        replyTask?.cancel()
        measureTask?.cancel() // 新事件内容从矮开始重新长高

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
                scheduleAutoDismiss()
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
            scheduleAutoDismiss()
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

    /// 执行深度模型推荐的操作。
    private func performAction(_ action: RecommendedAction) {
        logInfo("执行推荐操作：\(action.label)（\(action.type)）")
        switch action.type {
        case "open_url":
            if let url = URL(string: action.arg), url.scheme?.hasPrefix("http") == true {
                NSWorkspace.shared.open(url)
            } else {
                logInfo("推荐操作 open_url 的参数无效：\(action.arg.prefix(60))")
            }
        case "search":
            guard let encoded = action.arg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.bing.com/search?q=\(encoded)") else { return }
            NSWorkspace.shared.open(url)
        case "copy":
            copyHandler(action.arg) // 写剪贴板前会抑制下一次触发
        default:
            logInfo("未知操作类型：\(action.type)")
        }
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
            x: visible.maxX - BubbleMetrics.width - margin,
            y: visible.minY + margin
        )
    }

    // MARK: - 高度自适应

    /// 把窗口高度设为内容自然高度（clamp 到 [min, 屏幕可用]），底边位置不动、向上顶开。
    private func applyResize(contentHeight: CGFloat) {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxHeight = min(BubbleMetrics.maxHeight, visible.height - margin * 2)
        let height = min(max(contentHeight, BubbleMetrics.minHeight), maxHeight)

        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        panel.setFrame(frame, display: false)
    }

    // MARK: - 自动关闭

    /// 内容越长给越多阅读时间：8 秒起，每 30 字 +1 秒，上限 40 秒；悬停时暂停。
    private func scheduleAutoDismiss() {
        let seconds = min(8 + Double(model.totalReplyLength) / 30.0, 40)
        scheduleAutoDismiss(after: seconds)
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        guard !isHovering else { return } // 悬停中不排程，等鼠标移开时再计时
        logInfo("气泡将于 \(Int(seconds)) 秒后自动关闭（鼠标悬停可暂停）")
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.animateOut()
        }
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
            logInfo("鼠标进入气泡，已暂停自动关闭")
        } else {
            // 仍在生成时交由完成点统一调度；已完成后移开 8 秒关闭
            if case .pending = model.fastSlot { return }
            scheduleAutoDismiss(after: 8)
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
