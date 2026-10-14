# ClipboardAgent

一个 macOS 菜单栏小工具：**监听剪贴板，复制任意文字后，在屏幕右下角弹出一个 Agent 气泡**，展示对这段文字的分析回复。

原生 Swift / AppKit / SwiftUI 实现，零第三方依赖，不需要任何系统权限（不用辅助功能、不用屏幕录制）。

## 效果

复制文字后，右下角弹出气泡卡片：

```
┌────────────────────────────────┐
│ ✨ Clip Agent                  │
│    正在分析复制的文本…          │
│ ╭────────────────────────────╮ │
│ │ 复制的文本                  │ │
│ │ 你复制的原文（最多 3 行）    │ │
│ ╰────────────────────────────╯ │
│ Agent 回复区（思考动画 → 回复） │
│                                │
│ 复制任意文字即可触发  复制回复 关闭 │
└────────────────────────────────┘
```

- 思考态：加载动画 + “正在分析…”
- 回复态：展示 Agent 回复，8 秒后自动淡出关闭
- 气泡不抢焦点（nonactivating panel），跨空间（所有桌面/全屏可见）
- 菜单栏 💬 图标：暂停 / 恢复监听，退出

## 运行

```bash
# 方式一：开发运行
swift run

# 方式二：打包成可双击的 .app（推荐）
./build.sh
open build/ClipboardAgent.app
```

## 工作原理

| 文件 | 职责 |
|---|---|
| `Sources/ClipboardAgent/AppEntry.swift` | `@main` 入口，启动 NSApplication（仅菜单栏模式） |
| `Sources/ClipboardAgent/AppDelegate.swift` | 菜单栏图标与菜单，把监听事件接到气泡 |
| `Sources/ClipboardAgent/ClipboardMonitor.swift` | 每 0.4s 轮询 `NSPasteboard.changeCount`，识别新复制的文本 |
| `Sources/ClipboardAgent/BubbleController.swift` | 右下角悬浮 `NSPanel` 的生命周期：弹出、思考→回复、自动关闭 |
| `Sources/ClipboardAgent/BubbleView.swift` | SwiftUI 气泡 UI（毛玻璃圆角卡片） |
| `Sources/ClipboardAgent/AgentService.swift` | Agent 协议 + 离线演示实现 |
| `Sources/ClipboardAgent/LlmAgent.swift` | `OpenAICompatibleAgent`：OpenAI 协议真实模型请求与错误处理 |
| `Sources/ClipboardAgent/AppSettings.swift` | `ModelConfig` 模型配置 + UserDefaults 持久化 |
| `Sources/ClipboardAgent/SettingsView.swift` | 模型配置界面（SwiftUI Form） |
| `Sources/ClipboardAgent/SettingsWindowController.swift` | 配置窗口控制器 |

细节设计：

- **定位**：锚定在 `NSScreen.main.visibleFrame` 右下角，自动避开 Dock 和菜单栏
- **防自我触发**：点“复制回复”把回复写回剪贴板前，先 `suppressNextChange()`，不会再次弹气泡
- **快速连续复制**：旧分析任务被取消，气泡直接切换到新内容
- **超长文本**：展示截断到 2000 字符，分析仍用全文

## 模型配置（双模型级联）

复制文字后的处理流程：**⚡ 快速响应模型**先给出第一版回复，**🧠 深度思考模型**同时并行请求，完成后把深度分析追加到气泡下方（两段都保留，可对照）。回复**流式逐字显示**（LLM 走 SSE，离线演示为打字机效果），流式文本末尾带光标并自动滚动到底部。深度请求超时 30 秒，失败时气泡保留快速回复并标注原因。

菜单栏 💬 → **模型配置…**（⌘,，或启动时加 `--settings` 参数）：

- **Agent 模式**：离线演示（默认，同样演示双阶段级联 + 打字机效果）/ OpenAI 兼容 API（真实模型）
- **流式输出**：默认开启，SSE 逐字渲染；个别网关不支持流式时可在设置里关闭（关闭后走普通一次性请求，服务端若对 `stream:true` 仍返回完整 JSON 也会自动兜底解析）
- **⚡ 快速响应模型** / **🧠 深度思考模型**：**各自独立的接口地址、API Key、模型名称**——可以跨供应商级联（如快速用 GLM-4-Flash、深度用 DeepSeek-R1）
  - 兼容 OpenAI Chat Completions 协议：OpenAI、DeepSeek、GLM、通义、Moonshot、Ollama 等
  - 接口地址填到 `/v1` 即可（Ollama 填 `http://localhost:11434/v1`，Key 可留空）
  - 「启用深度思考模型」开关关闭后只走快速模型
- **思考控制**：快速模型固定禁用思考；深度模型可设**思考强度**（低/中/高/最高）
  - 「思考参数」按端点选择协议风格：自动（按接口地址判断）/ `reasoning_effort` / `thinking.type`（GLM）/ `thinking.type + reasoning_effort`（DeepSeek）/ `enable_thinking`（Qwen）/ 不发送
  - 强度按供应商自动折算：DeepSeek 无"中"档（→高）、OpenAI 无"最高"档（→高）
  - DeepSeek（V3.2+，`deepseek-flash`）**思考默认开启**——快速模型会被自动加上 `thinking:{"type":"disabled"}`，深度模型加 `enabled` + `reasoning_effort`；思考过程走 `reasoning_content`，在气泡的灰色「💭 思考过程」块中流式展示，正文随后流出
- **系统提示词**：两个模型共用
- **测试连接**：并行探测两个端点，⚡/🧠 各显示一行结果（延迟 + 回复预览 / 失败原因）
- 配置即时生效，持久化在本机 UserDefaults；API Key 只会发送到你填写的接口地址；旧版单模型配置自动迁移为快速模型

## 接入真实 LLM

默认的 `SimulatedAgent` 是离线的类型识别演示，`OpenAICompatibleAgent` 是内置的 OpenAI 协议实现（上面的配置界面配的就是它）。想接入其它协议（如 Anthropic Messages API）或自定义流程，实现 `AgentService` 协议即可：

```swift
struct LlmAgent: AgentService {
    let displayName = "GPT Agent"

    func respond(to text: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
        // … 组装 JSON 请求体（把 text 放进 messages）…
        let (data, _) = try await URLSession.shared.data(for: request)
        // … 解析返回的 content …
        return content
    }
}
```

然后在 `AppDelegate.init()` 里替换：

```swift
bubble = BubbleController(agent: LlmAgent())
```

API Key 建议从环境变量或 Keychain 读取，不要写进代码。

## 已知注意点

- 入口文件里那个注释是踩过坑的：**不要**用 `await MainActor.run { app.run() }` 引导——那会让并发运行时认为主线程被一个永不结束的 MainActor 任务占用，之后所有 MainActor 任务和主队列 dispatch 都不再执行（气泡会永远停在“正在分析…”）。
- 最低支持 macOS 14（Sonoma）。
