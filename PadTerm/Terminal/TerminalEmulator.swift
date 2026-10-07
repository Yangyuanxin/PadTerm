//
//  TerminalEmulator.swift
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
//  VT100 / ANSI 转义序列解析器：把串口收到的字节流翻译成 TerminalBuffer 的操作。
//  覆盖嵌入式 Linux（busybox / bash / getty）常用的全部控制序列。
//

import Foundation

/// 终端解析器（非隔离，主线程调用）
final class TerminalEmulator {
    let buffer: TerminalBuffer

    /// 收到 BEL
    var onBell: (() -> Void)?
    /// 标题变化（OSC 0 / 1 / 2）
    var onTitleChange: ((String) -> Void)?
    /// 对端查询（如光标位置报告）需要回复的字节
    var onResponse: (([UInt8]) -> Void)?

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParameter
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsIgnore
        case charset
    }

    private var state: State = .ground
    private var parameters: [Int] = []
    private var currentValue = 0
    private var hasCurrentValue = false
    private var privateMarker: UInt8?
    private var intermediates: [UInt8] = []
    private var stringBuffer: [UInt8] = []
    private var lastPrinted: Unicode.Scalar = " "

    // UTF-8 增量解码
    private var utf8Bytes: [UInt8] = []
    private var utf8Remaining = 0

    init(cols: Int = 80, rows: Int = 24) {
        buffer = TerminalBuffer(cols: cols, rows: rows)
    }

    // MARK: - 入口

    /// 喂入一段字节流（来自串口或本地回显）
    func feed(_ bytes: [UInt8]) {
        for byte in bytes { consume(byte) }
        if !buffer.pendingResponse.isEmpty {
            let response = buffer.pendingResponse
            buffer.pendingResponse.removeAll(keepingCapacity: true)
            onResponse?(response)
        }
        if buffer.bellPending {
            buffer.bellPending = false
            onBell?()
        }
    }

    /// 便捷方法：把字符串按 UTF-8 喂入（本地回显用）
    func feed(text: String) {
        feed(Array(text.utf8))
    }

    private func consume(_ byte: UInt8) {
        // ESC 在任何状态下都能打断当前序列（DCS/CSI 忽略态除外）
        if byte == 0x1B, state != .oscString, state != .dcsIgnore {
            resetSequence()
            state = .escape
            return
        }

        switch state {
        case .ground:
            handleGround(byte)
        case .escape:
            handleEscape(byte)
        case .escapeIntermediate:
            if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
            } else {
                state = .ground
                handleGround(byte)
            }
        case .csiEntry, .csiParameter:
            handleCSIParameter(byte)
        case .csiIntermediate:
            if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
            } else {
                dispatchCSI(byte)
            }
        case .csiIgnore:
            // 等待终止字节
            if byte >= 0x40 && byte <= 0x7E { state = .ground }
            if byte == 0x1B { state = .escape }
        case .oscString:
            handleOSC(byte)
        case .dcsIgnore:
            // DCS ... ST（ESC \ 或 0x9C）
            if byte == 0x9C { state = .ground }
        case .charset:
            // 跳过一个字符集指定字节（如 ESC ( B）
            state = .ground
        }
    }

    private func resetSequence() {
        parameters.removeAll(keepingCapacity: true)
        currentValue = 0
        hasCurrentValue = false
        privateMarker = nil
        intermediates.removeAll(keepingCapacity: true)
    }

    // MARK: - ground

    private func handleGround(_ byte: UInt8) {
        switch byte {
        case 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06:
            break // NUL / SOH ... ACK：串口终端忽略
        case 0x07:
            buffer.bellPending = true
        case 0x08:
            buffer.backspace()
        case 0x09:
            buffer.tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            buffer.lineFeed()
        case 0x0D:
            buffer.carriageReturn()
        case 0x0E, 0x0F:
            break // SO / SI 字符集切换，忽略
        case 0x1B:
            state = .escape
        case 0x7F:
            break // DEL：忽略（由应用层决定如何映射退格）
        case 0x20...0x7E:
            let scalar = Unicode.Scalar(byte)
            buffer.put(scalar)
            lastPrinted = scalar
        default:
            handleUTF8(byte)
        }
    }

    private func handleUTF8(_ byte: UInt8) {
        if utf8Remaining == 0 {
            switch byte {
            case 0xC2...0xDF: utf8Remaining = 1
            case 0xE0...0xEF: utf8Remaining = 2
            case 0xF0...0xF4: utf8Remaining = 3
            default:
                // 非法字节按 Latin-1 显示
                let scalar = Unicode.Scalar(byte)
                buffer.put(scalar)
                lastPrinted = scalar
                return
            }
            utf8Bytes.removeAll(keepingCapacity: true)
            utf8Bytes.append(byte)
            return
        }

        guard byte & 0xC0 == 0x80 else {
            utf8Remaining = 0
            utf8Bytes.removeAll(keepingCapacity: true)
            return
        }
        utf8Bytes.append(byte)
        utf8Remaining -= 1
        guard utf8Remaining == 0 else { return }

        var codePoint: UInt32 = 0
        let lead = utf8Bytes[0]
        switch utf8Bytes.count {
        case 2: codePoint = UInt32(lead & 0x1F)
        case 3: codePoint = UInt32(lead & 0x0F)
        case 4: codePoint = UInt32(lead & 0x07)
        default: break
        }
        for following in utf8Bytes.dropFirst() {
            codePoint = (codePoint << 6) | UInt32(following & 0x3F)
        }
        utf8Bytes.removeAll(keepingCapacity: true)
        if let scalar = Unicode.Scalar(codePoint) {
            buffer.put(scalar)
            lastPrinted = scalar
        }
    }

    // MARK: - escape

    private func handleEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            resetSequence()
            state = .csiEntry
        case UInt8(ascii: "]"):
            stringBuffer.removeAll(keepingCapacity: true)
            state = .oscString
        case UInt8(ascii: "P"):
            state = .dcsIgnore
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            state = .charset
        case UInt8(ascii: "7"):
            buffer.saveCursor()
            state = .ground
        case UInt8(ascii: "8"):
            buffer.restoreCursor()
            state = .ground
        case UInt8(ascii: "D"):
            buffer.lineFeed()
            state = .ground
        case UInt8(ascii: "E"):
            buffer.carriageReturn()
            buffer.lineFeed()
            state = .ground
        case UInt8(ascii: "M"):
            buffer.reverseLineFeed()
            state = .ground
        case UInt8(ascii: "H"):
            buffer.setTabStop()
            state = .ground
        case UInt8(ascii: "c"):
            buffer.reset()
            state = .ground
        case 0x5B...0x5F where byte != UInt8(ascii: "["):
            state = .ground
        case 0x20...0x2F:
            intermediates.append(byte)
            state = .escapeIntermediate
        default:
            state = .ground
        }
    }

    // MARK: - CSI

    private func handleCSIParameter(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            hasCurrentValue = true
            currentValue = min(currentValue * 10 + Int(byte - UInt8(ascii: "0")), 65_535)
            state = .csiParameter
        case UInt8(ascii: ";"):
            pushParameter()
            state = .csiParameter
        case 0x3C...0x3F: // < = > ? 私有前缀
            privateMarker = byte
            state = .csiParameter
        case 0x20...0x2F:
            pushParameter()
            intermediates.append(byte)
            state = .csiIntermediate
        case 0x40...0x7E:
            pushParameter()
            dispatchCSI(byte)
        default:
            state = .csiIgnore
        }
    }

    private func pushParameter() {
        parameters.append(hasCurrentValue ? currentValue : 0)
        currentValue = 0
        hasCurrentValue = false
    }

    private func parameter(_ index: Int, default fallback: Int = 1) -> Int {
        guard index < parameters.count else { return fallback }
        let value = parameters[index]
        return value == 0 ? fallback : value
    }

    private func parameterZero(_ index: Int) -> Int {
        guard index < parameters.count else { return 0 }
        return parameters[index]
    }

    private func dispatchCSI(_ final: UInt8) {
        state = .ground
        let isPrivate = privateMarker == UInt8(ascii: "?")
        let char = Character(UnicodeScalar(final))

        if isPrivate {
            dispatchPrivateMode(char)
            return
        }

        switch char {
        case "@": // ICH
            buffer.insertBlankCells(parameter(0))
        case "A": // CUU
            buffer.moveCursor(dx: 0, dy: -parameter(0))
        case "B", "e": // CUD / VPR
            buffer.moveCursor(dx: 0, dy: parameter(0))
        case "C", "a": // CUF / HPR
            buffer.moveCursor(dx: parameter(0), dy: 0)
        case "D": // CUB
            buffer.moveCursor(dx: -parameter(0), dy: 0)
        case "E": // CNL
            buffer.moveCursor(dx: 0, dy: parameter(0))
            buffer.carriageReturn()
        case "F": // CPL
            buffer.moveCursor(dx: 0, dy: -parameter(0))
            buffer.carriageReturn()
        case "G", "`": // CHA / HPA
            buffer.moveCursorTo(row: buffer.cursorY, col: parameter(0) - 1)
        case "d": // VPA
            buffer.moveCursorTo(row: parameter(0) - 1, col: buffer.cursorX)
        case "H", "f": // CUP / HVP
            buffer.moveCursorTo(row: parameter(0) - 1, col: parameter(1) - 1)
        case "I": // CHT
            buffer.tabForward(parameter(0))
        case "J": // ED
            buffer.eraseInDisplay(parameterZero(0))
        case "K": // EL
            buffer.eraseInLine(parameterZero(0))
        case "L": // IL
            buffer.insertLines(parameter(0))
        case "M": // DL
            buffer.deleteLines(parameter(0))
        case "P": // DCH
            buffer.deleteCharacters(parameter(0))
        case "S": // SU
            buffer.scrollUp(parameter(0))
        case "T": // SD
            buffer.scrollDown(parameter(0))
        case "X": // ECH
            buffer.eraseCharacters(parameter(0))
        case "Z": // CBT 后退 tab
            for _ in 0..<parameter(0) { buffer.moveCursor(dx: -1, dy: 0) }
        case "b": // REP
            buffer.repeatLastCharacter(lastPrinted, count: parameter(0))
        case "g": // TBC
            buffer.clearTabStop(parameterZero(0))
        case "h", "l": // SM / RM
            dispatchMode(char)
        case "m": // SGR
            applySGR()
        case "n": // DSR
            dispatchDeviceStatus()
        case "r": // DECSTBM
            let top = parameter(0, default: 1) - 1
            let bottom = parameter(1, default: buffer.rows) - 1
            buffer.setScrollRegion(top: top, bottom: bottom)
        case "s": // SCP（ANSI.SYS 保存光标）
            buffer.saveCursor()
        case "u": // RCP
            buffer.restoreCursor()
        case "c": // DA：自报身份为 VT102
            buffer.pendingResponse.append(contentsOf: Array("\u{1B}[?6c".utf8))
        case "t": // XTWINOPS：18 → 报告窗口尺寸 ESC[8;rows;cols t（vim / resize 等会查询）
            if parameterZero(0) == 18 {
                buffer.pendingResponse.append(
                    contentsOf: Array("\u{1B}[8;\(buffer.rows);\(buffer.cols)t".utf8))
            }
        default:
            break
        }
    }

    private func dispatchMode(_ char: Character) {
        let enable = char == "h"
        for raw in parameters {
            switch raw {
            case 4: buffer.insertMode = enable          // IRM
            case 20: buffer.newLineMode = enable        // LNM
            default: break
            }
        }
    }

    private func dispatchPrivateMode(_ char: Character) {
        let enable = char == "h"
        for raw in parameters {
            switch raw {
            case 1: break     // DECCKM 光标键模式：序列由本端生成，忽略
            case 3:           // DECCOLM 132 列
                if !enable { buffer.clearScreen() }
            case 7: buffer.autoWrap = enable            // DECAWM
            case 25: buffer.cursorVisible = enable      // DECTCEM
            case 6:                                     // DECOM 原点模式
                buffer.originMode = enable
                buffer.moveCursorTo(row: 0, col: 0)
            case 47, 1047, 1049:                        // 备用屏幕：不支持，等同于清屏
                if enable { buffer.clearScreen() }
            default: break
            }
        }
    }

    private func dispatchDeviceStatus() {
        guard let code = parameters.first else { return }
        switch code {
        case 5:
            buffer.pendingResponse.append(contentsOf: Array("\u{1B}[0n".utf8))
        case 6:
            let row = buffer.cursorY + 1
            let col = buffer.cursorX + 1
            buffer.pendingResponse.append(contentsOf: Array("\u{1B}[\(row);\(col)R".utf8))
        default:
            break
        }
    }

    // MARK: - SGR

    private func applySGR() {
        guard !parameters.isEmpty else {
            buffer.attributes = CellAttributes()
            return
        }
        var index = 0
        while index < parameters.count {
            let value = parameters[index]
            switch value {
            case 0:
                buffer.attributes = CellAttributes()
            case 1:
                buffer.attributes.style.insert(.bold)
                buffer.attributes.style.remove(.faint)
            case 2:
                buffer.attributes.style.insert(.faint)
                buffer.attributes.style.remove(.bold)
            case 3:
                buffer.attributes.style.insert(.italic)
            case 4:
                buffer.attributes.style.insert(.underline)
            case 5, 6:
                buffer.attributes.style.insert(.blink)
            case 7:
                buffer.attributes.style.insert(.inverse)
            case 8:
                buffer.attributes.style.insert(.hidden)
            case 9:
                buffer.attributes.style.insert(.strikethrough)
            case 21:
                buffer.attributes.style.insert(.underline)
            case 22:
                buffer.attributes.style.subtract([.bold, .faint])
            case 23:
                buffer.attributes.style.remove(.italic)
            case 24:
                buffer.attributes.style.remove(.underline)
            case 25:
                buffer.attributes.style.remove(.blink)
            case 27:
                buffer.attributes.style.remove(.inverse)
            case 28:
                buffer.attributes.style.remove(.hidden)
            case 29:
                buffer.attributes.style.remove(.strikethrough)
            case 30...37:
                buffer.attributes.foreground = .init(kind: .indexed(UInt8(value - 30)))
            case 38:
                let (color, consumed) = parseExtendedColor(startingAt: index + 1)
                buffer.attributes.foreground = color
                index += consumed
            case 39:
                buffer.attributes.foreground = .default
            case 40...47:
                buffer.attributes.background = .init(kind: .indexed(UInt8(value - 40)))
            case 48:
                let (color, consumed) = parseExtendedColor(startingAt: index + 1)
                buffer.attributes.background = color
                index += consumed
            case 49:
                buffer.attributes.background = .default
            case 90...97:
                buffer.attributes.foreground = .init(kind: .indexed(UInt8(value - 90 + 8)))
            case 100...107:
                buffer.attributes.background = .init(kind: .indexed(UInt8(value - 100 + 8)))
            default:
                break
            }
            index += 1
        }
    }

    /// 返回 (颜色, 额外消耗的参数个数)
    private func parseExtendedColor(startingAt start: Int) -> (TerminalColor, Int) {
        guard start < parameters.count else { return (.default, 0) }
        switch parameters[start] {
        case 2:
            guard start + 3 < parameters.count else { return (.default, parameters.count - start) }
            let red = UInt8(clamping: parameters[start + 1])
            let green = UInt8(clamping: parameters[start + 2])
            let blue = UInt8(clamping: parameters[start + 3])
            return (.init(kind: .rgb(red: red, green: green, blue: blue)), 4)
        case 5:
            guard start + 1 < parameters.count else { return (.default, parameters.count - start) }
            let index = UInt8(clamping: parameters[start + 1])
            return (.init(kind: .indexed(index)), 2)
        default:
            return (.default, 0)
        }
    }

    // MARK: - OSC

    private func handleOSC(_ byte: UInt8) {
        // 终止符：BEL(0x07) 或 ST(ESC \，ESC 已在入口处理)
        if byte == 0x07 {
            finishOSC()
            return
        }
        if byte == 0x5C, stringBuffer.last == 0x1B {
            stringBuffer.removeLast()
            finishOSC()
            return
        }
        if stringBuffer.count > 4096 {
            state = .ground
            stringBuffer.removeAll(keepingCapacity: true)
            return
        }
        stringBuffer.append(byte)
    }

    private func finishOSC() {
        state = .ground
        guard let text = String(bytes: stringBuffer, encoding: .utf8) ??
                String(bytes: stringBuffer, encoding: .isoLatin1) else {
            stringBuffer.removeAll(keepingCapacity: true)
            return
        }
        stringBuffer.removeAll(keepingCapacity: true)
        // 格式：<num>;<title>
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let code = parts.first, let number = Int(code) else { return }
        if number == 0 || number == 1 || number == 2 {
            let title = parts.count > 1 ? String(parts[1]) : ""
            buffer.title = title
            onTitleChange?(title)
        }
    }
}

extension String {
    /// 兼容 Latin-1 字节流构造（OSC 标题可能不是合法 UTF-8）
    init?(bytes: [UInt8], encoding: String.Encoding) {
        let data = Data(bytes)
        self.init(data: data, encoding: encoding)
    }
}
