import SwiftUI

/// iPadOS 判定为「有外接键盘」时系统软键盘高度为 0，这时用内置触屏键盘兜底。
/// 直接把字节 / 文本送到远端 shell，不依赖任何第一响应者状态。
struct TouchKeyboard: View {
    var onBytes: ([UInt8]) -> Void
    var onText: (String) -> Void
    var onHide: () -> Void

    @State private var shifted = false
    @State private var symbolMode = false

    private let rows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "\\"],
        ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "`", "$"]
    ]
    private let symbolRows: [[String]] = [
        ["!", "@", "#", "%", "^", "&", "*", "(", ")", "_", "+", "|"],
        ["~", "<", ">", "?", ":", "\"", "{", "}", "$", "`", "=", "-"],
        ["'", ";", ",", ".", "/", "\\", "[", "]", "(", ")", "-", "_"],
        ["%", "^", "&", "*", "+", "!", "@", "#", "~", "`", "|", "?"]
    ]

    var body: some View {
        VStack(spacing: 6) {
            functionRow
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 5) {
                    ForEach((symbolMode ? symbolRows : rows)[index], id: \.self) { key in
                        keyButton(title: shifted ? key.uppercased() : key) { onText(shifted ? key.uppercased() : key) }
                    }
                }
            }
            bottomRow
        }
        .padding(8)
        .background(.ultraThinMaterial)
    }

    private var functionRow: some View {
        HStack(spacing: 5) {
            keyButton(title: "Esc") { onBytes([0x1B]) }
            keyButton(title: "Tab") { onBytes([0x09]) }
            keyButton(title: "^C") { onBytes([0x03]) }
            keyButton(title: "^D") { onBytes([0x04]) }
            keyButton(title: "^Z") { onBytes([0x1A]) }
            keyButton(title: "^L") { onBytes([0x0C]) }
            keyButton(title: "↑") { onBytes([0x1B, 0x5B, 0x41]) }
            keyButton(title: "↓") { onBytes([0x1B, 0x5B, 0x42]) }
            keyButton(title: "←") { onBytes([0x1B, 0x5B, 0x44]) }
            keyButton(title: "→") { onBytes([0x1B, 0x5B, 0x43]) }
            keyButton(title: "?123") { symbolMode.toggle() }
            keyButton(title: "隐藏") { onHide() }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 5) {
            keyButton(title: shifted ? "⇧" : "↑", width: 46) { shifted.toggle() }
            keyButton(title: "空格", width: 220) { onText(" ") }
            keyButton(title: "⌫", width: 46) { onBytes([0x7F]) }
            keyButton(title: "回车", width: 70) { onBytes([0x0D]) }
        }
    }

    private func keyButton(title: String, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .frame(maxWidth: width == nil ? .infinity : width, minHeight: 38)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
