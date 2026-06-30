import SwiftUI

// MARK: - Overlay Colors

// Shared dark palette for the overlay panels and their rows/chips. Module-
// internal (not file-private) so the per-feature overlay views split out of
// Chau7OverlayView (clipboard history, bookmarks, snippets) reference the same
// constants instead of each redefining them.
let overlayPanelBackground = Color(red: 0.10, green: 0.10, blue: 0.10)
let overlayRowBackground = Color(red: 0.16, green: 0.16, blue: 0.16)
let overlayChipBackground = Color(red: 0.22, green: 0.22, blue: 0.22)
