import SwiftUI
import AppKit
import Chau7Core

// MARK: - F16: Clipboard History Overlay

struct ClipboardHistoryOverlayView: View {
    var model: OverlayTabsModel
    var clipboardManager = ClipboardHistoryManager.shared

    var body: some View {
        DraggableOverlay(id: "clipboard", workspace: model.overlayWorkspaceIdentifier, maxWidth: OverlayLayout.commandPanelMaxWidth) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Clipboard History", "Clipboard History"))
                        .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    Spacer()
                    Button(L("Clear", "Clear")) {
                        clipboardManager.clear()
                    }
                    .controlSize(.small)
                    Button(L("Close", "Close")) {
                        model.toggleClipboardHistory()
                    }
                    .controlSize(.small)
                }

                if clipboardManager.items.isEmpty {
                    Text(L("No clipboard history yet.", "No clipboard history yet."))
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(clipboardManager.items) { item in
                                ClipboardItemRow(item: item, onPaste: {
                                    model.pasteFromClipboardHistory(item)
                                }, onPin: {
                                    clipboardManager.togglePin(item)
                                }, onRemove: {
                                    clipboardManager.remove(item)
                                })
                            }
                        }
                    }
                    .frame(maxHeight: OverlayLayout.commandListMaxHeight)
                }

                Text(L("Click to paste • ⌘V to paste selected", "Click to paste • ⌘V to paste selected"))
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardHistoryManager.ClipboardItem
    let onPaste: () -> Void
    let onPin: () -> Void
    let onRemove: () -> Void

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)

                Text(Self.timeFormatter.localizedString(for: item.timestamp, relativeTo: Date()))
                    .font(.custom("Avenir Next", size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onPin) {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? L("overlay.unpin", "Unpin") : L("overlay.pin", "Pin"))

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Remove", "Remove"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.clipboardItem", "Clipboard item: %@"), item.preview))
        .accessibilityHint(item.isPinned ? "Pinned. Tap to paste" : "Tap to paste")
        .onTapGesture {
            onPaste()
        }
    }
}

