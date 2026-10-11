//! Tab bar and overlay actions (tabs, bookmarks, minimal mode).

use gpui::actions;

actions!(
    chau7,
    [
        /// Close every tab of the window but the selected one.
        CloseOtherTabs,
        /// Swap the selected tab with its left neighbor.
        MoveTabLeft,
        /// Swap the selected tab with its right neighbor.
        MoveTabRight,
        /// Open the rename panel on the color row (`showTabColorPicker`).
        ShowTabColorPicker,
        /// Bookmark the cursor line of the selected tab.
        AddBookmark,
        /// Show or hide the bookmarks panel.
        ToggleBookmarks,
        /// Record tabs and scrub through the recordings.
        ShowSessionTimeline,
        /// Minimal mode (Cmd+Shift+M).
        ToggleMinimalMode,
    ]
);
