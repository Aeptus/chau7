import Chau7Core
import SwiftUI

/// A persistent scrolling surface instead of a system Menu, whose content
/// replacement resets its offset. Equality ignores transport-only descriptor
/// fields and unrelated terminal/activity output; row identity is the tab ID.
struct RemoteTabPickerView: View, Equatable {
    let snapshot: RemoteTabPickerSnapshot
    let activeTabID: UInt32
    let inventoryState: RemoteTabInventoryState
    let isConnected: Bool
    let onSelect: (UInt32) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var focus = RemoteTabPickerFocus()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.activeTabID == rhs.activeTabID
            && lhs.inventoryState == rhs.inventoryState && lhs.isConnected == rhs.isConnected
    }

    private var groups: [RemoteTabPickerSnapshot.Group] {
        snapshot.filteredGroups(query: query)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if groups.isEmpty {
                            emptyState
                        }
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    sessionRow(row)
                                        .id(row.id)
                                }
                            } header: {
                                if snapshot.groups.count > 1 {
                                    repositoryHeader(group)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .background(Color(uiColor: .systemBackground))
                .scrollDismissesKeyboard(.interactively)
                .task {
                    // onAppear precedes the first navigation/scroll layout.
                    // Yield so the selected row has an anchor before scrolling.
                    await Task.yield()
                    focusSelection(using: proxy)
                }
                .onChange(of: snapshot.tabIDs) { _, _ in focusSelection(using: proxy) }
                .onChange(of: activeTabID) { _, _ in focusSelection(using: proxy) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Current", systemImage: "scope") {
                            query = ""
                            // Let a cleared search lay out the selected row.
                            Task { @MainActor in
                                await Task.yield()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(activeTabID, anchor: .center)
                                }
                            }
                        }
                        .disabled(!snapshot.tabIDs.contains(activeTabID))
                        .accessibilityHint("Scrolls to the open session.")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Session, repository, or branch"
            )
            .safeAreaInset(edge: .bottom) {
                if !isConnected {
                    Label("Reconnect to switch sessions", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
    }

    private func repositoryHeader(_ group: RemoteTabPickerSnapshot.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.rows.first?.projectName == nil ? "terminal" : "folder")
                .accessibilityHidden(true)
            Text(group.title)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: 8)
            Text(group.rows.count, format: .number)
                .monospacedDigit()
                .accessibilityLabel("\(group.rows.count) sessions")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func focusSelection(using proxy: ScrollViewProxy) {
        // A search is intentional browsing; don't pull the list away from it.
        guard query.isEmpty,
              let target = focus.target(activeTabID: activeTabID, visibleTabIDs: snapshot.tabIDs)
        else { return }
        proxy.scrollTo(target, anchor: .center)
    }

    private func sessionRow(_ row: RemoteTabPickerSnapshot.Row) -> some View {
        let selected = row.id == activeTabID
        return Button {
            onSelect(row.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.aiProvider == nil ? "terminal" : "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let provider = row.aiProvider {
                            Text(provider)
                                .layoutPriority(1)
                        }
                        if let branch = row.branchName {
                            Text(branch)
                                .truncationMode(.middle)
                        }
                        if row.isMCPControlled {
                            Image(systemName: "face.dashed.fill")
                                .accessibilityLabel("MCP controlled")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("#\(row.id)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Session \(row.id)")
                if selected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear)
            .overlay(alignment: .bottom) {
                Divider().padding(.leading, 42)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("session.\(row.id)")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label(inventoryState == .syncing ? "Syncing sessions…" : "No sessions", systemImage: "terminal")
            } description: {
                Text(inventoryState == .syncing
                     ? "Your Mac's sessions will appear here."
                     : "Open a terminal tab on your Mac to get started.")
            }
        }
    }
}
