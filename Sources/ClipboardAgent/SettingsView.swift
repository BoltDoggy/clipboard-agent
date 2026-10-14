import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var fastTest: TestResult?
    @State private var deepTest: TestResult?
    @State private var isTesting = false

    struct TestResult {
        let ok: Bool
        let message: String
    }

    var body: some View {
        Form {
            modeSection
            fastSection
            thinkingSection
            toolsSection
            promptSection
            testSection
            noteSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 780)
    }

    // MARK: - Agent 模式

    private var modeSection: some View {
        Section {
            Picker("模式", selection: $settings.config.useLLM) {
                Text("离线演示 Agent（无需配置）").tag(false)
                Text("OpenAI 兼容 API（真实模型）").tag(true)
            }
            .pickerStyle(.radioGroup)
            Toggle("流式输出（逐字显示回复）", isOn: $settings.config.streamOutput)
        } header: {
            Text("Agent 模式")
        } footer: {
            Text("复制文字后：⚡ 快速模型先回复，🧠 深度模型同时思考、完成后追加。回复逐字流式显示（关闭后一次性显示，兼容不支持 SSE 的网关）。")
        }
    }

    // MARK: - ⚡ 快速响应模型

    private var fastSection: some View {
        Section {
            endpointFields($settings.config.fast)
        } header: {
            Text("⚡ 快速响应模型")
        } footer: {
            Text("复制后最先展示的回复，固定禁用思考（按所选思考参数风格自动映射为禁用指令）。建议选延迟低的小模型（gpt-4o-mini / glm-4-flash / qwen-turbo …）。")
        }
        .disabled(!settings.config.useLLM)
    }

    // MARK: - 🧠 深度思考模型

    private var thinkingSection: some View {
        Section {
            Toggle("启用深度思考模型", isOn: $settings.config.enableThinking)
            endpointFields($settings.config.thinking)
            Picker("思考强度", selection: $settings.config.thinkingEffort) {
                ForEach(ThinkingEffort.allCases, id: \.self) { effort in
                    Text(effort.label).tag(effort)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("🧠 深度思考模型")
        } footer: {
            Text("与快速模型并行请求、完成后追加到气泡（可跨供应商）。思考强度映射 reasoning_effort（DeepSeek 无中档→高、OpenAI 无最高档→高）；思考过程会在气泡的 💭 灰色块中流式展示。")
        }
        .disabled(!settings.config.useLLM)
    }

    // MARK: - 🔍 ReAct 工具

    private var toolsSection: some View {
        Section {
            Toggle("启用网络搜索（ReAct 工具调用）", isOn: $settings.config.enableWebTools)
            SecureField("智谱工具 API Key", text: $settings.config.toolAPIKey, prompt: Text("选填；不填则回退 DuckDuckGo 免费搜索"))
        } header: {
            Text("🔍 网络搜索工具")
        } footer: {
            Text("深度模型可按 ReAct 方式调用 web_search / read_webpage（气泡中显示 🔍/📄 步骤行）。搜索与阅读优先走智谱 BigModel 工具 API（open.bigmodel.cn，需其 API Key）；未填 Key 时回退 DuckDuckGo。")
        }
        .disabled(!settings.config.useLLM || !settings.config.enableThinking)
    }

    private func endpointFields(_ endpoint: Binding<EndpointConfig>) -> some View {
        Group {
            TextField("接口地址", text: endpoint.baseURL, prompt: Text("https://api.openai.com/v1"))
            SecureField("API Key", text: endpoint.apiKey, prompt: Text("sk-…（本地服务可留空）"))
            TextField("模型名称", text: endpoint.model, prompt: Text("gpt-4o / glm-4.7 / deepseek-r1 …"))
            Picker("思考参数", selection: endpoint.thinkingStyle) {
                ForEach(ThinkingStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
        }
    }

    // MARK: - 系统提示词

    private var promptSection: some View {
        Section {
            TextEditor(text: $settings.config.systemPrompt)
                .font(.system(size: 12))
                .frame(minHeight: 84)
        } header: {
            Text("系统提示词")
        } footer: {
            Text("快速与深度两个模型共用这条指令。")
        }
        .disabled(!settings.config.useLLM)
    }

    // MARK: - 测试连接

    private var testSection: some View {
        Section {
            HStack(spacing: 10) {
                Button("测试连接") { testConnection() }
                    .disabled(!settings.config.useLLM || isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("正在请求…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let fastTest {
                testRow(badge: "⚡", name: settings.config.fast.model, result: fastTest)
            }
            if settings.config.enableThinking, let deepTest {
                testRow(badge: "🧠", name: settings.config.thinking.model, result: deepTest)
            }
        } footer: {
            Text("并行向两个端点各发送一条最小请求，验证地址、密钥与模型名。")
        }
    }

    private func testRow(badge: String, name: String, result: TestResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(badge).font(.caption)
            Text(name.isEmpty ? "（未填模型名）" : name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(result.ok ? .green : .red)
            Text(result.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 说明

    private var noteSection: some View {
        Section {
            Text("配置即时生效。所有信息仅保存在本机（UserDefaults），API Key 只会发送到你填写的接口地址。深度请求超时 30 秒，超时或失败时气泡保留快速回复并标注原因。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 测试逻辑

    private func testConnection() {
        let config = settings.config
        let fastAgent = OpenAICompatibleAgent(endpoint: config.fast, systemPrompt: config.systemPrompt, timeout: 20)
        let deepAgent = config.enableThinking
            ? OpenAICompatibleAgent(endpoint: config.thinking, systemPrompt: config.systemPrompt, timeout: 20)
            : nil
        let probe = "连接测试，请只回复：pong"
        isTesting = true
        fastTest = nil
        deepTest = nil

        Task {
            let start = Date()
            // 两个端点并行探测：深度先启动（async let），快速先出结果
            async let deepOutcome: AgentOutcome? = Self.runOpt(deepAgent, probe)
            fastTest = Self.result(await runAgent(fastAgent, probe), since: start)
            if let outcome = await deepOutcome {
                deepTest = Self.result(outcome, since: start)
            }
            isTesting = false
        }
    }

    private static func runOpt(_ agent: (any AgentService)?, _ text: String) async -> AgentOutcome? {
        guard let agent else { return nil }
        return await runAgent(agent, text)
    }

    private static func result(_ outcome: AgentOutcome, since start: Date) -> TestResult {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        switch outcome {
        case .ok(let reply):
            return TestResult(ok: true, message: "成功（\(ms) ms）：\(String(reply.prefix(40)))")
        case .failed(let message):
            return TestResult(ok: false, message: message)
        }
    }
}
