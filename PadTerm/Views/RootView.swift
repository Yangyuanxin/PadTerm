import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppState
    @State private var selectedID: UUID? = UserDefaults.standard.uuid(forKey: "lastSelectedHostUUID")

    var body: some View {
        NavigationSplitView {
            HostListView(selectedID: $selectedID)
        } detail: {
            if let host = store.hosts.first(where: { $0.id == selectedID }) {
                HostDetailView(host: host)
            } else {
                PlaceholderView(selectedID: $selectedID)
            }
        }
        .onChange(of: selectedID) { newValue in
            // 记住上次选中的设备，重启后自动进入终端
            UserDefaults.standard.set(newValue?.uuidString, forKey: "lastSelectedHostUUID")
        }
        .onAppear {
            // 首次启动（无历史记录）自动选中第一台设备，直接进入终端
            if selectedID == nil { selectedID = store.hosts.first?.id }
        }
    }
}

extension UserDefaults {
    func uuid(forKey key: String) -> UUID? {
        guard let string = string(forKey: key) else { return nil }
        return UUID(uuidString: string)
    }
}

private struct PlaceholderView: View {
    @EnvironmentObject private var store: AppState
    @Binding var selectedID: UUID?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("PadTerm")
                .font(.largeTitle.bold())
            Text("在 iPad 上通过 SSH 管理 3D 打印机 / Linux 设备：\n终端交互 + 指标可视化 + AI 会话分析")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button {
                    selectedID = store.hosts.first?.id
                } label: {
                    Label(store.hosts.isEmpty ? "请在左侧 + 添加设备" : "选择第一台设备", systemImage: "chevron.left")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.hosts.isEmpty)
                Button { showSettings = true } label: { Label("配置 AI 接口", systemImage: "gearshape") }
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("终端：支持 ANSI 颜色、Tab 补全、Ctrl+C / ↑↓ 历史等快捷键")
                bullet("监控：CPU / 内存 / 存储 / IO / 网络 / 温度 / TOP 进程，自动刷新")
                bullet("AI：设备问答模式会带上实时指标快照，命令可一键丢回终端")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            VStack(spacing: 2) {
                Text("Copyright © 2026 杨源鑫 (Bruce.yang) · All rights reserved")
                Text("出品：嵌入式应用研究院 · 技术博客：Bruce.yang的嵌入式之旅 · GitHub：@Yangyuanxin")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onDismiss: { showSettings = false }) }
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .labelStyle(.titleAndIcon)
    }
}
