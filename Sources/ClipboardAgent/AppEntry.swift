import AppKit

// ClipboardAgent：常驻菜单栏的剪贴板监听器。
// 复制任意文字后，在屏幕右下角弹出一个 Agent 气泡进行分析回复。
//
// 注意：不要用 `await MainActor.run { app.run() }` 之类的写法包住 run()——
// 那样并发运行时会认为主线程被一个永不结束的 MainActor 任务占用，
// 之后所有 MainActor 任务 / 主队列 dispatch 都不再执行。
// @main 生成的主线程入口等价于经典的顶层引导，运行循环可正常调度。

@main
enum ClipboardAgentApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // 仅菜单栏，不占 Dock
        app.run()
    }
}
