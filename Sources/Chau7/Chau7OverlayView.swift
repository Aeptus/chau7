import SwiftUI
import AppKit

struct Chau7OverlayView: View {
    @ObservedObject var overlayModel: OverlayTabsModel
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            terminalStack
        }
        .background(Color.clear)
        .onAppear {
            overlayModel.configureRenderSuspension(
                enabled: appModel.isSuspendBackgroundRendering,
                delay: appModel.suspendRenderDelaySeconds
            )
        }
        .onChange(of: appModel.isSuspendBackgroundRendering) { _ in
            overlayModel.configureRenderSuspension(
                enabled: appModel.isSuspendBackgroundRendering,
                delay: appModel.suspendRenderDelaySeconds
            )
        }
        .onChange(of: appModel.suspendRenderDelayText) { _ in
            overlayModel.configureRenderSuspension(
                enabled: appModel.isSuspendBackgroundRendering,
                delay: appModel.suspendRenderDelaySeconds
            )
        }
    }

    private var topBar: some View {
        let selected = overlayModel.selectedTab
        let session = selected?.session
        return HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(overlayModel.tabs) { tab in
                        TabButton(
                            title: tab.displayTitle,
                            path: tab.session.displayPath(),
                            session: tab.session,
                            isSelected: tab.id == overlayModel.selectedTabID,
                            isSuspended: overlayModel.isTabSuspended(tab.id),
                            tabColor: tab.effectiveColor,  // F05: Use effective color (auto or manual)
                            commandBadge: tab.commandBadge,  // F20: Last command badge
                            isBroadcastIncluded: overlayModel.isBroadcastMode && !overlayModel.broadcastExcludedTabIDs.contains(tab.id),  // F13
                            onSelect: { overlayModel.selectTab(id: tab.id) },
                            onRename: { overlayModel.beginRename(tabID: tab.id) },
                            onClose: { overlayModel.closeTab(id: tab.id) }
                        )
                    }

                    Button {
                        overlayModel.newTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Spacer()

            if let session, session.isGitRepo {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                    Text(session.gitBranch ?? "Git")
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.20))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.05)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var terminalStack: some View {
        ZStack(alignment: .top) {
            // Keep all tab views alive so background processes continue running.
            ForEach(overlayModel.tabs) { tab in
                let isSelected = tab.id == overlayModel.selectedTabID
                let isSuspended = overlayModel.isTabSuspended(tab.id)
                TerminalViewRepresentable(model: tab.session, isSuspended: isSuspended)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }

            if overlayModel.isSearchVisible {
                SearchOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if overlayModel.isRenameVisible {
                RenameOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // F16: Clipboard History
            if overlayModel.isClipboardHistoryVisible {
                ClipboardHistoryOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // F17: Bookmarks
            if overlayModel.isBookmarkListVisible {
                BookmarkListOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

struct TabButton: View {
    let title: String
    let path: String
    @ObservedObject var session: TerminalSessionModel
    let isSelected: Bool
    let isSuspended: Bool
    let tabColor: TabColor
    let commandBadge: String?  // F20: Last command badge
    let isBroadcastIncluded: Bool  // F13: Broadcast indicator
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void

    var body: some View {
        let indicatorColor = isSuspended
            ? Color.gray.opacity(0.6)
            : (isSelected ? tabColor.color : tabColor.color.opacity(0.6))

        HStack(spacing: 8) {
            Text(title.isEmpty ? "Shell" : title)
                .font(.custom("Avenir Next", size: 12).weight(.semibold))
                .lineLimit(1)
            Text("- \(path)")
                .font(.custom("Avenir Next", size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            if isSuspended {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Rendering suspended")
            }

            // F20: Command badge (duration + exit status)
            if let badge = commandBadge {
                Text(badge)
                    .font(.custom("Avenir Next", size: 10).weight(.medium))
                    .foregroundStyle(badge.contains("✗") ? .red : .green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.2))
                    .clipShape(Capsule())
            }

            // F13: Broadcast indicator
            if isBroadcastIncluded {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            if session.isGitRepo {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? tabColor.color.opacity(0.25)
                : Color.black.opacity(0.18)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                onRename()
            }
        )
        .onTapGesture {
            onSelect()
        }
    }
}

struct SearchOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search terminal", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onChange(of: model.searchQuery) { _ in
                        model.refreshSearch()
                    }
                    .onSubmit {
                        model.nextMatch()
                    }

                Text("\(model.searchMatchCount) matches")
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)

                // Case sensitivity toggle (Issue #23 fix)
                Toggle(isOn: $model.isCaseSensitive) {
                    Text("Aa")
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Case sensitive search")
                .onChange(of: model.isCaseSensitive) { _ in
                    model.refreshSearch()
                }

                Button("Close") {
                    model.toggleSearch()
                }
                .controlSize(.small)
                // Note: Escape is handled by AppDelegate.handleKeyEvent()
            }

            if model.searchResults.isEmpty && !model.searchQuery.isEmpty {
                Text("No results")
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)
            } else if !model.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.searchResults, id: \.self) { line in
                        SearchResultRow(line: line, query: model.searchQuery, caseSensitive: model.isCaseSensitive)
                    }
                }
                .frame(maxHeight: 120)
            }

            HStack(spacing: 8) {
                Button("Prev") { model.previousMatch() }
                    .controlSize(.small)
                    // Note: Cmd+Shift+G is in menu commands
                Button("Next") { model.nextMatch() }
                    .controlSize(.small)
                    // Note: Cmd+G is in menu commands
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .onAppear { isFocused = true }
    }
}

struct SearchResultRow: View {
    let line: String
    let query: String
    var caseSensitive: Bool = false

    var body: some View {
        if query.isEmpty {
            Text(line)
                .font(.custom("Avenir Next", size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text(attributedLine())
                .font(.custom("Avenir Next", size: 11))
        }
    }

    private func attributedLine() -> AttributedString {
        var result = AttributedString(line)

        // Use appropriate case handling based on setting
        let searchLine = caseSensitive ? line : line.lowercased()
        let searchQuery = caseSensitive ? query : query.lowercased()

        var searchRange = searchLine.startIndex..<searchLine.endIndex
        while let range = searchLine.range(of: searchQuery, range: searchRange) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].foregroundColor = .white
                result[attrRange].backgroundColor = .orange.opacity(0.6)
            }
            searchRange = range.upperBound..<searchLine.endIndex
        }
        return result
    }
}

struct RenameOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Tab name", text: $model.renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    // Issue #18 fix: Allow Enter key to confirm rename
                    .onSubmit {
                        model.commitRename()
                    }

                Button("Cancel") { model.cancelRename() }
                    .controlSize(.small)
                    // Note: Escape is handled by AppDelegate.handleKeyEvent()
                Button("Save") { model.commitRename() }
                    .controlSize(.small)
                    // Note: Enter triggers onSubmit on the TextField
            }

            HStack(spacing: 8) {
                ForEach(TabColor.allCases) { color in
                    Button {
                        model.renameColor = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(model.renameColor == color ? 0.9 : 0.2), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .onAppear { isFocused = true }
    }
}

// StatusBadge was removed - it was unused in the UI

// MARK: - F16: Clipboard History Overlay

struct ClipboardHistoryOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var clipboardManager = ClipboardHistoryManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard History")
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                Spacer()
                Button("Clear") {
                    clipboardManager.clear()
                }
                .controlSize(.small)
                Button("Close") {
                    model.toggleClipboardHistory()
                }
                .controlSize(.small)
            }

            if clipboardManager.items.isEmpty {
                Text("No clipboard history yet.")
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
                .frame(maxHeight: 200)
            }

            Text("Click to paste • ⌘V to paste selected")
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .frame(maxWidth: 400)
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
                .help(item.isPinned ? "Unpin" : "Pin")

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onPaste()
        }
    }
}

// MARK: - F17: Bookmarks Overlay

struct BookmarkListOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
    @State private var newBookmarkLabel: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bookmarks")
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                Spacer()
                Button("Add") {
                    model.addBookmark(label: newBookmarkLabel.isEmpty ? nil : newBookmarkLabel)
                    newBookmarkLabel = ""
                }
                .controlSize(.small)
                Button("Close") {
                    model.toggleBookmarkList()
                }
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                TextField("Bookmark label (optional)", text: $newBookmarkLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            let bookmarks = model.getBookmarksForCurrentTab()
            if bookmarks.isEmpty {
                Text("No bookmarks for this tab.")
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
                .frame(maxHeight: 180)
            }

            Text("⌘B to add bookmark • Click to jump")
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .frame(maxWidth: 400)
    }
}

struct BookmarkRow: View {
    let bookmark: BookmarkManager.Bookmark
    let onJump: () -> Void
    let onRemove: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
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
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onJump()
        }
    }
}
