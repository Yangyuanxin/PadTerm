import XCTest

/// 针对移植自 SerialStudio 的终端模拟器（TerminalBuffer + TerminalEmulator）的回归测试
final class TerminalEmulatorTests: XCTestCase {

    private func makeEmulator(cols: Int = 40, rows: Int = 6) -> TerminalEmulator {
        TerminalEmulator(cols: cols, rows: rows)
    }

    private func feed(_ emulator: TerminalEmulator, _ text: String) {
        emulator.feed(Array(text.utf8))
    }

    /// 把缓冲（含回滚）渲染成纯文本
    private func text(of emulator: TerminalEmulator) -> String {
        var lines: [String] = []
        for index in 0..<emulator.buffer.scrollbackCount {
            if let line = emulator.buffer.scrollbackLine(index) { lines.append(Self.render(line)) }
        }
        for row in 0..<emulator.buffer.rows { lines.append(Self.render(emulator.buffer.lineAt(row))) }
        return lines.joined(separator: "\n")
    }

    private static func render(_ cells: [TerminalCell]) -> String {
        var output = ""
        for cell in cells {
            if cell.isWideContinuation { continue }
            if let scalar = Unicode.Scalar(cell.code) { output.unicodeScalars.append(scalar) }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    func testPrintAndCRLF() {
        let emulator = makeEmulator()
        feed(emulator, "hello\r\nls -la")
        let output = text(of: emulator)
        XCTAssertTrue(output.contains("hello"))
        XCTAssertTrue(output.contains("ls -la"))
    }

    /// OSC（设置窗口标题）的余下内容不能被当成可见字符打印
    func testOSCTitleIsNotPrinted() {
        let emulator = makeEmulator()
        var receivedTitle = ""
        emulator.onTitleChange = { receivedTitle = $0 }
        feed(emulator, "\u{1B}]0;root@board:/tmp\u{07}prompt$ ")
        let output = text(of: emulator)
        XCTAssertFalse(output.contains("]0;"), "OSC 序列泄漏到屏幕：\(output)")
        XCTAssertEqual(receivedTitle, "root@board:/tmp")
        XCTAssertTrue(output.contains("prompt$"))
    }

    /// 远端查询光标位置必须正确应答（设备开 shell 第一件事就问）
    func testCursorPositionReport() {
        let emulator = makeEmulator(cols: 30, rows: 10)
        var replies: [[UInt8]] = []
        emulator.onResponse = { replies.append($0) }
        feed(emulator, "\u{1B}[3;5H\u{1B}[6n")
        XCTAssertEqual(replies.first.flatMap { String(bytes: $0, encoding: .utf8) }, "\u{1B}[3;5R")
    }

    /// 历史输出要能回滚
    func testScrollbackKeepsHistory() {
        let emulator = makeEmulator(cols: 30, rows: 4)
        for index in 0..<12 { feed(emulator, "line-\(index)\r\n") }
        let output = text(of: emulator)
        XCTAssertTrue(output.contains("line-0"), "缺少更早的历史行")
        XCTAssertTrue(output.contains("line-11"), "缺少最新行")
    }

    /// EL / ED 清除行为
    func testEraseInLineAndDisplay() {
        let emulator = makeEmulator()
        feed(emulator, "abcdefgh")
        feed(emulator, "\u{1B}[1;1H\u{1B}[K")
        XCTAssertFalse(text(of: emulator).contains("abcdefgh"))

        feed(emulator, "xyz\r\n\u{1B}[2J")
        XCTAssertFalse(text(of: emulator).contains("xyz"))
    }

    /// 自动换行
    func testAutowrap() {
        let emulator = makeEmulator(cols: 20, rows: 4)
        feed(emulator, "0123456789012345678901234")
        let lines = text(of: emulator).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "01234567890123456789")
        XCTAssertEqual(lines[1], "01234")
    }

    /// SGR：16 色、256 色、真彩色不应崩溃且保留文本
    func testSGRVariants() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[1;31mRED\u{1B}[0m ")
        feed(emulator, "\u{1B}[38;5;208mORANGE\u{1B}[39m ")
        feed(emulator, "\u{1B}[48;2;20;30;40mBG\u{1B}[49m")
        let output = text(of: emulator)
        XCTAssertTrue(output.contains("RED"))
        XCTAssertTrue(output.contains("ORANGE"))
        XCTAssertTrue(output.contains("BG"))
    }

    /// 改变尺寸后应保留已有内容
    func testResizeKeepsContent() {
        let emulator = makeEmulator(cols: 30, rows: 6)
        feed(emulator, "last-line")
        XCTAssertTrue(text(of: emulator).contains("last-line"))
        emulator.buffer.resize(cols: 60, rows: 20)
        XCTAssertTrue(text(of: emulator).contains("last-line"), "resize 后丢失了内容")
    }

    /// 宽字符（CJK）占位
    func testWideCharacter() {
        let emulator = makeEmulator(cols: 20, rows: 3)
        feed(emulator, "中文abc")
        let firstLine = Self.render(emulator.buffer.lineAt(0))
        XCTAssertTrue(firstLine.hasPrefix("中文abc"), "中文占位不正确：\(firstLine)")
        XCTAssertEqual(emulator.buffer.cursorX, 7, "宽字符应占两列")
    }
}
