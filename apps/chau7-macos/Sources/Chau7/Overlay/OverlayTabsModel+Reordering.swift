import Foundation

/// Tab reordering primitives. Four entry points cover the reordering
/// patterns the app uses:
///
///   - `moveTab(id:toIndex:)` — insertion-point-based move (drop-target
///     style). Clamps destination; adjusts for removal offset so the
///     caller can pass the "insertion point among current tabs" index.
///   - `moveTab(fromIndex:toIndex:)` — Chrome/Safari-style drag end,
///     both indices interpreted in the *current* tab array.
///   - `moveGroup(fromRange:toIndex:)` — contiguous-group drag for
///     within-window repo-group reorder. Destination is the
///     post-removal insertion point (caller precomputes this via
///     `TabBarLayout.groupDestinationIndex`).
///   - `moveCurrentTabLeft` / `moveCurrentTabRight` — keyboard shortcuts,
///     adjacent swap only.
///
/// All methods assert `.onQueue(.main)` because they mutate the
/// `@Observable` `tabs` array that SwiftUI observes — stray off-main
/// mutations would be undefined behavior in the observation fanout.
extension OverlayTabsModel {
    func moveTab(id: UUID, toIndex: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let fromIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clampedIndex = max(0, min(toIndex, tabs.count))
        let adjustedIndex = clampedIndex > fromIndex ? clampedIndex - 1 : clampedIndex
        guard adjustedIndex != fromIndex else { return }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: adjustedIndex)
        Log.info("Moved tab \(id) to index \(adjustedIndex)")
    }

    /// Moves a tab from one index to another. Used at drag-end for Chrome/Safari style reordering.
    func moveTab(fromIndex source: Int, toIndex destination: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard source != destination,
              source >= 0, source < tabs.count,
              destination >= 0, destination < tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        Log.info("Moved tab from index \(source) to \(destination)")
    }

    /// Moves a contiguous group of tabs from `range` so that the first tab
    /// of the group lands at `destination`. Used for within-window group drag.
    func moveGroup(fromRange range: Range<Int>, toIndex destination: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= tabs.count,
              destination >= 0,
              destination <= tabs.count - range.count,
              destination != range.lowerBound else { return }
        let group = Array(tabs[range])
        tabs.removeSubrange(range)
        // groupDestinationIndex already accounts for group removal:
        // rightward returns (neighbor - count + 1), leftward returns
        // the raw index. Either way, destination is the correct
        // post-removal insertion point.
        tabs.insert(contentsOf: group, at: destination)
        Log.info("Moved group (\(range.count) tabs) from \(range.lowerBound) to \(destination)")
    }

    func moveCurrentTabRight() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
              index < tabs.count - 1 else { return }
        tabs.swapAt(index, index + 1)
        Log.info("Moved tab right to index \(index + 1)")
    }

    func moveCurrentTabLeft() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
              index > 0 else { return }
        tabs.swapAt(index, index - 1)
        Log.info("Moved tab left to index \(index - 1)")
    }
}
