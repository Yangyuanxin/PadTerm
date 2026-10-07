import SwiftUI

/// iPadOS 判定为「有外接键盘」时系统软键盘高度为 0，这时用内置触屏键盘兜底。
/// 直接把字节 / 文本送到远端 shell，不依赖任何第一响应者状态。
/// iPhone 上自动压缩键高与字号，避免键盘占掉半屏、按键文字被挤成两行。
struct TouchKeyboard: View {
    var onBytes: ([UInt8]) -> Void
    var onText: (String) -> Void
    var onHide: () -> Void

    @State private var shifted = false
    @State private var symbolMode = false
    @Environment(\.horizontalSizeClass) private var hSize

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

    private var compact: Bool { hSize == .compact }
    private var keyHeight: CGFloat { compact ? 31 : 38 }
    private var keyFont: CGFloat { compact ? 12.5 : 15 }
    private var gap: CGFloat { compact ? 4 : 5 }

    var body: some View {
        VStack(spacing: gap) {
            functionRow
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: gap) {
                    ForEach((symbolMode ? symbolRows : rows)[index], id: \.self) { key in
                        keyButton(title: shifted ? key.uppercased() : key) { onText(shifted ? key.uppercased() : key) }
                    }
                }
            }
            bottomRow
        }
        .padding(compact ? 6 : 8)
        .padding(.bottom, compact ? 2 : 4)
        .background(.ultraThinMaterial)
    }

    private var functionRow: some View {
        HStack(spacing: gap) {
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
            keyButton(title: symbolMode ? "abc" : "?123") { symbolMode.toggle() }
            keyButton(title: "隐藏") { onHide() }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: gap) {
            keyButton(title: shifted ? "⇧" : "⇪", width: compact ? 42 : 46) { shifted.toggle() }
            // 空格用弹性宽度吃掉剩余空间；不要加 layoutPriority，
            // 否则它会被优先铺满整行，把 ⇧/⌫/回车 挤成 0 宽
            keyButton(title: "空格") { onText(" ") }
            keyButton(title: "⌫", width: compact ? 42 : 46) { onBytes([0x7F]) }
            keyButton(title: "回车", width: compact ? 62 : 70) { onBytes([0x0D]) }
        }
    }

    /// 自绘按键：单行文字 + 自动缩放，杜绝「Esc 被挤成两行竖排」
    private func keyButton(title: String, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .font(.system(size: keyFont, weight: .medium, design: .monospaced))
                .frame(maxWidth: width == nil ? .infinity : width, minHeight: keyHeight, maxHeight: keyHeight)
                .background(Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 6 : 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
