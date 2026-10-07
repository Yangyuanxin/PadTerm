import SwiftUI

// MARK: - 侧边设备列表

struct HostListView: View {
    @EnvironmentObject private var store: AppState
    @Binding var selectedID: UUID?
    @State private var showEditor = false
    @State private var editingHost: HostConfig?
    @State private var showSettings = false
    /// 鼠标环境（Catalyst）无法左滑，用确认弹窗删
    @State private var pendingDelete: HostConfig?

    var body: some View {
        List(selection: $selectedID) {
            Section("设备") {
                ForEach(store.hosts) { host in
                    hostRow(host)
                }
                .onMove(perform: move)
                .onDelete(perform: remove)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PadTerm")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEditor = true } label: { Image(systemName: "plus") }
            }
            // 鼠标/键盘环境下用它进入编辑模式，行首就会出现红色删除按钮
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            ToolbarItem(placement: .status) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .alert("删除设备",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let host = pendingDelete { delete(host) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(deletePrompt)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onDismiss: { showSettings = false }) }
        }
        .sheet(isPresented: $showEditor) {
            HostEditorView(host: nil, onDismiss: { showEditor = false }, onSave: { save($0) })
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, onDismiss: { editingHost = nil }, onSave: { update($0) })
        }
    }

    private var deletePrompt: String {
        guard let host = pendingDelete else { return "" }
        return "确定删除「\(host.name)」？钥匙串里保存的密码也会一并清除。"
    }

    private func hostRow(_ host: HostConfig) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.body)
                Text(host.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: host.kind.symbol) }
        .tag(host.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { delete(host) } label: { Label("删除", systemImage: "trash") }
            Button { editingHost = host } label: { Label("编辑", systemImage: "pencil") }
        }
        .contextMenu {
            Button { editingHost = host } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) { pendingDelete = host } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func save(_ host: HostConfig) {
        store.hosts.append(host)
        store.disconnect(host: host)   // 清掉可能存在的旧会话
        store.save()
        selectedID = host.id
    }

    private func update(_ host: HostConfig) {
        if let index = store.hosts.firstIndex(where: { $0.id == host.id }) {
            store.disconnect(host: host)
            store.hosts[index] = host
            store.save()
        }
    }

    private func delete(_ host: HostConfig) {
        store.disconnect(host: host)
        KeychainHelper.delete(identifier: host.id.uuidString)
        store.hosts.removeAll { $0.id == host.id }
        store.save()
        if selectedID == host.id { selectedID = nil }
    }

    private func remove(at offsets: IndexSet) {
        let victims = offsets.map { store.hosts[$0] }
        victims.forEach { delete($0) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        store.hosts.move(fromOffsets: source, toOffset: destination)
        store.save()
    }
}

// MARK: - 新增 / 编辑设备

struct HostEditorView: View {
    var host: HostConfig?
    var onSave: (HostConfig) -> Void
    /// 由弹出方直接关闭自己，避免嵌套导航容器里 dismiss 失效
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostConfig
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?

    init(host: HostConfig?, onDismiss: (() -> Void)? = nil,
         onSave: @escaping (HostConfig) -> Void) {
        self.host = host
        self.onDismiss = onDismiss
        self.onSave = onSave
        var base = host ?? HostConfig(name: "", hostname: "")
        _draft = State(initialValue: base)
        _password = State(initialValue: KeychainHelper.password(for: (host ?? base).id.uuidString) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（例如：Voron 2.4）", text: $draft.name)
                    TextField("主机地址 / IP", text: $draft.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("端口：\(draft.port)", value: $draft.port, in: 1...65535)
                    TextField("用户名", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("认证") {
                    SecureField("密码（保存在系统钥匙串）", text: $password)
                    Toggle("使用密码认证", isOn: $draft.usePassword)
                    Text("root 免密或允许「none」认证的打印机主板/开发板无需填密码，App 会自动优先尝试免密登录，失败后再尝试空密码与密码认证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("备注") {
                    TextField("备注（可选）", text: $draft.note)
                    Stepper("监控刷新间隔：\(String(format: "%.0f", draft.pollInterval)) 秒", value: $draft.pollInterval, in: 1...60, step: 1)
                }
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("测试 SSH 连接")
                            Spacer()
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(draft.hostname.isEmpty || draft.username.isEmpty)

                    if let testResult {
                        Text(testResult)
                            .font(.caption.monospaced())
                            .foregroundStyle(testResult.hasPrefix("✅") ? .green : .red)
                    }
                }
            }
            .navigationTitle(host == nil ? "添加设备" : "编辑设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if !password.isEmpty { KeychainHelper.setPassword(password, for: draft.id.uuidString) }
                        onSave(draft)
                        onDismiss?()
                        dismiss()
                    }
                    .disabled(draft.name.isEmpty || draft.hostname.isEmpty || draft.username.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 620)
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        if !password.isEmpty { KeychainHelper.setPassword(password, for: draft.id.uuidString) }
        let service = SSHService(host: draft)
        do {
            let result = try await service.exec("uname -a && free -m | head -2", timeout: 12)
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            testResult = "✅ 连接成功\n\(text)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
        service.close()
    }
}

// MARK: - 设备详情容器

enum DetailTab: String, CaseIterable, Identifiable {
    case terminal = "终端"
    case monitor = "监控"
    case ai = "AI 会话"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .ai: return "sparkles"
        }
    }
}

struct HostDetailView: View {
    let host: HostConfig
    @EnvironmentObject private var store: AppState

    @StateObject private var terminalVM: TerminalViewModel
    @StateObject private var metricsVM: MetricsViewModel
    @State private var tab: DetailTab = .terminal

    init(host: HostConfig) {
        self.host = host
        let service = AppState.shared.session(for: host)
        _terminalVM = StateObject(wrappedValue: TerminalViewModel(host: host, service: service))
        _metricsVM = StateObject(wrappedValue: MetricsViewModel(host: host, service: service))
    }

    var body: some View {
        TabView(selection: $tab) {
            TerminalScreen(host: host, viewModel: terminalVM)
                .tabItem { Label(DetailTab.terminal.rawValue, systemImage: DetailTab.terminal.symbol) }
                .tag(DetailTab.terminal)

            DashboardView(host: host, viewModel: metricsVM)
                .tabItem { Label(DetailTab.monitor.rawValue, systemImage: DetailTab.monitor.symbol) }
                .tag(DetailTab.monitor)

            AIChatView(host: host, metrics: metricsVM) { command in
                tab = .terminal
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    terminalVM.send(line: command)
                }
            }
            .tabItem { Label(DetailTab.ai.rawValue, systemImage: DetailTab.ai.symbol) }
            .tag(DetailTab.ai)
        }
        .onAppear { if !metricsVM.isRunning { metricsVM.start() } }
        .onDisappear { metricsVM.stop() }
    }
}
