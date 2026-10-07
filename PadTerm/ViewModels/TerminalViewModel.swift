//
//  TerminalViewModel.swift
//  PadTerm
//
//  终端会话：SSH PTY shell ↔ TerminalEmulator（移植自 SerialStudio）
//  数据流：远端输出 → emulator.feed → 渲染视图刷新；本地输入 → session 下发
//

import SwiftUI
import UIKit

@MainActor
final class TerminalViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected(String)
        case failed(String)
    }

    let quickCommands = [
        "uname -a", "free -h", "df -h", "ls -la", "top -bn1",
        "ps aux | head -20", "dmesg | tail -20", "cat /proc/cpuinfo | head -20",
        "history | tail -20", "ip addr"
    ]

    /// 终端仿真器（参考 SerialStudio 实现）
    let emulator = TerminalEmulator(cols: 80, rows: 24)

    @Published private(set) var status: Status = .idle
    @Published var fontSize: Double = 14
    @Published private(set) var terminalTitle = ""
    @Published var hint = "打开设备后即可像 screen / minicom 一样登录终端"

    /// 收发原始字节诊断日志（排查输入/回显问题的现场记录）
    @Published private(set) var diagnostics: [String] = []
    @Published var showDiagnostics = false
    private let diagTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// 渲染视图由 TerminalCanvas 注入，用于触发重绘
    weak var renderView: TerminalRenderView?
    /// 键盘焦点状态（终端视图自己成为第一响应者）
    @Published var isKeyboardVisible = false
    /// 系统软键盘是否真的显示出来了（按键盘实际高度判定，h=0 表示 iPadOS 认为有外接键盘）
    @Published var systemKeyboardShown = false
    /// 点击终端时请求弹出键盘
    var onRequestKeyboard: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?

    private let host: HostConfig
    private let service: SSHService
    private var session: ShellSession?
    private var sizeSyncTask: Task<Void, Never>?

    // 命令历史
    private var history: [String] = []
    private var historyCursor: Int?

    var isSessionActive: Bool { session != nil }
    var cols: Int { emulator.buffer.cols }
    var rows: Int { emulator.buffer.rows }

    init(host: HostConfig, service: SSHService) {
        self.host = host
        self.service = service

        // 远端查询（光标位置、设备属性、DSR）要原样回写，否则提示符会错位
        emulator.onResponse = { [weak self] bytes in
            Task { @MainActor in self?.session?.write(Data(bytes)) }
        }
        emulator.onTitleChange = { [weak self] title in
            Task { @MainActor in self?.terminalTitle = title }
        }
        emulator.onBell = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hint = "远端发送了响铃（BEL）"
            }
        }
    }

    // MARK: - 连接

    func connect() {
        guard !isSessionActive else { return }
        sizeSyncTask?.cancel()
        status = .connecting
        hint = "正在连接 \(host.username)@\(host.hostname)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let shell = try await self.service.openShell(cols: self.cols, rows: self.rows)
                self.attach(shell)
            } catch {
                self.status = .failed(error.localizedDescription)
                self.systemMessage("连接失败：\(error.localizedDescription)")
            }
        }
    }

    private func attach(_ shell: ShellSession) {
        session = shell
        shell.onOutput = { [weak self] data in
            Task { @MainActor in self?.handleOutput(data) }
        }
        shell.onClose = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.session = nil
                if case .connected = self.status {
                    self.systemMessage("\r\n[连接已断开]")
                }
                self.status = .idle
                self.hint = "连接已断开"
                self.renderView?.refresh()
            }
        }
        shell.onError = { [weak self] text in
            Task { @MainActor in self?.systemMessage("[会话异常：\(text)]") }
        }
        status = .connected("已连接 \(host.username)@\(host.hostname)")
        hint = "点终端弹出键盘，直接敲命令；窗口变化自动同步远端（敲 stty size 可核对）"
        systemMessage("已连接 \(host.username)@\(host.hostname)")
        renderView?.refresh()
        // 连接成功后自动唤起键盘，像真正的终端一样直接敲
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onRequestKeyboard?()
        }
    }

    func disconnect() {
        sizeSyncTask?.cancel()
        session?.close()
        session = nil
        status = .idle
        systemMessage("[已断开连接]")
        hint = "已手动断开"
    }

    // MARK: - 数据

    private func handleOutput(_ data: Data) {
        logDiag(direction: "RX", bytes: [UInt8](data))
        emulator.feed([UInt8](data))
        renderView?.refresh()
        if UserDefaults.standard.bool(forKey: "padterm.debugGrid") { renderView?.dumpGrid("rx") }
    }

    /// 键盘事件路径调试（presses/insert/delete 是否到达终端视图）
    func logUIEvent(_ text: String) {
        guard showDiagnostics else { return }
        diagnostics.append("\(diagTimeFormatter.string(from: Date())) UI \(text)")
        if diagnostics.count > 60 {
            diagnostics.removeFirst(diagnostics.count - 60)
        }
    }

    /// 记录收发原始字节（最多留 60 条；高频流控节流，避免日志本身拖垮 UI）
    private func logDiag(direction: String, bytes: [UInt8]) {
        guard showDiagnostics, !bytes.isEmpty else { return }
        let now = Date()
        if let last = lastDiagTime[direction], now.timeIntervalSince(last) < 0.15 {
            diagDropped += 1
            return
        }
        lastDiagTime[direction] = now
        let hex = bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = bytes.prefix(24).map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }
        diagnostics.append("\(diagTimeFormatter.string(from: now)) \(direction) \(bytes.count)B [\(hex)] \(String(ascii))")
        if diagDropped > 0 {
            diagnostics.append("…（已省略 \(diagDropped) 条高频日志）")
            diagDropped = 0
        }
        if diagnostics.count > 60 {
            diagnostics.removeFirst(diagnostics.count - 60)
        }
    }

    private var lastDiagTime: [String: Date] = [:]
    private var diagDropped = 0

    /// 本地系统提示（灰色斜线索）
    func systemMessage(_ text: String) {
        var bytes: [UInt8] = Array("\u{1B}[90m".utf8)
        bytes.append(contentsOf: Array(text.utf8))
        bytes.append(contentsOf: Array("\u{1B}[0m\r\n".utf8))
        emulator.feed(bytes)
        renderView?.refresh()
    }

    // MARK: - 尺寸

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != self.cols || rows != self.rows else { return }
        emulator.buffer.resize(cols: cols, rows: rows)
        hint = "终端尺寸 \(cols)×\(rows)（本地），远端窗口已同步"
        renderView?.refresh()

        guard let session else { return }
        // 节流向远端下发窗口尺寸，避免拖动时刷屏
        sizeSyncTask?.cancel()
        sizeSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.session?.resize(cols: cols, rows: rows)
        }
    }

    // MARK: - 发送

    func sendBytes(_ bytes: [UInt8]) {
        guard let session, !bytes.isEmpty else { return }
        logDiag(direction: "TX", bytes: bytes)
        let hex = bytes.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        FileLog.log("TX \(bytes.count)B [\(hex)]")
        session.write(Data(bytes))
    }

    /// 恢复被 ^S 冻结的输出流 / 复位终端状态
    func resumeFlowAndReset() {
        sendBytes([0x11])          // ^Q：解除 ^S 流控
        send(text: "stty sane\r")  // 复位行规程，恢复回显
        hint = "已发送 ^Q + stty sane，若仍无回显请看诊断日志"
    }

    /// 把剪贴板内容直接当一行命令执行（键盘彻底失灵时的兜底输入通道）
    func pasteAndRun() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            hint = "剪贴板是空的"
            return
        }
        send(line: text)
        hint = "已执行剪贴板命令：\(text)"
    }

    func send(text: String) {
        sendBytes(Array(text.utf8))
    }

    /// 发送一行命令（回车结尾），并记录历史
    func send(line: String) {
        guard !line.isEmpty else { return }
        recordHistory(line)
        sendBytes(Array((line + "\r").utf8))
    }

    func sendControl(_ byte: UInt8) { sendBytes([byte]) }

    // MARK: - 清屏 / 复制

    func clearScreen() {
        emulator.buffer.clearScreen()
        renderView?.refresh()
        sendBytes([0x0C])   // Ctrl+L：让对端重绘提示符
    }

    func copyVisibleText() {
        renderView?.selectAllContent()
        renderView?.copySelection()
        hint = "已复制整个终端内容"
    }

    func requestKeyboard() {
        onRequestKeyboard?()
    }

    /// 是否允许「窗口重新回到前台时自动抢焦点」。切走终端 tab 时必须关掉，
    /// 否则 AI 会话页面刚收掉的键盘会被终端立刻重新顶起来。
    func setAutoFocusEnabled(_ enabled: Bool) {
        renderView?.autoFocusOnWindowKey = enabled
    }

    func dismissKeyboard() {
        #if targetEnvironment(macCatalyst)
        // Mac 上没有软键盘，「收键盘」= 失去第一响应者 = 完全无法输入，禁止
        #else
        onDismissKeyboard?()
        #endif
    }

    func toggleKeyboard() {
        #if targetEnvironment(macCatalyst)
        // Mac 上点击终端只做一件事：确保终端持有键盘焦点
        onRequestKeyboard?()
        #else
        isKeyboardVisible ? onDismissKeyboard?() : onRequestKeyboard?()
        #endif
    }

    // MARK: - 命令历史

    private func recordHistory(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if history.last != line { history.append(line) }
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyCursor = nil
    }

    /// 上一条命令（首次调用返回最近一条）
    func previousCommand(current: String) -> String? {
        guard !history.isEmpty else { return nil }
        if historyCursor == nil {
            if !current.isEmpty, history.last != current { history.append(current) }
            historyCursor = history.count - 1
        } else if let index = historyCursor, index > 0 {
            historyCursor = index - 1
        }
        guard let index = historyCursor, history.indices.contains(index) else { return nil }
        return history[index]
    }

    /// 下一条命令
    func nextCommand() -> String? {
        guard let index = historyCursor else { return nil }
        if index < history.count - 1 {
            historyCursor = index + 1
            return history[historyCursor ?? index]
        }
        historyCursor = nil
        return ""
    }
}
