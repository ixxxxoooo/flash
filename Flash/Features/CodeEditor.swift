import SwiftUI
import AppKit

/// 带 Surge 配置语法高亮的文本编辑器
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 10, height: 12)
        tv.delegate = context.coordinator
        tv.string = text
        tv.isEditable = isEditable
        Highlighter.apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = isEditable
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            Highlighter.apply(to: tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            Highlighter.apply(to: tv)
        }
    }
}

/// 基于正则的轻量高亮
enum Highlighter {
    private static let rules: [(NSRegularExpression, NSColor, Bool)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
        let types = "http|https|socks5|socks5-tls|ss|vmess|trojan|hysteria2|tuic|tuic-v5|snell|anytls|select|url-test|fallback|load-balance|smart"
        return [
            (re("https?://[^\\s,\"']+"), .systemGreen, false),
            (re("(?<=[=,]\\s?)(\(types))\\b"), .systemPurple, false),
            (re("^\\s*[A-Z][A-Z0-9-]+(?=,)"), .systemBlue, false),
            (re("^\\s*[^=\\n,#\\[/;][^=\\n]*?(?=\\s*=)"), .systemOrange, false),
            (re("^\\s*\\[[^\\]\\n]+\\]"), .systemTeal, true),
            (re("^\\s*(#|//|;).*$"), .secondaryLabelColor, false),
            (re("^\\s*#!.*$"), .systemPink, false),
        ]
    }()

    static func apply(to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let base = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: NSColor.labelColor], range: full)
        for (regex, color, isBold) in rules {
            regex.enumerateMatches(in: storage.string, range: full) { m, _, _ in
                guard let r = m?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: r)
                if isBold { storage.addAttribute(.font, value: bold, range: r) }
            }
        }
        storage.endEditing()
    }
}
