import SwiftUI
import WebKit

/// 轻量 Markdown 渲染：标题 / 列表 / 引用 / 分割线 / 表格 / 代码块 / 行内格式，
/// ```mermaid 代码块走 WKWebView 真实渲染成流程图。
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownParser.parse(text)) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            attributed(text)
                .font(level <= 2 ? .headline : (level == 3 ? .subheadline : .callout))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            attributed(text).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        attributed(item).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit()
                        attributed(item).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                attributed(text).foregroundStyle(.secondary)
            }
        case .divider:
            Divider()
        case .table(let rows):
            table(rows)
        case .code(let language, let code):
            if language.lowercased() == "mermaid" {
                MermaidView(code: code)
            } else {
                codeBlock(language: language, code: code)
            }
        }
    }

    /// 行内格式（加粗、行内代码、链接）交给系统 AttributedString 解析
    private func attributed(_ text: String) -> some View {
        let view: Text
        if let parsed = try? AttributedString(markdown: text,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            view = Text(parsed)
        } else {
            view = Text(text)
        }
        return view.textSelection(.enabled)
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func table(_ rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        attributed(cell)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if colIndex < row.count - 1 { Divider().frame(width: 1) }
                    }
                }
                .padding(.vertical, 5)
                .background(rowIndex == 0 ? Color.secondary.opacity(0.12) : Color.clear)
                if rowIndex < rows.count - 1 { Divider() }
            }
        }
        .font(.caption)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

// MARK: - 解析

enum MDBlock: Identifiable {
    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case divider
    case table([[String]])
    case code(String, String)

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l)\(t)"
        case .paragraph(let t): return "p\(t)"
        case .bullet(let items): return "b\(items.joined())"
        case .ordered(let items): return "o\(items.joined())"
        case .quote(let t): return "q\(t)"
        case .divider: return "hr\(UUID().uuidString)"
        case .table(let rows): return "t\(rows.flatMap { $0 }.joined())"
        case .code(let l, let c): return "c\(l)\(c)"
        }
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // 代码块
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language, code.joined(separator: "\n")))
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { index += 1; continue }

            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && trimmed.count >= 3 {
                blocks.append(.divider); index += 1; continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let title = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(hashes, title)); index += 1; continue
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(lines[index].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            // 表格
            if trimmed.contains("|"), index + 1 < lines.count,
               lines[index + 1].contains("|"), lines[index + 1].contains("-") {
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|") {
                    let raw = lines[index].trimmingCharacters(in: .whitespaces)
                    let cells = raw.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.isEmpty }) { rows.append(cells) }
                    index += 1
                }
                let filtered = rows.filter { row in
                    !(row.count > 1 && row[1].allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }))
                }
                if filtered.count >= 2 { blocks.append(.table(filtered)) } else { blocks.append(.paragraph(rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))) }
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("- ") || candidate.hasPrefix("* ") else { break }
                    items.append(String(candidate.dropFirst(2)))
                    index += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            if let firstSpace = trimmed.firstIndex(of: " "),
               trimmed.prefix(while: { $0.isNumber }).isEmpty == false,
               trimmed[trimmed.startIndex..<firstSpace].hasSuffix(".") {
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let dot = candidate.firstIndex(of: "."),
                          !candidate.prefix(upTo: dot).isEmpty,
                          candidate.prefix(upTo: dot).allSatisfy({ $0.isNumber }) else { break }
                    items.append(String(candidate[candidate.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let t = candidate.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("#") || t.hasPrefix("> ")
                    || t.hasPrefix("- ") || t.hasPrefix("* ") { break }
                paragraph.append(candidate)
                index += 1
            }
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) } else { index += 1 }
        }
        return blocks
    }
}

// MARK: - Mermaid 流程图

struct MermaidView: UIViewRepresentable {
    let code: String
    @State private var height: CGFloat = 220

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.render(code: code)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(code: code)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MermaidView
        weak var webView: WKWebView?
        private var lastCode: String?

        init(_ parent: MermaidView) { self.parent = parent }

        func render(code: String) {
            guard code != lastCode else { return }
            lastCode = code
            guard let htmlURL = MermaidAssets.writeHTML(code: code) else { return }
            webView?.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
                guard let self, let height = value as? CGFloat, height > 40 else { return }
                DispatchQueue.main.async { self.parent.height = min(max(height + 16, 120), 900) }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: height)
    }
}

enum MermaidAssets {
    /// 把 mermaid.min.js 与 HTML 放到缓存目录，供 WKWebView 以 file:// 加载
    static func writeHTML(code: String) -> URL? {
        let dir = URL.cachesDirectory.appendingPathComponent("mermaid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsURL = dir.appendingPathComponent("mermaid.min.js")
        if !FileManager.default.fileExists(atPath: jsURL.path) {
            guard let bundled = Bundle.main.url(forResource: "mermaid", withExtension: "min.js")
                    ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else { return nil }
            try? FileManager.default.copyItem(at: bundled, to: jsURL)
        }
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:8px;background:transparent;color:#e6edf3;font-family:-apple-system}
        svg{max-width:100%;height:auto}</style></head>
        <body><div class="mermaid">\(code.escapedForHTML())</div>
        <script src="mermaid.min.js"></script>
        <script>mermaid.initialize({startOnLoad:true,theme:'dark',securityLevel:'loose'});</script>
        </body></html>
        """
        let htmlURL = dir.appendingPathComponent("diagram.html")
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return htmlURL
    }
}

private extension String {
    func escapedForHTML() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
