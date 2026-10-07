import SwiftUI

struct TerminalScreen: View {
    let host: HostConfig
    @ObservedObject var viewModel: TerminalViewModel
    @State private var showTouchKeyboard = false

    /// 设备形态：iPhone 用系统软键盘（全键盘 / 九宫格由用户在系统键盘上切换）；
    /// iPad 特殊处理（系统键盘可能被判定为「有外接键盘」而不弹出，需要内置键盘兜底）；
    /// Mac Catalyst 有硬件键盘，不需要任何软键盘入口。
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }
    /// 只有 iPad 需要内置触屏键盘兜底
    private var needsTouchKeyboardFallback: Bool { isPad && !isMac }
    /// Mac 上不需要「键盘」浮动按钮
    private var needsKeyboardButton: Bool { !isMac }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            ZStack(alignment: .topTrailing) {
                TerminalCanvas(model: viewModel, usesKeyboardAccessory: isPhone)
                    .background(Color(uiColor: TerminalTheme.dark.background))
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.toggleKeyboard() }
                connectionBadge
                    .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                // iPhone 调起系统软键盘；iPad 若系统键盘不弹（判定有外接键盘）再切内置键盘
                if needsKeyboardButton && !viewModel.systemKeyboardShown && !showTouchKeyboard {
                    Button {
                        viewModel.requestKeyboard()
                        guard needsTouchKeyboardFallback else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            if !viewModel.systemKeyboardShown { withAnimation { showTouchKeyboard = true } }
                        }
                    } label: {
                        Label("键盘", systemImage: "keyboard")
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(14)
                }
            }
            .overlay(alignment: .bottom) {
                // 系统键盘高度为 0（iPadOS 认为有外接键盘）时的兜底输入，仅 iPad
                if needsTouchKeyboardFallback && showTouchKeyboard {
                    TouchKeyboard(
                        onBytes: { viewModel.sendBytes($0) },
                        onText: { viewModel.sendBytes([UInt8]($0.utf8)) },
                        onHide: { withAnimation { showTouchKeyboard = false } }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .overlay(alignment: .topLeading) {
                if viewModel.showDiagnostics {
                    DiagnosticsOverlay(lines: viewModel.diagnostics)
                        .padding(.leading, 8)
                        .padding(.top, 4)
                }
            }
        }
        // iPad：键盘弹出时不压缩终端（布局变化 → 行列变化 → 向远端 resize → 画面跳动）
        // iPhone：屏幕小，必须让出键盘空间，否则大半屏被键盘盖住看不到输出
        .ignoreKeyboardOnSmallScreen(isPhone)
        .navigationTitle(terminalNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !viewModel.isSessionActive { viewModel.connect() }
            // 进页面即让终端拿到键盘焦点（此前焦点闭包未接线，按键全部丢失）
            // iPhone / iPad 会因此弹出系统软键盘；Mac 上无副作用
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { viewModel.requestKeyboard() }
            // iPad 专用：系统键盘若始终不出现（判定有外接键盘时键盘高度为 0），切换到内置触屏键盘
            if needsTouchKeyboardFallback {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if !viewModel.systemKeyboardShown { withAnimation { showTouchKeyboard = true } }
                }
            }
        }
        .onChange(of: viewModel.systemKeyboardShown) { shown in
            // 系统键盘真的出来了就收起内置键盘，避免两层叠着
            if shown { withAnimation { showTouchKeyboard = false } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: viewModel.toggleKeyboard) {
                    Image(systemName: viewModel.isKeyboardVisible ? "keyboard.fill" : "keyboard")
                }
                Button {
                    if viewModel.isSessionActive { viewModel.disconnect() } else { viewModel.connect() }
                } label: {
                    Label(viewModel.isSessionActive ? "断开" : "连接",
                          systemImage: viewModel.isSessionActive ? "xmark.circle" : "cable.connector")
                }
                Menu {
                Button("复制全部终端内容") { viewModel.copyVisibleText() }
                Divider()
                Button("恢复终端（^Q + stty sane）") { viewModel.resumeFlowAndReset() }
                Button("执行剪贴板命令") { viewModel.pasteAndRun() }
                Divider()
                Button(viewModel.showDiagnostics ? "隐藏收发日志" : "显示收发日志") {
                    viewModel.showDiagnostics.toggle()
                }
                    Button("清屏 (Ctrl+L)") { viewModel.clearScreen() }
                    Divider()
                    Menu("字号：\(Int(viewModel.fontSize))pt") {
                        ForEach([10, 12, 14, 16, 18, 22, 26], id: \.self) { size in
                            Button("\(size) pt") { viewModel.fontSize = Double(size) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var terminalNavigationTitle: String {
        viewModel.terminalTitle.isEmpty
            ? "\(host.name) · 终端"
            : "\(host.name) · \(viewModel.terminalTitle)"
    }

    /// 压成单行的状态条：状态 + 提示 + 终端尺寸都在一行，把纵向空间留给终端
    private var statusBanner: some View {
        HStack(spacing: 8) {
            switch viewModel.status {
            case .idle:
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("未连接").font(.caption)
            case .connecting:
                ProgressView().controlSize(.small)
                Text("正在通过 SSH 连接 \(host.subtitle)…").font(.caption)
            case .connected(let text):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(text).font(.caption)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(text).font(.caption).foregroundStyle(.red)
            }
            Text(viewModel.hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            Text("\(viewModel.cols)×\(viewModel.rows)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var connectionBadge: some View {
        if case .connecting = viewModel.status {
            ProgressView().tint(.white)
        }
    }

    // MARK: - 控制键

    // MARK: - 输入区
    // 底部预设功能键行已移除：终端视图本身是第一响应者（UIKeyInput），
    // Esc/Tab/Ctrl+字母/方向键 全部由软键盘上方的辅助键条和硬件键盘提供。

    // 终端视图本身即输入目标（UIKeyInput），无需底部输入框：
    // 直接敲即是 shell 行编辑，↑↓ Tab Ctrl 全部由远端的 readline/bash 处理。
}

private extension View {
    /// iPhone 小屏必须让出系统键盘的空间；iPad 保持不压缩（避免终端行列变化导致画面跳动）
    @ViewBuilder func ignoreKeyboardOnSmallScreen(_ isSmallScreen: Bool) -> some View {
        if isSmallScreen { self } else { self.ignoresSafeArea(.keyboard, edges: .bottom) }
    }
}

/// 收发原始字节诊断浮层（排查输入/回显问题时打开）
private struct DiagnosticsOverlay: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green)
                            .id(index)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .background(Color.black.opacity(0.78))
            .cornerRadius(6)
            .onChange(of: lines.count) { _ in
                if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
        }
    }
}
