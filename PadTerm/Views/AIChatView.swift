import SwiftUI

struct AIChatView: View {
    let host: HostConfig?
    var metrics: MetricsViewModel?
    var onRunCommand: (String) -> Void

    @EnvironmentObject private var store: AppState

    @State private var messages: [AIMessage] = []
    @State private var draft: String = ""
    @State private var mode: AISessionMode = .device
    @State private var streaming = false
    @State private var lastError: String?
    /// 自动到设备上执行 AI 给出的命令（危险命令会被拦截）
    @State private var autoExec = true
    @State private var confirmNewSession = false
    @State private var sessionID = UUID()
    @State private var showHistory = false
    @State private var lastSavedAt: Date?

    private let maxRounds = 4
    private let commandTimeout: TimeInterval = 25

    var body: some View {
        // 关键点：本视图是 TabView 的一个 tab，TabView 子视图不会继承导航栏上下文，
        // 不自己包一层 NavigationStack，下面 .toolbar 里的按钮根本不会渲染。
        NavigationStack {
            VStack(spacing: 0) {
                modeBar
                Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty { emptyHint }
                        ForEach(messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if streaming {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("生成中…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        // 标题固定，避免切换模式时导航栏重排
        .navigationTitle("\(host?.name ?? "设备") · AI 会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { askNewSession() } label: {
                    Label("新会话", systemImage: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { saveCurrentSession(); showHistory = true } label: {
                    Label("会话记录", systemImage: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("开启新会话") { askNewSession() }
                    Button("查看会话记录") { saveCurrentSession(); showHistory = true }
                    Divider()
                    Button(mode == .device ? "切换到普通问答" : "切换到设备问答") {
                        mode = mode == .device ? .general : .device
                    }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ChatHistoryView(currentID: sessionID,
                                onOpen: openSession,
                                onDelete: { ChatSessionStore.delete(id: $0) },
                                onNewSession: { showHistory = false; startNewSession() },
                                onDismiss: { showHistory = false })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showHistory = false }
                        }
                    }
            }
        }
        .onAppear { FileLog.log("AIChatView 启动 build=2026-10-08d（按钮内置在页面顶部条）") }
        .onDisappear(perform: saveCurrentSession)
        .onChange(of: messages.count) { _, _ in saveCurrentSession() }
        .alert("开启新会话？", isPresented: $confirmNewSession) {
            Button("取消", role: .cancel) {}
            Button("开启新会话") { startNewSession() }
        } message: {
            Text("当前 \(messages.count) 条对话将被清空，重新开始一轮问答。")
        }
        }
    }

    // MARK: - 顶部模式条

    /// 顶部条：宽屏（iPad）单行放下全部信息；窄屏（iPhone）自动退化为去掉状态文字的紧凑行
    private var modeBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    modePicker.frame(width: 185).fixedSize()
                    statusText.font(.caption).lineLimit(1)
                    saveStatusText
                    Spacer(minLength: 8)
                    sessionButtons
                }
                HStack(spacing: 8) {
                    modePicker
                        .frame(maxWidth: 185)
                    saveStatusText
                    Spacer(minLength: 6)
                    sessionButtons
                }
            }
            .frame(minHeight: 34)

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
        .animation(.easeInOut(duration: 0.15), value: mode)
    }

    /// 分段控件只放文字：图标+中文在窄屏会被挤成两行，很难看
    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(AISessionMode.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    /// 这两个按钮直接画在页面里，不放 .toolbar：
    /// 本视图嵌在 NavigationSplitView → TabView 中，导航栏工具栏会被外层吞掉，按钮根本不渲染。
    private var sessionButtons: some View {
        HStack(spacing: 8) {
            Button { askNewSession() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button { saveCurrentSession(); showHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            moreMenu
        }
    }

    /// 自动保存状态：单行显示，不再是独立的一整行
    private var saveStatusText: some View {
        HStack(spacing: 4) {
            Image(systemName: lastSavedAt == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(lastSavedAt == nil ? Color.secondary : Color.green)
            if let lastSavedAt {
                Text("已保存 \(lastSavedAt.formatted(.dateTime.hour().minute()))")
            } else {
                Text("自动保存")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// 快照刷新 / 自动执行等设备模式专属控制，收进菜单以省一行
    private var moreMenu: some View {
        Menu {
            Button {
                mode = mode == .device ? .general : .device
            } label: {
                Label(mode == .device ? "切换到普通问答" : "切换到设备问答",
                      systemImage: "arrow.left.arrow.right")
            }
            Divider()
            if mode == .device {
                Button { metrics?.refreshOnce() } label: {
                    Label("刷新快照", systemImage: "arrow.clockwise")
                }
                Button {
                    autoExec.toggle()
                } label: {
                    Label(autoExec ? "取消自动执行命令" : "自动执行命令",
                          systemImage: autoExec ? "checkmark.circle.fill" : "circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var statusText: some View {
        Group {
            if mode == .device {
                if let host {
                    Label(host.subtitle, systemImage: host.kind.symbol)
                        .foregroundStyle(.secondary)
                } else {
                    Label("未绑定设备，仅普通问答可用", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Label("普通问答：不携带设备上下文，也不会执行命令", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 消息

    private func messageRow(_ message: AIMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch message.role {
            case .assistant:
                assistantBubble(message)
            case .user:
                userBubble(message)
            case .system:
                toolCard(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// 命令执行过程 / 输出：左侧灰色卡片，清楚区分「这是工具产生的，不是你说的」
    private func toolCard(_ message: AIMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.content.hasPrefix("📄") ? "doc.text" : "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
            MarkdownView(text: message.content)
                .font(.caption)
        }
        .padding(10)
        .background(Color(uiColor: .systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func userBubble(_ message: AIMessage) -> some View {
        Text(message.content)
            .textSelection(.enabled)
            .padding(12)
            .background(Color.accentColor.opacity(0.16), in: bubbleShape)
            .frame(maxWidth: 620, alignment: .trailing)
    }

    private func assistantBubble(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(text: message.content)
            if !extractCommands(message.content).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(extractCommands(message.content), id: \.self) { command in
                        HStack {
                            Text(command)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                            Spacer()
                            Button {
                                onRunCommand(command)
                            } label: { Label("在终端执行", systemImage: "terminal") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: bubbleShape)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private let bubbleShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("可以开始提问了", systemImage: "sparkles")
                .font(.headline)
            Text(mode == .device
                 ? "例如：这台打印机 CPU 为什么这么高？磁盘快满了吗？Moonraker 服务状态怎么查？\n回复里的命令可以一键丢到终端执行。"
                 : "普通 AI 问答模式，不携带设备上下文。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(mode == .device ? "向 AI 提问这台设备的问题…" : "随便问点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                Button(action: send) {
                    Label("发送", systemImage: "paperplane.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || streaming)
            }
            Text("模型：\(store.aiSettings.model.isEmpty ? "未配置" : store.aiSettings.model)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    // MARK: - 逻辑

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !streaming else { return }
        draft = ""
        lastError = nil
        messages.append(.user(question))

        let modeUsed = mode
        let snapshot: MetricSnapshot? = (modeUsed == .device) ? metrics?.current : nil
        let boundHost = (modeUsed == .device) ? host : nil
        let settings = store.aiSettings

        let history = messages.filter { $0.role != .system }.suffix(16)
        var payload: [AIMessage] = []
        if modeUsed == .device {
            payload.append(DevicePrompt.buildSystem(settings: settings, host: boundHost, snapshot: snapshot))
        } else {
            payload.append(.system(settings.systemPrompt))
        }
        payload.append(contentsOf: history)

        streaming = true
        messages.append(.assistant(""))
        let assistantIndex = messages.count - 1

        Task { @MainActor in
            await runAgent(payload: payload, settings: settings, host: boundHost, assistantIndex: assistantIndex)
            streaming = false
        }
    }

    private func askNewSession() {
        if messages.isEmpty { startNewSession() } else { confirmNewSession = true }
    }

    private func startNewSession() {
        saveCurrentSession()
        messages = []
        draft = ""
        lastError = nil
        streaming = false
        sessionID = UUID()
        metrics?.refreshOnce()
    }

    /// 把当前对话写入会话记录（同 id 覆盖）
    private func saveCurrentSession() {
        guard !messages.isEmpty else { return }
        let title = messages.first(where: { $0.role == .user })?.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "新会话"
        var session = AIChatSession(
            id: sessionID,
            title: String(title.prefix(28)),
            hostName: host?.name ?? "未绑定设备",
            mode: mode.rawValue,
            model: store.aiSettings.model.isEmpty ? "未配置" : store.aiSettings.model
        )
        session.messages = messages
        session.updatedAt = Date()
        ChatSessionStore.upsert(session)
        lastSavedAt = Date()
    }

    private func openSession(_ session: AIChatSession) {
        saveCurrentSession()
        sessionID = session.id
        messages = session.messages
        lastError = nil
        showHistory = false
    }

    /// 代理循环：AI 给命令 → App 自己到设备上执行 → 把真实输出喂回 AI → 再收敛，最多 maxRounds 轮
    private func runAgent(payload: [AIMessage],
                          settings: AISettings,
                          host: HostConfig?,
                          assistantIndex: Int) async {
        var working = payload
        var index = assistantIndex

        for round in 0..<maxRounds {
            let client = AIClient(settings: settings)
            do {
                let stream = client.stream(messages: working)
                for try await delta in stream {
                    messages[index].content += delta
                }
                if messages[index].content.isEmpty {
                    messages[index].content = "（没有返回内容，请检查模型名或接口地址）"
                }
            } catch {
                lastError = error.localizedDescription
                messages[index].content = "❌ \(error.localizedDescription)"
                return
            }

            let reply = messages[index].content
            working.append(.assistant(reply))

            // 只有设备模式 + 开启自动执行 + 已绑定设备，才真的去设备上跑
            guard autoExec, mode == .device, let host else { return }
            let commands = extractCommands(reply)
            guard !commands.isEmpty, round < maxRounds - 1 else { return }

            let service = store.session(for: host)
            var transcript = ""
            for command in commands.prefix(3) {
                if isRisky(command) {
                    transcript += "\n$ \(command)\n（已跳过：命中危险命令规则，需你手动确认）\n"
                    continue
                }
                messages.append(.system("🔧 正在设备上执行：`\(command)`"))
                do {
                    let result = try await service.exec(command, timeout: commandTimeout)
                    let output = Self.truncate(result.stdout.isEmpty ? result.stderr : result.stdout)
                    let tail = result.stdout.isEmpty ? "" : (result.stderr.isEmpty ? "" : "\n[stderr] \(Self.truncate(result.stderr, limit: 1500))")
                    let codeText = result.exitCode.map { "[exit \($0)]" } ?? "[无退出码]"
                    transcript += "\n$ \(command)\n\(output)\(tail)\n\(codeText)\n"
                    messages.append(.system("📄 `\(command)` 的输出：\n```\n\(output)\(tail)\n\(codeText)\n```"))
                } catch {
                    transcript += "\n$ \(command)\n（执行失败：\(error.localizedDescription)）\n"
                    messages.append(.system("⚠️ `\(command)` 执行失败：\(error.localizedDescription)"))
                }
            }

            let followUp = "以下是你在设备上执行命令得到的真实输出（不要臆测，只能依据这些事实）：\n"
                + transcript
                + "\n请基于这些真实输出继续分析。若信息已足够，直接给出结论；若还需补充，继续用 ```bash 代码块给出下一条只读命令。"
            messages.append(.system("⬆️ 已把上面的真实输出交给模型继续分析"))
            working.append(.user(followUp))

            messages.append(.assistant(""))
            index = messages.count - 1
        }
    }

    /// 输出截断，避免把超长日志塞爆上下文
    private static func truncate(_ text: String, limit: Int = 6000) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "\n…（已截断 \(text.count - limit) 字符）"
    }

    /// 危险命令拦截：命中的不自动执行，交给用户手动点「在终端执行」
    private func isRisky(_ command: String) -> Bool {
        let lower = command.lowercased()
        let blocked = ["rm ", "rm\t", "rm -", "mkfs", "dd ", "dd=", "shutdown", "reboot", "halt", "init ",
                       "systemctl stop", "systemctl restart", "systemctl disable", "killall", "pkill",
                       "kill -9", "chmod 777", "chown -r", "userdel", "passwd", "fdisk", "parted",
                       "swapoff", "iptables", "crontab -r", "shutdown -", ":(){", "mv /", "mv /*"]
        if blocked.contains(where: { lower.contains($0) }) { return true }
        // 管道喂给 shell 执行 / 覆写系统文件
        if lower.contains("| sh") || lower.contains("|sh") || lower.contains("| bash") || lower.contains("curl ") && lower.contains("sh") {
            return true
        }
        if lower.contains("> /dev/") || lower.contains("> /etc/") || lower.contains("> /boot/") { return true }
        return false
    }

    /// 从 ```bash / ```sh 代码块中提取可执行命令
    private func extractCommands(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inside = false
        var language = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside, trimmed.hasPrefix("```") {
                inside = true
                language = trimmed.dropFirst(3).lowercased()
                current = ""
                continue
            }
            if inside, trimmed.hasPrefix("```") {
                let command = current.trimmingCharacters(in: .whitespacesAndNewlines)
                let lang = language.isEmpty || language == "bash" || language == "sh" || language == "shell" || language == "zsh"
                if lang, !command.isEmpty { result.append(command) }
                inside = false
                continue
            }
            if inside { current += line + "\n" }
        }
        return result
    }
}
