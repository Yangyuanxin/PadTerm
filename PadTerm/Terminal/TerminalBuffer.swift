//
//  TerminalBuffer.swift
//  SerialStudio —— macOS 串口调试助手
//
//  Copyright (c) 2026 杨源鑫 (Bruce.yang) All rights reserved.
//  公众号/品牌：嵌入式应用研究院
//  技术博客：Bruce.yang的嵌入式之旅
//  GitHub: https://github.com/Yangyuanxin
//
//  SPDX-License-Identifier: MIT
//  本项目以 MIT 协议开源，详见仓库根目录 LICENSE 文件。
//
//  终端屏幕缓冲区：字符网格 + 回滚区 + 光标 + 滚动区域 + 字符属性。
//  支持 VT100 / ANSI 转义序列（由 TerminalEmulator 解析后调用本文件的接口）。
//

import UIKit
import Foundation

// MARK: - 主题

/// 终端配色（xterm 风格 256 色表）
struct TerminalTheme {
    var background: UIColor
    var foreground: UIColor
    /// 索引 0...255 的调色板
    var palette: [UIColor]

    func color(at index: UInt8) -> UIColor {
        palette.indices.contains(Int(index)) ? palette[Int(index)] : foreground
    }

    /// 深色终端主题（与常见 Linux console / xterm 一致）
    static let dark = TerminalTheme(
        background: UIColor(red: 0.075, green: 0.086, blue: 0.110, alpha: 1),
        foreground: UIColor(red: 0.827, green: 0.843, blue: 0.862, alpha: 1),
        palette: Self.buildPalette()
    )

    private static func buildPalette() -> [UIColor] {
        let basic: [(Double, Double, Double)] = [
            (0.000, 0.000, 0.000), // 0 black
            (0.804, 0.000, 0.000), // 1 red
            (0.055, 0.714, 0.475), // 2 green
            (0.898, 0.898, 0.063), // 3 yellow
            (0.141, 0.447, 0.784), // 4 blue
            (0.737, 0.247, 0.737), // 5 magenta
            (0.067, 0.659, 0.804), // 6 cyan
            (0.898, 0.898, 0.898), // 7 white
            (0.400, 0.400, 0.400), // 8 bright black
            (0.957, 0.298, 0.298), // 9 bright red
            (0.137, 0.820, 0.545), // 10 bright green
            (0.961, 0.961, 0.263), // 11 bright yellow
            (0.231, 0.557, 0.918), // 12 bright blue
            (0.839, 0.416, 0.839), // 13 bright magenta
            (0.161, 0.804, 0.859), // 14 bright cyan
            (0.961, 0.961, 0.961)  // 15 bright white
        ]
        var palette: [UIColor] = basic.map {
            UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1)
        }
        // 16...231：6 x 6 x 6 色立方
        for index in 16..<232 {
            let value = index - 16
            let r = value / 36
            let g = (value % 36) / 6
            let b = value % 6
            let unit: CGFloat = r == 0 ? 0 : (CGFloat(r) * 40 + 55) / 255
            let unitG: CGFloat = g == 0 ? 0 : (CGFloat(g) * 40 + 55) / 255
            let unitB: CGFloat = b == 0 ? 0 : (CGFloat(b) * 40 + 55) / 255
            palette.append(UIColor(red: unit, green: unitG, blue: unitB, alpha: 1))
        }
        // 232...255：灰阶
        for index in 232..<256 {
            let level = CGFloat(index - 232) * 10 + 8
            palette.append(UIColor(white: level / 255, alpha: 1))
        }
        return palette
    }
}

// MARK: - 颜色

/// 单元格颜色：默认色 / 256 索引色 / 24 位真彩
struct TerminalColor: Equatable {
    enum Kind: Equatable {
        case `default`
        case indexed(UInt8)
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
    }

    var kind: Kind

    static let `default` = TerminalColor(kind: .default)

    func resolve(foreground: Bool, theme: TerminalTheme) -> UIColor {
        switch kind {
        case .default:
            return foreground ? theme.foreground : theme.background
        case .indexed(let index):
            return theme.color(at: index)
        case .rgb(let red, let green, let blue):
            return UIColor(red: CGFloat(red) / 255,
                           green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255,
                           alpha: 1)
        }
    }
}

// MARK: - 字符属性

struct CellStyle: OptionSet {
    let rawValue: UInt8
    static let bold          = CellStyle(rawValue: 1 << 0)
    static let faint         = CellStyle(rawValue: 1 << 1)
    static let italic        = CellStyle(rawValue: 1 << 2)
    static let underline     = CellStyle(rawValue: 1 << 3)
    static let blink         = CellStyle(rawValue: 1 << 4)
    static let inverse       = CellStyle(rawValue: 1 << 5)
    static let hidden        = CellStyle(rawValue: 1 << 6)
    static let strikethrough = CellStyle(rawValue: 1 << 7)
}

struct CellAttributes: Equatable {
    var foreground: TerminalColor = .default
    var background: TerminalColor = .default
    var style: CellStyle = []
}

/// 一个屏幕格子
struct TerminalCell: Equatable {
    /// Unicode 码位，空格表示空单元
    var code: UInt32 = 32
    var attributes: CellAttributes = CellAttributes()
    /// 宽字符（CJK / 全角）的延续占位格
    var isWideContinuation = false

    static let blank = TerminalCell()

    var isEmpty: Bool { code == 32 && !isWideContinuation }
}

// MARK: - 缓冲区

/// 屏幕缓冲区。所有方法均应在主线程调用。
final class TerminalBuffer {
    private(set) var cols: Int
    private(set) var rows: Int

    private var cells: [TerminalCell]
    private var scrollback: [[TerminalCell]] = []
    /// 回滚区最大行数
    var scrollbackLimit: Int = 3000

    // 光标
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private var savedX = 0
    private var savedY = 0
    private var savedAttributes = CellAttributes()

    /// 当前写入属性
    var attributes = CellAttributes()
    /// 自动换行（DEC 模式 ?7）
    var autoWrap = true
    /// 光标可见（DEC 模式 ?25）
    var cursorVisible = true
    /// 原点模式（DECOM）：光标坐标相对滚动区域
    var originMode = false
    /// 插入模式（IRM）
    var insertMode = false
    /// 新行模式（LNM）：收到 LF 时是否同时回车
    var newLineMode = false
    /// 已到达行尾，下一次写入前先换行
    var wrapPending = false

    /// 滚动区域（含首尾）
    private(set) var scrollTop = 0
    private(set) var scrollBottom: Int

    /// 终端标题（OSC 0/1/2 设置）
    var title = ""
    /// 收到 BEL，等待界面响铃
    var bellPending = false
    /// 需要回传给对端的应答（如 DSR 光标位置报告）
    var pendingResponse: [UInt8] = []

    private var tabStops: Set<Int>

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.cells = Array(repeating: .blank, count: self.cols * self.rows)
        self.scrollBottom = self.rows - 1
        self.tabStops = Set(stride(from: 8, to: self.cols, by: 8))
    }

    // MARK: 访问

    private func index(row: Int, col: Int) -> Int { row * cols + col }

    func cellAt(row: Int, col: Int) -> TerminalCell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .blank }
        return cells[index(row: row, col: col)]
    }

    private func setCell(row: Int, col: Int, _ cell: TerminalCell) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        cells[index(row: row, col: col)] = cell
    }

    /// 取一行的副本
    func lineAt(_ row: Int) -> [TerminalCell] {
        guard row >= 0, row < rows else { return [] }
        return Array(cells[index(row: row, col: 0)..<index(row: row, col: cols)])
    }

    /// 回滚区行数
    var scrollbackCount: Int { scrollback.count }

    /// 回滚区某一行（0 为最早的一行）
    func scrollbackLine(_ index: Int) -> [TerminalCell]? {
        guard index >= 0, index < scrollback.count else { return nil }
        return scrollback[index]
    }

    var blankLine: [TerminalCell] {
        Array(repeating: TerminalCell(code: 32, attributes: attributes), count: cols)
    }

    // MARK: 尺寸

    func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        guard newCols != cols || newRows != rows else { return }

        var content: [[TerminalCell]] = (0..<rows).map { lineAt($0) }
        content = content.map { line -> [TerminalCell] in
            if line.count == newCols { return line }
            if line.count > newCols { return Array(line[0..<newCols]) }
            return line + Array(repeating: .blank, count: newCols - line.count)
        }
        // 回滚区里的行同样归一化宽度
        scrollback = scrollback.map { line -> [TerminalCell] in
            if line.count == newCols { return line }
            if line.count > newCols { return Array(line[0..<newCols]) }
            return line + Array(repeating: .blank, count: newCols - line.count)
        }

        cols = newCols
        rows = newRows
        cells = Array(repeating: .blank, count: cols * rows)
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Set(stride(from: 8, to: cols, by: 8))

        // 行数变少：顶部溢出的行进入回滚区；行数变多：内容顶部对齐，底部补空行
        if content.count > rows {
            let drop = content.count - rows
            pushToScrollback(Array(content[0..<drop]))
            content = Array(content[drop...])
        } else if content.count < rows {
            content.append(contentsOf: Array(repeating: Array(repeating: .blank, count: cols),
                                             count: rows - content.count))
        }
        for (row, line) in content.enumerated() {
            for (col, cell) in line.enumerated() { setCell(row: row, col: col, cell) }
        }
        cursorX = min(cursorX, cols - 1)
        cursorY = min(cursorY, rows - 1)
        wrapPending = false
    }

    // MARK: 光标

    func moveCursorTo(row: Int, col: Int) {
        if originMode {
            cursorY = min(max(row + scrollTop, scrollTop), scrollBottom)
        } else {
            cursorY = min(max(row, 0), rows - 1)
        }
        cursorX = min(max(col, 0), cols - 1)
        wrapPending = false
    }

    func moveCursor(dx: Int, dy: Int) {
        moveCursorTo(row: cursorY + dy, col: cursorX + dx)
    }

    func carriageReturn() {
        cursorX = 0
        wrapPending = false
    }

    func lineFeed() {
        if newLineMode { cursorX = 0 }
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
        wrapPending = false
    }

    func reverseLineFeed() {
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
        wrapPending = false
    }

    func backspace() {
        if wrapPending {
            wrapPending = false
            return
        }
        if cursorX > 0 { cursorX -= 1 }
    }

    func tabForward(_ count: Int = 1) {
        for _ in 0..<max(1, count) {
            var next = cursorX + 1
            while next < cols - 1, !tabStops.contains(next) { next += 1 }
            cursorX = min(next, cols - 1)
        }
        wrapPending = false
    }

    func setTabStop() { tabStops.insert(cursorX) }

    func clearTabStop(_ mode: Int) {
        switch mode {
        case 0: tabStops.remove(cursorX)
        case 3: tabStops.removeAll()
        default: break
        }
    }

    func saveCursor() {
        savedX = cursorX
        savedY = cursorY
        savedAttributes = attributes
    }

    func restoreCursor() {
        cursorX = min(savedX, cols - 1)
        cursorY = min(savedY, rows - 1)
        attributes = savedAttributes
        wrapPending = false
    }

    // MARK: 写入

    /// 写入一个字符（自动处理换行、插入模式与宽字符）
    func put(_ scalar: Unicode.Scalar) {
        let wide = TerminalBuffer.isWideScalar(scalar)
        if wrapPending && autoWrap {
            carriageReturn()
            lineFeed()
        }
        if insertMode { insertBlankCells(1) }

        var cell = TerminalCell(code: scalar.value, attributes: attributes)
        setCell(row: cursorY, col: cursorX, cell)
        if wide && cursorX + 1 < cols {
            cell.code = 32
            cell.isWideContinuation = true
            setCell(row: cursorY, col: cursorX + 1, cell)
        }

        let step = wide ? 2 : 1
        if cursorX + step >= cols {
            if autoWrap {
                cursorX = cols - 1
                wrapPending = true
            } else {
                cursorX = cols - 1
            }
        } else {
            cursorX += step
        }
    }

    /// 重复上一个字符（CSI b）
    func repeatLastCharacter(_ scalar: Unicode.Scalar, count: Int) {
        for _ in 0..<max(0, count) { put(scalar) }
    }

    // MARK: 滚动 / 擦除

    func scrollUp(_ count: Int) {
        let times = min(count, scrollBottom - scrollTop + 1)
        for _ in 0..<times {
            if scrollTop == 0 { pushToScrollback([lineAt(0)]) }
            for row in scrollTop..<scrollBottom {
                let next = lineAt(row + 1)
                replaceLine(row, with: next)
            }
            replaceLine(scrollBottom, with: Array(repeating: .blank, count: cols))
        }
    }

    func scrollDown(_ count: Int) {
        let times = min(count, scrollBottom - scrollTop + 1)
        for _ in 0..<times {
            var row = scrollBottom
            while row > scrollTop {
                let previous = lineAt(row - 1)
                replaceLine(row, with: previous)
                row -= 1
            }
            replaceLine(scrollTop, with: Array(repeating: .blank, count: cols))
        }
    }

    /// 清空屏幕：0 = 光标之后，1 = 光标之前，2 = 全部，3 = 全部并清回滚
    func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLineCells(row: cursorY, from: cursorX, to: cols)
            for row in (cursorY + 1)..<rows { replaceLine(row, with: blankCells()) }
        case 1:
            for row in 0..<cursorY { replaceLine(row, with: blankCells()) }
            eraseLineCells(row: cursorY, from: 0, to: min(cursorX + 1, cols))
        case 3:
            scrollback.removeAll()
            fallthrough
        default:
            for row in 0..<rows { replaceLine(row, with: blankCells()) }
        }
    }

    /// 清空行：0 = 光标之后，1 = 光标之前，2 = 整行
    func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: eraseLineCells(row: cursorY, from: cursorX, to: cols)
        case 1: eraseLineCells(row: cursorY, from: 0, to: min(cursorX + 1, cols))
        default: eraseLineCells(row: cursorY, from: 0, to: cols)
        }
    }

    /// 删除 n 个字符（左侧内容右移？不，DCH：删除后右侧左移）
    func deleteCharacters(_ count: Int) {
        let line = lineAt(cursorY)
        let remove = min(count, cols - cursorX)
        var updated = Array(line[0..<cursorX])
        if cursorX + remove < cols {
            updated.append(contentsOf: line[(cursorX + remove)..<cols])
        }
        updated.append(contentsOf: blankCells(count: remove))
        replaceLine(cursorY, with: updated)
    }

    /// 擦除 n 个字符（不移动其它内容）
    func eraseCharacters(_ count: Int) {
        eraseLineCells(row: cursorY, from: cursorX, to: min(cursorX + max(0, count), cols))
    }

    /// 插入 n 个空字符
    func insertBlankCells(_ count: Int) {
        let line = lineAt(cursorY)
        let insert = min(count, cols - cursorX)
        var updated = Array(line[0..<cursorX])
        updated.append(contentsOf: blankCells(count: insert))
        if cursorX + insert < cols {
            updated.append(contentsOf: line[cursorX..<(cols - insert)])
        }
        replaceLine(cursorY, with: Array(updated.prefix(cols)))
    }

    /// 插入 n 行（当前行下移）
    func insertLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let times = min(count, scrollBottom - cursorY + 1)
        for _ in 0..<times {
            var row = scrollBottom
            while row > cursorY {
                replaceLine(row, with: lineAt(row - 1))
                row -= 1
            }
            replaceLine(cursorY, with: Array(repeating: .blank, count: cols))
        }
        cursorX = 0
    }

    /// 删除 n 行
    func deleteLines(_ count: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let times = min(count, scrollBottom - cursorY + 1)
        for _ in 0..<times {
            for row in cursorY..<scrollBottom {
                replaceLine(row, with: lineAt(row + 1))
            }
            replaceLine(scrollBottom, with: Array(repeating: .blank, count: cols))
        }
        cursorX = 0
    }

    /// 设置滚动区域
    func setScrollRegion(top: Int, bottom: Int) {
        let t = min(max(top, 0), rows - 1)
        var b = min(max(bottom, 0), rows - 1)
        if b < t { b = t }
        scrollTop = t
        scrollBottom = b
        moveCursorTo(row: originMode ? 0 : t, col: 0)
    }

    // MARK: 状态

    func reset() {
        cells = Array(repeating: .blank, count: cols * rows)
        scrollback.removeAll()
        cursorX = 0
        cursorY = 0
        savedX = 0
        savedY = 0
        attributes = CellAttributes()
        autoWrap = true
        cursorVisible = true
        originMode = false
        insertMode = false
        newLineMode = false
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Set(stride(from: 8, to: cols, by: 8))
        title = ""
    }

    /// 清屏但不清回滚区
    func clearScreen() {
        cells = Array(repeating: .blank, count: cols * rows)
        cursorX = 0
        cursorY = 0
        wrapPending = false
    }

    /// 导出纯文本（回滚区 + 当前屏）
    func plainText() -> String {
        var lines: [String] = []
        lines.reserveCapacity(scrollback.count + rows)
        for line in scrollback { lines.append(Self.text(of: line)) }
        for row in 0..<rows { lines.append(Self.text(of: lineAt(row))) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func text(of line: [TerminalCell]) -> String {
        var text = ""
        for cell in line where !cell.isWideContinuation {
            if let scalar = Unicode.Scalar(cell.code) {
                text.unicodeScalars.append(scalar)
            }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    // MARK: 内部

    private func blankCells(count: Int = 0) -> [TerminalCell] {
        Array(repeating: .blank, count: max(0, count))
    }

    private func replaceLine(_ row: Int, with line: [TerminalCell]) {
        guard row >= 0, row < rows else { return }
        var source = line
        if source.count < cols {
            source.append(contentsOf: Array(repeating: .blank, count: cols - source.count))
        }
        for (col, cell) in source.prefix(cols).enumerated() {
            setCell(row: row, col: col, cell)
        }
    }

    private func eraseLineCells(row: Int, from: Int, to: Int) {
        guard row >= 0, row < rows else { return }
        let start = max(0, from)
        let end = min(to, cols)
        guard start < end else { return }
        for col in start..<end {
            let cell = TerminalCell(code: 32, attributes: attributes)
            // 清理宽字符的另一半
            if col > 0, cells[index(row: row, col: col - 1)].isWideContinuation {
                cells[index(row: row, col: col - 1)] = .blank
            }
            setCell(row: row, col: col, cell)
        }
        if end < cols, cells[index(row: row, col: end)].isWideContinuation {
            setCell(row: row, col: end, .blank)
        }
    }

    private func pushToScrollback(_ lines: [[TerminalCell]]) {
        guard !lines.isEmpty else { return }
        // 尾部空行不进回滚区，避免退出时刷屏
        let meaningful = lines.filter { line in
            line.contains { !$0.isEmpty }
        }
        scrollback.append(contentsOf: meaningful)
        let overflow = scrollback.count - scrollbackLimit
        if overflow > 0 {
            scrollback.removeFirst(overflow)
        }
    }

    /// 判断是否东亚宽字符（占两列）
    static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6:
            return true
        case 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
