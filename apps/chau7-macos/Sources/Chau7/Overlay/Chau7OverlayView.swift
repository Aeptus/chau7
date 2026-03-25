import SwiftUI
import AppKit
import Chau7Core

// MARK: - Overlay Colors

private let overlayPanelBackground = Color(red: 0.10, green: 0.10, blue: 0.10)
private let overlayRowBackground = Color(red: 0.16, green: 0.16, blue: 0.16)
private let overlayChipBackground = Color(red: 0.22, green: 0.22, blue: 0.22)

// MARK: - Toolbar Background

private struct ToolbarBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

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
    static let tabChipHeight: CGFloat = 22
}

// MARK: - Safari-style Unified Toolbar Delegate

/// Toolbar delegate that provides a tab bar as the main toolbar item.
/// Uses Safari's unified toolbar style for seamless traffic light integration.
final class TabBarToolbarDelegate: NSObject, NSToolbarDelegate {
    static let shared = TabBarToolbarDelegate()

    private static let tabBarItemIdentifier = NSToolbarItem.Identifier("TabBarItem")
    private var tabsModels: [NSToolbar.Identifier: OverlayTabsModel] = [:]
    private var toolbarItems: [NSToolbar.Identifier: NSToolbarItem] = [:]

    /// Cached hosting views to prevent recreation on toolbar reload.
    /// This is critical for stability - macOS may request toolbar items multiple times.
    private var cachedHostingViews: [NSToolbar.Identifier: TabBarHostingView] = [:]

    override private init() {
        super.init()
    }

    func registerTabsModel(_ model: OverlayTabsModel, for toolbarIdentifier: NSToolbar.Identifier) {
        tabsModels[toolbarIdentifier] = model
        // Invalidate cached view when model changes
        cachedHostingViews.removeValue(forKey: toolbarIdentifier)
    }

    /// Removes cached resources for a toolbar.
    /// Note: Currently unused because overlay windows are hidden (orderOut) rather than
    /// destroyed. The windows persist for the app's lifetime, so cached views are retained
    /// intentionally. Call this if window destruction is added in the future.
    func unregisterToolbar(_ toolbarIdentifier: NSToolbar.Identifier) {
        tabsModels.removeValue(forKey: toolbarIdentifier)
        cachedHostingViews.removeValue(forKey: toolbarIdentifier)
        toolbarItems.removeValue(forKey: toolbarIdentifier)
        Log.info("TabBarToolbarDelegate: unregistered toolbar \(toolbarIdentifier)")
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabBarItemIdentifier,
              let tabsModel = tabsModels[toolbar.identifier] else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        toolbarItems[toolbar.identifier] = item

        // Reuse cached hosting view if available (critical for stability)
        if let cachedView = cachedHostingViews[toolbar.identifier] {
            Log.info("TabBarToolbarDelegate: reusing cached hosting view for \(toolbar.identifier)")
            item.view = cachedView
            applySizing(to: item, model: tabsModel)
            return item
        }

        // Create new hosting view only if not cached
        Log.info("TabBarToolbarDelegate: creating new hosting view for \(toolbar.identifier)")
        let tabBarView = ToolbarTabBarView(overlayModel: tabsModel)
        let hostingView = TabBarHostingView(rootView: tabBarView)
        hostingView.tabsModel = tabsModel
        hostingView.refreshWindowTitles = { [weak tabsModel] in
            // Refresh window titles lazily from AppDelegate
            guard let model = tabsModel else { return }
            model.onRefreshWindowTitles?()
        }
        hostingView.installRightClickMonitor()

        // Cache for future requests
        cachedHostingViews[toolbar.identifier] = hostingView
        item.view = hostingView
        applySizing(to: item, model: tabsModel)

        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabBarItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabBarItemIdentifier]
    }

    /// Recreates the toolbar for a window, discarding the old NSHostingView entirely.
    /// This is the only reliable recovery when an NSHostingView in a toolbar becomes stale.
    /// Direct manipulation of the hosting view (needsLayout, rootView replacement) causes
    /// crashes from recursive constraint updates during layout cycles (EXC_BREAKPOINT in
    /// _postWindowNeedsUpdateConstraints).
    func recreateToolbar(for window: NSWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let oldToolbar = window.toolbar else {
            Log.warn("TabBarToolbarDelegate: no toolbar to recreate")
            return
        }
        let toolbarID = oldToolbar.identifier
        guard tabsModels[toolbarID] != nil else {
            Log.warn("TabBarToolbarDelegate: no model for \(toolbarID)")
            return
        }

        Log.info("TabBarToolbarDelegate: recreating toolbar \(toolbarID)")

        // 1. Remove the old toolbar entirely - this destroys the stale NSHostingView
        window.toolbar = nil
        cachedHostingViews.removeValue(forKey: toolbarID)
        toolbarItems.removeValue(forKey: toolbarID)

        // 2. Create a fresh toolbar - macOS will call our delegate to make a new NSHostingView
        let newToolbar = NSToolbar(identifier: toolbarID)
        newToolbar.displayMode = .iconOnly
        newToolbar.delegate = self
        window.toolbar = newToolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
            window.titlebarSeparatorStyle = .none
        }
        TitlebarBackgroundInstaller.install(for: window)

        Log.info("TabBarToolbarDelegate: toolbar recreated for \(toolbarID)")
        DispatchQueue.main.async { [weak self] in
            self?.updateToolbarItemSizing(for: window)
        }
    }

    func updateToolbarItemSizing(for window: NSWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let toolbar = window.toolbar else { return }
        guard let item = toolbarItems[toolbar.identifier] else { return }
        let model = tabsModels[toolbar.identifier]
        applySizing(to: item, model: model)
    }

    /// Checks if the hosting view has a valid visible frame. Calls `onCollapsed` if the
    /// view exists but has zero/tiny dimensions (NSToolbar layout engine collapsed it).
    func validateHostingViewFrame(for window: NSWindow, onCollapsed: () -> Void) {
        guard let toolbar = window.toolbar else { return }
        guard let item = toolbarItems[toolbar.identifier] else { return }
        guard let view = item.view as? TabBarHostingView else { return }
        let frame = view.frame
        if frame.width < 10 || frame.height < 5 {
            Log.warn("TabBarToolbarDelegate: hosting view collapsed — frame=\(frame) superview=\(view.superview != nil ? "present" : "nil") window=\(view.window != nil ? "present" : "nil")")
            onCollapsed()
        }
    }

    private func applySizing(to item: NSToolbarItem, model: OverlayTabsModel?) {
        let minWidth = max(180, CGFloat(model?.tabs.count ?? 1) * 30)
        let maxWidth: CGFloat
        let height: CGFloat
        if let window = model?.overlayWindow {
            maxWidth = max(window.contentLayoutRect.width, minWidth)
            let titlebarHeight = window.frame.height - window.contentLayoutRect.height
            height = max(OverlayLayout.tabBarHeight, titlebarHeight)
        } else {
            maxWidth = max(800, minWidth)
            height = OverlayLayout.tabBarHeight
        }
        if !maxWidth.isFinite || !height.isFinite || maxWidth <= 0 || height <= 0 {
            Log
                .warn(
                    "TabBarToolbarDelegate.applySizing: invalid toolbar metrics. model=\(model != nil ? "present" : "nil"), minWidth=\(Int(minWidth)), maxWidth=\(Int(maxWidth)), height=\(Int(height))"
                )
        }

        // item.minSize/maxSize are the only reliable toolbar sizing API.
        // Auto Layout constraints on the hosting view don't control toolbar space allocation.
        // Use KVC to avoid deprecation warnings — Apple deprecated these in macOS 12
        // but never shipped a replacement API (constraints don't control toolbar allocation).
        item.setValue(NSValue(size: NSSize(width: minWidth, height: height)), forKey: "minSize")
        item.setValue(NSValue(size: NSSize(width: maxWidth, height: height)), forKey: "maxSize")

        guard let view = item.view as? TabBarHostingView else { return }
        view.desiredSize = NSSize(width: maxWidth, height: height)

        if view.translatesAutoresizingMaskIntoConstraints {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        if let minConstraint = view.minWidthConstraint,
           let maxConstraint = view.maxWidthConstraint,
           let heightConstraint = view.heightConstraint {
            minConstraint.constant = minWidth
            maxConstraint.constant = maxWidth
            heightConstraint.constant = height
            return
        }

        let minConstraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
        let maxConstraint = view.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: height)
        view.minWidthConstraint = minConstraint
        view.maxWidthConstraint = maxConstraint
        view.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([minConstraint, maxConstraint, heightConstraint])
    }
}

private final class TabBarHostingView: NSHostingView<ToolbarTabBarView> {
    var minWidthConstraint: NSLayoutConstraint?
    var maxWidthConstraint: NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?

    /// The size the toolbar delegate wants this view to be.
    /// Used by intrinsicContentSize so NSToolbar's layout engine allocates
    /// the correct width instead of falling back to SwiftUI's minimum (180px).
    var desiredSize = NSSize(width: 800, height: OverlayLayout.tabBarHeight) {
        didSet {
            if desiredSize != oldValue {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        desiredSize
    }

    override var fittingSize: NSSize {
        desiredSize
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Reference to the overlay model for context menu actions.
    weak var tabsModel: OverlayTabsModel?
    /// Refresh window titles lazily on right-click (avoids expensive rebuild on every focus)
    var refreshWindowTitles: (() -> Void)?

    private var rightClickMonitor: Any?

    /// Install an application-level right-click monitor. NSHostingView swallows
    /// rightMouseDown internally, so we intercept before it reaches the view.
    func installRightClickMonitor() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }
            guard let model = self.tabsModel else { return event }

            guard let hitTab = self.hitTestTab(at: location, in: model) else { return event }

            // Refresh window titles lazily — only when the menu is actually shown
            self.refreshWindowTitles?()

            let menu = self.buildTabContextMenu(for: hitTab, model: model)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil // consume the event
        }
    }

    func removeRightClickMonitor() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    deinit {
        removeRightClickMonitor()
    }

    private func buildTabContextMenu(for tab: OverlayTab, model: OverlayTabsModel) -> NSMenu {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename Tab...", action: #selector(contextRenameTab(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = tab.id
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let idleItem = NSMenuItem(title: "Move to Idle Tabs", action: #selector(contextMoveToIdle(_:)), keyEquivalent: "")
        idleItem.target = self
        idleItem.representedObject = tab.id
        menu.addItem(idleItem)

        // "Move to Window" submenu — always shows "New Window", plus existing windows
        let windowSubmenu = NSMenu()
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(contextMoveToNewWindow(_:)), keyEquivalent: "")
        newWindowItem.target = self
        newWindowItem.representedObject = tab.id
        windowSubmenu.addItem(newWindowItem)
        if !model.otherWindowTitles.isEmpty {
            windowSubmenu.addItem(.separator())
            for window in model.otherWindowTitles {
                let item = NSMenuItem(title: window.title, action: #selector(contextMoveToWindow(_:)), keyEquivalent: "")
                item.target = self
                item.tag = window.id
                item.representedObject = tab.id
                windowSubmenu.addItem(item)
            }
        }
        let windowMenuItem = NSMenuItem(title: "Move to Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowSubmenu
        menu.addItem(windowMenuItem)

        // Repo grouping (manual mode or always for remove)
        let groupingMode = FeatureSettings.shared.repoGroupingMode
        if groupingMode != .off {
            menu.addItem(.separator())
            if tab.repoGroupID != nil {
                let ungroupItem = NSMenuItem(title: "Remove from Repo Group", action: #selector(contextRemoveFromGroup(_:)), keyEquivalent: "")
                ungroupItem.target = self
                ungroupItem.representedObject = tab.id
                menu.addItem(ungroupItem)
            }
            if groupingMode == .manual, tab.repoGroupID == nil, tab.session?.gitRootPath != nil {
                let groupItem = NSMenuItem(title: "Add to Repo Group", action: #selector(contextAddToGroup(_:)), keyEquivalent: "")
                groupItem.target = self
                groupItem.representedObject = tab.id
                menu.addItem(groupItem)

                let groupAllItem = NSMenuItem(title: "Group All Same Repo", action: #selector(contextGroupAllSameRepo(_:)), keyEquivalent: "")
                groupAllItem.target = self
                groupAllItem.representedObject = tab.id
                menu.addItem(groupAllItem)
            }
        }

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = tab.id
        menu.addItem(closeItem)

        return menu
    }

    @objc func contextAddToGroup(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.addTabToRepoGroup(tabID: tabID)
    }

    @objc func contextRemoveFromGroup(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.removeTabFromRepoGroup(tabID: tabID)
    }

    @objc func contextGroupAllSameRepo(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.groupAllSameRepo(asTab: tabID)
    }

    private func hitTestTab(at point: NSPoint, in model: OverlayTabsModel) -> OverlayTab? {
        let visibleTabs: [OverlayTab]
        if FeatureSettings.shared.groupIdleTabs {
            let now = Date()
            let idleIDs = Set(model.tabs.filter { tab in
                guard let session = tab.displaySession ?? tab.session,
                      tab.id != model.selectedTabID else { return false }
                return now.timeIntervalSince(session.lastActivityDate) > FeatureSettings.shared.idleTabThresholdSeconds
            }.map(\.id))
            visibleTabs = model.tabs.filter { !idleIDs.contains($0.id) }
        } else {
            visibleTabs = model.tabs
        }
        guard !visibleTabs.isEmpty else { return nil }

        // Count total items in the tab bar (tabs + repo tag chips for groups)
        var repoGroupsSeen = Set<String>()
        var repoTagCount = 0
        for tab in visibleTabs {
            if let gid = tab.repoGroupID, !repoGroupsSeen.contains(gid) {
                repoGroupsSeen.insert(gid)
                repoTagCount += 1
            }
        }
        let totalItems = visibleTabs.count + repoTagCount + 1 // +1 for new-tab button
        let itemWidth = bounds.width / CGFloat(totalItems)
        let rawIndex = Int(point.x / itemWidth)

        // Map rawIndex to tab index, skipping repo tag chip slots
        var tabIndex = 0
        var slot = 0
        var lastGroupID: String?
        for tab in visibleTabs {
            if let gid = tab.repoGroupID, gid != lastGroupID {
                // Repo tag chip occupies this slot
                if slot == rawIndex { return tab } // Click on tag → return first tab in group
                slot += 1
                lastGroupID = gid
            }
            if slot == rawIndex { return tab }
            slot += 1
            tabIndex += 1
        }
        return nil
    }

    // NSMenu validates items by checking if target responds to the action.
    // Implement NSMenuItemValidation to always enable our context menu items.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }

    @objc func contextRenameTab(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.beginRename(tabID: tabID)
    }

    @objc func contextMoveToIdle(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.forceTabIdle(id: tabID)
    }

    @objc func contextMoveToWindow(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.onMoveTabToWindow?(tabID, sender.tag)
    }

    @objc func contextMoveToNewWindow(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        // Use tag -1 to signal "create new window" to AppDelegate
        tabsModel?.onMoveTabToWindow?(tabID, -1)
    }

    @objc func contextCloseTab(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? UUID else { return }
        tabsModel?.closeTab(id: tabID)
    }
}

private struct TabDropIndicator: Equatable {
    let tabID: UUID
    let isAfter: Bool
}

private struct TabWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Preference key for tracking the global midX of each tab chip (for hover card positioning)
private struct TabMidXPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Preference key for tracking rendered tab count (for auto-recovery)
private struct RenderedTabCountKey: PreferenceKey {
    static var defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) {
        value += nextValue()
    }
}

/// Preference key for tracking tab bar size (for visibility-based recovery)
private struct TabBarSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Take the larger size (in case of multiple reports)
        if next.width > value.width || next.height > value.height {
            value = next
        }
    }
}

/// SwiftUI view for the tab bar that goes in the unified toolbar
private struct ToolbarTabBarView: View {
    @ObservedObject var overlayModel: OverlayTabsModel
    @State private var draggingTabID: UUID?
    @State private var tabWidths: [UUID: CGFloat] = [:]
    @State private var recoveryDebounce: DispatchWorkItem?

    /// Tabs idle for 10+ minutes (empty when feature is off or no tabs are idle).
    /// Reads the setting directly to avoid subscribing to all FeatureSettings changes.
    private var idleTabs: [OverlayTab] {
        guard FeatureSettings.shared.groupIdleTabs else { return [] }
        let threshold = FeatureSettings.shared.idleTabThresholdSeconds
        let now = Date()
        return overlayModel.tabs.filter { tab in
            guard let session = tab.displaySession ?? tab.session,
                  tab.id != overlayModel.selectedTabID else { return false }
            return now.timeIntervalSince(session.lastActivityDate) > threshold
        }
    }

    /// Tabs to show in the tab bar (all tabs minus idle ones)
    private var visibleTabs: [OverlayTab] {
        let idle = idleTabs
        if idle.isEmpty { return overlayModel.tabs }
        let idleIDs = Set(idle.map(\.id))
        return overlayModel.tabs.filter { !idleIDs.contains($0.id) }
    }
    // MARK: - Repo Grouping Segments

    /// A segment in the tab bar: either a single ungrouped tab or a group of tabs sharing a repo.
    private enum TabBarSegment: Identifiable {
        case single(OverlayTab)
        case group(id: String, displayName: String, tabs: [OverlayTab])

        var id: String {
            switch self {
            case .single(let tab): return tab.id.uuidString
            case .group(let id, _, _): return "group-\(id)"
            }
        }
    }

    /// Computes segments from visible tabs: contiguous runs of same repoGroupID become groups.
    private var tabBarSegments: [TabBarSegment] {
        guard FeatureSettings.shared.repoGroupingMode != .off else {
            return visibleTabs.map { .single($0) }
        }
        var segments: [TabBarSegment] = []
        var currentGroupID: String?
        var currentGroupTabs: [OverlayTab] = []

        func flushGroup() {
            guard let groupID = currentGroupID, !currentGroupTabs.isEmpty else { return }
            if currentGroupTabs.count >= 1 {
                let name = URL(fileURLWithPath: groupID).lastPathComponent
                segments.append(.group(id: groupID, displayName: name, tabs: currentGroupTabs))
            }
            currentGroupTabs = []
            currentGroupID = nil
        }

        for tab in visibleTabs {
            if let gid = tab.repoGroupID {
                if gid == currentGroupID {
                    currentGroupTabs.append(tab)
                } else {
                    flushGroup()
                    currentGroupID = gid
                    currentGroupTabs = [tab]
                }
            } else {
                flushGroup()
                segments.append(.single(tab))
            }
        }
        flushGroup()
        return segments
    }

    // Gesture-based drag state for tab reordering (Chrome/Safari style deferred reorder)
    @State private var dragOffset: CGFloat = 0
    @State private var dragHomeIndex = 0 // Original index when drag started
    @State private var dragCurrentSlot = 0 // Visual slot the dragged tab occupies
    /// Must match HStack spacing in the tab bar ForEach.
    private let tabSpacing: CGFloat = 8
    @State private var lastTinySizeLogAt: Date = .distantPast
    @State private var lastVisibilityLogAt: Date = .distantPast
    @State private var tabMidXPositions: [UUID: CGFloat] = [:]

    var body: some View {
        let selected = overlayModel.selectedTab

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Idle tabs dropdown chip (only visible when there are idle tabs)
                            if !idleTabs.isEmpty {
                                idleTabsDropdown(tabs: idleTabs)
                            }

                            // Active tabs — grouped by repo when grouping is enabled
                            ForEach(tabBarSegments) { segment in
                                switch segment {
                                case .single(let tab):
                                    tabView(for: tab)
                                        .background(Color.clear.preference(key: RenderedTabCountKey.self, value: 1))
                                        .fixedSize(horizontal: false, vertical: true)
                                case .group(let groupID, let name, let groupTabs):
                                    let groupColor = RepoTagChip.color(for: groupID)
                                    HStack(spacing: tabSpacing) {
                                        RepoTagChip(name: name, groupColor: groupColor)

                                        ForEach(groupTabs) { tab in
                                            tabView(for: tab, hideRepoPath: true)
                                                .background(Color.clear.preference(key: RenderedTabCountKey.self, value: 1))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .overlay(alignment: .top) {
                                        // 1px line spanning the entire group (tag + pills)
                                        Rectangle()
                                            .fill(groupColor.opacity(0.5))
                                            .frame(height: 1)
                                            .offset(y: -1)
                                    }
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
                            .frame(height: OverlayLayout.tabChipHeight, alignment: .center)
                            .background(Color.black.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                            .accessibilityLabel(L("New tab", "New tab"))
                            .accessibilityHint(L("Opens a new terminal tab", "Opens a new terminal tab"))
                        }
                        .onPreferenceChange(TabWidthPreferenceKey.self) { widths in
                            tabWidths = widths
                        }
                        .onPreferenceChange(TabMidXPreferenceKey.self) { positions in
                            tabMidXPositions = positions
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                    // Force complete re-render of ScrollView content when refresh token changes
                    // This is more aggressive than just the ForEach id - it recreates the entire scroll view
                    .id("tabbar-scroll-\(overlayModel.tabBarRefreshToken)")
                    // Hardening: ensure ScrollView content maintains minimum size
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: overlayModel.selectedTabID) { newID in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }

                Spacer()

                if let session = selected?.session {
                    HStack(spacing: 8) {
                        DevServerBadge(session: session)
                        GitBranchBadge(session: session)
                    }
                }
            }
            .frame(height: OverlayLayout.tabBarHeight, alignment: .center)
            // Keep a minimal background on the actual tab row only.
            .background(Color.black.opacity(0.001))
        }
        .padding(.trailing, 8)
        .frame(minWidth: 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(ToolbarBackgroundView())
        // Report actual rendered size for visibility-based recovery
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TabBarSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(TabBarSizeKey.self) { size in
            overlayModel.reportTabBarSize(size)
            // Log tiny/zero rendered sizes immediately so disappearance can be diagnosed from logs.
            let now = Date()
            let expectedMinWidth = CGFloat(overlayModel.tabs.count) * 30
            if size.width <= 0 || size.height <= 0 || size.width < 1 || size.height < 10 || size.width < expectedMinWidth, now.timeIntervalSince(lastTinySizeLogAt) > 1.0 {
                lastTinySizeLogAt = now
                Log
                    .warn(
                        "ToolbarTabBarView: suspicious tab bar size reported width=\(Int(size.width)) height=\(Int(size.height)), tabs=\(overlayModel.tabs.count), expectedMinWidth=\(Int(expectedMinWidth)), refreshToken=\(overlayModel.tabBarRefreshToken)"
                    )
            }
        }
        .onChange(of: overlayModel.tabs.count) { newCount in
            Log.trace("ToolbarTabBarView: tabs.count changed to \(newCount)")
        }
        .onAppear {
            let now = Date()
            if now.timeIntervalSince(lastVisibilityLogAt) > 2.0 {
                lastVisibilityLogAt = now
                Log.trace("ToolbarTabBarView: appeared, tabs=\(overlayModel.tabs.count)")
            }
        }
        .onDisappear {
            let now = Date()
            if now.timeIntervalSince(lastVisibilityLogAt) > 2.0 {
                lastVisibilityLogAt = now
                Log.trace("ToolbarTabBarView: disappeared, tabs=\(overlayModel.tabs.count)")
            }
        }
        // Auto-recovery: detect when rendered tab count doesn't match model
        // Report rendered count to model for watchdog monitoring
        .onPreferenceChange(RenderedTabCountKey.self) { renderedCount in
            overlayModel.reportRenderedTabCount(renderedCount)
            let expectedCount = overlayModel.tabs.count
            // Only act if we rendered ZERO tabs but expected some (the critical bug case)
            // During normal add/remove, renderedCount trails briefly but is never zero when tabs exist
            if renderedCount == 0, expectedCount > 0 {
                // Debounce to avoid triggering during animations/transitions
                recoveryDebounce?.cancel()
                let task = DispatchWorkItem { [weak overlayModel] in
                    guard let model = overlayModel else { return }
                    // Only refresh if model still has tabs
                    // The refresh is idempotent, so false positives are harmless
                    let currentExpected = model.tabs.count
                    if currentExpected > 0 {
                        Log.warn("TabBar auto-recovery (preference): rendered=0, expected=\(currentExpected), forcing refresh")
                        model.refreshTabBar()
                    }
                }
                recoveryDebounce = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
            }
        }
    }

    private func idleTabsDropdown(tabs: [OverlayTab]) -> some View {
        IdleTabsChip(
            tabs: tabs,
            overlayModel: overlayModel,
            idleDuration: idleDuration
        )
    }

    private func idleDuration(for tab: OverlayTab) -> String {
        guard let session = tab.displaySession ?? tab.session else { return "" }
        let seconds = Int(Date().timeIntervalSince(session.lastActivityDate))
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    @ViewBuilder
    private func tabView(for tab: OverlayTab, hideRepoPath: Bool = false) -> some View {
        let isSelected = tab.id == overlayModel.selectedTabID
        let isSuspended = overlayModel.isTabSuspended(tab.id)

        // Use UnifiedTabButton for stable view identity (avoids if/else type switching)
        UnifiedTabButton(
            tab: tab,
            isSelected: isSelected,
            isSuspended: isSuspended,
            isBroadcastIncluded: overlayModel.isBroadcastMode && !overlayModel.broadcastExcludedTabIDs.contains(tab.id),
            hideRepoPath: hideRepoPath,
            onSelect: { overlayModel.selectTab(id: tab.id) },
            onRename: { overlayModel.beginRename(tabID: tab.id) },
            onClose: { overlayModel.closeTab(id: tab.id) },
            onHover: { isHovering in
                if isHovering {
                    overlayModel.prewarmTab(id: tab.id)
                    let midX = tabMidXPositions[tab.id] ?? 0
                    overlayModel.tabHoverBegan(id: tab.id, anchorX: midX)
                } else {
                    overlayModel.cancelPrewarm(id: tab.id)
                    overlayModel.tabHoverEnded(id: tab.id)
                }
            },
            onMoveToIdle: { overlayModel.forceTabIdle(id: tab.id) },
            otherWindows: overlayModel.otherWindowTitles,
            onMoveToWindow: { overlayModel.onMoveTabToWindow?(tab.id, $0) }
        )
        // Explicit stable identity based on tab UUID
        .id(tab.id)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TabWidthPreferenceKey.self, value: [tab.id: proxy.size.width])
                    .preference(key: TabMidXPreferenceKey.self, value: [tab.id: proxy.frame(in: .global).midX])
            }
        )
        // Visual offset: dragged tab follows cursor, displaced neighbors slide
        .offset(x: tabDragOffset(for: tab))
        .animation(draggingTabID == tab.id ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: dragCurrentSlot)
        .zIndex(draggingTabID == tab.id ? 1 : 0)
        // Gesture-based tab reordering (more reliable than .onDrag in ScrollViews)
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    handleTabDrag(tab: tab, translation: value.translation.width)
                }
                .onEnded { value in
                    handleTabDragEnd(tab: tab, translation: value.translation.width)
                }
        )
    }

    /// Returns the visual X offset for a tab during a drag gesture.
    /// - Dragged tab: follows the cursor via `dragOffset`
    /// - Displaced neighbors: shift by one tab width to fill the gap
    /// - All others: no offset
    private func tabDragOffset(for tab: OverlayTab) -> CGFloat {
        guard let dragID = draggingTabID else { return 0 }

        // The dragged tab itself tracks the cursor directly
        if tab.id == dragID { return dragOffset }

        // Find this tab's original index (model is unchanged during drag)
        guard let i = overlayModel.tabs.firstIndex(where: { $0.id == tab.id }) else { return 0 }

        let draggedWidth = tabWidths[dragID] ?? 100
        let shift = draggedWidth + tabSpacing

        if dragCurrentSlot > dragHomeIndex {
            // Dragging right: tabs between (home, currentSlot] shift left
            if i > dragHomeIndex, i <= dragCurrentSlot {
                return -shift
            }
        } else if dragCurrentSlot < dragHomeIndex {
            // Dragging left: tabs in [currentSlot, home) shift right
            if i >= dragCurrentSlot, i < dragHomeIndex {
                return shift
            }
        }
        return 0
    }

    private func handleTabDrag(tab: OverlayTab, translation: CGFloat) {
        overlayModel.dismissHoverCard()
        let snapshot = overlayModel.tabs

        // Initialize drag state on first call
        if draggingTabID == nil {
            guard let home = snapshot.firstIndex(where: { $0.id == tab.id }) else { return }
            draggingTabID = tab.id
            dragHomeIndex = home
            dragCurrentSlot = home
            Log.info("Tab drag started (gesture): tabID=\(tab.id), homeIndex=\(home)")
        }

        // Guard: if a second tab somehow starts a gesture, ignore it
        guard draggingTabID == tab.id else { return }

        // Tab was closed during drag — abort cleanly
        guard let liveIndex = snapshot.firstIndex(where: { $0.id == tab.id }) else {
            Log.warn("Tab drag aborted: tab \(tab.id) no longer in tabs array")
            draggingTabID = nil
            dragOffset = 0
            return
        }

        // A background tab may have been closed/added during drag, shifting
        // indices.  Re-sync dragHomeIndex so slot calculation and moveTab
        // use a valid starting point.
        if liveIndex != dragHomeIndex {
            let delta = liveIndex - dragHomeIndex
            dragHomeIndex = liveIndex
            dragCurrentSlot = max(0, min(dragCurrentSlot + delta, snapshot.count - 1))
        }

        // Dragged tab follows the cursor directly (no model mutation)
        dragOffset = translation

        let widths = snapshot.map { tabWidths[$0.id] ?? 100 }
        dragCurrentSlot = TabDragLayout.destinationIndex(
            for: translation,
            homeIndex: dragHomeIndex,
            tabWidths: widths,
            spacing: tabSpacing
        )
    }

    private func handleTabDragEnd(tab: OverlayTab, translation: CGFloat) {
        // Ignore if this isn't the tab being dragged (or no drag active)
        guard draggingTabID == tab.id else { return }

        let from = dragHomeIndex
        let to = dragCurrentSlot

        // Clear drag visuals and commit reorder in the same animation transaction
        // so SwiftUI diffs old (offsets + old order) → new (no offsets + new order)
        // as one smooth move per tab identity.
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            draggingTabID = nil
            dragOffset = 0
            if from != to {
                overlayModel.moveTab(fromIndex: from, toIndex: to)
            }
        }

        Log.info("Tab drag ended: tabID=\(tab.id), from=\(from), to=\(to)")
    }

}

/// Separate view to properly observe session's git status changes
private struct GitBranchBadge: View {
    @ObservedObject var session: TerminalSessionModel

    var body: some View {
        if session.isGitRepo {
            let branchName = session.gitBranch ?? L("status.unknown", "unknown")
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                Text(branchName.isEmpty ? L("git.label", "Git") : branchName)
                    .font(.custom("Avenir Next", size: 11).weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.20))
            .clipShape(Capsule())
            .accessibilityLabel(String(format: L("accessibility.gitBranch", "Git branch: %@"), branchName))
        }
    }
}

/// Separate view to properly observe session's dev server status
private struct DevServerBadge: View {
    @ObservedObject var session: TerminalSessionModel

    var body: some View {
        if let server = session.devServer {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                Text(server.name)
                    .font(.custom("Avenir Next", size: 11).weight(.semibold))
                if let port = server.port {
                    Text(String(format: L("devServer.portSuffix", ":%d"), port))
                        .font(.custom("Avenir Next", size: 10).weight(.medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.25))
            .clipShape(Capsule())
            .accessibilityLabel(
                String(
                    format: L("accessibility.devServer", "Dev server: %@ on port %d"),
                    server.name,
                    server.port ?? 0
                )
            )
            .onTapGesture {
                // Open the dev server URL in browser
                if let url = server.url, let nsURL = URL(string: url) {
                    NSWorkspace.shared.open(nsURL)
                }
            }
        }
    }
}

// MARK: - Tab Switch Optimization: Cursor Placeholder

/// A lightweight view that shows a blinking cursor immediately during tab switch.
/// This creates the perception of instant responsiveness while the terminal renders.
struct CursorPlaceholderView: View {
    let promptText: String
    let cursorPosition: CGPoint

    /// Use TimelineView for reliable cursor blinking
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let cursorVisible = Int(timeline.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)

            GeometryReader { _ in
                ZStack(alignment: .bottomLeading) {
                    // Minimal dark background
                    Color.black.opacity(0.95)

                    // Prompt area with blinking cursor at bottom
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer()

                        HStack(spacing: 0) {
                            // Show abbreviated path as prompt
                            Text(L("$ ", "$ "))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.green.opacity(0.8))

                            Text(promptText)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)

                            Text(" ")

                            // Blinking cursor block
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 8, height: 16)
                                .opacity(cursorVisible ? 1 : 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
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

    /// Computes the slide direction based on tab indices
    private func slideDirection(for tab: OverlayTab, isSelected: Bool) -> CGFloat {
        guard isSelected else { return 0 }
        let currentIndex = overlayModel.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        let previousIndex = overlayModel.previousTabIndex
        // Slide from right if moving to a tab on the right, from left otherwise
        return currentIndex > previousIndex ? 1 : -1
    }

    private var terminalStack: some View {
        ZStack(alignment: .top) {

            // MARK: - Tab Switch Optimization: Snapshot Layer (shows instantly)

            // This displays a cached screenshot while the real terminal renders
            ForEach(overlayModel.tabs) { tab in
                let isSelected = tab.id == overlayModel.selectedTabID
                if isSelected, !overlayModel.isTerminalReady, let snapshot = tab.cachedSnapshot {
                    // Show snapshot instantly while terminal renders
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .zIndex(2) // Above terminal but below overlays
                }
            }

            // MARK: - Tab Switch Optimization: Cursor Placeholder (appears first)

            // Shows a blinking cursor immediately for perceived instant response
            // Only shows if the tab has been viewed before (has cached prompt text)
            ForEach(overlayModel.tabs) { tab in
                let isSelected = tab.id == overlayModel.selectedTabID
                let hasContent = !tab.lastPromptText.isEmpty || tab.cachedSnapshot != nil
                if isSelected, !overlayModel.isTerminalReady, hasContent {
                    CursorPlaceholderView(
                        promptText: tab.lastPromptText.isEmpty ? "~" : tab.lastPromptText,
                        cursorPosition: tab.lastCursorPosition
                    )
                    .zIndex(3) // Above snapshot for immediate cursor feedback
                }
            }

            // MARK: - Shell Loading Bar

            ForEach(overlayModel.tabs) { tab in
                let isSelected = tab.id == overlayModel.selectedTabID
                if isSelected, let session = tab.displaySession {
                    ShellLoadingBar(session: session)
                        .zIndex(4)
                }
            }

            // MARK: - Tab Switch Optimization: Lazy Tab Loading + Directional Motion

            // Only keep nearby tabs (selected ± 1, previous ± 1) in full view hierarchy.
            // This ensures smooth transitions even when jumping between distant tabs.
            // Distant tabs use lightweight placeholders - their shell processes
            // continue running via retainedRustTerminalView in TerminalSessionModel.
            ForEach(Array(overlayModel.tabs.enumerated()), id: \.element.id) { index, tab in
                let isSelected = tab.id == overlayModel.selectedTabID
                let keepLiveHierarchy = overlayModel.shouldKeepTabInLiveHierarchy(tab: tab, index: index)
                let isSuspended = overlayModel.isTabSuspended(tab.id)
                let direction = slideDirection(for: tab, isSelected: isSelected)

                if keepLiveHierarchy {
                    // Full terminal view for selected and adjacent tabs
                    SplitPaneView(controller: tab.splitController, isSuspended: isSuspended, isActive: isSelected)
                        .opacity(isSelected && overlayModel.isTerminalReady ? 1 : 0)
                        .offset(x: isSelected ? 0 : (30 * direction)) // Subtle slide effect
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .zIndex(isSelected ? 1 : 0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: isSelected)
                } else {
                    // Lightweight placeholder for distant tabs
                    // The terminal process keeps running via retainedRustTerminalView
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
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

            // MARK: - Tab Hover Card

            if overlayModel.hoverCardTabID != nil {
                TabHoverCard(
                    overlayModel: overlayModel,
                    anchorX: overlayModel.hoverCardAnchorX
                )
                .allowsHitTesting(true)
                .zIndex(8)
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

            if settings.isShortcutHelperHintEnabled {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        ShortcutHelperHintView(
                            label: L("shortcut.helper.label", "Keyboard Shortcuts"),
                            shortcut: "⌘/"
                        )
                        ShortcutHelperHintView(
                            label: L("shortcut.helper.reportIssue.label", "Report Issue"),
                            shortcut: reportIssueShortcutText,
                            accessibilityHint: L(
                                "shortcut.helper.reportIssue.hint",
                                "Open the bug report flow"
                            )
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.trailing, 12)
                }
                .padding(.top, OverlayLayout.tabBarHeight + 8)
                .padding(.trailing, 4)
                .zIndex(11)
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

    private var reportIssueShortcutText: String {
        settings.shortcut(for: "reportIssue")?.displayString ?? "⇧⌘I"
    }
}

private struct ShortcutHelperHintView: View {
    let label: String
    let shortcut: String
    let accessibilityHint: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.custom("Avenir Next", size: 11).weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.92))
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityLabel(
            String(
                format: L("accessibility.shortcutHelper", "%@ %@"),
                label,
                shortcut
            )
        )
        .accessibilityHint(accessibilityHint)
    }

    init(
        label: String,
        shortcut: String,
        accessibilityHint: String = L("shortcut.helper.hint", "Show the keyboard shortcuts window")
    ) {
        self.label = label
        self.shortcut = shortcut
        self.accessibilityHint = accessibilityHint
    }
}

/// ASCII loading bar shown during shell startup, replacing the old 5s-only indicator.
/// Two modes: normal loading (top-left bar below TIP) and slow/hung warning (centered).
/// Uses @ObservedObject so SwiftUI observes session property changes
/// (OverlayTab is Equatable by id only, so ForEach won't re-diff on session changes).
private struct ShellLoadingBar: View {
    @ObservedObject var session: TerminalSessionModel

    private static let barWidth = 28
    private static let litWidth = 10
    /// Total animation positions: bar sweeps right then left (bounce)
    private static let totalPositions = (barWidth - litWidth) * 2

    @State private var offset = 0
    @State private var visible = false

    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private var barString: String {
        // Bounce: offset 0..<(barWidth-litWidth) goes right, then reverses
        let maxOffset = Self.barWidth - Self.litWidth
        let pos = offset <= maxOffset ? offset : Self.totalPositions - offset
        var chars = [Character](repeating: "░", count: Self.barWidth)
        for i in pos ..< (pos + Self.litWidth) {
            chars[i] = "▸"
        }
        return "  " + String(chars) + " "
    }

    var body: some View {
        if session.shellStartupSlow {
            // Shell possibly hung — centered warning
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Shell initializing\u{2026}")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: session.shellStartupSlow)
        } else if session.isShellLoading {
            // Normal loading — ASCII bar below TIP, top-leading aligned
            VStack(alignment: .leading) {
                Text(barString + "Loading shell\u{2026}")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 65)
            .padding(.leading, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(visible ? 1 : 0)
            .onReceive(timer) { _ in
                offset = (offset + 1) % Self.totalPositions
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeIn(duration: 0.15)) {
                        visible = true
                    }
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
        }
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

// MARK: - Unified Tab Button (Stable Identity)

/// A unified tab button that handles both session and non-session cases
/// without view identity switching. This prevents SwiftUI from recreating
/// the view when tab.session changes between nil and non-nil.
// MARK: - Repo Tag Chip

/// Non-interactive pill-shaped chip showing a repo name. Sits inline with tab pills
/// but is visually muted (dimmer, no close button, not selectable).
struct RepoTagChip: View {
    let name: String
    let groupColor: Color

    var body: some View {
        Text(name)
            .font(.custom("Avenir Next", size: 11).weight(.semibold))
            .foregroundStyle(groupColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(height: OverlayLayout.tabChipHeight, alignment: .center)
            .allowsHitTesting(false)
    }

    /// Deterministic color for a repo path — same repo always gets the same color.
    static func color(for repoGroupID: String) -> Color {
        let colors = TabColor.allCases
        let hash = abs(repoGroupID.hashValue)
        return colors[hash % colors.count].color
    }
}

// MARK: - Unified Tab Button

struct UnifiedTabButton: View {
    let tab: OverlayTab
    let isSelected: Bool
    let isSuspended: Bool
    let isBroadcastIncluded: Bool
    var hideRepoPath: Bool = false
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    var onHover: ((Bool) -> Void)?
    /// Context menu: move tab to idle dropdown
    var onMoveToIdle: () -> Void = {}
    /// Context menu: available windows to move tab to
    var otherWindows: [OverlayTabsModel.WindowMenuItem] = []
    /// Context menu: move tab to another window
    var onMoveToWindow: ((Int) -> Void)?

    /// Pulse animation state
    @State private var isPulsing = false

    /// Notification style helpers
    private var notificationStyle: TabNotificationStyle? {
        tab.notificationStyle
    }

    private var titleFont: Font {
        var font = Font.custom("Avenir Next", size: 12)
        if notificationStyle?.isBold == true {
            font = font.weight(.bold)
        } else {
            font = font.weight(.semibold)
        }
        if notificationStyle?.isItalic == true {
            font = font.italic()
        }
        return font
    }

    private var titleColor: Color? {
        notificationStyle?.titleColor
    }

    @ViewBuilder
    private var notificationBorderOverlay: some View {
        let borderWidth = notificationStyle?.borderWidth ?? 0
        let borderColor = notificationStyle?.borderColor ?? .clear
        if borderWidth > 0 {
            let dash = notificationStyle?.borderDash ?? []
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, style: StrokeStyle(lineWidth: borderWidth, dash: dash))
        }
    }

    private var resolvedTitle: String {
        tab.displayTitle
    }

    private var resolvedPath: String {
        tab.displaySession?.tabPathDisplayName() ?? ""
    }

    /// Whether this tab should show only the custom title (hiding all extras).
    private var isMinimalDisplay: Bool {
        FeatureSettings.shared.customTitleOnly
            && tab.customTitle != nil
            && !tab.customTitle!.isEmpty
    }

    @ViewBuilder
    private var tabContextMenu: some View {
        Button("Rename Tab...") { onRename() }
        Divider()
        Button("Move to Idle Tabs") { onMoveToIdle() }
        if !otherWindows.isEmpty {
            Menu("Move to Window") {
                ForEach(otherWindows) { window in
                    Button(window.title) { onMoveToWindow?(window.id) }
                }
            }
        }
        Divider()
        Button("Close Tab") { onClose() }
    }

    var body: some View {
        tabChip
            // Context menu is handled natively via TabBarHostingView.rightMouseDown
            // because SwiftUI's .contextMenu doesn't work inside NSToolbarItem hosts.
            .onHover { isHovering in
                onHover?(isHovering)
            }
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(
                isPulsing
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onChange(of: notificationStyle?.shouldPulse) { shouldPulse in
                isPulsing = shouldPulse == true
            }
            .onChange(of: tab.notificationStyle) { newStyle in
                if newStyle == nil { isPulsing = false }
            }
            .onAppear {
                isPulsing = notificationStyle?.shouldPulse == true
            }
    }

    @ViewBuilder
    private var tabChip: some View {
        HStack(spacing: 8) {
            // Session-dependent content (icon, title, path, git) in an observing subview
            if let session = tab.displaySession {
                TabSessionContent(
                    session: session,
                    customTitle: tab.customTitle,
                    isMinimalDisplay: isMinimalDisplay,
                    hideRepoPath: hideRepoPath,
                    notificationStyle: notificationStyle,
                    titleFont: titleFont,
                    titleColor: titleColor
                )
            } else {
                Text(resolvedTitle)
                    .font(titleFont)
                    .foregroundStyle(titleColor ?? .primary)
                    .lineLimit(1)
            }

            if !isMinimalDisplay {
                // MCP indicator
                if tab.isMCPControlled, FeatureSettings.shared.mcpShowTabIndicator {
                    Image(systemName: "face.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                        .help("MCP-controlled tab")
                }

                // F20: Command badge
                if let badge = tab.commandBadge {
                    Text(badge)
                        .font(.custom("Avenir Next", size: 10).weight(.medium))
                        .foregroundStyle(badge.contains("✗") ? .red : .green)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.2))
                        .clipShape(Capsule())
                }

                // F13: Broadcast indicator
                if FeatureSettings.shared.showTabBroadcastIndicator, isBroadcastIncluded {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                // Git indicator — observed via TabSessionContent, keep fallback here
                if FeatureSettings.shared.showTabGitIndicator, tab.displaySession?.isGitRepo ?? false {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("tab.close", "Close tab"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(height: OverlayLayout.tabChipHeight, alignment: .center)
        .background(
            isSelected
                ? tab.effectiveColor.color.opacity(0.25)
                : (tab.isMCPControlled && FeatureSettings.shared.mcpShowTabIndicator ? Color.purple.opacity(0.15) : Color.black.opacity(0.18))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(notificationBorderOverlay)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: L("accessibility.tabWithPath", "%@ tab%@"),
                resolvedTitle,
                resolvedPath.isEmpty ? "" : ", \(resolvedPath)"
            )
        )
        .accessibilityHint(
            isSelected
                ? L("accessibility.tabRenameSelected", "Selected. Double-tap to rename")
                : L("accessibility.tabRename", "Double-tap to select, then double-tap to rename")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Use simultaneousGesture for taps so they don't block drag recognition
        // Double-tap has higher count so it naturally takes precedence over single-tap
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onRename()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onSelect()
            }
        )
        // onHover, contextMenu, pulse animation, and onChange are in body
    }
}

// MARK: - Tab Session Content (observes session for live updates)

/// Subview that observes the `TerminalSessionModel` so icons, title, and path
/// update reactively when `aiDisplayAppName`, `devServer`, or directory change.
/// Without this, `UnifiedTabButton` (which takes `OverlayTab` as a struct value)
/// would never re-render for session property changes.
struct TabSessionContent: View {
    @ObservedObject var session: TerminalSessionModel
    let customTitle: String?
    let isMinimalDisplay: Bool
    var hideRepoPath: Bool = false
    let notificationStyle: TabNotificationStyle?
    let titleFont: Font
    let titleColor: Color?

    private var aiProductLogo: Image? {
        guard let appName = session.aiDisplayAppName else { return nil }
        return AIAgentLogo.image(forAppName: appName)
    }

    private var devServerIconName: String? {
        guard let devName = session.devServer?.name,
              devName.compare("Vite", options: .caseInsensitive) == .orderedSame else {
            return nil
        }
        return "bolt.fill"
    }

    private var resolvedTitle: String {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        if let activeName = session.aiDisplayAppName, !activeName.isEmpty {
            return activeName
        }
        if let devName = session.devServer?.name,
           devName.compare("Vite", options: .caseInsensitive) == .orderedSame {
            return devName
        }
        return L("tab.shell", "Shell")
    }

    var body: some View {
        if !isMinimalDisplay {
            if let iconName = notificationStyle?.icon {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(notificationStyle?.iconColor ?? notificationStyle?.titleColor ?? .primary)
                    .accessibilityHidden(true)
            } else if FeatureSettings.shared.showTabIcons {
                if let logo = aiProductLogo {
                    logo
                        .resizable()
                        .frame(width: 14, height: 14)
                        .opacity(session.isAIRunning ? 1.0 : 0.35)
                        .accessibilityHidden(true)
                } else if let devIcon = devServerIconName {
                    Image(systemName: devIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
            }
        }

        Text(resolvedTitle)
            .font(titleFont)
            .foregroundStyle(titleColor ?? .primary)
            .lineLimit(1)

        if !isMinimalDisplay, !hideRepoPath {
            if FeatureSettings.shared.showTabPath {
                let path = session.tabPathDisplayName()
                if !path.isEmpty {
                    Text(String(format: L("tab.path.prefix", "- %@"), path))
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

struct DraggableOverlay<Content: View>: View {
    let id: String
    let workspace: String?
    let maxWidth: CGFloat?
    @ViewBuilder let content: Content
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var dragOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    init(id: String, workspace: String?, maxWidth: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.id = id
        self.workspace = workspace
        self.maxWidth = maxWidth
        self.content = content()
    }

    private var drag: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                dragOffset.width += value.translation.width
                dragOffset.height += value.translation.height
                settings.setOverlayOffset(dragOffset, for: id, workspace: workspace)
            }
    }

    var body: some View {
        let workspaceKey = workspace ?? "global"
        VStack(spacing: 0) {
            // Drag handle — sole target for the drag gesture.
            // Isolating the gesture here prevents DragGesture from
            // stealing scroll events inside ScrollViews in the content.
            // Full-width hit area (minHeight: 20) so the grab target is generous.
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity, minHeight: 20)
                .contentShape(Rectangle())
                .gesture(drag)
            content
        }
        .background(overlayPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: maxWidth ?? .infinity)
        .padding(.horizontal, 16)
        .offset(x: dragOffset.width + dragTranslation.width, y: dragOffset.height + dragTranslation.height)
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

/// macOS traffic-light style close button for overlay panels.
struct OverlayCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovered ? Color.red : Color.red.opacity(0.8))
                    .frame(width: 12, height: 12)
                if isHovered {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L("Close", "Close"))
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
                    TextField(L("Search terminal", "Search terminal"), text: $model.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .accessibilityLabel(L("Search terminal", "Search terminal"))
                        .accessibilityHint(L("Enter text to search in terminal output", "Enter text to search in terminal output"))
                        .onChange(of: model.searchQuery) { _ in
                            model.refreshSearch()
                        }
                        .onSubmit {
                            model.nextMatch()
                        }

                    Text(String(format: L("search.matches", "%d matches"), model.searchMatchCount))
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            String(format: L("search.matches.found", "%d matches found"), model.searchMatchCount)
                        )

                    // Case sensitivity toggle (Issue #23 fix)
                    Toggle(isOn: $model.isCaseSensitive) {
                        Text(L("Aa", "Aa"))
                            .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(L("Case sensitive search", "Case sensitive search"))
                    .accessibilityLabel(L("Case sensitive", "Case sensitive"))
                    .accessibilityHint(
                        model.isCaseSensitive
                            ? L("status.currentlyEnabled", "Currently enabled")
                            : L("status.currentlyDisabled", "Currently disabled")
                    )
                    .onChange(of: model.isCaseSensitive) { _ in
                        model.refreshSearch()
                    }
                    .disabled(model.isSemanticSearch)

                    Toggle(isOn: $model.isRegexSearch) {
                        Text(L(".*", ".*"))
                            .font(.custom("Avenir Next", size: 11).weight(.semibold))
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(L("Regex search", "Regex search"))
                    .accessibilityLabel(L("Regular expression search", "Regular expression search"))
                    .accessibilityHint(
                        model.isRegexSearch
                            ? L("status.currentlyEnabled", "Currently enabled")
                            : L("status.currentlyDisabled", "Currently disabled")
                    )
                    .onChange(of: model.isRegexSearch) { _ in
                        model.refreshSearch()
                    }
                    .disabled(model.isSemanticSearch)

                    if settings.isSemanticSearchEnabled {
                        Toggle(isOn: $model.isSemanticSearch) {
                            Text(L("Cmd", "Cmd"))
                                .font(.custom("Avenir Next", size: 11).weight(.semibold))
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(L("Semantic command search", "Semantic command search"))
                        .accessibilityLabel(L("Semantic command search", "Semantic command search"))
                        .onChange(of: model.isSemanticSearch) { _ in
                            model.refreshSearch()
                        }
                    }

                    Button(L("Close", "Close")) {
                        model.toggleSearch()
                    }
                    .controlSize(.small)
                    // Note: Escape is handled by AppDelegate.handleKeyEvent()
                }

                if let error = model.searchError {
                    Text(error)
                        .font(.custom("Avenir Next", size: 11))
                        .foregroundStyle(.orange)
                } else if model.searchResults.isEmpty, !model.searchQuery.isEmpty {
                    Text(L("No results", "No results"))
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
                    Button(L("Prev", "Prev")) { model.previousMatch() }
                        .controlSize(.small)
                        .accessibilityLabel(L("Previous match", "Previous match"))
                        .accessibilityHint(L("Go to previous search result", "Go to previous search result"))
                    // Note: Cmd+Shift+G is in menu commands
                    Button(L("Next", "Next")) { model.nextMatch() }
                        .controlSize(.small)
                        .accessibilityLabel(L("Next match", "Next match"))
                        .accessibilityHint(L("Go to next search result", "Go to next search result"))
                    // Note: Cmd+G is in menu commands
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .onAppear { isFocused = true }
        }
    }
}

struct SearchResultRow: View {
    let line: String
    let query: String
    var caseSensitive = false
    var useRegex = false

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

        var searchRange = searchLine.startIndex ..< searchLine.endIndex
        while let range = searchLine.range(of: searchQuery, range: searchRange) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].foregroundColor = .white
                result[attrRange].backgroundColor = .orange.opacity(0.6)
            }
            searchRange = range.upperBound ..< searchLine.endIndex
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
                    TextField(L("Tab name", "Tab name"), text: $model.renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: OverlayLayout.commandListMinWidth)
                        .focused($isFocused)
                        // Issue #18 fix: Allow Enter key to confirm rename
                        .onSubmit {
                            model.commitRename()
                        }

                    Button(L("Cancel", "Cancel")) { model.cancelRename() }
                        .controlSize(.small)
                    // Note: Escape is handled by AppDelegate.handleKeyEvent()
                    Button(L("Save", "Save")) { model.commitRename() }
                        .controlSize(.small)
                    // Note: Enter triggers onSubmit on the TextField
                }

                HStack(spacing: 8) {
                    Text(L("Color:", "Color:"))
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
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
                .help(item.isPinned ? "Unpin" : "Pin")

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

// MARK: - F17: Bookmarks Overlay

struct BookmarkListOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var bookmarkManager = BookmarkManager.shared
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

// MARK: - F21: Snippets Overlay

struct SnippetManagerOverlayView: View {
    @ObservedObject var model: OverlayTabsModel
    @ObservedObject private var manager = SnippetManager.shared
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var query = ""
    @State private var draft = SnippetDraft()
    @State private var editingEntry: SnippetEntry?
    @State private var isEditorVisible = false
    @State private var deleteTarget: SnippetEntry?
    // Variable input dialog state
    @State private var pendingVariableEntry: SnippetEntry?
    @State private var pendingVariables: [SnippetInputVariable] = []
    @State private var isVariableDialogVisible = false

    /// All available letters for quick selection (a-z)
    private static let allLetters = Set("abcdefghijklmnopqrstuvwxyz")

    private let panelMaxWidth: CGFloat = 560
    private let listMaxHeight: CGFloat = 400

    private var repoAvailable: Bool {
        FeatureSettings.shared.isRepoSnippetsEnabled && manager.activeRepoRoot != nil
    }

    private var preferredSource: SnippetSource {
        repoAvailable ? .repo : .global
    }

    /// Result of building the key map for snippets
    struct KeyMapResult {
        /// Maps snippet ID to its assigned key (nil if conflict or no key available)
        let snippetKeys: [String: Character]
        /// Maps key to snippet entry for quick lookup
        let keyToSnippet: [Character: SnippetEntry]
        /// Keys that have conflicts (multiple snippets claim the same custom key)
        let conflictingKeys: Set<Character>
    }

    /// Builds a key map for the given snippets:
    /// 1. Custom keys (from snippet.key) take priority
    /// 2. Conflicting custom keys are marked (neither gets the key)
    /// 3. Remaining snippets get auto-assigned from available letters
    private func buildKeyMap(for entries: [SnippetEntry]) -> KeyMapResult {
        var snippetKeys: [String: Character] = [:]
        var keyToSnippet: [Character: SnippetEntry] = [:]
        var usedKeys = Set<Character>()
        var conflictingKeys = Set<Character>()

        // First pass: assign custom keys and detect conflicts
        var customKeyEntries: [(entry: SnippetEntry, key: Character)] = []
        for entry in entries {
            if let customKey = entry.snippet.validatedKey {
                customKeyEntries.append((entry, customKey))
            }
        }

        // Group by key to detect conflicts
        let grouped = Dictionary(grouping: customKeyEntries) { $0.key }
        for (key, group) in grouped {
            if group.count > 1 {
                // Conflict: multiple snippets have the same custom key
                conflictingKeys.insert(key)
            } else if let first = group.first {
                // No conflict: assign the key
                snippetKeys[first.entry.id] = key
                keyToSnippet[key] = first.entry
                usedKeys.insert(key)
            }
        }

        // Second pass: auto-assign remaining letters to snippets without custom keys
        var availableLetters = Self.allLetters.subtracting(usedKeys).subtracting(conflictingKeys).sorted()
        for entry in entries {
            // Skip if already has a key assigned
            if snippetKeys[entry.id] != nil { continue }
            // Skip if has a conflicting custom key
            if let customKey = entry.snippet.validatedKey, conflictingKeys.contains(customKey) { continue }

            // Auto-assign next available letter
            if let nextLetter = availableLetters.first {
                snippetKeys[entry.id] = nextLetter
                keyToSnippet[nextLetter] = entry
                availableLetters.removeFirst()
            }
        }

        return KeyMapResult(
            snippetKeys: snippetKeys,
            keyToSnippet: keyToSnippet,
            conflictingKeys: conflictingKeys
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Main snippet selector panel
            DraggableOverlay(id: "snippets", workspace: model.overlayWorkspaceIdentifier, maxWidth: panelMaxWidth) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        OverlayCloseButton(action: { model.toggleSnippetManager() })
                        Text(L("Snippets", "Snippets"))
                            .font(.custom("Avenir Next", size: 12).weight(.semibold))
                        Spacer()
                        Button(L("New", "New")) {
                            startCreate()
                        }
                        .controlSize(.small)
                        .disabled(!settings.isSnippetsEnabled)
                    }

                    if !settings.isSnippetsEnabled {
                        Text(L("Snippets are disabled in Settings.", "Snippets are disabled in Settings."))
                            .font(.custom("Avenir Next", size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        let filtered = manager.filteredEntries(query: query)
                        let keyMap = buildKeyMap(for: filtered)

                        SnippetSearchField(
                            text: $query,
                            onEscape: { model.toggleSnippetManager() },
                            onLetterKey: { letter in
                                if query.isEmpty, !isEditorVisible, !isVariableDialogVisible {
                                    if let entry = keyMap.keyToSnippet[letter] {
                                        attemptInsert(entry)
                                    }
                                }
                            }
                        )

                        if isEditorVisible, !isVariableDialogVisible {
                            SnippetEditorView(
                                draft: $draft,
                                isNew: editingEntry == nil,
                                repoAvailable: repoAvailable,
                                onCancel: cancelEdit,
                                onSave: saveEdit
                            )
                        } else {
                            if filtered.isEmpty {
                                Text(L("No snippets found.", "No snippets found."))
                                    .font(.custom("Avenir Next", size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(filtered) { entry in
                                            let assignedKey = query.isEmpty ? keyMap.snippetKeys[entry.id] : nil
                                            let hasConflict = entry.snippet.validatedKey.map { keyMap.conflictingKeys.contains($0) } ?? false
                                            SnippetRowView(
                                                entry: entry,
                                                quickSelectLetter: assignedKey,
                                                hasKeyConflict: hasConflict,
                                                onInsert: { attemptInsert(entry) },
                                                onEdit: { startEdit(entry) },
                                                onDelete: { deleteTarget = entry },
                                                onTogglePin: { manager.togglePin(entry) }
                                            )
                                        }
                                    }
                                }
                                .frame(maxHeight: listMaxHeight)

                                if query.isEmpty {
                                    Text(L("Press a letter to quick-insert", "Press a letter to quick-insert"))
                                        .font(.custom("Avenir Next", size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if let root = manager.activeRepoRoot, settings.isRepoSnippetsEnabled {
                        Text(String(format: L("snippet.repo", "Repo: %@"), root))
                            .font(.custom("Avenir Next", size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .onAppear {
                    query = ""
                }
                .alert(item: $deleteTarget) { entry in
                    Alert(
                        title: Text(L("Delete snippet?", "Delete snippet?")),
                        message: Text(entry.snippet.title),
                        primaryButton: .destructive(Text(L("Delete", "Delete"))) {
                            manager.deleteSnippet(entry)
                        },
                        secondaryButton: .cancel()
                    )
                }
            }

            // Variable input dialog — separate floating panel on top
            if isVariableDialogVisible, let entry = pendingVariableEntry {
                DraggableOverlay(id: "snippet-variables", workspace: model.overlayWorkspaceIdentifier, maxWidth: 420) {
                    SnippetVariableDialog(
                        snippetTitle: entry.snippet.title,
                        variables: $pendingVariables,
                        onCancel: cancelVariableInput,
                        onInsert: insertWithVariables
                    )
                }
                .padding(.top, 50)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
    }

    private func startCreate() {
        let repoPath = preferredSource == .repo ? (manager.activeRepoRoot ?? "") : ""
        draft = SnippetDraft(source: preferredSource, repoPath: repoPath)
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
            key: entry.snippet.key ?? "",
            source: entry.source,
            repoPath: entry.repoRoot ?? ""
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

    /// Attempts to insert a snippet, showing variable dialog if needed
    private func attemptInsert(_ entry: SnippetEntry) {
        let variables = SnippetManager.parseInputVariables(from: entry.snippet.body)
        if variables.isEmpty {
            // No variables - insert directly
            model.insertSnippet(entry)
        } else {
            // Has variables - show dialog
            pendingVariableEntry = entry
            pendingVariables = variables
            isVariableDialogVisible = true
        }
    }

    /// Cancels variable input and returns to snippet list
    private func cancelVariableInput() {
        isVariableDialogVisible = false
        pendingVariableEntry = nil
        pendingVariables = []
    }

    /// Inserts snippet with filled-in variables
    private func insertWithVariables() {
        guard let entry = pendingVariableEntry else { return }
        model.insertSnippetWithVariables(entry, variables: pendingVariables)
        cancelVariableInput()
    }
}

struct SnippetRowView: View {
    let entry: SnippetEntry
    let quickSelectLetter: Character?
    let hasKeyConflict: Bool
    let onInsert: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Quick select letter badge
            if let letter = quickSelectLetter {
                Text(String(letter))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if hasKeyConflict, let conflictKey = entry.snippet.validatedKey {
                // Show conflicting key with warning style
                Text(String(conflictKey))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.orange.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(
                        Text(
                            String(
                                format: L("snippets.conflictKey", "Key '%@' is used by multiple snippets"),
                                String(conflictKey)
                            )
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if entry.snippet.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.accentColor)
                    }

                    Text(entry.snippet.title)
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))

                    Text(entry.source.displayName.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(overlayChipBackground)
                        .clipShape(Capsule())

                    if entry.isOverridden {
                        Text(L("OVERRIDDEN", "OVERRIDDEN"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    if hasKeyConflict {
                        Text(L("KEY CONFLICT", "KEY CONFLICT"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.orange)
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
                Button(action: onTogglePin) {
                    Image(systemName: entry.snippet.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.snippet.isPinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.snippet.isPinned ? L("Unpin", "Unpin") : L("Pin to top", "Pin to top"))

                Button(action: onInsert) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Insert", "Insert"))

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Edit", "Edit"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Delete", "Delete"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.snippet", "Snippet: %@"), entry.snippet.title))
        .accessibilityHint(L("Tap to insert into terminal", "Tap to insert into terminal"))
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
                TextField(L("Title", "Title"), text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                TextField(L("ID (optional)", "ID (optional)"), text: $draft.id)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: 120)
                TextField(L("Key", "Key"), text: $draft.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 40)
                    .help(L("Quick-select key (single letter a-z)", "Quick-select key (single letter a-z)"))
            }

            TextEditor(text: $draft.body)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: OverlayLayout.colorPreviewHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            Text(L("Variables: ${input:Name} or ${input:Name:default}", "Variables: ${input:Name} or ${input:Name:default}"))
                .font(.custom("Avenir Next", size: 9))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                TextField(L("Tags (comma separated)", "Tags (comma separated)"), text: $draft.tagsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                TextField(L("Folder", "Folder"), text: $draft.folder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
            }

            HStack(spacing: 8) {
                TextField(L("Shells (zsh, bash, fish)", "Shells (zsh, bash, fish)"), text: $draft.shellsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))

                Picker(L("Location", "Location"), selection: $draft.source) {
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
                Button(L("Cancel", "Cancel")) { onCancel() }
                    .controlSize(.small)
                Button(L("Save", "Save")) { onSave() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Snippet Variable Input Dialog

struct SnippetVariableDialog: View {
    let snippetTitle: String
    @Binding var variables: [SnippetInputVariable]
    let onCancel: () -> Void
    let onInsert: () -> Void
    @FocusState private var focusedField: String?

    /// Creates a safe binding to a variable's value that won't crash if index becomes invalid
    /// This prevents crashes when the array is cleared while text field callbacks are pending
    private func safeValueBinding(for variable: SnippetInputVariable) -> Binding<String> {
        Binding<String>(
            get: {
                // Find by id instead of index for safety
                variables.first(where: { $0.id == variable.id })?.value ?? variable.value
            },
            set: { newValue in
                // Find and update by id instead of index
                if let idx = variables.firstIndex(where: { $0.id == variable.id }) {
                    variables[idx].value = newValue
                }
            }
        )
    }

    /// Creates a safe binding to a variable's selectedOptions for multi-select
    private func safeSelectedOptionsBinding(for variable: SnippetInputVariable) -> Binding<Set<String>> {
        Binding<Set<String>>(
            get: {
                variables.first(where: { $0.id == variable.id })?.selectedOptions ?? variable.selectedOptions
            },
            set: { newValue in
                if let idx = variables.firstIndex(where: { $0.id == variable.id }) {
                    variables[idx].selectedOptions = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                OverlayCloseButton(action: onCancel)
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.secondary)
                Text(L("Fill in variables", "Fill in variables"))
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                Spacer()
                Text(snippetTitle)
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)
            }

            // Use ForEach with identifiable items instead of indices to avoid binding crashes
            // when the array is modified while text field callbacks are pending
            ForEach(variables) { variable in
                SnippetVariableRow(
                    variable: variable,
                    valueBinding: safeValueBinding(for: variable),
                    selectedOptionsBinding: safeSelectedOptionsBinding(for: variable),
                    focusedField: $focusedField,
                    onSubmit: {
                        // Move to next field or submit
                        if let currentIndex = variables.firstIndex(where: { $0.id == variable.id }),
                           currentIndex < variables.count - 1 {
                            focusedField = variables[currentIndex + 1].id
                        } else {
                            onInsert()
                        }
                    }
                )
            }

            HStack {
                Spacer()
                Button(L("Cancel", "Cancel")) { onCancel() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(L("Insert", "Insert")) { onInsert() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }

            Text(L("Tab to next field • Enter to insert", "Tab to next field • Enter to insert"))
                .font(.custom("Avenir Next", size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onAppear {
            // Focus first text field (pickers don't need focus)
            if let first = variables.first(where: { $0.inputType == .text }) {
                focusedField = first.id
            }
        }
    }
}

/// Helper view for each variable row - renders appropriate control based on input type
private struct SnippetVariableRow: View {
    let variable: SnippetInputVariable
    @Binding var valueBinding: String
    @Binding var selectedOptionsBinding: Set<String>
    var focusedField: FocusState<String?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variable.name)
                .font(.custom("Avenir Next", size: 10).weight(.medium))
                .foregroundStyle(.secondary)

            switch variable.inputType {
            case .text:
                TextField(
                    variable.defaultValue.isEmpty ? "Enter value..." : variable.defaultValue,
                    text: $valueBinding
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused(focusedField, equals: variable.id)
                .onSubmit(onSubmit)

            case .singleSelect:
                if variable.options.isEmpty {
                    // Fallback to text field if options array is empty (defensive)
                    TextField(L("Enter value...", "Enter value..."), text: $valueBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                } else {
                    Picker("", selection: $valueBinding) {
                        ForEach(variable.options, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 11))
                }

            case .multiSelect:
                if variable.options.isEmpty {
                    // Fallback to text field if options array is empty (defensive)
                    TextField(L("Enter values (space-separated)...", "Enter values (space-separated)..."), text: $valueBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                } else {
                    MultiSelectOptionsView(
                        options: variable.options,
                        selectedOptions: $selectedOptionsBinding
                    )
                }
            }
        }
    }
}

/// Multi-select options displayed as toggle buttons
private struct MultiSelectOptionsView: View {
    let options: [String]
    @Binding var selectedOptions: Set<String>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                MultiSelectOptionButton(
                    option: option,
                    isSelected: selectedOptions.contains(option),
                    onToggle: {
                        if selectedOptions.contains(option) {
                            selectedOptions.remove(option)
                        } else {
                            selectedOptions.insert(option)
                        }
                    }
                )
            }
        }
    }
}

/// Individual toggle button for multi-select option
private struct MultiSelectOptionButton: View {
    let option: String
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .secondary)
                Text(option)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Simple flow layout for multi-select options
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return (CGSize(width: totalWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - Snippet Search Field (with quick-select letter handling)

private struct SnippetSearchField: NSViewRepresentable {
    @Binding var text: String
    var onEscape: () -> Void
    var onLetterKey: (Character) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SnippetKeyHandlingTextField {
        let field = SnippetKeyHandlingTextField()
        field.placeholderString = "Search snippets (or press a-z to quick-select)"
        field.font = NSFont.systemFont(ofSize: 11)
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.textColor = NSColor.labelColor
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.onEscape = onEscape
        field.onLetterKey = onLetterKey
        field.textBinding = $text

        // Request focus with retry logic to handle view hierarchy timing
        field.focusWithRetry()
        return field
    }

    func updateNSView(_ nsView: SnippetKeyHandlingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onEscape = onEscape
        nsView.onLetterKey = onLetterKey
        nsView.textBinding = $text
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SnippetSearchField

        init(_ parent: SnippetSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }

    final class SnippetKeyHandlingTextField: NSTextField {
        var onEscape: (() -> Void)?
        var onLetterKey: ((Character) -> Void)?
        var textBinding: Binding<String>?

        /// Generation counter to cancel stale focus retries
        private var focusGeneration = 0

        func focusIfNeeded() {
            guard let window else { return }
            if window.firstResponder === self {
                return
            }
            if let editor = window.firstResponder as? NSTextView, editor.delegate as? NSTextField === self {
                return
            }
            window.makeFirstResponder(self)
        }

        /// Focuses the field with retry logic for when view hierarchy isn't ready
        func focusWithRetry(attempts: Int = 3, delay: TimeInterval = 0.05) {
            // Increment generation to cancel any pending retries from previous calls
            focusGeneration += 1
            let currentGeneration = focusGeneration
            focusWithRetryInternal(attempts: attempts, delay: delay, generation: currentGeneration)
        }

        private func focusWithRetryInternal(attempts: Int, delay: TimeInterval, generation: Int) {
            // Cancel if generation has changed (panel was closed/reopened)
            guard generation == focusGeneration else { return }
            guard attempts > 0 else { return }

            // Check if still in view hierarchy
            guard let window, superview != nil else {
                // Not in hierarchy yet, retry
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.focusWithRetryInternal(attempts: attempts - 1, delay: delay * 2, generation: generation)
                }
                return
            }

            // Already focused
            if window.firstResponder === self { return }
            if let editor = window.firstResponder as? NSTextView, editor.delegate as? NSTextField === self { return }

            // Try to focus
            let success = window.makeFirstResponder(self)
            if !success {
                // Focus failed, retry with longer delay
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.focusWithRetryInternal(attempts: attempts - 1, delay: delay * 2, generation: generation)
                }
            }
        }

        /// Cancel pending focus retries (call when view is being removed)
        func cancelFocusRetries() {
            focusGeneration += 1
        }

        override func keyDown(with event: NSEvent) {
            // Escape key
            if event.keyCode == 53 {
                onEscape?()
                return
            }

            // Check for letter keys (a-z) when field is empty
            if let chars = event.charactersIgnoringModifiers,
               chars.count == 1,
               let char = chars.lowercased().first,
               char >= "a", char <= "z",
               event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                // Only trigger quick-select if the field is empty
                if stringValue.isEmpty {
                    onLetterKey?(char)
                    return
                }
            }

            super.keyDown(with: event)
        }
    }
}
