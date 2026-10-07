//
//  TerminalRenderView.swift
//  PadTerm
//
//  终端渲染视图，**移植自 SerialStudio（uart_tools）的 AppKit 版本**，
//  针对 iPadOS / Mac Catalyst 改为 UIKit 实现：直接绘制字符网格，
//  支持 ANSI 颜色、粗体/斜体/下划线/删除线/反显/隐藏、宽字符、滚动回滚、
//  光标闪烁、长按拖选复制与双指缩放字号。
//

import SwiftUI
import UIKit

// MARK: - 渲染视图

/// 必须显式声明 UIKeyInput：只实现 insertText/deleteBackward/hasText 而不声明协议的话，
/// UIKit 不会把它当作文本输入对象 —— becomeFirstResponder 会返回 true，但系统软键盘永远不弹出。
final class TerminalRenderView: UIView, UIKeyInput, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    let emulator: TerminalEmulator
    let theme: TerminalTheme = .dark

    var fontSize: CGFloat {
        didSet { updateFontMetrics(); setNeedsDisplay() }
    }

    /// 网格尺寸变化（列、行）
    var onResize: ((Int, Int) -> Void)?
    /// 双指缩放调整字号
    var onFontSizeChange: ((CGFloat) -> Void)?
    /// 单击终端（唤起输入）
    var onTap: (() -> Void)?
    /// 选中并复制
    var onCopy: ((String) -> Void)?
    /// 直连终端的按键输入（字节原样下发到 shell）
    var onInput: (([UInt8]) -> Void)?
    /// 键盘焦点变化
    var onFocusChange: ((Bool) -> Void)?
    /// 输入路径调试事件（presses/insert/delete 何时到达）
    var onDebugEvent: ((String) -> Void)?

    // MARK: 键盘输入属性（作为第一响应者直接接收按键，不用外部输入框）

    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    // 必须用系统完整键盘：.asciiCapable 会显示精简版 ASCII 键盘（键位不全）
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false
    var textContentType: UITextContentType?

    weak var scrollView: UIScrollView? {
        didSet { scrollView?.backgroundColor = theme.background }
    }

    private var baseFont: UIFont
    private var boldFont: UIFont
    private var italicFont: UIFont
    private var cellWidth: CGFloat = 8
    private var lineHeight: CGFloat = 18
    /// 文字排版框相对 cell 顶部的 y 偏移（垂直居中）
    private var textTopOffset: CGFloat = 2

    private var blinkTimer: Timer?
    private var blinkOn = true

    private struct Selection {
        var startRow: Int
        var startCol: Int
        var endRow: Int
        var endCol: Int

        var isEmpty: Bool { startRow == endRow && startCol == endCol }

        var ordered: (row0: Int, col0: Int, row1: Int, col1: Int) {
            if startRow < endRow || (startRow == endRow && startCol <= endCol) {
                return (startRow, startCol, endRow, endCol)
            }
            return (endRow, endCol, startRow, startCol)
        }
    }

    private var selection: Selection?
    private var isSelecting = false
    private var pinchBaseSize: CGFloat?

    init(emulator: TerminalEmulator, fontSize: CGFloat) {
        self.emulator = emulator
        self.fontSize = fontSize
        self.baseFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        self.italicFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: .zero)
        self.italicFont = Self.makeItalic(base: baseFont)
        isOpaque = true
        backgroundColor = theme.background
        contentMode = .redraw
        clearsContextBeforeDrawing = true
        updateFontMetrics()
        setupGestures()
        startBlink()
        // Mac 上窗口失焦再点回来时，UIKit 不会自动恢复第一响应者，必须自己补聚焦
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.autoFocusOnWindowKey else { return }
            FileLog.log("windowDidBecomeKey -> refocus, wasResponder=\(self.isFirstResponder)")
            self.showKeyboard()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { blinkTimer?.invalidate() }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - 直连键盘输入（iSH/Blink 模式：终端自己就是对焦的那一个）

    var hasText: Bool { true }

    /// 窗口重新成为 key 时是否自动补聚焦（连接成功/点击终端后置 true）
    var autoFocusOnWindowKey = true

    func insertText(_ text: String) {
        onDebugEvent?("insert \(text.debugDescription)")
        FileLog.log("insertText \(text.debugDescription)")
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r": bytes.append(0x0D)   // 软键盘回车 → CR（pty 只认 CR）
            case "\t": bytes.append(0x09)
            default: bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        guard !bytes.isEmpty else { return }
        scrollToBottomIfNeeded()
        onInput?(bytes)
    }

    func deleteBackward() {
        onDebugEvent?("deleteBackward")
        FileLog.log("deleteBackward")
        onInput?([0x7F])   // DEL，readline / vim 都按 DEL 解释退格
    }

    // MARK: 硬件键盘

    /// HID 键码 → 逃逸序列
    private static let hidMap: [UIKeyboardHIDUsage: [UInt8]] = {
        func esc(_ body: String) -> [UInt8] { Array("\u{1B}\(body)".utf8) }
        return [
            .keyboardEscape: [0x1B],
            .keyboardTab: [0x09],
            .keyboardReturnOrEnter: [0x0D],
            .keyboardDeleteOrBackspace: [0x7F],
            .keyboardDeleteForward: esc("[3~"),
            .keyboardInsert: esc("[2~"),
            .keyboardUpArrow: esc("[A"),
            .keyboardDownArrow: esc("[B"),
            .keyboardRightArrow: esc("[C"),
            .keyboardLeftArrow: esc("[D"),
            .keyboardHome: esc("[H"),
            .keyboardEnd: esc("[F"),
            .keyboardPageUp: esc("[5~"),
            .keyboardPageDown: esc("[6~"),
            .keyboardF1: esc("OP"), .keyboardF2: esc("OQ"), .keyboardF3: esc("OR"), .keyboardF4: esc("OS"),
            .keyboardF5: esc("[15~"), .keyboardF6: esc("[17~"), .keyboardF7: esc("[18~"),
            .keyboardF8: esc("[19~"), .keyboardF9: esc("[20~"), .keyboardF10: esc("[21~"),
            .keyboardF11: esc("[23~"), .keyboardF12: esc("[24~")
        ]
    }()

    /// UIKeyCommand.input → 序列（与 hidMap 保持一致）
    private static let inputMap: [String: String] = [
        UIKeyCommand.inputEscape: "\u{1B}",
        UIKeyCommand.inputUpArrow: "\u{1B}[A",
        UIKeyCommand.inputDownArrow: "\u{1B}[B",
        UIKeyCommand.inputRightArrow: "\u{1B}[C",
        UIKeyCommand.inputLeftArrow: "\u{1B}[D",
        UIKeyCommand.inputHome: "\u{1B}[H",
        UIKeyCommand.inputEnd: "\u{1B}[F",
        UIKeyCommand.inputPageUp: "\u{1B}[5~",
        UIKeyCommand.inputPageDown: "\u{1B}[6~"
    ]

    override var keyCommands: [UIKeyCommand]? {
        var list: [UIKeyCommand] = []
        for (input, body) in Self.inputMap {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKeyCommand(_:)))
            list.append(command)
        }
        // Ctrl+字母 → 控制字节；⌥+字母 → ESC+字母（Meta，readline 的 yank 等要用）
        for value in UInt8(1)...26 {
            let letter = String(UnicodeScalar(UInt8(96) + value))
            list.append(UIKeyCommand(input: letter, modifierFlags: .control, action: #selector(handleKeyCommand(_:))))
            list.append(UIKeyCommand(input: letter, modifierFlags: .alternate, action: #selector(handleKeyCommand(_:))))
        }
        // Tab（硬件 Tab 会被焦点系统截走，这里显式声明）
        list.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleKeyCommand(_:))))
        // ⌘ 组合：既能在 iPad 外接键盘用，也会生成 Mac 菜单栏里的编辑项
        list.append(UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(handleKeyCommand(_:))))
        list.append(UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(handleKeyCommand(_:))))
        list.append(UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(handleKeyCommand(_:))))
        list.append(UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(handleKeyCommand(_:))))
        return list
    }

    private func handleCommandKey(_ input: String) {
        switch input {
        case "c": copy(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        case "k": send([0x0C])
        default: break
        }
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input, input.count == 1 else { return }
        let flags = command.modifierFlags
        if flags.contains(.command) { handleCommandKey(input); return }
        if flags.contains(.control) {
            guard let ascii = input.utf8.first, ascii >= 97, ascii <= 122 else { return }
            send([ascii - 96])
            return
        }
        if flags.contains(.alternate) {
            send([0x1B] + Array(input.utf8))
            return
        }
        if input == "\t" { send([0x09]); return }
        if input == "\u{1B}" { send([0x1B]); return }
        if let body = Self.inputMap[input] { send(Array(body.utf8)) }
    }

    /// 未被 UIKeyCommand 接管的按键（某些键盘/输入法组合）
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key {
            let info = "presses keyCode=\(key.keyCode.rawValue) chars=\(key.characters.debugDescription) flags=\(key.modifierFlags.rawValue)"
            onDebugEvent?(info)
            FileLog.log(info)
        } else {
            FileLog.log("presses (no key info) count=\(presses.count)")
        }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            // 特殊键：HID 键码直接映射
            if let bytes = Self.hidMap[key.keyCode] {
                if key.keyCode == .keyboardDeleteOrBackspace {
                    deleteBackward()
                } else {
                    send(bytes)
                }
                handled = true
                continue
            }
            #if targetEnvironment(macCatalyst)
            // Catalyst 不会把硬件字符键桥接到 insertText（回车这类特殊键反而能到 pressesBegan），
            // 所以字符输入必须在这里自己转，否则字母/数字/符号全部打不进去
            let flags = key.modifierFlags
            if flags.contains(.command) || flags.contains(.alphaShift) { continue } // ⌘ 组合交给系统
            if flags.contains(.control), let c = key.charactersIgnoringModifiers.lowercased().utf8.first,
               (97...122).contains(c) {
                send([c - 96])
                handled = true
                continue
            }
            if flags.contains(.alternate) {
                send([0x1B] + Array(key.charactersIgnoringModifiers.utf8))
                handled = true
                continue
            }
            if !key.characters.isEmpty {
                insertText(key.characters)
                handled = true
            }
            #endif
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let selectAll = UIAction(title: "全选并复制") { _ in self?.selectAllContent(); self?.copySelection() }
            let paste = UIAction(title: "粘贴") { _ in self?.paste(nil) }
            let clear = UIAction(title: "清屏") { _ in self?.send([0x0C]) }
            return UIMenu(children: [selectAll, paste, clear])
        }
    }

    // MARK: 系统编辑快捷键（⌘C / ⌘V）

    override func copy(_ sender: Any?) {
        if let selection, !selection.isEmpty { copySelection(); return }
        selectAllContent()
        copySelection()
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        insertText(text)
    }

    override func selectAll(_ sender: Any?) {
        selectAllContent()
    }

    // MARK: 键盘可见性：区分「拿到焦点」与「系统键盘真的显示出来了」

    /// 系统键盘实际高度（0 = 没显示，iPadOS 认为有外接键盘）
    private(set) var lastKeyboardHeight: CGFloat = 0
    /// 系统键盘是否真的可见
    private(set) var systemKeyboardShown = false
    var onKeyboardVisibility: ((Bool) -> Void)?

    private func installKeyboardDiagnostics() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                           name: UIResponder.keyboardDidShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide(_:)),
                           name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        FileLog.log("KB \(note.name.rawValue) h=\(Int(frame.height)) w=\(Int(frame.width)) firstResponder=\(isFirstResponder)")
        // 只有高度 > 0 才算「系统键盘真的显示了」；h=0 表示 iPadOS 认为有外接键盘
        lastKeyboardHeight = frame.height
        let shown = frame.height > 0
        if shown != systemKeyboardShown {
            systemKeyboardShown = shown
            onKeyboardVisibility?(shown)
        }
    }

    @objc private func keyboardDidHide(_ note: Notification) {
        FileLog.log("KB \(note.name.rawValue)")
        lastKeyboardHeight = 0
        if systemKeyboardShown {
            systemKeyboardShown = false
            onKeyboardVisibility?(false)
        }
    }

    // MARK: 键盘附属 toolbar

    private lazy var keyboardAccessory: UIView? = {
        let accessory = TerminalKeyboardAccessory(frame: CGRect(x: 0, y: 0, width: 0, height: 44),
                                                  inputViewStyle: .keyboard)
        accessory.onSend = { [weak self] bytes in self?.send(bytes) }
        accessory.onHideKeyboard = { [weak self] in self?.hideKeyboard() }
        return accessory
    }()

    /// 是否把 Esc/Tab/Ctrl/方向键辅助条挂在系统键盘上方。
    /// iPhone 始终启用；iPad 接了硬件键盘、系统键盘不弹时不能挂，否则会孤零零悬在屏幕底部。
    var accessoryEnabled = false

    override var inputAccessoryView: UIView? { accessoryEnabled ? keyboardAccessory : nil }

    // MARK: 输入辅助

    /// 唤起软键盘；若此刻还未挂到窗口上（页面刚出现）会在下一个 runloop 重试
    func showKeyboard() {
        if becomeFirstResponder() { return }
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    func hideKeyboard() { _ = resignFirstResponder() }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        FileLog.log("becomeFirstResponder -> \(became)")
        onFocusChange?(became)
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        FileLog.log("resignFirstResponder -> \(resigned)")
        onFocusChange?(!resigned)
        return resigned
    }

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        scrollToBottomIfNeeded()
        onInput?(bytes)
    }

    private func scrollToBottomIfNeeded() {
        guard let scrollView, !isPinnedToBottom else { return }
        pinToBottom()
    }

    private static func makeItalic(base: UIFont) -> UIFont {
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    // MARK: 字体度量

    private func updateFontMetrics() {
        baseFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        italicFont = Self.makeItalic(base: baseFont)
        let advance = ("M" as NSString).size(withAttributes: [.font: baseFont]).width
        cellWidth = max(1, advance)
        lineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading) + 1
        textTopOffset = (lineHeight - (baseFont.ascender - baseFont.descender)) / 2
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGridFromVisibleSize()
        refreshFrame()
    }

    private func updateGridFromVisibleSize() {
        guard let scrollView else { return }
        let visible = scrollView.bounds.size
        let cols = max(20, Int(floor(max(visible.width - 4, cellWidth) / cellWidth)))
        let rows = max(4, Int(floor(max(visible.height, lineHeight) / lineHeight)))
        onResize?(cols, rows)
    }

    func refresh() {
        refreshFrame()
        setNeedsDisplay()
        if UserDefaults.standard.bool(forKey: "padterm.debugGrid") { dumpGrid("refresh") }
    }

    private var totalRows: Int { emulator.buffer.scrollbackCount + emulator.buffer.rows }

    private func refreshFrame() {
        let height = CGFloat(totalRows) * lineHeight
        let width = CGFloat(emulator.buffer.cols) * cellWidth
        let pinned = isPinnedToBottom
        if abs(frame.size.height - height) > 0.5 || abs(frame.size.width - width) > 0.5 {
            frame.size = CGSize(width: width, height: height)
        }
        if let scrollView {
            scrollView.contentSize = CGSize(width: width, height: max(height, scrollView.bounds.height))
        }
        if pinned { pinToBottom() }
    }

    private var isPinnedToBottom: Bool {
        guard let scrollView else { return true }
        return scrollView.contentOffset.y + scrollView.bounds.height >= frame.height - lineHeight
    }

    private func pinToBottom() {
        guard let scrollView else { return }
        let maxY = max(0, frame.height - scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
    }

    // MARK: 绘制

    override func draw(_ rect: CGRect) {
        theme.background.setFill()
        UIRectFill(rect)

        let first = max(0, Int(floor(rect.minY / lineHeight)))
        let last = min(totalRows - 1, Int(ceil(rect.maxY / lineHeight)))
        guard first <= last else { return }

        for row in first...last {
            guard let line = cellsForRow(row) else { continue }
            draw(line: line, atRow: row)
        }
        drawSelection()
        drawCursor()
    }

    private func cellsForRow(_ row: Int) -> [TerminalCell]? {
        let scrollback = emulator.buffer.scrollbackCount
        if row < scrollback { return emulator.buffer.scrollbackLine(row) }
        let screenRow = row - scrollback
        guard screenRow < emulator.buffer.rows else { return nil }
        return emulator.buffer.lineAt(screenRow)
    }

    private func draw(line: [TerminalCell], atRow row: Int) {
        let top = CGFloat(row) * lineHeight
        var col = 0
        while col < line.count {
            let attributes = line[col].attributes
            let startCol = col
            var text = ""
            while col < line.count, line[col].attributes == attributes {
                let cell = line[col]
                if !cell.isWideContinuation {
                    if let scalar = Unicode.Scalar(cell.code), cell.code != 32 {
                        text.unicodeScalars.append(scalar)
                    } else {
                        text.append(" ")
                    }
                }
                col += 1
            }
            drawRun(text: text, attributes: attributes, startCol: startCol, endCol: col, top: top)
        }
    }

    private func drawRun(text: String,
                         attributes: CellAttributes,
                         startCol: Int,
                         endCol: Int,
                         top: CGFloat) {
        let rect = CGRect(x: CGFloat(startCol) * cellWidth,
                          y: top,
                          width: CGFloat(endCol - startCol) * cellWidth,
                          height: lineHeight)

        var foreground = attributes.foreground.resolve(foreground: true, theme: theme)
        var background = attributes.background.resolve(foreground: false, theme: theme)
        if attributes.style.contains(.inverse) { swap(&foreground, &background) }
        if attributes.style.contains(.faint) {
            foreground = foreground.withAlphaComponent(0.6)
        }

        let needsBackground = attributes.style.contains(.inverse)
            || attributes.background.kind != .default
        if needsBackground {
            background.setFill()
            UIRectFill(rect)
        }

        guard !attributes.style.contains(.hidden) else { return }
        guard !(attributes.style.contains(.blink) && !blinkOn) else { return }

        var font = baseFont
        if attributes.style.contains(.bold) { font = boldFont }
        if attributes.style.contains(.italic) { font = italicFont }

        var typeAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground
        ]
        if attributes.style.contains(.underline) {
            typeAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if attributes.style.contains(.strikethrough) {
            typeAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        // 必须用 draw(at:)：draw(with:options:) 在不带 .usesLineFragmentOrigin 时
        // 把 y 当成基线，整行文字会比起网格上浮约一个 ascender，导致光标与文本错位
        let origin = CGPoint(x: rect.minX, y: top + textTopOffset)
        (text as NSString).draw(at: origin, withAttributes: typeAttributes)
    }

    private func drawCursor() {
        guard emulator.buffer.cursorVisible else { return }
        let row = emulator.buffer.scrollbackCount + emulator.buffer.cursorY
        guard row < totalRows else { return }
        let column = emulator.buffer.cursorX
        let rect = CGRect(x: CGFloat(column) * cellWidth,
                          y: CGFloat(row) * lineHeight,
                          width: cellWidth,
                          height: lineHeight)

        guard blinkOn else {
            UIColor.white.withAlphaComponent(0.45).setStroke()
            UIBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return
        }

        theme.foreground.withAlphaComponent(0.75).setFill()
        UIRectFill(rect)

        guard let line = cellsForRow(row), column < line.count else { return }
        let cell = line[column]
        guard !cell.isWideContinuation, let scalar = Unicode.Scalar(cell.code), cell.code != 32 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: theme.background
        ]
        let origin = CGPoint(x: rect.minX, y: rect.minY + textTopOffset)
        (String(scalar) as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawSelection() {
        guard let selection, !selection.isEmpty else { return }
        let (row0, col0, row1, col1) = selection.ordered
        UIColor.systemBlue.withAlphaComponent(0.35).setFill()
        for row in row0...row1 {
            guard row < totalRows else { continue }
            let startCol = row == row0 ? col0 : 0
            let endCol = row == row1 ? col1 : emulator.buffer.cols
            guard endCol > startCol else { continue }
            UIRectFill(CGRect(x: CGFloat(startCol) * cellWidth,
                              y: CGFloat(row) * lineHeight,
                              width: CGFloat(endCol - startCol) * cellWidth,
                              height: lineHeight))
        }
    }

    // MARK: 手势

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let select = UILongPressGestureRecognizer(target: self, action: #selector(handleSelect(_:)))
        select.minimumPressDuration = 0.35
        select.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(select)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        addInteraction(UIContextMenuInteraction(delegate: self))
        installKeyboardDiagnostics()

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleSelect(_:)))
        drag.delegate = self
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)
    }

    /// 只让鼠标/触控板触发拖选，手指仍然交给 UIScrollView 滚动，避免 iPad 上滚不动
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            #if targetEnvironment(macCatalyst)
            return true
            #else
            return touch.type == .indirectPointer || touch.type == .pencil
            #endif
        }
        return true
    }

    private func cellPosition(from gesture: UIGestureRecognizer) -> (row: Int, col: Int) {
        let point = gesture.location(in: self)
        let row = min(max(Int(floor(point.y / lineHeight)), 0), max(0, totalRows - 1))
        let col = min(max(Int(floor(point.x / cellWidth)), 0), max(0, emulator.buffer.cols - 1))
        return (row, col)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // 只清选中；键盘焦点切换统一由 SwiftUI 层处理，避免两处同时 toggle 互相抵消
        clearSelection()
    }

    @objc private func handleSelect(_ gesture: UILongPressGestureRecognizer) {
        let position = cellPosition(from: gesture)
        switch gesture.state {
        case .began:
            selection = Selection(startRow: position.row, startCol: position.col,
                                  endRow: position.row, endCol: position.col)
            isSelecting = true
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.impactOccurred()
        case .changed:
            guard isSelecting, var current = selection else { return }
            current.endRow = position.row
            current.endCol = position.col
            selection = current
        case .ended, .cancelled:
            isSelecting = false
            if let selection, !selection.isEmpty {
                copySelection()
            }
        default:
            break
        }
        setNeedsDisplay()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseSize = fontSize
        case .changed:
            guard let base = pinchBaseSize else { return }
            let proposed = min(max(base * gesture.scale, 8), 32)
            onFontSizeChange?(proposed)
        default:
            pinchBaseSize = nil
        }
    }

    // MARK: 选区

    func clearSelection() {
        selection = nil
        setNeedsDisplay()
    }

    func selectAllContent() {
        selection = Selection(startRow: 0, startCol: 0,
                              endRow: max(0, totalRows - 1), endCol: emulator.buffer.cols)
        setNeedsDisplay()
    }

    /// 选中区域的纯文本（含回滚）
    func selectedText() -> String? {
        guard let selection, !selection.isEmpty else { return nil }
        let (row0, col0, row1, col1) = selection.ordered
        var lines: [String] = []
        for row in row0...row1 {
            guard let cells = cellsForRow(row) else { continue }
            let start = row == row0 ? col0 : 0
            let end = min(row == row1 ? col1 : cells.count, cells.count)
            var text = ""
            for index in start..<end where index < cells.count {
                let cell = cells[index]
                if !cell.isWideContinuation, let scalar = Unicode.Scalar(cell.code) {
                    text.unicodeScalars.append(scalar)
                }
            }
            lines.append(text.trimmingCharacters(in: CharacterSet(charactersIn: " ")))
        }
        let content = lines.joined(separator: "\n")
        return content.isEmpty ? nil : content
    }

    func copySelection() {
        guard let content = selectedText() else { return }
        UIPasteboard.general.string = content
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
        onCopy?(content)
        clearSelection()
    }

    // MARK: 光标闪烁

    private func startBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            self.setNeedsDisplay()
        }
    }

    // MARK: 对外

    /// 字号变化后重新计算网格
    func updateGridForFontSizeChange() {
        updateGridFromVisibleSize()
        refreshFrame()
        setNeedsDisplay()
    }

    func dumpGrid(_ reason: String) {
        let rows = emulator.buffer.rows, cols = emulator.buffer.cols
        let cy = emulator.buffer.cursorY, cx = emulator.buffer.cursorX
        FileLog.log("GRID \(reason) grid=\(cols)x\(rows) cursor=\(cy),\(cx) cellW=\(cellWidth)")
        for r in max(0, cy - 1)...min(rows - 1, cy + 1) {
            var s = ""
            let line = emulator.buffer.lineAt(r)
            for c in 0..<min(cols, line.count) {
                let cell = line[c]
                s += String(Unicode.Scalar(cell.code) ?? " ")
            }
            FileLog.log("ROW \(r)|\(s)|")
        }
    }
}

// MARK: - SwiftUI 包装

struct TerminalCanvas: UIViewRepresentable {
    @ObservedObject var model: TerminalViewModel
    /// iPhone 上把辅助键条挂到系统软键盘上方（iPad/Mac 关闭，避免硬件键盘时悬空）
    var usesKeyboardAccessory = false

    func makeUIView(context: Context) -> UIScrollView {
        MainActor.assumeIsolated {
            let scrollView = UIScrollView(frame: .zero)
            scrollView.backgroundColor = TerminalTheme.dark.background
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceVertical = true
            scrollView.keyboardDismissMode = .interactive
            scrollView.contentInsetAdjustmentBehavior = .never

            let render = TerminalRenderView(emulator: model.emulator,
                                           fontSize: CGFloat(model.fontSize))
            render.accessoryEnabled = usesKeyboardAccessory
            render.scrollView = scrollView
            render.onResize = { cols, rows in model.resize(cols: cols, rows: rows) }
            render.onFontSizeChange = { size in model.fontSize = Double(size) }
            render.onInput = { bytes in model.sendBytes(bytes) }
            render.onFocusChange = { focused in model.isKeyboardVisible = focused }
            render.onKeyboardVisibility = { shown in
                model.systemKeyboardShown = shown
                FileLog.log("系统键盘可见性 -> \(shown)")
            }
            render.onDebugEvent = { text in model.logUIEvent(text) }
            render.onCopy = { text in model.hint = "已复制选中内容（\(text.count) 字符）" }
            scrollView.addSubview(render)
            model.renderView = render
            // 焦点请求的落地实现（此前没人赋值，导致所有「请求聚焦」都是空调用）
            model.onRequestKeyboard = { render.showKeyboard() }
            model.onDismissKeyboard = { render.hideKeyboard() }
            FileLog.log("TerminalCanvas.makeUIView 已接线 onRequestKeyboard")
            return scrollView
        }
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        MainActor.assumeIsolated {
            guard let render = model.renderView else { return }
            if render.accessoryEnabled != usesKeyboardAccessory {
                render.accessoryEnabled = usesKeyboardAccessory
                if render.isFirstResponder { render.reloadInputViews() }
            }
            let size = CGFloat(model.fontSize)
            if abs(render.fontSize - size) > 0.01 {
                render.fontSize = size
                render.updateGridForFontSizeChange()
            }
            render.setNeedsDisplay()
        }
    }
}
