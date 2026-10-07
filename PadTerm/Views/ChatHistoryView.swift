import SwiftUI

/// 会话记录抽屉：切换 / 重命名 / 删除历史会话
struct ChatHistoryView: View {
    let currentID: UUID
    var onOpen: (AIChatSession) -> Void
    var onDelete: (UUID) -> Void
    var onNewSession: () -> Void
    /// 由弹出方直接关闭自己，避免嵌套导航容器里 dismiss 失效
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AIChatSession] = []
    @State private var renaming: AIChatSession?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                Button {
                    onNewSession()
                } label: {
                    Label("开启新会话", systemImage: "square.and.pencil")
                }
            }

            Section("历史会话") {
                if sessions.isEmpty {
                    Text("还没有会话记录").foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    Button {
                        onOpen(session)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if session.id == currentID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                                Text(session.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Spacer()
                                Text(session.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(session.hostName) · \(session.mode) · \(session.model) · \(session.messages.count) 条"
                                 + (session.commandCount > 0 ? " · 执行 \(session.commandCount) 条命令" : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !session.summary.isEmpty {
                                Text(session.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDelete(session.id)
                            sessions = ChatSessionStore.load()
                        } label: { Label("删除", systemImage: "trash") }
                        Button {
                            renaming = session
                            renameText = session.title
                        } label: { Label("重命名", systemImage: "pencil") }
                        .tint(.orange)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("会话记录")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    sessions = ChatSessionStore.load()
                    onDismiss?()
                    dismiss()
                }
            }
        }
        .onAppear { sessions = ChatSessionStore.load() }
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil },
                                                 set: { if !$0 { renaming = nil } })) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if var target = renaming {
                    target.title = renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? target.title : renameText
                    ChatSessionStore.upsert(target)
                    sessions = ChatSessionStore.load()
                }
                renaming = nil
            }
        }
    }
}
