import AppKit
import StashCore

@MainActor enum CodePresentation {
    // shortcut: lexical coloring is not a language parser, upgrade when semantic diagnostics are required.
    private static let expressions: [CodeLanguage: NSRegularExpression] = Dictionary(uniqueKeysWithValues: CodeLanguage.allCases.compactMap { language in
        // Consume unfinished tokens once, rather than rescanning every later opening delimiter.
        let quoted = #""(?:\\[\s\S]|[^"\\])*(?:"|\\?\z)|'(?:\\[\s\S]|[^'\\])*(?:'|\\?\z)"#
        var comment = #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"#
        var string = quoted
        var syntax = #"\$[\w]+"#
        let words: String
        switch language {
        case .css:
            words = "important|inherit|initial|none|auto"
            comment = #"/\*[\s\S]*?(?:\*/|\z)"#
            syntax = #"[#.][\w-]+|(?<![-\w])[-\w]+(?=\s*:)"#
        case .html, .xml:
            words = ""
            comment = #"<!--[\s\S]*?(?:-->|\z)"#
            syntax = #"</?[\w:-]+|<![\w]+|(?<![\w:-])[\w:-]+(?=\s*=)"#
        case .php:
            words = "echo|function|class|public|private|protected|static|return|if|else|elseif|foreach|while|new|null|true|false|use|namespace"
            comment += #"|#[^\r\n]*"#
            syntax += #"|<\?php|\?>"#
        case .javascript, .typescript:
            words = "const|let|var|function|return|if|else|for|while|class|new|import|export|from|async|await|throw|try|catch|interface|type|extends|implements|public|private|null|undefined|true|false"
            string += #"|`(?:\\[\s\S]|[^`\\])*(?:`|\\?\z)"#
        case .json:
            words = "true|false|null"
            comment = "(?!)"
        case .markdown:
            words = ""
            comment = #"<!--[\s\S]*?(?:-->|\z)"#
            string = #"`[^`\r\n]*(?:`|(?=\r|\n|\z))"#
            syntax = #"^#{1,6}[^\r\n]*|\*\*[^*\r\n]+\*\*|\[[^\[\]\r\n]+\]\([^\(\)\r\n]*(?:\)|(?=\r|\n|\z))"#
        case .sql:
            words = "select|from|where|insert|into|values|update|set|delete|create|table|join|on|as|and|or|not|null|order|by|group|having|limit|distinct|true|false"
            comment = #"--[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"#
        case .python:
            words = "def|class|return|if|elif|else|for|while|in|import|from|as|try|except|finally|raise|with|lambda|async|await|True|False|None|and|or|not|pass"
            comment = #"#[^\r\n]*"#
            string = #"\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)|"# + quoted
        case .swift:
            words = "let|var|func|class|struct|enum|protocol|extension|return|if|else|for|while|guard|switch|case|default|import|public|private|static|throw|throws|try|catch|async|await|nil|true|false|self"
            string = #"\"\"\"[\s\S]*?(?:\"\"\"|\z)|"# + quoted
        case .bash:
            words = "if|then|else|elif|fi|for|do|done|while|case|esac|function|in|export|local|return"
            comment = #"#[^\r\n]*"#
            syntax = #"\$\{?\w+\}?"#
        case .yaml:
            words = "true|false|null|yes|no"
            comment = #"#[^\r\n]*"#
            syntax = #"^[ \t]*[\w.-]+(?=\s*:)"#
        }
        let keyword = words.isEmpty ? "(?!)" : #"\b(?:"# + words + #")\b"#
        let pattern = "(?<comment>\(comment))|(?<string>\(string))|(?<keyword>\(keyword))|(?<number>\\b[0-9]+(?:\\.[0-9]+)?\\b)|(?<syntax>\(syntax))"
        let options: NSRegularExpression.Options = language == .sql ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines]
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return (language, expression)
    })

    private static let colors: [(String, NSColor)] = [
        ("comment", readable(.systemGreen)), ("string", readable(.systemRed)),
        ("keyword", readable(.systemPurple)), ("number", readable(.systemBlue)),
        ("syntax", readable(.systemOrange))
    ]

    private static func readable(_ hue: NSColor) -> NSColor {
        // Native accent hues need label-color contrast when used for body text.
        NSColor(name: nil) { appearance in
            var color = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                color = hue.blended(withFraction: 0.6, of: .labelColor) ?? .labelColor
            }
            return color
        }
    }

    static func apply(to textView: NSTextView, language: String?, isCode: Bool) {
        guard let layout = textView.layoutManager else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        guard isCode else { return }
        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.textColor, forCharacterRange: range)
        guard let language, let known = CodeLanguage(rawValue: language), let expression = expressions[known] else { return }
        expression.enumerateMatches(in: textView.string, range: range) { match, _, _ in
            guard let match else { return }
            for (name, color) in colors {
                let token = match.range(withName: name)
                if token.location != NSNotFound { layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token) }
            }
        }
    }
}

@MainActor final class CodeLineRuler: NSRulerView {
    private weak var text: NSTextView?
    private var starts = [0]
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    override var isFlipped: Bool { true }

    init(scroll: NSScrollView, text: NSTextView) {
        self.text = text
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = text
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Line numbers")
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        refresh()
    }
    required init(coder: NSCoder) { fatalError("CodeLineRuler is created programmatically") }

    func refresh() {
        guard let text else { return }
        let source = text.string as NSString
        starts = [0]
        var offset = 0
        while offset < source.length {
            let end = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            guard end > offset else { break }
            if end < source.length || UnicodeScalar(source.character(at: end - 1)).map(CharacterSet.newlines.contains) == true { starts.append(end) }
            offset = end
        }
        ruleThickness = max(38, CGFloat(String(starts.count).count) * 8 + 18)
        setAccessibilityValue((1...starts.count).map(String.init).joined(separator: "\n"))
        needsDisplay = true
    }

    @objc private func scrolled() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let text, let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let length = (text.string as NSString).length
        let visible = layout.glyphRange(forBoundingRect: text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y), in: container)
        let firstCharacter = visible.length > 0 ? layout.characterIndexForGlyph(at: visible.location) : length
        for (index, start) in starts.enumerated() {
            if start < firstCharacter { continue }
            let fragment: NSRect
            if start < length { fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil) }
            else { fragment = layout.extraLineFragmentRect }
            let point = convert(NSPoint(x: 0, y: fragment.minY + text.textContainerOrigin.y), from: text)
            if point.y > bounds.maxY { break }
            let number = String(index + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: point.y + max(0, (fragment.height - size.height) / 2)), withAttributes: attributes)
        }
    }
}
