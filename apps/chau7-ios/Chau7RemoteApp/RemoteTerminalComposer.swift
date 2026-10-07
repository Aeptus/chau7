import Chau7Core
import SwiftUI
import UIKit

/// Native input events distinguish Return from paste, including a single pasted newline.
struct RemoteTerminalComposer: UIViewRepresentable {
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
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
        }
        if focused.wrappedValue, !view.isFirstResponder { view.becomeFirstResponder() }
        if !focused.wrappedValue, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RemoteTerminalComposerTextView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(lineHeight + inset, min(natural.height, lineHeight * 4 + inset)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RemoteTerminalComposer
        init(_ parent: RemoteTerminalComposer) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused.wrappedValue = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused.wrappedValue = false }
    }
}

final class RemoteTerminalComposerTextView: UITextView, UITextPasteDelegate {
    var holdToSend = false
    var onSubmit: (() -> Void)?
    private var isPasting = false

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
