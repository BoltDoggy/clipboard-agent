import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = ClipboardMonitor()
    private let bubble: BubbleController

    override init() {
        bubble = BubbleController()
        super.init()

        // 每次复制时按当前配置取 Agent：LLM 配置不完整时自动回退到离线演示
        bubble.agentProvider = { AppSettings.shared.currentAgents }

        // “复制回复”写回剪贴板前，先抑制下一次监听触发，避免自己弹自己。
        bubble.copyHandler = { [monitor] reply in
            monitor.suppressNextChange()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(reply, forType: .string)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onEvent = { [bubble] event in
            switch event {
            case .text(let text):
                bubble.present(copied: text)
            case .files(let urls):
                bubble.present(files: urls)
            }
        }
        monitor.start()
        setupStatusItem()
        logInfo("当前 Agent：⚡\(AppSettings.shared.currentAgents.fast.displayName)" +
                (AppSettings.shared.currentAgents.thinking.map { " + 🧠\($0.displayName)" } ?? "（深度思考未启用）"))
        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right.fill",
                accessibilityDescription: "ClipboardAgent"
            )
            button.toolTip = "ClipboardAgent — 剪贴板 Agent 气泡"
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "模型配置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let pauseItem = NSMenuItem(
            title: "暂停监听",
            action: #selector(togglePause(_:)),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 ClipboardAgent",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        monitor.togglePaused()
        sender.title = monitor.isPaused ? "恢复监听" : "暂停监听"
        logInfo(monitor.isPaused ? "监听已暂停" : "监听已恢复")
        if monitor.isPaused {
            bubble.dismissNow()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

func logInfo(_ message: String) {
    fputs("[ClipboardAgent] \(message)\n", stderr)
}
