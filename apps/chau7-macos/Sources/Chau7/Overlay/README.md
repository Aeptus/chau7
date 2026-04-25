# Overlay

Tab bar model, views, and hover card — the core UI for managing terminal tabs.

## Files

| File | Purpose |
|------|---------|
| `OverlayTabsModel.swift` | Central model: tab lifecycle, selection, persistence, grouping, notifications |
| `OverlayTabsModel+SessionFinder.swift` | Provider session-finder registry, identity normalization, scrollback capture |
| `OverlayTabsModel+RestorePipeline.swift` | Tab-state restore + backup IO + restoreTabState orchestration |
| `OverlayTabsModel+ResumePrefillDelivery.swift` | Resume-command scheduling + validation + delivery state machine |
| `OverlayTabsModel+AIResumeMetadata.swift` | AI resume metadata resolution, repo identity helpers, sanitization |
| `OverlayTabsModel+RevealLifecycle.swift` | Selected-tab reveal handoff (preview → live frame), startup live-frame reporting |
| `OverlayTabsModel+DeferredRestore.swift` | Background-tab deferred restore queue management |
| `OverlayTabsModel+RenderSuspension.swift` | Render lifecycle / phase decisions / suspension state |
| `OverlayTabsModel+Refresh.swift` | Force-refresh selected tab, tab bar recovery |
| `OverlayTabsModel+NotificationActions.swift` | CTO per-tab override, tab notification styling, MCP action handlers |
| `OverlayTabsModel+OverlayActions.swift` | Overlay dismissal, split-pane operations, last-command tracking |
| `OverlayTabsModel+RenameSearchClipboard.swift` | Rename dialog, search panel, clipboard/zoom pass-throughs |
| `OverlayTabsModel+Features.swift` | F05/F13/F16/F17/F21 feature blocks |
| `OverlayTabsModel+TabSwitchOptimization.swift` | Pre-warm on hover, snapshot capture, tab-switch optimization, render state caching |
| `OverlayTabsModel+RestorePreviewSnapshot.swift` | NSView/bitmap helpers for restore-preview snapshot capture |
| `Chau7OverlayView.swift` | Tab bar SwiftUI views: segments, buttons, brackets, drag/drop, hit testing |
| `TabHoverCard.swift` | Hover card: AI session summary, conflicts, process info, notification state |

## Architecture

`OverlayTabsModel` is an `ObservableObject` with `@Published var tabs: [OverlayTab]`.
Each `OverlayTab` is a struct (Equatable by id + key fields) wrapping a `SplitPaneController`.
The tab bar is rendered via `ToolbarTabBarView` in an `NSToolbarItem` host.

Extension files split the model by feature domain — same class, separate files.
