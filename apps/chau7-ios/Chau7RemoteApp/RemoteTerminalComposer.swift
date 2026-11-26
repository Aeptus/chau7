import Chau7Core
import SwiftUI
import UIKit

/// Native input events distinguish Return from paste, including a single pasted newline.
struct RemoteTerminalComposer: UIViewRepresentable {
    @Binding var text: String
    /// Plain state, not `FocusState`: SwiftUI only honours a `FocusState` value
    /// for a view carrying `.focused(_:)`, which a UIKit text view cannot.
    @Binding var isFocused: Bool
    let holdToSend: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> RemoteTerminalComposerTextView {
        let view = RemoteTerminalComposerTextView()
        view.delegate = context.coordinator
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: RemoteTerminalComposerTextView, context: Context) {
        context.coordinator.parent = self
        view.holdToSend = holdToSend
        view.onSubmit = onSubmit
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: text.utf16.count, length: 0)
            view.revealCaret()
        }
        view.syncFocus(requested: isFocused)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RemoteTerminalComposerTextView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.composerHeight(fittingWidth: width))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RemoteTerminalComposer
        init(_ parent: RemoteTerminalComposer) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { publishFocus(true) }
        func textViewDidEndEditing(_ textView: UITextView) { publishFocus(false) }

        /// `syncFocus` reaches these callbacks during a SwiftUI update, where the
        /// state already holds the value; writing it again there is an error.
        private func publishFocus(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }
    }
}

final class RemoteTerminalComposerTextView: UITextView, UITextPasteDelegate {
    var holdToSend = false {
        didSet {
            guard holdToSend != oldValue else { return }
            returnKeyType = holdToSend ? .default : .send
            if isFirstResponder { reloadInputViews() }
        }
    }
    var onSubmit: (() -> Void)?
    private var isPasting = false
    private var laidOutSize = CGSize.zero
    static let maxVisibleLines = 4

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        )
        adjustsFontForContentSizeCategory = true
        backgroundColor = .clear
        textColor = .label
        textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textContainer.lineFragmentPadding = 0
        returnKeyType = .send
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        accessibilityLabel = "Terminal input"
        pasteDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Height for `width`: the text's own height, between one line and
    /// `maxVisibleLines`. Scrolling is on only when the text is taller than
    /// that. A scrolling text view moves its content up a line as soon as the
    /// caret wraps, before the view has grown, which hides the first line of a
    /// draft that still fits.
    func composerHeight(fittingWidth width: CGFloat) -> CGFloat {
        let lineHeight = font?.lineHeight ?? 20
        let inset = textContainerInset.top + textContainerInset.bottom
        let natural = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let tallest = lineHeight * CGFloat(Self.maxVisibleLines) + inset
        let overflows = natural > tallest + 0.5
        if isScrollEnabled != overflows { isScrollEnabled = overflows }
        return max(lineHeight + inset, min(natural, tallest))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        revealCaret()
    }

    /// Text set from outside (Paste button, restored draft) and a resize do not
    /// scroll on their own; without this the end of a long draft stays hidden.
    func revealCaret() {
        if isScrollEnabled {
            scrollRangeToVisible(selectedRange)
        } else if contentOffset != .zero {
            contentOffset = .zero
        }
    }

    /// Make first-responder status match what the screen asked for. A request
    /// made before the view is in a window is retried on the next update.
    func syncFocus(requested: Bool) {
        switch RemoteComposerInputPolicy.focusChange(requested: requested, isFirstResponder: isFirstResponder) {
        case .takeKeyboard: becomeFirstResponder()
        case .releaseKeyboard: resignFirstResponder()
        case nil: break
        }
    }

    override func insertText(_ text: String) {
        if RemoteComposerInputPolicy.shouldSubmit(insertedText: text, isPasting: isPasting,
                                                  holdToSend: holdToSend) {
            onSubmit?()
        } else {
            super.insertText(text)
        }
    }

    override func paste(_ sender: Any?) {
        performPaste { super.paste(sender) }
    }

    // Item providers and paste permission can resolve after paste(_:) returns.
    // This delegate owns final insertion, including asynchronous paste/drop.
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                         performPasteOf attributedString: NSAttributedString,
                                         to textRange: UITextRange) -> UITextRange {
        let offset = offset(from: beginningOfDocument, to: textRange.start)
        performPaste { replace(textRange, withText: attributedString.string) }
        // Programmatic UITextInput replacement need not emit the editing delegate.
        // Publish the final content so SwiftUI's Send action sees this paste.
        delegate?.textViewDidChange?(self)
        guard let start = position(from: beginningOfDocument, offset: offset),
              let end = position(from: start, offset: attributedString.string.utf16.count),
              let inserted = self.textRange(from: start, to: end) else { return textRange }
        return inserted
    }

    /// Keep the whole UIKit paste operation inside the event-provenance guard.
    func performPaste(_ operation: () -> Void) {
        let previous = isPasting
        isPasting = true
        defer { isPasting = previous }
        operation()
    }
}
