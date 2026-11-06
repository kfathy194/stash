import AppKit

@MainActor final class CodeTextView: NSTextView {
    var codeEditing = false

    override func insertTab(_ sender: Any?) {
        guard codeEditing else { super.insertTab(sender); return }
        if selectedRange().length == 0 { replaceSelection(with: "\t") }
        else { indent(removing: false) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard codeEditing else { super.insertBacktab(sender); return }
        indent(removing: true)
    }

    override func insertNewline(_ sender: Any?) {
        guard codeEditing else { super.insertNewline(sender); return }
        let source = string as NSString
        let selected = selectedRange()
        let start = source.lineRange(for: NSRange(location: selected.location, length: 0)).location
        let before = source.substring(with: NSRange(location: start, length: selected.location - start))
        let prefix = before.prefix { $0 == " " || $0 == "\t" }
        replaceSelection(with: "\n" + prefix)
    }

    private func replaceSelection(with value: String) {
        breakUndoCoalescing()
        insertText(value, replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    private func indent(removing: Bool) {
        let source = string as NSString
        let selected = selectedRange()
        let range = source.lineRange(for: NSRange(location: selected.location, length: max(0, selected.length - 1)))
        let block = source.substring(with: range) as NSString
        var replacement = ""
        var offset = 0
        while offset < block.length {
            let lineRange = block.lineRange(for: NSRange(location: offset, length: 0))
            var line = block.substring(with: lineRange)
            if removing {
                if line.first == "\t" { line.removeFirst() }
                else { line.removeFirst(line.prefix(4).prefix { $0 == " " }.count) }
            } else { line = "\t" + line }
            replacement += line
            offset = NSMaxRange(lineRange)
        }
        guard replacement != block as String else { return }
        breakUndoCoalescing()
        insertText(replacement, replacementRange: range)
        if selected.length == 0 {
            let removed = range.length - (replacement as NSString).length
            setSelectedRange(NSRange(location: max(range.location, selected.location - removed), length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        }
        breakUndoCoalescing()
        undoManager?.setActionName(removing ? "Outdent code" : "Indent code")
    }
}
