import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppState
    /// 由弹出方直接关闭自己，避免嵌套导航容器里 dismiss 失效
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var temperature = 0.3
    @State private var systemPrompt = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var presetNote = ""

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                if !baseURL.isEmpty {
                    let preview = AISettings(baseURL: baseURL, apiKey: apiKey, model: model,
                                             temperature: temperature, systemPrompt: systemPrompt)
                    Text("实际请求：\(AIClient.endpoint(for: preview))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if baseURL.localizedCaseInsensitiveContains("codebuddy") {
                    Text("⚠️ CodeBuddy 的 ck_ 密钥是 IDE 内部凭证，官方没有对外公开的 OpenAI 兼容接口，填进来必然 404。请改用下面「填入服务商预设」里的服务商。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Menu {
                    ForEach(AISettings.Presets.all) { preset in
                        Button(preset.name) {
                            baseURL = preset.baseURL
                            model = preset.model
                            if !preset.apiKey.isEmpty { apiKey = preset.apiKey }
                            presetNote = preset.note
                            apply()
                        }
                    }
                } label: {
                    HStack {
                        Text("填入服务商预设")
                        Spacer()
                        Image(systemName: "chevron.down.circle")
                    }
                }
                .font(.footnote)
                if !presetNote.isEmpty {
                    Text(presetNote).font(.caption).foregroundStyle(.secondary)
                }
                TextField("模型名称", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Text("温度")
                    Slider(value: $temperature, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f", temperature)).monospacedDigit()
                }
            } header: {
                Text("AI 接口（OpenAI 兼容）")
            } footer: {
                Text("支持任何 OpenAI /chat/completions 兼容服务。填 base URL 时系统会自动补上 https 与 /chat/completions；API Key 只保存在本机，不会随源码或备份分享出去。")
            }

            Section("角色设定") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 110)
            }

            Section {
                Button {
                    Task { await testAPI() }
                } label: {
                    HStack {
                        Text("测试 AI 接口")
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                if let testResult {
                    Text(testResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(testResult.hasPrefix("✅") ? .green : .red)
                }
            }

            Section("说明") {
                Label("SSH 密码保存在系统钥匙串（Keychain），不写入配置文件", systemImage: "lock.shield")
                Label("主机密钥采用首次信任策略（类似常见 SSH 客户端）", systemImage: "key.horizontal")
                Label("指标数据取自 /proc 文件系统，无需在设备上安装 agent", systemImage: "cpu")
            }
            .font(.caption)

            Section("关于 PadTerm") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PadTerm").font(.headline)
                            Text(appVersion).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Text("PadTerm 是一款面向 iPad / Mac 的 SSH 终端与设备运维工具：用一块屏幕完成「连上设备 → 敲命令 → 看指标 → 问 AI」的闭环，主要服务树莓派、嵌入式 Linux 开发板与小型服务器。")
                        .font(.caption)
                        .foregroundStyle(.primary)

                    Divider()

                    Text("功能").font(.caption.bold())
                    featureRow("终端", "完整终端仿真（ANSI 颜色、光标定位、Tab 补全、Ctrl+C/D/Z、↑↓ 历史）、软键盘辅助键条与内置触屏键盘兜底，支持 SFTP 式常用运维操作与一键粘贴执行。")
                    featureRow("监控", "免 agent：直接读 /proc 与 df / ps，实时展示 CPU 多核占用、内存与 Swap、磁盘 IO、网络速率、CPU 温度、df -h 分区表与资源占用 TOP 进程，可 1s~10s 自动刷新。")
                    featureRow("AI 会话", "普通问答与设备问答两种模式；设备问答会自动附带实时指标快照，支持流式输出与 Markdown / 代码高亮，AI 给出的命令可一键丢回终端执行（可关闭自动执行）。会话自动保存，可随时回溯、重命名、删除。")

                    Divider()

                    Text("技术实现").font(.caption.bold())
                    Text("SSH 基于 libssh2 直连，密码存入系统钥匙串；指标采集全部通过标准 Linux 命令与 /proc 文件，设备上无需安装任何 agent；AI 走 OpenAI 兼容的 /chat/completions 接口，可接任意服务商或本机 Ollama / LM Studio。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Copyright © 2026 杨源鑫 (Bruce.yang) · All rights reserved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    creditRow("出品", "嵌入式应用研究院", systemImage: "building.2")
                    creditRow("技术博客", "Bruce.yang的嵌入式之旅", systemImage: "book")
                    creditRow("GitHub", "@Yangyuanxin", systemImage: "person.crop.circle")
                    creditRow("License", "GPL-3.0", systemImage: "doc.badge.gearshape")

                    Link(destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) {
                        Label("查看 GNU General Public License v3.0 全文", systemImage: "link")
                            .font(.caption)
                    }
                    Text("本程序为自由软件：你可以依据自由软件基金会发布的 GNU 通用公共许可证第三版（或任何更新版本）的条款重新发布或修改它；本程序基于希望它有用而发布，但不提供任何担保。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .onAppear(perform: load)
        .onDisappear(perform: apply)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    apply()
                    onDismiss?()
                    dismiss()
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private func featureRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("· \(title)").font(.caption).fontWeight(.medium)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
        }
    }

    private func creditRow(_ title: String, _ value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title + "：")
                .foregroundStyle(.secondary)
            Text(value)
            Spacer()
        }
        .font(.caption)
    }

    private func load() {
        let settings = store.aiSettings
        baseURL = settings.baseURL
        apiKey = settings.apiKey
        model = settings.model
        temperature = settings.temperature
        systemPrompt = settings.systemPrompt
    }

    private func apply() {
        store.aiSettings.baseURL = baseURL
        store.aiSettings.apiKey = apiKey
        store.aiSettings.model = model
        store.aiSettings.temperature = temperature
        store.aiSettings.systemPrompt = systemPrompt
        store.save()
    }

    private func testAPI() async {
        apply()
        testing = true
        defer { testing = false }
        var settings = store.aiSettings
        settings.baseURL = baseURL
        settings.apiKey = apiKey
        settings.model = model
        settings.temperature = temperature
        settings.systemPrompt = systemPrompt
        let client = AIClient(settings: settings)
        do {
            var reply = ""
            for try await delta in client.stream(messages: [.system("你只回复两个字：正常"), .user("健康检查")]) {
                reply += delta
                if reply.count > 40 { break }
            }
            testResult = "✅ 接口可用，模型回复：\(reply.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            var message = "❌ \(error.localizedDescription)\n请求地址：\(AIClient.endpoint(for: settings))"
            if "\(error)".contains("404") || error.localizedDescription.contains("404") {
                let probe = await AIClient.probe(baseURL: settings.baseURL, apiKey: settings.apiKey)
                let ok = probe.filter { $0.1 == 200 || $0.1 == 401 || $0.1 == 403 }
                if ok.isEmpty {
                    message += "\n已探测该域名的常见接口前缀，全部不可用：\n"
                        + probe.map { "\($0.1) \($0.0)" }.joined(separator: "\n")
                        + "\n结论：这个域名不提供 OpenAI 兼容接口，请改用预设里的服务商。"
                } else {
                    message += "\n该域名下可用的地址：\n" + ok.map { "\($0.1) \($0.0)" }.joined(separator: "\n")
                }
            }
            testResult = message
        }
    }
}
