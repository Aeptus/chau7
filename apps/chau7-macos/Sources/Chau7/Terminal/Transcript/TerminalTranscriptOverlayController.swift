import AppKit

final class TerminalTranscriptOverlayController {
    private let container = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let titleLabel = NSTextField(labelWithString: "Transcript")
    private var lastText = ""

    var isVisible: Bool {
        !container.isHidden
    }

    init() {
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        container.isHidden = true

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        container.addSubview(titleLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func attach(to parent: NSView) {
        guard container.superview == nil else { return }
        parent.addSubview(container)
        layout(in: parent.bounds)
    }

    func layout(in bounds: NSRect) {
        let inset: CGFloat = 14
        let width = max(240, bounds.width - inset * 2)
        let height = max(180, bounds.height * 0.72)
        container.frame = NSRect(
            x: inset,
            y: max(inset, bounds.height - height - inset),
            width: width,
            height: min(height, bounds.height - inset * 2)
        )
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        textView.maxSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    func show(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if text != lastText {
            lastText = text
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }

        container.isHidden = false
        container.superview?.addSubview(container, positioned: .above, relativeTo: nil)
    }

    func hide() {
        container.isHidden = true
    }

    func scroll(lines: Int, lineHeight: CGFloat) {
        guard isVisible else { return }

        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maxY = max(0, documentHeight - clipView.bounds.height)
        let currentY = clipView.bounds.origin.y
        let delta = CGFloat(lines) * max(1, lineHeight)
        let nextY = min(max(0, currentY - delta), maxY)
        clipView.scroll(to: NSPoint(x: 0, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
    }
}
