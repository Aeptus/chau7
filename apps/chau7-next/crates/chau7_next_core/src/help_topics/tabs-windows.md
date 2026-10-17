# Working with Tabs & Windows

## Tab Management

| Action | Shortcut |
|--------|----------|
| New Tab | ⌘T |
| Close Tab | ⌘W |
| Close Other Tabs | ⌥⌘W |
| Next Tab | ⇧⌘] or ⌃Tab or ⌥⌘→ |
| Previous Tab | ⇧⌘[ or ⌃⇧Tab or ⌥⌘← |
| Select Tab 1-9 | ⌘1-9 |
| Move Tab Right | ⇧⌥⌘] |
| Move Tab Left | ⇧⌥⌘[ |
| Rename Tab | ⇧⌘R |

## Idle Tabs and Numbered Shortcuts

The idle-tabs dropdown groups tabs by repository, with a repository heading and separators between groups. Tabs without a repository appear in **No repository**. Select a tab to bring it back to the tab bar; **Close All Idle** still applies to every idle group.

In **Settings > Tabs > Keyboard Navigation**, enable **Numbered Shortcuts Target Visible Tabs Only** to make numbered shortcuts follow the visible tab order. Tabs inside the Idle dropdown are skipped. Tabs outside the horizontal viewport still count. The option is off by default, preserving the existing all-tabs order.

The equivalent configuration is `numbered_shortcuts_visible_only = true` under `[next]`. It applies to the configured numbered shortcuts, including Cmd+1–9 on macOS, Alt+1–9 on Linux/Windows, and function-key bindings.

## Window Management

| Action | Shortcut |
|--------|----------|
| New Window | ⌘N |
| Close Window | ⇧⌘W |
| Full Screen | ⌃⌘F |

## Moving Tabs Between Windows

**Right-click menu:** Right-click any tab → **Move to Window** → select the target window or **New Window**. For grouped tabs, right-click the group bracket (repo name) → **Move Group to Window**.

**Drag and drop:** In windowed (non-fullscreen) mode, drag a tab or group bracket to the other visible window. Note: drag between windows does not work in fullscreen mode - macOS prevents cursor movement between fullscreen Spaces during drag. Use the right-click menu instead.

## Repo Tab Grouping

Tabs in the same git repository are automatically grouped with a colored bracket showing the repo name. Right-click the bracket for group actions (move group, ungroup, close group). You can also manually group tabs via right-click → **Group All Same Repo**.

## Tab Colors

Each tab can have a custom color. Right-click a tab or use **⇧⌘R** to change its color. Tabs can also be automatically colored based on the AI CLI you're using.
