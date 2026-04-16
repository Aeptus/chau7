import Foundation
import Chau7Core

final class TabRenderLifecycleController {
    struct Snapshot {
        let selectedTabID: UUID
        let isInputPriorityWindow: Bool
        let isWindowVisibleForRendering: Bool
        let previousLiveHierarchyTabID: UUID?
        let prewarmingTabIDs: Set<UUID>
        let restoreBootstrapTabIDs: Set<UUID>
        let isRenderSuspensionEnabled: Bool
        let isStartupRestoreActive: Bool
    }

    struct TabDescriptor {
        let id: UUID
        let isMCPControlled: Bool
        let hasAttachedTerminalView: Bool
        let hasBackgroundActivity: Bool
    }

    func decision(
        for descriptor: TabDescriptor,
        snapshot: Snapshot
    ) -> TabRenderLifecycleDecision {
        TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: descriptor.id == snapshot.selectedTabID,
                isInputPriorityWindow: snapshot.isInputPriorityWindow,
                isWindowVisibleForRendering: snapshot.isWindowVisibleForRendering,
                isPreviousLiveTab: descriptor.id == snapshot.previousLiveHierarchyTabID,
                isPrewarming: snapshot.prewarmingTabIDs.contains(descriptor.id),
                hasBackgroundActivity: descriptor.hasBackgroundActivity,
                isRenderSuspensionEnabled: snapshot.isRenderSuspensionEnabled,
                isStartupRestoreActive: snapshot.isStartupRestoreActive,
                hasPendingRestoreBootstrap: snapshot.restoreBootstrapTabIDs.contains(descriptor.id),
                isMCPControlled: descriptor.isMCPControlled,
                hasAttachedTerminalView: descriptor.hasAttachedTerminalView
            )
        )
    }
}
