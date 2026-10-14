import AppKit

/// 剪贴板事件：纯文本 / Finder 复制的文件。
enum ClipboardEvent {
    case text(String)
    case files([URL])
}

/// 轮询 `NSPasteboard.changeCount` 监听剪贴板变化。
/// 纯轮询方案，不需要任何系统权限（辅助功能 / 屏幕录制都不用）。
/// 只在主线程使用（Timer 挂在主 RunLoop 上）。
final class ClipboardMonitor {
    /// 新的剪贴板事件（已去除首尾空白；文本为空或仅文件无内容时也会回调文件事件）。在主线程回调。
    var onEvent: ((ClipboardEvent) -> Void)?

    private(set) var isPaused = false

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var suppressNext = false

    init() {
        // 记住启动时的计数，避免把剪贴板里已有的内容当成新复制。
        lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.invalidate()
    }

    func start(interval: TimeInterval = 0.4) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// 忽略下一次剪贴板变化（用于“复制回复”写回剪贴板时避免再次触发）。
    func suppressNextChange() {
        suppressNext = true
    }

    @discardableResult
    func togglePaused() -> Bool {
        isPaused.toggle()
        return isPaused
    }

    private func poll() {
        guard !isPaused else { return }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if suppressNext {
            suppressNext = false
            return
        }

        // 文件事件：Finder ⌘C 放的是 fileURL 类型（此时 .string 读不到），优先识别
        if pasteboard.types?.contains(.fileURL) == true,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            onEvent?(.files(urls))
            return
        }

        guard let raw = pasteboard.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onEvent?(.text(text))
    }
}
