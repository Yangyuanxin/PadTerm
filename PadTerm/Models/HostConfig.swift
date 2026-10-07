import Foundation

/// 一台被管理的远端设备（通常是跑 Klipper/Moonraker 的 Linux 主机）
struct HostConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var hostname: String
    var port: Int = 22
    var username: String = "pi"
    /// 是否使用密码认证（密码本体存在 Keychain，不落磁盘）
    var usePassword: Bool = true
    /// 统一按 Linux/Unix 终端对待，不再区分设备类型（保留字段仅为兼容旧数据）
    var kind: HostKind = .linux
    var note: String = ""
    /// 轮询间隔（秒），用于监控页自动刷新
    var pollInterval: Double = 2.0

    enum HostKind: String, Codable, CaseIterable, Identifiable {
        case printer = "3D打印机"
        case linux = "Linux主机"
        case router = "路由/嵌入式"

        var id: String { rawValue }
        // 统一图标：都是 Linux/Unix 终端
        var symbol: String { "terminal" }
        private var legacy: String {
            switch self {
            case .printer: return "printer.3d"
            case .linux: return "desktopcomputer"
            case .router: return "wifi.router"
            }
        }
    }

    var subtitle: String {
        "\(username)@\(hostname):\(port)"
    }
}

/// Keychain 读写封装（密码不进 JSON 文件）
enum KeychainHelper {
    static func setPassword(_ password: String, for identifier: String) {
        guard let data = password.data(using: .utf8) else { return }
        delete(identifier: identifier)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: identifier,
            kSecAttrService as String: "com.padterm.ssh",
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func password(for identifier: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: identifier,
            kSecAttrService as String: "com.padterm.ssh",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: identifier,
            kSecAttrService as String: "com.padterm.ssh"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 设备列表持久化到 App 沙盒 Documents/hosts.json
enum HostStore {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("hosts.json")
    }

    static func load() -> [HostConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return builtinDemo() }
        do { return try JSONDecoder().decode([HostConfig].self, from: data) }
        catch { return builtinDemo() }
    }

    static func save(_ hosts: [HostConfig]) {
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func builtinDemo() -> [HostConfig] { [] }
}
