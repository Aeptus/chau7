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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if groups.isEmpty {
                            emptyState
                        }
                        ForEach(groups) { group in
                            if snapshot.groups.count > 1 {
                                HStack {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(String(group.rows.count))
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .padding(.bottom, 8)
                            }
                            ForEach(group.rows) { row in
                                sessionRow(row)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(UIColor.systemGroupedBackground))
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
            .searchable(text: $query, prompt: "Session, project, or branch")
            .safeAreaInset(edge: .bottom) {
                if !isConnected {
                    Label("Reconnect to switch sessions", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.bar)
                }
            }
        }
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
            HStack(spacing: 12) {
                Image(systemName: row.aiProvider == nil ? "terminal" : "sparkles")
                    .font(.body)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                        .font(.body.weight(selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text("#\(row.id)")
                            .monospacedDigit()
                        if let provider = row.aiProvider {
                            Text(provider)
                        }
                        if let branch = row.branchName {
                            Label(branch, systemImage: "arrow.triangle.branch")
                        }
                        if row.isMCPControlled {
                            Image(systemName: "face.dashed.fill")
                                .accessibilityLabel("MCP controlled")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 64)
            .background(selected ? Color.accentColor.opacity(0.10) : Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
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
