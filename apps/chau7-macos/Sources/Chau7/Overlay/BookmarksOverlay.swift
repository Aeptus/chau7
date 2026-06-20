import SwiftUI
import AppKit
import Chau7Core

// MARK: - F17: Bookmarks Overlay

struct BookmarkListOverlayView: View {
    var model: OverlayTabsModel
    var bookmarkManager = BookmarkManager.shared
    @State private var newBookmarkLabel = ""

    var body: some View {
        DraggableOverlay(id: "bookmarks", workspace: model.overlayWorkspaceIdentifier, maxWidth: OverlayLayout.searchPanelMaxWidth) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Bookmarks", "Bookmarks"))
                        .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    Spacer()
                    Button(L("Add", "Add")) {
                        model.addBookmark(label: newBookmarkLabel.isEmpty ? nil : newBookmarkLabel)
                        newBookmarkLabel = ""
                    }
                    .controlSize(.small)
                    Button(L("Close", "Close")) {
                        model.toggleBookmarkList()
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    TextField(L("Bookmark label (optional)", "Bookmark label (optional)"), text: $newBookmarkLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                let bookmarks = model.getBookmarksForCurrentTab()
                if bookmarks.isEmpty {
                    Text(L("No bookmarks for this tab.", "No bookmarks for this tab."))
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(bookmarks) { bookmark in
                                BookmarkRow(bookmark: bookmark, onJump: {
                                    model.jumpToBookmark(bookmark)
                                }, onRemove: {
                                    bookmarkManager.removeBookmark(bookmark)
                                })
                            }
                        }
                    }
                    .frame(maxHeight: OverlayLayout.snippetPreviewMaxHeight)
                }

                Text(L("⌘B to add bookmark • Click to jump", "⌘B to add bookmark • Click to jump"))
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

struct BookmarkRow: View {
    let bookmark: BookmarkManager.Bookmark
    let onJump: () -> Void
    let onRemove: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = LocalizationManager.shared.currentLanguage.locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                if let label = bookmark.label, !label.isEmpty {
                    Text(label)
                        .font(.custom("Avenir Next", size: 11).weight(.medium))
                }

                Text(bookmark.linePreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(Self.timeFormatter.string(from: bookmark.timestamp))
                    .font(.custom("Avenir Next", size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help(L("Remove", "Remove"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: L("accessibility.bookmark", "Bookmark: %@"),
                bookmark.label ?? bookmark.linePreview
            )
        )
        .accessibilityHint(L("Tap to jump to this location", "Tap to jump to this location"))
        .onTapGesture {
            onJump()
        }
    }
}

