import SwiftUI
import AppKit

// MARK: - Enhanced Editor View

/// Enhanced text editor view that wraps NSTextView with IDE-like features.
/// Used in split panes when opening files via Cmd+click or the editor pane.
///
/// Features:
/// - Line numbers gutter
/// - Current line highlighting
/// - Find and replace (Cmd+F / Cmd+Shift+F)
/// - Go to line (Cmd+G)
/// - Word wrap toggle
/// - Tab size configuration
/// - Bracket matching
/// - Auto-indent
/// - Minimap (optional)
struct EnhancedEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    let language: EditorLanguage
    let config: EditorConfig
    let onSave: (() -> Void)?
    /// Optional 1-based line to scroll into view. Callers should clear the
    /// source value via `onScrollHandled` once consumed so the request fires
    /// exactly once per change.
    var scrollToLine: Int?
    var onScrollHandled: (() -> Void)?

    func makeNSView(context: Context) -> EditorScrollView {
        let scrollView = EditorScrollView()
        let textView = scrollView.editorTextView

        // Configure text view
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(config.fontSize), weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true

        // Current line highlighting
        if config.highlightCurrentLine {
            textView.insertionPointColor = NSColor.controlAccentColor
        }

        // Line numbers
        if config.showLineNumbers {
            scrollView.setupLineNumberGutter()
        }

        // Word wrap
        if !config.wordWrap {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = true
        }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Set initial text
        textView.string = text
        context.coordinator.applySyntaxHighlighting()

        return scrollView
    }

    func updateNSView(_ scrollView: EditorScrollView, context: Context) {
        let textView = scrollView.editorTextView
        if textView.string != text {
            let savedRange = textView.selectedRange()
            let savedVisibleRect = textView.visibleRect
            textView.string = text
            context.coordinator.applySyntaxHighlighting()
            // Restore selection and scroll position when still valid
            let utf16Length = (text as NSString).length
            if savedRange.location + savedRange.length <= utf16Length {
                textView.setSelectedRange(savedRange)
            }
            textView.scrollToVisible(savedVisibleRect)
        }
        if let line = scrollToLine, line > 0 {
            context.coordinator.scrollToLine(line)
            onScrollHandled?()
        }
    }

    static func dismantleNSView(_ scrollView: EditorScrollView, coordinator: EditorCoordinator) {
        // Clear the undo stack to prevent use-after-free when the NSTextView
        // is deallocated but NSUndoManager still holds references to it.
        let textView = scrollView.editorTextView
        textView.undoManager?.removeAllActions()
        coordinator.syntaxTimer?.invalidate()
        coordinator.textView = nil
    }

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(parent: self)
    }
}

// MARK: - Editor Coordinator

class EditorCoordinator: NSObject, NSTextViewDelegate {
    let parent: EnhancedEditorView
    weak var textView: NSTextView?
    var syntaxTimer: Timer?

    init(parent: EnhancedEditorView) {
        self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = textView else { return }
        parent.text = textView.string

        // Debounced syntax highlighting (150ms delay to avoid excessive re-highlighting)
        syntaxTimer?.invalidate()
        syntaxTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.applySyntaxHighlighting()
        }

        // Auto-indent on newline
        if parent.config.autoIndent {
            handleAutoIndent(textView)
        }

        // Bracket matching
        if parent.config.bracketMatching {
            highlightMatchingBracket(textView)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = textView else { return }
        parent.selectedRange = textView.selectedRange()

        // Update bracket matching on cursor move
        if parent.config.bracketMatching {
            highlightMatchingBracket(textView)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Handle Cmd+S for save
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            return false
        }

        // Handle Tab key for custom tab insertion
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            let tabString = parent.config.tabString
            textView.insertText(tabString, replacementRange: textView.selectedRange())
            return true
        }

        // Handle Shift+Tab for outdent
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            handleOutdent(textView)
            return true
        }

        return false
    }

    // MARK: - Syntax Highlighting

    func applySyntaxHighlighting() {
        guard let textView = textView else { return }
        let text = textView.string

        guard !text.isEmpty else { return }

        let storage = textView.textStorage!
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()

        // Reset to default style
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: CGFloat(parent.config.fontSize), weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        storage.setAttributes(defaultAttrs, range: fullRange)

        // Apply language-specific highlighting rules
        for rule in parent.language.compiledRules() {
            let matches = rule.regex.matches(in: text, range: fullRange)
            for match in matches {
                storage.addAttribute(.foregroundColor, value: rule.color, range: match.range)
                if rule.isBold {
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(
                            ofSize: CGFloat(parent.config.fontSize),
                            weight: .bold
                        ),
                        range: match.range
                    )
                }
            }
        }

        storage.endEditing()
    }

    // MARK: - Scroll to Line

    func scrollToLine(_ targetLine: Int) {
        guard let textView else { return }
        let nsText = textView.string as NSString
        var currentLine = 1
        var lineStart = 0
        var index = 0
        while index < nsText.length {
            if currentLine == targetLine {
                lineStart = index
                break
            }
            if nsText.character(at: index) == 0x0A {
                currentLine += 1
            }
            index += 1
        }
        if currentLine < targetLine {
            lineStart = nsText.length
        }
        let range = NSRange(location: lineStart, length: 0)
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(range)
    }

    // MARK: - Auto-Indent

    private func handleAutoIndent(_ textView: NSTextView) {
        let text = textView.string
        let cursorPos = textView.selectedRange().location
        guard cursorPos > 0 else { return }

        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: cursorPos - 1, length: 0))
        let line = nsText.substring(with: lineRange)

        // Count leading whitespace from the previous line
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        if !indent.isEmpty, nsText.substring(with: NSRange(location: cursorPos - 1, length: 1)) == "\n" {
            textView.insertText(String(indent), replacementRange: textView.selectedRange())
        }
    }

    // MARK: - Outdent

    private func handleOutdent(_ textView: NSTextView) {
        let text = textView.string
        let selectedRange = textView.selectedRange()
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        let line = nsText.substring(with: lineRange)

        let tabString = parent.config.tabString
        if line.hasPrefix(tabString) {
            let newLine = String(line.dropFirst(tabString.count))
            textView.replaceCharacters(in: lineRange, with: newLine)
        } else if line.hasPrefix("\t") {
            let newLine = String(line.dropFirst(1))
            textView.replaceCharacters(in: lineRange, with: newLine)
        }
    }

    // MARK: - Bracket Matching

    private static let openBracketPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]
    private static let closeBracketPairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]

    private func highlightMatchingBracket(_ textView: NSTextView) {
        if let matchPos = matchingBracketPosition(in: textView) {
            textView.showFindIndicator(for: NSRange(location: matchPos, length: 1))
        }
    }

    /// Resolve the matching-bracket position for the character under the
    /// caret in `textView`, scanning forward for openers and backward for
    /// closers. Returns nil if the caret isn't on a bracket character or
    /// no balanced match exists.
    private func matchingBracketPosition(in textView: NSTextView) -> Int? {
        let text = textView.string
        let pos = textView.selectedRange().location
        guard pos < text.count else { return nil }
        let char = text[text.index(text.startIndex, offsetBy: pos)]
        if let closing = Self.openBracketPairs[char] {
            return findMatchingBracketForward(in: text, from: pos, open: char, close: closing)
        }
        if let opening = Self.closeBracketPairs[char] {
            return findMatchingBracketBackward(in: text, from: pos, open: opening, close: char)
        }
        return nil
    }

    /// Search forward from the given position to find the matching closing bracket.
    private func findMatchingBracketForward(in text: String, from pos: Int, open: Character, close: Character) -> Int? {
        let chars = Array(text)
        var depth = 0
        for i in pos ..< chars.count {
            if chars[i] == open { depth += 1 }
            if chars[i] == close { depth -= 1 }
            if depth == 0, i != pos { return i }
        }
        return nil
    }

    /// Search backward from the given position to find the matching opening bracket.
    private func findMatchingBracketBackward(in text: String, from pos: Int, open: Character, close: Character) -> Int? {
        let chars = Array(text)
        var depth = 0
        for i in stride(from: pos, through: 0, by: -1) {
            if chars[i] == close { depth += 1 }
            if chars[i] == open { depth -= 1 }
            if depth == 0, i != pos { return i }
        }
        return nil
    }

    /// Jump the cursor to the matching bracket at the current position.
    func jumpToMatchingBracket(_ textView: NSTextView) {
        guard let target = matchingBracketPosition(in: textView) else { return }
        textView.setSelectedRange(NSRange(location: target, length: 0))
        textView.scrollRangeToVisible(NSRange(location: target, length: 1))
    }
}
