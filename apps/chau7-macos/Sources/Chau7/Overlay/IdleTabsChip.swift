import SwiftUI

/// Compact chip that shows idle tab count. Click to expand a popover listing
/// idle tabs with hover card support and click-to-select.
struct IdleTabsChip: View {
    let tabs: [OverlayTab]
    @ObservedObject var overlayModel: OverlayTabsModel
    let idleDuration: (OverlayTab) -> String

    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10))
                Text("\(tabs.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(height: OverlayLayout.tabChipHeight, alignment: .center)
            .background(isExpanded ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Idle tabs (\(tabs.count))")
        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
            idleTabsList
        }
    }

    private var idleTabsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tabs) { tab in
                idleTabRow(tab: tab)
                if tab.id != tabs.last?.id {
                    Divider()
                }
            }

            Divider()

            Button {
                overlayModel.dismissHoverCard()
                for tab in tabs {
                    overlayModel.closeTab(id: tab.id)
                }
                isExpanded = false
            } label: {
                Label("Close All Idle", systemImage: "xmark.circle")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 240)
    }

    private func idleTabRow(tab: OverlayTab) -> some View {
        let title = tab.customTitle ?? tab.displaySession?.activeAppName ?? "Tab"
        let idle = idleDuration(tab)

        return Button {
            overlayModel.dismissHoverCard()
            overlayModel.selectTab(id: tab.id)
            isExpanded = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Text(idle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                // Show the tab hover card anchored near the popover
                overlayModel.tabHoverBegan(id: tab.id, anchorX: 40)
            } else {
                overlayModel.tabHoverEnded(id: tab.id)
            }
        }
    }
}
