import AppKit
import SwiftUI

/// 模型配置窗口：单例，关闭后可重复打开（菜单栏 ⌘, 或 --settings 启动参数）。
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "模型配置"
        window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
