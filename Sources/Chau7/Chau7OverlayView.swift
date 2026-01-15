import SwiftUI
import AppKit

// MARK: - Overlay Colors

private let overlayPanelBackground = Color(red: 0.10, green: 0.10, blue: 0.10)
private let overlayRowBackground = Color(red: 0.16, green: 0.16, blue: 0.16)
private let overlayChipBackground = Color(red: 0.22, green: 0.22, blue: 0.22)

// MARK: - Overlay Layout Constants

enum OverlayLayout {
    // Panel sizes
    static let searchPanelMaxWidth: CGFloat = 400
    static let commandPanelMaxWidth: CGFloat = 400
    static let snippetPanelMaxWidth: CGFloat = 520
    static let colorPickerMaxWidth: CGFloat = 140

    // Content heights
    static let searchMatchListMaxHeight: CGFloat = 120
    static let commandListMaxHeight: CGFloat = 200
    static let snippetPreviewMaxHeight: CGFloat = 180
    static let snippetListMaxHeight: CGFloat = 260
    static let colorPreviewHeight: CGFloat = 90

    // Component sizes
    static let iconSize: CGFloat = 24
    static let smallIconSize: CGFloat = 20
    static let commandListMinWidth: CGFloat = 200

    // Tab bar
    static let tabBarHeight: CGFloat = 28
}

// MARK: - Safari-style Unified Toolbar Delegate

/// Toolbar delegate that provides a tab bar as the main toolbar item.
/// Uses Safari's unified toolbar style for seamless traffic light integration.
final class TabBarToolbarDelegate: NSObject, NSToolbarDelegate {
    static let shared = TabBarToolbarDelegate()

    private static let tabBarItemIdentifier = NSToolbarItem.Identifier("TabBarItem")
    private var tabsModels: [NSToolbar.Identifier: OverlayTabsModel] = [:]

    private override init() {
        super.init()
    }

    func registerTabsModel(_ model: OverlayTabsModel, for toolbarIdentifier: NSToolbar.Identifier) {
        tabsModels[toolbarIdentifier] = model
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabBarItemIdentifier,
              let tabsModel = tabsModels[toolbar.identifier] else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let tabBarView = ToolbarTabBarView(overlayModel: tabsModel)
        let hostingView = NSHostingView(rootView: tabBarView)
        item.view = hostingView

        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabBarItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabBarItemIdentifier]
    }
}

/// SwiftUI view for the tab bar that goes in the unified toolbar
private struct ToolbarTabBarView: View {
    @ObservedObject var overlayModel: OverlayTabsModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        let selected = overlayModel.selectedTab
        let session = selected?.session

        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(overlayModel.tabs) { tab in
                        if let session = tab.session {
                            TabButton(
                                customTitle: tab.customTitle,
                                session: session,
                                isSelected: tab.id == overlayModel.selectedTabID,
                                isSuspended: overlayModel.isTabSuspended(tab.id),
                                tabColor: tab.effectiveColor,
                                commandBadge: tab.commandBadge,
                                isBroadcastIncluded: overlayModel.isBroadcastMode && !overlayModel.broadcastExcludedTabIDs.contains(tab.id),
                                onSelect: { overlayModel.selectTab(id: tab.id) },
                                onRename: { overlayModel.beginRename(tabID: tab.id) },
                                onClose: { overlayModel.closeTab(id: tab.id) }
                            )
                        } else {
                            TabButtonFallback(
                                title: tab.displayTitle,
                                isSelected: tab.id == overlayModel.selectedTabID,
                                isSuspended: overlayModel.isTabSuspended(tab.id),
                                tabColor: tab.effectiveColor,
                                commandBadge: tab.commandBadge,
                                isBroadcastIncluded: overlayModel.isBroadcastMode && !overlayModel.broadcastExcludedTabIDs.contains(tab.id),
                                onSelect: { overlayModel.selectTab(id: tab.id) },
                                onRename: { overlayModel.beginRename(tabID: tab.id) },
                                onClose: { overlayModel.closeTab(id: tab.id) }
                            )
                        }
                    }

                    Button {
                        overlayModel.newTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .accessibilityLabel("New tab")
                    .accessibilityHint("Opens a new terminal tab")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
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
                .accessibilityLabel("Git branch: \(session.gitBranch ?? "unknown")")
            }
        }
        .padding(.trailing, 8)
        .frame(height: OverlayLayout.tabBarHeight)
        .frame(maxWidth: .infinity)
    }
}

struct Chau7OverlayView: View {
    @ObservedObject var overlayModel: OverlayTabsModel
    @ObservedObject var appModel: AppModel
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        // Tab bar is now in the unified toolbar (Safari-style)
        terminalStack
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

    private var terminalStack: some View {
        ZStack(alignment: .top) {
            // Keep all tab views alive so background processes continue running.
            ForEach(overlayModel.tabs) { tab in
                let isSelected = tab.id == overlayModel.selectedTabID
                let isSuspended = overlayModel.isTabSuspended(tab.id)
                SplitPaneView(controller: tab.splitController, isSuspended: isSuspended, isActive: isSelected)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }

            if overlayModel.hasActiveOverlay {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        overlayModel.dismissOverlays()
                    }
                    .zIndex(5)
            }

            if overlayModel.isSearchVisible {
                SearchOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }

            if overlayModel.isRenameVisible {
                RenameOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }

            // F16: Clipboard History
            if overlayModel.isClipboardHistoryVisible {
                ClipboardHistoryOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }

            // F17: Bookmarks
            if overlayModel.isBookmarkListVisible {
                BookmarkListOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }

            // F21: Snippets
            if overlayModel.isSnippetManagerVisible {
                SnippetManagerOverlayView(model: overlayModel)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }

            // Task Lifecycle (v1.1) - Candidate banner at top
            if let candidate = overlayModel.currentCandidate {
                TaskCandidateView(
                    candidate: candidate,
                    onConfirm: { overlayModel.confirmTaskCandidate() },
                    onDismiss: { overlayModel.dismissTaskCandidate() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(15)
            }

            // Task Lifecycle (v1.1) - Assessment panel
            if overlayModel.isTaskAssessmentVisible, let task = overlayModel.currentTask {
                VStack {
                    Spacer()
                    TaskAssessmentView(
                        task: task,
                        onApprove: { note in overlayModel.assessTask(approved: true, note: note) },
                        onFail: { note in overlayModel.assessTask(approved: false, note: note) },
                        onCancel: { overlayModel.dismissTaskAssessment() }
                    )
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(15)
            }

            // Task Lifecycle (v1.1) - Active task bar at bottom
            if let task = overlayModel.currentTask, !overlayModel.isTaskAssessmentVisible {
                VStack {
                    Spacer()
                    TaskAssessmentBar(
                        task: task,
                        onApprove: { overlayModel.assessTask(approved: true, note: nil) },
                        onFail: { overlayModel.showTaskAssessment() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(12)
            }
        }
        .modifier(ReduceMotionAnimationModifier(
            values: [
                overlayModel.isSearchVisible,
                overlayModel.isRenameVisible,
                overlayModel.isClipboardHistoryVisible,
                overlayModel.isBookmarkListVisible,
                overlayModel.isSnippetManagerVisible,
                overlayModel.currentCandidate != nil,
                overlayModel.currentTask != nil,
                overlayModel.isTaskAssessmentVisible
            ]
        ))
    }
}

/// Modifier that applies animations with reduce motion support
private struct ReduceMotionAnimationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let values: [Bool]

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: values)
    }
}

struct TabButton: View {
    let customTitle: String?
    @ObservedObject var session: TerminalSessionModel
    let isSelected: Bool
    let isSuspended: Bool
    let tabColor: TabColor
    let commandBadge: String?  // F20: Last command badge
    let isBroadcastIncluded: Bool  // F13: Broadcast indicator
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void

    private var resolvedTitle: String {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        if let activeName = session.activeAppName, !activeName.isEmpty {
            return activeName
        }
        return "Shell"
    }

    private var resolvedPath: String {
        session.displayPath()
    }

    /// Returns the bundled logo for the detected AI product, or nil for regular shell.
    private var aiProductLogo: Image? {
        guard let appName = session.activeAppName else { return nil }
        return AIAgentLogo.image(forAppName: appName)
    }

    var body: some View {
        let indicatorColor = isSuspended
            ? Color.gray.opacity(0.6)
            : (isSelected ? tabColor.color : tabColor.color.opacity(0.6))

        HStack(spacing: 8) {
            // AI product logo (persists even when tab is renamed)
            if let logo = aiProductLogo {
                logo
                    .resizable()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }

            Text(resolvedTitle)
                .font(.custom("Avenir Next", size: 12).weight(.semibold))
                .lineLimit(1)
            Text("- \(resolvedPath)")
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
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            isSelected
                ? tabColor.color.opacity(0.25)
                : Color.black.opacity(0.18)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resolvedTitle) tab, \(resolvedPath)")
        .accessibilityHint(isSelected ? "Selected. Double-tap to rename" : "Double-tap to select, then double-tap to rename")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

struct TabButtonFallback: View {
    let title: String
    let isSelected: Bool
    let isSuspended: Bool
    let tabColor: TabColor
    let commandBadge: String?
    let isBroadcastIncluded: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void

    var body: some View {
        let indicatorColor = isSuspended
            ? Color.gray.opacity(0.6)
            : (isSelected ? tabColor.color : tabColor.color.opacity(0.6))

        HStack(spacing: 8) {
            Text(title)
                .font(.custom("Avenir Next", size: 12).weight(.semibold))
                .lineLimit(1)

            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            if let badge = commandBadge {
                Text(badge)
                    .font(.custom("Avenir Next", size: 10).weight(.medium))
                    .foregroundStyle(badge.contains("✗") ? .red : .green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.2))
                    .clipShape(Capsule())
            }

            if isBroadcastIncluded {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            isSelected
                ? tabColor.color.opacity(0.25)
                : Color.black.opacity(0.18)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) tab")
        .accessibilityHint(isSelected ? "Selected. Double-tap to rename" : "Double-tap to select, then double-tap to rename")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

struct DraggableOverlay<Content: View>: View {
    let id: String
    let workspace: String?
    @ViewBuilder let content: Content
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var dragOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    init(id: String, workspace: String?, @ViewBuilder content: () -> Content) {
        self.id = id
        self.workspace = workspace
        self.content = content()
    }

    var body: some View {
        let workspaceKey = workspace ?? "global"
        content
            .offset(x: dragOffset.width + dragTranslation.width, y: dragOffset.height + dragTranslation.height)
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        dragOffset.width += value.translation.width
                        dragOffset.height += value.translation.height
                        settings.setOverlayOffset(dragOffset, for: id, workspace: workspace)
                    }
            )
            .onAppear {
                dragOffset = settings.overlayOffset(for: id, workspace: workspace)
            }
            .onChange(of: settings.overlayPositionsVersion) { _ in
                dragOffset = settings.overlayOffset(for: id, workspace: workspace)
            }
            .onChange(of: workspaceKey) { _ in
                dragOffset = settings.overlayOffset(for: id, workspace: workspace)
            }
    }
}

struct SearchOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var settings = FeatureSettings.shared
    @FocusState private var isFocused: Bool

    var body: some View {
        DraggableOverlay(id: "search", workspace: model.overlayWorkspaceIdentifier) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search terminal", text: $model.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .accessibilityLabel("Search terminal")
                        .accessibilityHint("Enter text to search in terminal output")
                        .onChange(of: model.searchQuery) { _ in
                            model.refreshSearch()
                        }
                        .onSubmit {
                            model.nextMatch()
                        }

                    Text("\(model.searchMatchCount) matches")
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(model.searchMatchCount) matches found")

                    // Case sensitivity toggle (Issue #23 fix)
                    Toggle(isOn: $model.isCaseSensitive) {
                        Text("Aa")
                            .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Case sensitive search")
                    .accessibilityLabel("Case sensitive")
                    .accessibilityHint(model.isCaseSensitive ? "Currently enabled" : "Currently disabled")
                    .onChange(of: model.isCaseSensitive) { _ in
                        model.refreshSearch()
                    }
                    .disabled(model.isSemanticSearch)

                    Toggle(isOn: $model.isRegexSearch) {
                        Text(".*")
                            .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Regex search")
                    .accessibilityLabel("Regular expression search")
                    .accessibilityHint(model.isRegexSearch ? "Currently enabled" : "Currently disabled")
                    .onChange(of: model.isRegexSearch) { _ in
                        model.refreshSearch()
                    }
                    .disabled(model.isSemanticSearch)

                    if settings.isSemanticSearchEnabled {
                        Toggle(isOn: $model.isSemanticSearch) {
                            Text("Cmd")
                                .font(.custom("Avenir Next", size: 11).weight(.semibold))
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Semantic command search")
                        .accessibilityLabel("Semantic command search")
                        .onChange(of: model.isSemanticSearch) { _ in
                            model.refreshSearch()
                        }
                    }

                    Button("Close") {
                        model.toggleSearch()
                    }
                    .controlSize(.small)
                    // Note: Escape is handled by AppDelegate.handleKeyEvent()
                }

                if let error = model.searchError {
                    Text(error)
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.orange)
                } else if model.searchResults.isEmpty && !model.searchQuery.isEmpty {
                    Text("No results")
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                } else if !model.searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.searchResults, id: \.self) { line in
                            SearchResultRow(
                                line: line,
                                query: model.searchQuery,
                                caseSensitive: model.isCaseSensitive,
                                useRegex: model.isRegexSearch
                            )
                        }
                    }
                    .frame(maxHeight: OverlayLayout.searchMatchListMaxHeight)
                }

                HStack(spacing: 8) {
                    Button("Prev") { model.previousMatch() }
                        .controlSize(.small)
                        .accessibilityLabel("Previous match")
                        .accessibilityHint("Go to previous search result")
                        // Note: Cmd+Shift+G is in menu commands
                    Button("Next") { model.nextMatch() }
                        .controlSize(.small)
                        .accessibilityLabel("Next match")
                        .accessibilityHint("Go to next search result")
                        // Note: Cmd+G is in menu commands
                }
            }
            .padding(10)
            .background(overlayPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .onAppear { isFocused = true }
        }
    }
}

struct SearchResultRow: View {
    let line: String
    let query: String
    var caseSensitive: Bool = false
    var useRegex: Bool = false

    var body: some View {
        if query.isEmpty || useRegex {
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
        DraggableOverlay(id: "rename", workspace: model.overlayWorkspaceIdentifier) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Tab name", text: $model.renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: OverlayLayout.commandListMinWidth)
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
                    Text("Color:")
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(TabColor.allCases) { color in
                        Button {
                            model.renameColor = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(model.renameColor == color ? 1.0 : 0.3), lineWidth: model.renameColor == color ? 2.5 : 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(overlayPanelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .onAppear { isFocused = true }
        }
    }
}

// StatusBadge was removed - it was unused in the UI

// MARK: - F16: Clipboard History Overlay

struct ClipboardHistoryOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var clipboardManager = ClipboardHistoryManager.shared

    var body: some View {
        DraggableOverlay(id: "clipboard", workspace: model.overlayWorkspaceIdentifier) {
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
                    .frame(maxHeight: OverlayLayout.commandListMaxHeight)
                }

                Text("Click to paste • ⌘V to paste selected")
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(overlayPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .frame(maxWidth: OverlayLayout.commandPanelMaxWidth)
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
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clipboard item: \(item.preview)")
        .accessibilityHint(item.isPinned ? "Pinned. Tap to paste" : "Tap to paste")
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
        DraggableOverlay(id: "bookmarks", workspace: model.overlayWorkspaceIdentifier) {
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
                    .frame(maxHeight: OverlayLayout.snippetPreviewMaxHeight)
                }

                Text("⌘B to add bookmark • Click to jump")
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(overlayPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .frame(maxWidth: OverlayLayout.searchPanelMaxWidth)
        }
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
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bookmark: \(bookmark.label ?? bookmark.linePreview)")
        .accessibilityHint("Tap to jump to this location")
        .onTapGesture {
            onJump()
        }
    }
}

// MARK: - F21: Snippets Overlay

struct SnippetManagerOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var manager = SnippetManager.shared
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var query: String = ""
    @State private var draft = SnippetDraft()
    @State private var editingEntry: SnippetEntry?
    @State private var isEditorVisible = false
    @State private var deleteTarget: SnippetEntry?
    @FocusState private var isFocused: Bool

    private var repoAvailable: Bool {
        FeatureSettings.shared.isRepoSnippetsEnabled && manager.repoRoot != nil
    }

    private var preferredSource: SnippetSource {
        repoAvailable ? .repo : .global
    }

    var body: some View {
        DraggableOverlay(id: "snippets", workspace: model.overlayWorkspaceIdentifier) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Snippets")
                        .font(.custom("Avenir Next", size: 12).weight(.semibold))
                    Spacer()
                    Button("New") {
                        startCreate()
                    }
                    .controlSize(.small)
                    .disabled(!settings.isSnippetsEnabled)
                    Button("Close") {
                        model.toggleSnippetManager()
                    }
                    .controlSize(.small)
                }

                if !settings.isSnippetsEnabled {
                    Text("Snippets are disabled in Settings.")
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    TextField("Search snippets", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($isFocused)

                    if isEditorVisible {
                        SnippetEditorView(
                            draft: $draft,
                            isNew: editingEntry == nil,
                            repoAvailable: repoAvailable,
                            onCancel: cancelEdit,
                            onSave: saveEdit
                        )
                    } else {
                        let filtered = manager.filteredEntries(query: query)
                        if filtered.isEmpty {
                            Text("No snippets found.")
                                .font(.custom("Avenir Next", size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(filtered) { entry in
                                        SnippetRowView(
                                            entry: entry,
                                            onInsert: { model.insertSnippet(entry) },
                                            onEdit: { startEdit(entry) },
                                            onDelete: { deleteTarget = entry }
                                        )
                                    }
                                }
                            }
                            .frame(maxHeight: OverlayLayout.snippetListMaxHeight)
                        }
                    }
                }

                if let root = manager.repoRoot, settings.isRepoSnippetsEnabled {
                    Text("Repo: \(root)")
                        .font(.custom("Avenir Next", size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(10)
            .background(overlayPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .frame(maxWidth: OverlayLayout.snippetPanelMaxWidth)
            .onAppear { isFocused = true }
            .alert(item: $deleteTarget) { entry in
                Alert(
                    title: Text("Delete snippet?"),
                    message: Text(entry.snippet.title),
                    primaryButton: .destructive(Text("Delete")) {
                        manager.deleteSnippet(entry)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private func startCreate() {
        draft = SnippetDraft(source: preferredSource)
        editingEntry = nil
        isEditorVisible = true
    }

    private func startEdit(_ entry: SnippetEntry) {
        draft = SnippetDraft(
            id: entry.snippet.id,
            title: entry.snippet.title,
            body: entry.snippet.body,
            tagsText: entry.snippet.tags.joined(separator: ", "),
            folder: entry.snippet.folder ?? "",
            shellsText: entry.snippet.shells?.joined(separator: ", ") ?? "",
            source: entry.source
        )
        editingEntry = entry
        isEditorVisible = true
    }

    private func cancelEdit() {
        isEditorVisible = false
        editingEntry = nil
    }

    private func saveEdit() {
        let cleaned = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var finalDraft = draft
        finalDraft.title = cleaned
        if let entry = editingEntry {
            manager.updateSnippet(entry: entry, with: finalDraft)
        } else {
            manager.createSnippet(from: finalDraft)
        }
        isEditorVisible = false
        editingEntry = nil
    }
}

struct SnippetRowView: View {
    let entry: SnippetEntry
    let onInsert: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.snippet.title)
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))

                    Text(entry.source.displayName.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(overlayChipBackground)
                        .clipShape(Capsule())

                    if entry.isOverridden {
                        Text("OVERRIDDEN")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(entry.snippet.body)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !entry.snippet.tags.isEmpty {
                    Text(entry.snippet.tags.joined(separator: ", "))
                        .font(.custom("Avenir Next", size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onInsert) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Insert")

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Snippet: \(entry.snippet.title)")
        .accessibilityHint("Tap to insert into terminal")
        .onTapGesture {
            onInsert()
        }
    }
}

struct SnippetEditorView: View {
    @Binding var draft: SnippetDraft
    let isNew: Bool
    let repoAvailable: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "New Snippet" : "Edit Snippet")
                .font(.custom("Avenir Next", size: 11).weight(.semibold))

            HStack(spacing: 8) {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                TextField("ID (optional)", text: $draft.id)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
            }

            TextEditor(text: $draft.body)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: OverlayLayout.colorPreviewHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            HStack(spacing: 8) {
                TextField("Tags (comma separated)", text: $draft.tagsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                TextField("Folder", text: $draft.folder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
            }

            HStack(spacing: 8) {
                TextField("Shells (zsh, bash, fish)", text: $draft.shellsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))

                Picker("Location", selection: $draft.source) {
                    Text(SnippetSource.global.displayName).tag(SnippetSource.global)
                    Text(SnippetSource.profile.displayName).tag(SnippetSource.profile)
                    if repoAvailable {
                        Text(SnippetSource.repo.displayName).tag(SnippetSource.repo)
                    }
                }
                .frame(maxWidth: OverlayLayout.colorPickerMaxWidth)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .controlSize(.small)
                Button("Save") { onSave() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
