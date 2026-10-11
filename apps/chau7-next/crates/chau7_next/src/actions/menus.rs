//! The app menu bar, laid out like `Chau7App.swift`: the app menu, File,
//! Edit, View, Window and Help. Items only Chau7 Next has (config file,
//! broadcast, clipboard and command history, demo tabs) sit next to their
//! closest Swift neighbor.

use gpui::{Menu, MenuItem, SystemMenuType};

use super::*;

/// `tab_titles`: names of the selected window's tabs, for Window > Select Tab.
pub fn app_menus(tab_titles: &[String]) -> Vec<Menu> {
    localize_menus(english_menus(tab_titles), chau7_next_core::l10n::current())
}

/// Translate menu and item titles into `lang` with the Swift keys. Tab titles
/// (Window > Select Tab) are user text and stay as they are; on macOS the
/// Window menu keeps its name because GPUI finds the system window list by it.
fn localize_menus(menus: Vec<Menu>, lang: chau7_next_core::l10n::Lang) -> Vec<Menu> {
    use chau7_next_core::l10n::translate;
    fn menu(m: Menu, lang: chau7_next_core::l10n::Lang, top: bool) -> Menu {
        let keep = m.name == "Select Tab";
        let name = if top && cfg!(target_os = "macos") && m.name == "Window" {
            m.name
        } else {
            translate(lang, &m.name).into()
        };
        let items = m
            .items
            .into_iter()
            .map(|item| match item {
                MenuItem::Action {
                    name,
                    action,
                    os_action,
                    checked,
                    disabled,
                } => MenuItem::Action {
                    name: if keep {
                        name
                    } else {
                        translate(lang, &name).into()
                    },
                    action,
                    os_action,
                    checked,
                    disabled,
                },
                MenuItem::Submenu(sub) => MenuItem::Submenu(menu(sub, lang, false)),
                MenuItem::SystemMenu(os) => {
                    MenuItem::os_submenu(translate(lang, &os.name), os.menu_type)
                }
                other => other,
            })
            .collect();
        Menu {
            name,
            items,
            disabled: m.disabled,
        }
    }
    menus.into_iter().map(|m| menu(m, lang, true)).collect()
}

fn english_menus(tab_titles: &[String]) -> Vec<Menu> {
    vec![
        app_menu(),
        file_menu(),
        edit_menu(),
        view_menu(),
        window_menu(tab_titles),
        help_menu(),
    ]
}

fn app_menu() -> Menu {
    let mut items = vec![
        MenuItem::action("About Chau7 Next", ShowAbout),
        MenuItem::separator(),
        MenuItem::action("Settings…", OpenSettings),
        MenuItem::action("Open config.toml", OpenConfigFile),
        MenuItem::action("Reload Settings", ReloadConfig),
        MenuItem::separator(),
    ];
    if cfg!(target_os = "macos") {
        items.push(MenuItem::os_submenu("Services", SystemMenuType::Services));
        items.push(MenuItem::separator());
    }
    items.extend([
        MenuItem::action("Hide Chau7 Next", HideApp),
        MenuItem::action("Hide Others", HideOtherApps),
        MenuItem::action("Show All", ShowAllApps),
        MenuItem::separator(),
        MenuItem::action("Quit Chau7 Next", Quit),
    ]);
    Menu {
        name: "Chau7 Next".into(),
        items,
        disabled: false,
    }
}

fn file_menu() -> Menu {
    Menu {
        name: "File".into(),
        items: vec![
            MenuItem::action("New Window", NewWindow),
            MenuItem::action("New Tab", NewTab),
            MenuItem::action("SSH Connections…", crate::commands::ShowSshManager),
            MenuItem::action("SSH Hosts (~/.ssh/config)…", ShowSshHosts),
            MenuItem::separator(),
            MenuItem::action("Close Tab", CloseTab),
            MenuItem::action("Close Window", CloseWindow),
            MenuItem::action("Close Other Tabs", CloseOtherTabs),
            MenuItem::action("Reopen Closed Tab", ReopenClosedTab),
            MenuItem::separator(),
            MenuItem::action("Export Text…", ExportText),
            MenuItem::action("Print…", PrintTerminal),
            MenuItem::separator(),
            MenuItem::action("Import Terminal Profiles…", ImportTerminalProfiles),
        ],
        disabled: false,
    }
}

fn edit_menu() -> Menu {
    Menu {
        name: "Edit".into(),
        items: vec![
            MenuItem::action("Cut", Cut),
            MenuItem::action("Copy", Copy),
            MenuItem::action("Paste", Paste),
            MenuItem::action("AutoFill from Passwords…", AutoFillFromPasswords),
            MenuItem::action("Paste Escaped", PasteEscaped),
            MenuItem::action("Select All", SelectAll),
            MenuItem::separator(),
            MenuItem::submenu(Menu {
                name: "Find".into(),
                items: vec![
                    MenuItem::action("Find…", ToggleSearch),
                    MenuItem::action("Find Next", FindNext),
                    MenuItem::action("Find Previous", FindPrevious),
                    MenuItem::separator(),
                    MenuItem::action("Use Selection for Find", UseSelectionForFind),
                ],
                disabled: false,
            }),
            MenuItem::separator(),
            MenuItem::action("Snippets…", ToggleSnippets),
            MenuItem::action("Command Palette…", ToggleCommandPalette),
            MenuItem::separator(),
            MenuItem::action("Clipboard History…", ShowClipboardHistory),
            MenuItem::action("Command History…", ShowCommandHistory),
            MenuItem::separator(),
            MenuItem::action("Add Bookmark", AddBookmark),
            MenuItem::action("Bookmarks…", ToggleBookmarks),
        ],
        disabled: false,
    }
}

fn view_menu() -> Menu {
    Menu {
        name: "View".into(),
        items: vec![
            MenuItem::action("Data Explorer", DataExplorer),
            MenuItem::action("Terminal Analytics…", ShowTerminalAnalytics),
            MenuItem::action("Session Timeline…", ShowSessionTimeline),
            MenuItem::separator(),
            MenuItem::action("Enter Full Screen", ToggleFullScreen),
            MenuItem::action("Minimal Mode", ToggleMinimalMode),
            MenuItem::separator(),
            MenuItem::action("Zoom In", IncreaseFontSize),
            MenuItem::action("Zoom Out", DecreaseFontSize),
            MenuItem::action("Actual Size", ResetFontSize),
            MenuItem::separator(),
            MenuItem::action("Clear Screen", ClearScreen),
            MenuItem::action("Clear Scrollback", ClearScrollback),
            MenuItem::separator(),
            MenuItem::action("Previous Input Line", PreviousInputLine),
            MenuItem::action("Next Input Line", NextInputLine),
            MenuItem::separator(),
            MenuItem::submenu(Menu {
                name: "Panes".into(),
                items: vec![
                    MenuItem::action("Split Horizontally", SplitRight),
                    MenuItem::action("Split Vertically", SplitDown),
                    MenuItem::separator(),
                    MenuItem::action("Open Text Editor", OpenTextEditor),
                    MenuItem::action("Open File Preview", OpenFilePreview),
                    MenuItem::action("Open Diff Viewer", OpenDiffViewer),
                    MenuItem::action("Append Selection to Editor", AppendSelectionToEditor),
                    MenuItem::separator(),
                    MenuItem::action("Close Pane", ClosePane),
                    MenuItem::separator(),
                    MenuItem::action("Focus Next Pane", FocusNextPane),
                    MenuItem::action("Focus Previous Pane", FocusPreviousPane),
                ],
                disabled: false,
            }),
            MenuItem::separator(),
            MenuItem::action("Show Changed Files", ShowChangedFiles),
        ],
        disabled: false,
    }
}

fn window_menu(tab_titles: &[String]) -> Menu {
    // Tabs 1 to 9 carry Cmd+1..9; later tabs are listed without a shortcut
    // (their action is still "select tab N").
    let mut select: Vec<MenuItem> = tab_titles
        .iter()
        .enumerate()
        .map(|(i, title)| MenuItem::action(title.clone(), SelectTabNumber(i + 1)))
        .collect();
    if select.is_empty() {
        select.push(MenuItem::action("Tab 1", SelectTabNumber(1)));
    }
    Menu {
        name: "Window".into(),
        items: vec![
            MenuItem::action("Minimize", Minimize),
            MenuItem::action("Zoom", Zoom),
            MenuItem::separator(),
            MenuItem::action("Rename Tab…", RenameTab),
            MenuItem::separator(),
            MenuItem::action("Show Next Tab", NextTab),
            MenuItem::action("Show Previous Tab", PreviousTab),
            MenuItem::action("Move Tab Right", MoveTabRight),
            MenuItem::action("Move Tab Left", MoveTabLeft),
            MenuItem::action("Tab Color…", ShowTabColorPicker),
            MenuItem::separator(),
            MenuItem::submenu(Menu {
                name: "Select Tab".into(),
                items: select,
                disabled: false,
            }),
            MenuItem::separator(),
            MenuItem::action("Broadcast Input to All Tabs", ToggleBroadcast),
            MenuItem::action("Load Demo Tabs (debug)", SeedDebugTabs),
            MenuItem::action("Feature Profiler (debug)", ShowFeatureProfiler),
            // macOS adds the window list after this item (GPUI makes this
            // menu the app's `windowsMenu`).
            MenuItem::separator(),
            MenuItem::action("Bring All to Front", BringAllToFront),
        ],
        disabled: false,
    }
}

fn help_menu() -> Menu {
    Menu {
        name: "Help".into(),
        items: vec![
            MenuItem::action("Welcome to Chau7 Next", ShowWelcome),
            MenuItem::separator(),
            MenuItem::action("Chau7 Next Help", ShowHelp),
            MenuItem::action(
                "Technology, Licenses & Acknowledgments",
                ShowTechnologyLicenses,
            ),
            MenuItem::action("Keyboard Shortcuts…", ShowKeyboardShortcuts),
            MenuItem::action("Report Issue", ReportIssue),
            MenuItem::separator(),
            MenuItem::action("Debug Console", ToggleDebugConsole),
        ],
        disabled: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(menu: &Menu) -> Vec<String> {
        menu.items
            .iter()
            .filter_map(|item| match item {
                MenuItem::Action { name, .. } => Some(name.to_string()),
                MenuItem::Submenu(m) => Some(m.name.to_string()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn menus_follow_the_swift_layout() {
        let menus = app_menus(&["zsh".into(), "claude".into()]);
        let titles: Vec<_> = menus.iter().map(|m| m.name.to_string()).collect();
        assert_eq!(
            titles,
            ["Chau7 Next", "File", "Edit", "View", "Window", "Help"]
        );
        let file = names(&menus[1]);
        for item in [
            "New Window",
            "New Tab",
            "SSH Connections…",
            "Close Tab",
            "Close Window",
            "Close Other Tabs",
            "Reopen Closed Tab",
            "Export Text…",
            "Print…",
        ] {
            assert!(file.iter().any(|n| n == item), "File lacks {item}");
        }
        let window = &menus[4];
        let select = window
            .items
            .iter()
            .find_map(|i| match i {
                MenuItem::Submenu(m) if m.name == "Select Tab" => Some(names(m)),
                _ => None,
            })
            .expect("Select Tab submenu");
        assert_eq!(select, ["zsh", "claude"]);
    }

    #[test]
    fn menus_are_translated_with_the_swift_keys() {
        use chau7_next_core::l10n::{Lang, table};
        let tabs = ["Terminal".to_string()];
        let fr = localize_menus(english_menus(&tabs), Lang::Fr);
        let edit = names(&fr[2]);
        assert!(edit.contains(&table(Lang::Fr)["action.copy"]), "{edit:?}");
        // Tab titles are not translated.
        let select = fr[4]
            .items
            .iter()
            .find_map(|i| match i {
                MenuItem::Submenu(m) if m.items.len() == 1 => Some(names(m)),
                _ => None,
            })
            .expect("Select Tab submenu");
        assert_eq!(select, ["Terminal"]);
        // English stays as it is.
        let en = localize_menus(english_menus(&tabs), Lang::En);
        assert_eq!(en[1].name, "File");
    }
}
