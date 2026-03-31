# Overlay

Tab bar model, views, and hover card — the core UI for managing terminal tabs.

## Files

| File | Purpose |
|------|---------|
| `OverlayTabsModel.swift` | Central model: tab lifecycle, selection, persistence, grouping, notifications |
| `OverlayTabsModel+SessionFinder.swift` | AI resume resolution, Codex session matching, provider-specific finders |
| `OverlayTabsModel+TabSwitchOptimization.swift` | Pre-warm on hover, snapshot capture, render state caching |
| `Chau7OverlayView.swift` | Tab bar SwiftUI views: segments, buttons, brackets, drag/drop, hit testing |
| `TabHoverCard.swift` | Hover card: AI session summary, conflicts, process info, notification state |

## Architecture

`OverlayTabsModel` is an `ObservableObject` with `@Published var tabs: [OverlayTab]`.
Each `OverlayTab` is a struct (Equatable by id + key fields) wrapping a `SplitPaneController`.
The tab bar is rendered via `ToolbarTabBarView` in an `NSToolbarItem` host.

Extension files split the model by feature domain — same class, separate files.
