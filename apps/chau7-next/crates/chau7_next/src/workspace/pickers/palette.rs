//! The command palette's command list (`CommandPaletteProvider` in Swift).
//!
//! Each entry runs an action. Actions another area owns (Close Other Tabs,
//! Export Text, Scroll to Top, ...) are looked up by name with
//! `cx.build_action`: an entry shows up as soon as its action exists, so the
//! palette needs no change when that area lands.

use chau7_next_core::shortcut_display::{Mods, format_keystroke};
use gpui::{Action, App, Window};
use gpui_kit::assets::IconName;

use crate::actions::*;
use crate::commands::*;

/// The icon in front of a palette row (Swift: an SF Symbol).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(in crate::workspace) enum PaletteIcon {
    /// A Lucide icon close to the SF Symbol.
    Lucide(IconName),
    /// "Select Tab N": the digit in a circle (`N.circle`).
    Number(u8),
}

/// One palette entry.
pub(in crate::workspace) struct PaletteCommand {
    pub title: String,
    pub category: &'static str,
    pub icon: PaletteIcon,
    /// Shortcut as the keymap shows it (for example `⇧⌘N`).
    pub shortcut: Option<String>,
    pub action: Box<dyn Action>,
}

impl Clone for PaletteCommand {
    fn clone(&self) -> Self {
        Self {
            title: self.title.clone(),
            category: self.category,
            icon: self.icon,
            shortcut: self.shortcut.clone(),
            action: self.action.boxed_clone(),
        }
    }
}

/// An action made from its type or, when another area declares it, its name.
enum Spec {
    Typed(Box<dyn Action>),
    Named(&'static str),
}

fn typed<A: Action>(action: A) -> Spec {
    Spec::Typed(Box::new(action))
}

struct Entry {
    title: &'static str,
    category: &'static str,
    icon: PaletteIcon,
    spec: Spec,
}

fn entry(title: &'static str, category: &'static str, icon: IconName, spec: Spec) -> Entry {
    Entry {
        title,
        category,
        icon: PaletteIcon::Lucide(icon),
        spec,
    }
}

/// All commands in Swift's order: File, Edit, View, Terminal, Tabs, Window,
/// Help; then the Chau7 Next extras. Icons follow Swift's SF Symbols.
fn catalog() -> Vec<Entry> {
    use IconName as I;
    use Spec::Named;
    let mut list = vec![
        entry("New Window", "File", I::AppWindow, typed(NewWindow)),
        entry("New Tab", "File", I::SquarePlus, typed(NewTab)),
        entry("Close Tab", "File", I::SquareX, typed(CloseTab)),
        entry("Close Window", "File", I::X, typed(CloseWindow)),
        entry("Close Other Tabs", "File", I::CopyX, typed(CloseOtherTabs)),
        entry(
            "Reopen Closed Tab",
            "File",
            I::Undo2,
            typed(ReopenClosedTab),
        ),
        entry("Export Text...", "File", I::Share, typed(ExportText)),
        entry("Print...", "File", I::Printer, typed(PrintTerminal)),
        entry("Cut", "Edit", I::Scissors, typed(Cut)),
        entry("Copy", "Edit", I::Copy, typed(Copy)),
        entry("Paste", "Edit", I::ClipboardPaste, typed(Paste)),
        entry(
            "Paste Escaped",
            "Edit",
            I::ClipboardCopy,
            typed(PasteEscaped),
        ),
        entry("Select All", "Edit", I::TextCursorInput, typed(SelectAll)),
        entry("Find...", "Edit", I::Search, typed(ToggleSearch)),
        entry("Find Next", "Edit", I::CircleArrowDown, typed(FindNext)),
        entry(
            "Find Previous",
            "Edit",
            I::CircleArrowUp,
            typed(FindPrevious),
        ),
        entry(
            "Use Selection for Find",
            "Edit",
            I::TextSearch,
            typed(UseSelectionForFind),
        ),
        entry("Snippets...", "Edit", I::ListPlus, typed(ToggleSnippets)),
        entry(
            "Manage Snippets...",
            "Edit",
            I::ListChecks,
            typed(ManageSnippets),
        ),
        entry(
            "Migrate Snippets to Clean JSON",
            "Edit",
            I::RefreshCcw,
            typed(MigrateSnippets),
        ),
        entry(
            "Reload Snippets",
            "Edit",
            I::RotateCw,
            typed(ReloadSnippets),
        ),
        entry(
            "Toggle Full Screen",
            "View",
            I::Maximize2,
            typed(ToggleFullScreen),
        ),
        entry("Zoom In", "View", I::ZoomIn, typed(IncreaseFontSize)),
        entry("Zoom Out", "View", I::ZoomOut, typed(DecreaseFontSize)),
        entry("Actual Size", "View", I::ScanSearch, typed(ResetFontSize)),
        entry(
            "Open Text Editor",
            "Terminal",
            I::FileText,
            Named("chau7::OpenTextEditor"),
        ),
        entry(
            "Append Selection to Editor",
            "Terminal",
            I::ListEnd,
            Named("chau7::AppendSelectionToEditor"),
        ),
        entry("Split Horizontal", "Terminal", I::Rows2, typed(SplitRight)),
        entry("Split Vertical", "Terminal", I::Columns2, typed(SplitDown)),
        entry("Close Pane", "Terminal", I::X, typed(ClosePane)),
        entry(
            "Focus Next Pane",
            "Terminal",
            I::SquareArrowRight,
            typed(FocusNextPane),
        ),
        entry(
            "Focus Previous Pane",
            "Terminal",
            I::SquareArrowLeft,
            typed(FocusPreviousPane),
        ),
        entry("Clear Screen", "Terminal", I::Eraser, typed(ClearScreen)),
        entry(
            "Clear Scrollback",
            "Terminal",
            I::BrushCleaning,
            typed(ClearScrollback),
        ),
        entry(
            "Scroll to Top",
            "Terminal",
            I::ArrowUpToLine,
            typed(ScrollToTop),
        ),
        entry(
            "Scroll to Bottom",
            "Terminal",
            I::ArrowDownToLine,
            typed(ScrollToBottom),
        ),
        entry(
            "Previous Input Line",
            "Terminal",
            I::ArrowUpToLine,
            typed(PreviousInputLine),
        ),
        entry(
            "Next Input Line",
            "Terminal",
            I::ArrowDownToLine,
            typed(NextInputLine),
        ),
        entry("Show Next Tab", "Tabs", I::SquareArrowRight, typed(NextTab)),
        entry(
            "Show Previous Tab",
            "Tabs",
            I::SquareArrowLeft,
            typed(PreviousTab),
        ),
        entry(
            "Move Tab Right",
            "Tabs",
            I::ArrowRightToLine,
            typed(MoveTabRight),
        ),
        entry(
            "Move Tab Left",
            "Tabs",
            I::ArrowLeftToLine,
            typed(MoveTabLeft),
        ),
        entry("Rename Tab...", "Tabs", I::Pencil, typed(RenameTab)),
        entry(
            "Force Refresh Tab",
            "Tabs",
            I::RotateCw,
            typed(ForceRefreshTab),
        ),
        entry(
            "Refresh Tab Bar",
            "Tabs",
            I::RefreshCw,
            typed(RefreshTabBar),
        ),
    ];
    for (n, title) in [
        "Select Tab 1",
        "Select Tab 2",
        "Select Tab 3",
        "Select Tab 4",
        "Select Tab 5",
        "Select Tab 6",
        "Select Tab 7",
        "Select Tab 8",
        "Select Tab 9",
    ]
    .into_iter()
    .enumerate()
    {
        list.push(Entry {
            title,
            category: "Tabs",
            icon: PaletteIcon::Number(n as u8 + 1),
            spec: typed(SelectTabNumber(n + 1)),
        });
    }
    list.extend([
        entry("Settings...", "Window", I::Settings, typed(OpenSettings)),
        entry(
            "Debug Console",
            "Window",
            I::Terminal,
            typed(ToggleDebugConsole),
        ),
        entry(
            "SSH Connections...",
            "Window",
            I::Server,
            typed(ShowSshManager),
        ),
        entry(
            "Keyboard Shortcuts...",
            "Window",
            I::Keyboard,
            typed(ShowKeyboardShortcuts),
        ),
        entry("About Chau7 Next", "Help", I::Info, typed(ShowAbout)),
        entry("Documentation", "Help", I::Book, typed(ShowHelp)),
        entry(
            "Import Terminal Profiles...",
            "Window",
            I::Import,
            typed(ImportTerminalProfiles),
        ),
        entry(
            "Report Issue",
            "Help",
            I::MessageSquareWarning,
            typed(ReportIssue),
        ),
        // Chau7 Next extras (not in the Swift palette).
        entry(
            "Open config.toml",
            "Window",
            I::FileCog,
            typed(OpenConfigFile),
        ),
        entry(
            "Reload Settings",
            "Window",
            I::RefreshCw,
            typed(ReloadConfig),
        ),
        entry(
            "Clipboard History",
            "Edit",
            I::ClipboardList,
            typed(ShowClipboardHistory),
        ),
        entry(
            "Command History",
            "Terminal",
            I::Clock,
            typed(ShowCommandHistory),
        ),
        entry(
            "Session Timeline",
            "View",
            I::ClockArrowUp,
            typed(ShowSessionTimeline),
        ),
        entry(
            "Terminal Analytics",
            "View",
            I::ChartColumn,
            typed(ShowTerminalAnalytics),
        ),
        entry(
            "Toggle Broadcast Input",
            "Terminal",
            I::RadioTower,
            typed(ToggleBroadcast),
        ),
        entry("Connect via SSH", "Window", I::Server, typed(ShowSshHosts)),
        entry("Load Demo Tabs", "Window", I::Layers, typed(SeedDebugTabs)),
        entry(
            "AI Terminal Logs",
            "Window",
            I::ScrollText,
            Named("chau7_ai::ShowAiLogs"),
        ),
    ]);
    list
}

/// The commands that can run now, with their shortcuts.
pub(in crate::workspace) fn commands(window: &Window, cx: &App) -> Vec<PaletteCommand> {
    catalog()
        .into_iter()
        .filter_map(
            |Entry {
                 title,
                 category,
                 icon,
                 spec,
             }| {
                let action = match spec {
                    Spec::Typed(action) => action,
                    Spec::Named(name) => cx.build_action(name, None).ok()?,
                };
                let shortcut = window
                    .bindings_for_action(action.as_ref())
                    .last()
                    .map(|binding| {
                        binding
                            .keystrokes()
                            .iter()
                            .map(|k| {
                                let m = k.modifiers();
                                let mods = Mods {
                                    control: m.control,
                                    alt: m.alt,
                                    shift: m.shift,
                                    platform: m.platform,
                                };
                                format_keystroke(mods, k.key(), cfg!(target_os = "macos"))
                            })
                            .collect::<Vec<_>>()
                            .join(" ")
                    });
                Some(PaletteCommand {
                    title: crate::l10n::tr(title),
                    category,
                    icon,
                    shortcut,
                    action,
                })
            },
        )
        .collect()
}

/// Palette search: the command title or its category, case-insensitive.
pub(in crate::workspace) fn matches(command: &PaletteCommand, query: &str) -> bool {
    let query = query.to_lowercase();
    query.is_empty()
        || command.title.to_lowercase().contains(&query)
        || command.category.to_lowercase().contains(&query)
        || crate::l10n::tr(command.category)
            .to_lowercase()
            .contains(&query)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(title: &str, category: &'static str) -> PaletteCommand {
        PaletteCommand {
            title: title.into(),
            category,
            icon: PaletteIcon::Number(1),
            shortcut: None,
            action: Box::new(NewTab),
        }
    }

    #[test]
    fn search_matches_title_or_category() {
        let c = command("Close Other Tabs", "File");
        assert!(matches(&c, ""));
        assert!(matches(&c, "other"));
        assert!(matches(&c, "FILE"));
        assert!(!matches(&c, "edit"));
    }

    #[test]
    fn catalog_has_unique_titles_and_the_swift_set() {
        let titles: Vec<_> = catalog().into_iter().map(|e| e.title).collect();
        let mut seen = std::collections::HashSet::new();
        assert!(titles.iter().all(|t| seen.insert(*t)), "duplicate title");
        for needed in [
            "Select Tab 9",
            "Manage Snippets...",
            "Migrate Snippets to Clean JSON",
            "Reload Snippets",
            "SSH Connections...",
            "Print...",
            "Previous Input Line",
            "Next Input Line",
            "Keyboard Shortcuts...",
            "Force Refresh Tab",
            "Refresh Tab Bar",
        ] {
            assert!(titles.contains(&needed), "{needed}");
        }
    }

    #[test]
    fn every_icon_is_bundled() {
        use gpui::AssetSource;
        for e in catalog() {
            if let PaletteIcon::Lucide(icon) = e.icon {
                let path = icon.path();
                assert!(
                    matches!(crate::assets::AppAssets.load(&path), Ok(Some(_))),
                    "{} icon {path} is not bundled",
                    e.title
                );
            }
        }
    }
}
