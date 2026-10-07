//
//  TerminalKeyboardAccessory.swift
//  PadTerm
//
//  软键盘上方的辅助键条：Esc / Tab / Ctrl 组合 / 方向键 / 隐藏键盘
//  （没它，iPad 上连 Ctrl+C、Tab 补全、方向键都用不了）
//

import UIKit

final class TerminalKeyboardAccessory: UIInputView {
    var onSend: (([UInt8]) -> Void)?
    var onHideKeyboard: (() -> Void)?

    private struct Key {
        let title: String
        let bytes: [UInt8]
    }

    private static let keys: [Key] = {
        func esc(_ body: String) -> [UInt8] { Array("\u{1B}\(body)".utf8) }
        func ctrl(_ scalar: Unicode.Scalar) -> [UInt8] { [UInt8(scalar.value - 96)] }
        return [
            Key(title: "Esc", bytes: [0x1B]),
            Key(title: "Tab", bytes: [0x09]),
            Key(title: "^C", bytes: ctrl("c")),
            Key(title: "^D", bytes: ctrl("d")),
            Key(title: "^Z", bytes: ctrl("z")),
            Key(title: "^L", bytes: ctrl("l")),
            Key(title: "^R", bytes: ctrl("r")),
            Key(title: "^A", bytes: ctrl("a")),
            Key(title: "^E", bytes: ctrl("e")),
            Key(title: "^U", bytes: ctrl("u")),
            Key(title: "^K", bytes: ctrl("k")),
            Key(title: "^W", bytes: ctrl("w")),
            Key(title: "^?", bytes: [0x7F]),
            Key(title: "|", bytes: Array("|".utf8)),
            Key(title: "~", bytes: Array("~".utf8)),
            Key(title: "/", bytes: Array("/".utf8)),
            Key(title: "-", bytes: Array("-".utf8)),
            Key(title: "↑", bytes: esc("[A")),
            Key(title: "↓", bytes: esc("[B")),
            Key(title: "←", bytes: esc("[D")),
            Key(title: "→", bytes: esc("[C"))
        ]
    }()

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .fill
        scrollView.addSubview(stack)

        for key in Self.keys {
            stack.addArrangedSubview(makeButton(title: key.title, bytes: key.bytes))
        }

        let done = UIButton(type: .system)
        done.translatesAutoresizingMaskIntoConstraints = false
        done.setTitle("隐藏", for: .normal)
        done.setTitleColor(.label, for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        done.addAction(UIAction { [weak self] _ in self?.onHideKeyboard?() }, for: .touchUpInside)

        addSubview(scrollView)
        addSubview(done)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor, constant: -12),

            done.widthAnchor.constraint(equalToConstant: 52),
            done.heightAnchor.constraint(equalToConstant: 34),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            done.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func makeButton(title: String, bytes: [UInt8]) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        button.layer.cornerRadius = 6
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in self?.onSend?(bytes) }, for: .touchUpInside)
        return button
    }
}
