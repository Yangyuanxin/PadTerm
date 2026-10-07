import SwiftUI

@main
struct PadTermApp: App {
    @StateObject private var store = AppState.shared

    init() {
        FileLog.clear()
        FileLog.log("PadTerm 启动")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

/// 全局状态：设备列表、SSH 会话缓存、AI 配置
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hosts: [HostConfig] = []
    @Published var aiSettings = AISettings.load()

    /// key 为 host.id；同一台设备复用一条 SSH 连接（多个 exec / shell 复用）
    private var sessions: [UUID: SSHService] = [:]
    private let lock = NSLock()

    init() {
        hosts = HostStore.load()
    }

    func save() {
        HostStore.save(hosts)
        aiSettings.persist()
    }

    // MARK: - 会话管理

    func session(for host: HostConfig) -> SSHService {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[host.id] { return existing }
        let service = SSHService(host: host)
        sessions[host.id] = service
        return service
    }

    func disconnect(host: HostConfig) {
        lock.lock()
        let service = sessions.removeValue(forKey: host.id)
        lock.unlock()
        service?.close()
    }
}
