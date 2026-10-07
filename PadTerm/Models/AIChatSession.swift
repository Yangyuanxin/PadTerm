import Foundation

/// 一次 AI 会话的完整记录（含命令执行过程）
struct AIChatSession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var hostName: String
    var mode: String
    var model: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [AIMessage] = []

    var summary: String {
        let last = messages.last(where: { $0.role == .assistant })?.content ?? ""
        let flat = last.replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(60))
    }

    var commandCount: Int {
        messages.filter { $0.content.hasPrefix("🔧 正在设备上执行") }.count
    }
}

/// 会话记录持久化（Documents 目录 JSON）
enum ChatSessionStore {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ai_sessions.json")
    }

    static func load() -> [AIChatSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([AIChatSession].self, from: data)) ?? []
    }

    static func save(_ sessions: [AIChatSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 新增或更新（同一 id 覆盖），按更新时间倒序
    static func upsert(_ session: AIChatSession) {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == session.id }) {
            all[index] = session
        } else {
            all.insert(session, at: 0)
        }
        all.sort { $0.updatedAt > $1.updatedAt }
        if all.count > 100 { all = Array(all.prefix(100)) }
        save(all)
    }

    static func delete(id: UUID) {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
    }
}
