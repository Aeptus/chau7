import SwiftUI
import UIKit

struct RemoteTerminalSelectionSnapshot: Identifiable {
    let id = UUID()
    let text: String
}

/// A frozen copy uses native iOS selection without competing with live scrolling.
struct RemoteTerminalSelectionView: View {
    let text: String
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectionText(text: text, fontSize: fontSize)
                .overlay {
                    if text.isEmpty { Text("No terminal text yet").foregroundStyle(.secondary) }
                }
                .navigationTitle("Select Terminal Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy All") { UIPasteboard.general.string = text }
                            .disabled(text.isEmpty)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("Long-press text to select and copy.")
                        .font(.footnote).foregroundStyle(.secondary).padding(12)
                }
        }
    }
}

private struct SelectionText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    func makeUIView(context: Context) -> RemoteTerminalSelectionTextView {
        RemoteTerminalSelectionTextView(text: text, fontSize: fontSize)
    }
    func updateUIView(_ view: RemoteTerminalSelectionTextView, context: Context) {
        view.setSnapshot(text, fontSize: fontSize)
    }
}

final class RemoteTerminalSelectionTextView: UITextView {
    init(text: String, fontSize: CGFloat) {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        backgroundColor = .systemBackground
        textColor = .label
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textContainer.lineFragmentPadding = 0
        dataDetectorTypes = []
        accessibilityLabel = "Terminal text for selection"
        setSnapshot(text, fontSize: fontSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSnapshot(_ snapshot: String, fontSize: CGFloat) {
        if text != snapshot {
            text = snapshot
            selectedRange = NSRange(location: 0, length: 0)
        }
        if font?.pointSize != fontSize {
            font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }
}
