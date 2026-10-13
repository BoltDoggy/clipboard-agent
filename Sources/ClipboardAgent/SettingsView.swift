import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        Form {
            modeSection
            modelSection
            promptSection
            testSection
            noteSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 660)
    }

    // MARK: - Agent 模式

    private var modeSection: some View {
        Section {
            Picker("模式", selection: $settings.config.useLLM) {
                Text("离线演示 Agent（无需配置）").tag(false)
                Text("OpenAI 兼容 API（真实模型）").tag(true)
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Agent 模式")
        }
    }

    // MARK: - 模型配置

    private var modelSection: some View {
        Section {
            TextField("接口地址", text: $settings.config.baseURL, prompt: Text("https://api.openai.com/v1"))
            SecureField("API Key", text: $settings.config.apiKey, prompt: Text("sk-…（本地服务可留空）"))
            TextField("模型名称", text: $settings.config.model, prompt: Text("gpt-4o-mini / glm-4.7 / qwen2.5 …"))
        } header: {
            Text("模型配置")
        } footer: {
            Text("兼容 OpenAI Chat Completions 协议（OpenAI、DeepSeek、GLM、通义、Ollama 等）。接口地址需包含版本路径（如 /v1），也可直接填到 /chat/completions。")
        }
        .disabled(!settings.config.useLLM)
    }

    // MARK: - 系统提示词

    private var promptSection: some View {
        Section {
            TextEditor(text: $settings.config.systemPrompt)
                .font(.system(size: 12))
                .frame(minHeight: 88)
        } header: {
            Text("系统提示词")
        } footer: {
            Text("每次复制文字后，Agent 按这个指令处理文本。")
        }
        .disabled(!settings.config.useLLM)
    }

    // MARK: - 测试连接

    private var testSection: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                Button("测试连接") { testConnection() }
                    .disabled(!settings.config.useLLM || isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("正在请求…").font(.caption).foregroundStyle(.secondary)
                } else if let testResult {
                    Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testOK ? .green : .red)
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
        } footer: {
            Text("向接口发送一条最小请求，验证地址、密钥与模型名。")
        }
    }

    // MARK: - 说明

    private var noteSection: some View {
        Section {
            Text("配置即时生效，气泡标题会显示当前使用的模型。所有信息仅保存在本机（UserDefaults），API Key 只会发送到你填写的接口地址。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 测试逻辑

    private func testConnection() {
        let config = settings.config
        let agent = OpenAICompatibleAgent(config: config, timeout: 20)
        isTesting = true
        testResult = nil

        Task {
            let start = Date()
            do {
                let reply = try await agent.respond(to: "连接测试，请只回复：pong")
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                isTesting = false
                testOK = true
                testResult = "连接成功（\(ms) ms）：\(String(reply.prefix(40)))"
            } catch {
                isTesting = false
                testOK = false
                testResult = error.localizedDescription
            }
        }
    }
}
