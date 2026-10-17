//! Current Swift settings sections, localized search metadata and navigation.
//! Source: SettingsSearch.swift and SettingsNavigationModel.swift.

use crate::l10n::{self, Lang};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SettingsSection {
    StartHere,
    General,
    ProfilesBackup,
    About,
    FontColors,
    Display,
    Windows,
    Tabs,
    HoverCard,
    Repositories,
    Shell,
    ScrollbackPerf,
    DangerousCommands,
    Graphics,
    KeyboardMouse,
    SnippetsTools,
    Editor,
    MinimalMode,
    AiDetection,
    TokenOptimization,
    McpControl,
    RemoteControl,
    SshProfiles,
    ApiProxy,
    PromptInjection,
    Notifications,
    History,
    LogsHistory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsGroup {
    General,
    Appearance,
    Terminal,
    AiWorkflows,
    Automation,
    SafetyPrivacy,
}

impl SettingsGroup {
    pub const ALL: [Self; 6] = [
        Self::General,
        Self::Appearance,
        Self::Terminal,
        Self::AiWorkflows,
        Self::Automation,
        Self::SafetyPrivacy,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Self::General => "GENERAL",
            Self::Appearance => "APPEARANCE",
            Self::Terminal => "TERMINAL",
            Self::AiWorkflows => "AI WORKFLOWS",
            Self::Automation => "AUTOMATION",
            Self::SafetyPrivacy => "SAFETY & PRIVACY",
        }
    }
    pub fn sections(self) -> &'static [SettingsSection] {
        match self {
            Self::General => &[
                SettingsSection::StartHere,
                SettingsSection::General,
                SettingsSection::ProfilesBackup,
                SettingsSection::About,
            ],
            Self::Appearance => &[
                SettingsSection::Windows,
                SettingsSection::Tabs,
                SettingsSection::HoverCard,
                SettingsSection::FontColors,
                SettingsSection::Display,
                SettingsSection::MinimalMode,
            ],
            Self::Terminal => &[
                SettingsSection::Shell,
                SettingsSection::ScrollbackPerf,
                SettingsSection::Graphics,
                SettingsSection::KeyboardMouse,
            ],
            Self::AiWorkflows => &[
                SettingsSection::AiDetection,
                SettingsSection::McpControl,
                SettingsSection::PromptInjection,
                SettingsSection::TokenOptimization,
            ],
            Self::Automation => &[
                SettingsSection::SnippetsTools,
                SettingsSection::Editor,
                SettingsSection::Repositories,
                SettingsSection::ApiProxy,
                SettingsSection::RemoteControl,
                SettingsSection::SshProfiles,
            ],
            Self::SafetyPrivacy => &[
                SettingsSection::DangerousCommands,
                SettingsSection::Notifications,
                SettingsSection::History,
                SettingsSection::LogsHistory,
            ],
        }
    }
}

impl SettingsSection {
    pub const ALL: [Self; 28] = [
        Self::StartHere,
        Self::General,
        Self::ProfilesBackup,
        Self::About,
        Self::FontColors,
        Self::Display,
        Self::Windows,
        Self::Tabs,
        Self::HoverCard,
        Self::Repositories,
        Self::Shell,
        Self::ScrollbackPerf,
        Self::DangerousCommands,
        Self::Graphics,
        Self::KeyboardMouse,
        Self::SnippetsTools,
        Self::Editor,
        Self::MinimalMode,
        Self::AiDetection,
        Self::TokenOptimization,
        Self::McpControl,
        Self::RemoteControl,
        Self::SshProfiles,
        Self::ApiProxy,
        Self::PromptInjection,
        Self::Notifications,
        Self::History,
        Self::LogsHistory,
    ];
    pub fn id(self) -> &'static str {
        match self {
            Self::StartHere => "startHere",
            Self::General => "general",
            Self::ProfilesBackup => "profilesBackup",
            Self::About => "about",
            Self::FontColors => "fontColors",
            Self::Display => "display",
            Self::Windows => "windows",
            Self::Tabs => "tabs",
            Self::HoverCard => "hoverCard",
            Self::Repositories => "repositories",
            Self::Shell => "shell",
            Self::ScrollbackPerf => "scrollbackPerf",
            Self::DangerousCommands => "dangerousCommands",
            Self::Graphics => "graphics",
            Self::KeyboardMouse => "keyboardMouse",
            Self::SnippetsTools => "snippetsTools",
            Self::Editor => "editor",
            Self::MinimalMode => "minimalMode",
            Self::AiDetection => "aiDetection",
            Self::TokenOptimization => "tokenOptimization",
            Self::McpControl => "mcpControl",
            Self::RemoteControl => "remoteControl",
            Self::SshProfiles => "sshProfiles",
            Self::ApiProxy => "apiProxy",
            Self::PromptInjection => "promptInjection",
            Self::Notifications => "notifications",
            Self::History => "history",
            Self::LogsHistory => "logsHistory",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::StartHere => "Start Here",
            Self::General => "General",
            Self::ProfilesBackup => "Sync & Backup",
            Self::About => "About",
            Self::FontColors => "Font & Colors",
            Self::Display => "Display",
            Self::Windows => "Windows",
            Self::Tabs => "Tabs",
            Self::HoverCard => "Hover Card",
            Self::Repositories => "Repositories",
            Self::Shell => "Shell",
            Self::ScrollbackPerf => "Performance",
            Self::DangerousCommands => "Command Safety",
            Self::Graphics => "Graphics",
            Self::KeyboardMouse => "Keyboard & Mouse",
            Self::SnippetsTools => "Snippets & Tools",
            Self::Editor => "Text Editor",
            Self::MinimalMode => "Minimal Mode",
            Self::AiDetection => "AI Detection",
            Self::TokenOptimization => "Context Optimization",
            Self::McpControl => "Agent Control",
            Self::RemoteControl => "Remote Access",
            Self::SshProfiles => "SSH Profiles",
            Self::ApiProxy => "API Tracking",
            Self::PromptInjection => "AI Context",
            Self::Notifications => "Alerts",
            Self::History => "History",
            Self::LogsHistory => "Diagnostics",
        }
    }
    pub fn symbol(self) -> &'static str {
        match self {
            Self::StartHere => "checklist",
            Self::General => "gearshape",
            Self::ProfilesBackup => "arrow.triangle.2.circlepath",
            Self::About => "info.circle",
            Self::FontColors => "paintbrush",
            Self::Display => "eye",
            Self::Windows => "macwindow",
            Self::Tabs => "rectangle.stack",
            Self::HoverCard => "text.bubble",
            Self::Repositories => "folder.badge.gearshape",
            Self::Shell => "terminal",
            Self::ScrollbackPerf => "gauge.with.dots.needle.33percent",
            Self::DangerousCommands => "exclamationmark.triangle",
            Self::Graphics => "photo",
            Self::KeyboardMouse => "keyboard",
            Self::SnippetsTools => "bolt.fill",
            Self::Editor => "doc.text",
            Self::MinimalMode => "rectangle.compress.vertical",
            Self::AiDetection => "sparkles",
            Self::TokenOptimization => "bolt.horizontal.circle",
            Self::McpControl => "face.dashed",
            Self::RemoteControl => "antenna.radiowaves.left.and.right",
            Self::SshProfiles => "network",
            Self::ApiProxy => "network",
            Self::PromptInjection => "text.insert",
            Self::Notifications => "bell.badge",
            Self::History => "clock.arrow.circlepath",
            Self::LogsHistory => "doc.text.magnifyingglass",
        }
    }
    pub fn description(self) -> &'static str {
        match self {
            Self::StartHere => "Current setup, permissions, and service status",
            Self::General => "Startup, language, default directory, and advanced config files",
            Self::ProfilesBackup => "Profile auto-switch, iCloud sync, and settings backup",
            Self::About => "Version, support links, diagnostics, and acknowledgments",
            Self::FontColors => "Terminal font, color scheme, zoom, and ligatures",
            Self::Display => "Syntax highlighting, URLs, images, and output formatting",
            Self::Windows => "App theme, opacity, window behavior, and layout",
            Self::Tabs => "Tab behavior and appearance",
            Self::HoverCard => "Choose which sections appear in the tab hover card",
            Self::Repositories => "Manage repo descriptions, labels, and favorite files",
            Self::Shell => "Shell, cursor, and bell",
            Self::ScrollbackPerf => "Rendering, scrollback, and performance limits",
            Self::DangerousCommands => "Highlight and guard risky commands",
            Self::Graphics => "Sixel and Kitty graphics protocols",
            Self::KeyboardMouse => "Keyboard shortcuts and mouse behavior",
            Self::SnippetsTools => "Snippets, clipboard, bookmarks, and search",
            Self::Editor => "Built-in text editor font, indentation, and display",
            Self::MinimalMode => "Hide tab bar, title bar, and status elements",
            Self::AiDetection => "AI CLI detection, theming, and LLM provider",
            Self::TokenOptimization => "Context optimization mode, per-tab control, and prefix",
            Self::McpControl => "Agent tab creation, limits, and approval",
            Self::RemoteControl => "Remote app access, relay, pairing, and devices",
            Self::SshProfiles => "Import, sync, and export SSH connection profiles",
            Self::ApiProxy => "API call tracking and analytics",
            Self::PromptInjection => "Add repository context to AI requests",
            Self::Notifications => "Alert preferences and event filters",
            Self::History => "Command history and transcript retention",
            Self::LogsHistory => "Log monitors, diagnostic paths, and active sessions",
        }
    }
    pub fn group(self) -> SettingsGroup {
        match self {
            Self::StartHere | Self::General | Self::ProfilesBackup | Self::About => {
                SettingsGroup::General
            }
            Self::Windows
            | Self::Tabs
            | Self::HoverCard
            | Self::FontColors
            | Self::Display
            | Self::MinimalMode => SettingsGroup::Appearance,
            Self::Shell | Self::ScrollbackPerf | Self::Graphics | Self::KeyboardMouse => {
                SettingsGroup::Terminal
            }
            Self::AiDetection
            | Self::McpControl
            | Self::PromptInjection
            | Self::TokenOptimization => SettingsGroup::AiWorkflows,
            Self::SnippetsTools
            | Self::Editor
            | Self::Repositories
            | Self::ApiProxy
            | Self::RemoteControl
            | Self::SshProfiles => SettingsGroup::Automation,
            Self::DangerousCommands | Self::Notifications | Self::History | Self::LogsHistory => {
                SettingsGroup::SafetyPrivacy
            }
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SearchableSetting {
    pub id: &'static str,
    pub section: SettingsSection,
    pub title: &'static str,
    pub keywords: &'static str,
    pub description: &'static str,
    pub anchor_id: &'static str,
    title_key: &'static str,
    keywords_key: &'static str,
    description_key: &'static str,
}

impl SearchableSetting {
    pub fn localized_title(&self) -> String {
        l10n::l(self.title_key, self.title)
    }
    pub fn localized_description(&self) -> String {
        l10n::l(self.description_key, self.description)
    }
    pub fn matches(&self, query: &str) -> bool {
        self.matches_in(l10n::current(), query)
    }
    pub fn matches_in(&self, lang: Lang, query: &str) -> bool {
        let q = query.to_lowercase();
        l10n::localized(lang, self.title_key, self.title)
            .to_lowercase()
            .contains(&q)
            || l10n::localized(lang, self.description_key, self.description)
                .to_lowercase()
                .contains(&q)
            || l10n::localized(lang, self.keywords_key, self.keywords)
                .split(',')
                .map(str::trim)
                .any(|k| k.to_lowercase().contains(&q))
    }
}

pub const SEARCHABLE_SETTINGS: &[SearchableSetting] = &[
    SearchableSetting {
        id: "startHereStatus",
        section: SettingsSection::StartHere,
        title: "Start Here Status",
        keywords: "status,start here,overview,setup,health,permissions,profile,mcp,remote,logs",
        description: "Review launch, profile, permissions, Agent Control, remote access, alerts, and log paths",
        anchor_id: "startHereStatus",
        title_key: "settings.search.startHere.title",
        keywords_key: "settings.search.startHere.keywords",
        description_key: "settings.search.startHere.description",
    },
    SearchableSetting {
        id: "language",
        section: SettingsSection::General,
        title: "Language",
        keywords: "language,langue,français,english,i18n,localization,translation",
        description: "Application display language",
        anchor_id: "language",
        title_key: "settings.search.language.title",
        keywords_key: "settings.search.language.keywords",
        description_key: "settings.search.language.description",
    },
    SearchableSetting {
        id: "launch",
        section: SettingsSection::General,
        title: "Launch at Login",
        keywords: "startup,login,autostart,boot",
        description: "Automatically start Chau7 when you log in",
        anchor_id: "launch",
        title_key: "settings.search.launch.title",
        keywords_key: "settings.search.launch.keywords",
        description_key: "settings.search.launch.description",
    },
    SearchableSetting {
        id: "defaultDir",
        section: SettingsSection::General,
        title: "Default Directory",
        keywords: "path,folder,start,working",
        description: "Starting directory for new terminal tabs",
        anchor_id: "defaultDir",
        title_key: "settings.search.defaultDir.title",
        keywords_key: "settings.search.defaultDir.keywords",
        description_key: "settings.search.defaultDir.description",
    },
    SearchableSetting {
        id: "configFile",
        section: SettingsSection::General,
        title: "Config File",
        keywords: "toml,config,file,repo,global",
        description: "Load settings from TOML config files",
        anchor_id: "configFile",
        title_key: "settings.search.configFile.title",
        keywords_key: "settings.search.configFile.keywords",
        description_key: "settings.search.configFile.description",
    },
    SearchableSetting {
        id: "profileAutoSwitch",
        section: SettingsSection::ProfilesBackup,
        title: "Profile Auto-Switch",
        keywords: "auto,switch,rule,directory,git,ssh",
        description: "Automatically switch profiles based on rules",
        anchor_id: "profileAutoSwitch",
        title_key: "settings.search.profileAutoSwitch.title",
        keywords_key: "settings.search.profileAutoSwitch.keywords",
        description_key: "settings.search.profileAutoSwitch.description",
    },
    SearchableSetting {
        id: "icloud",
        section: SettingsSection::ProfilesBackup,
        title: "iCloud Sync",
        keywords: "cloud,sync,backup,restore",
        description: "Sync settings across Macs via iCloud",
        anchor_id: "icloud",
        title_key: "settings.search.icloud.title",
        keywords_key: "settings.search.icloud.keywords",
        description_key: "settings.search.icloud.description",
    },
    SearchableSetting {
        id: "export",
        section: SettingsSection::ProfilesBackup,
        title: "Export/Import Settings",
        keywords: "backup,restore,json,save,load",
        description: "Export or import settings as JSON",
        anchor_id: "export",
        title_key: "settings.search.export.title",
        keywords_key: "settings.search.export.keywords",
        description_key: "settings.search.export.description",
    },
    SearchableSetting {
        id: "resetSettings",
        section: SettingsSection::ProfilesBackup,
        title: "Reset All Settings to Defaults",
        keywords: "reset,defaults,recovery,restore,clear,settings",
        description: "Reset Chau7 settings after exporting a backup if needed",
        anchor_id: "resetSettings",
        title_key: "settings.general.reset.all",
        keywords_key: "settings.search.resetSettings.keywords",
        description_key: "settings.search.resetSettings.description",
    },
    SearchableSetting {
        id: "about",
        section: SettingsSection::About,
        title: "About Chau7",
        keywords: "about,version,license,logs,system,credits",
        description: "View app version, system information, links, and application logs",
        anchor_id: "about",
        title_key: "settings.search.about.title",
        keywords_key: "settings.search.about.keywords",
        description_key: "settings.search.about.description",
    },
    SearchableSetting {
        id: "aboutSupportInfo",
        section: SettingsSection::About,
        title: "Copy Support Info",
        keywords: "support,copy,issue,bug,report,github,help",
        description: "Copy build, system, and log details for support",
        anchor_id: "aboutSupportInfo",
        title_key: "settings.about.copySupportInfo",
        keywords_key: "settings.search.aboutSupportInfo.keywords",
        description_key: "settings.search.aboutSupportInfo.description",
    },
    SearchableSetting {
        id: "aboutDiagnostics",
        section: SettingsSection::About,
        title: "Diagnostics",
        keywords: "diagnostics,version,build,bundle,macos,architecture,log,debug",
        description: "Review build, system, and log details",
        anchor_id: "aboutDiagnostics",
        title_key: "settings.about.diagnostics",
        keywords_key: "settings.search.aboutDiagnostics.keywords",
        description_key: "settings.search.aboutDiagnostics.description",
    },
    SearchableSetting {
        id: "aboutAcknowledgments",
        section: SettingsSection::About,
        title: "Acknowledgments",
        keywords: "license,licenses,acknowledgments,credits,agpl,open source",
        description: "Open licenses, credits, and acknowledgments",
        anchor_id: "aboutAcknowledgments",
        title_key: "settings.about.acknowledgments",
        keywords_key: "settings.search.aboutAcknowledgments.keywords",
        description_key: "settings.search.aboutAcknowledgments.description",
    },
    SearchableSetting {
        id: "fontFamily",
        section: SettingsSection::FontColors,
        title: "Font Family",
        keywords: "typeface,menlo,monaco,monospace,text",
        description: "Choose the terminal font",
        anchor_id: "fontFamily",
        title_key: "settings.search.fontFamily.title",
        keywords_key: "settings.search.fontFamily.keywords",
        description_key: "settings.search.fontFamily.description",
    },
    SearchableSetting {
        id: "fontSize",
        section: SettingsSection::FontColors,
        title: "Font Size",
        keywords: "text,size,big,small,zoom",
        description: "Terminal font size in points",
        anchor_id: "fontSize",
        title_key: "settings.search.fontSize.title",
        keywords_key: "settings.search.fontSize.keywords",
        description_key: "settings.search.fontSize.description",
    },
    SearchableSetting {
        id: "defaultZoom",
        section: SettingsSection::FontColors,
        title: "Default Zoom",
        keywords: "scale,zoom,percent,size",
        description: "Default zoom percentage for new tabs",
        anchor_id: "defaultZoom",
        title_key: "settings.search.defaultZoom.title",
        keywords_key: "settings.search.defaultZoom.keywords",
        description_key: "settings.search.defaultZoom.description",
    },
    SearchableSetting {
        id: "colorScheme",
        section: SettingsSection::FontColors,
        title: "Color Scheme",
        keywords: "theme,colors,dracula,solarized,nord,dark,light",
        description: "Terminal color palette",
        anchor_id: "colorScheme",
        title_key: "settings.search.colorScheme.title",
        keywords_key: "settings.search.colorScheme.keywords",
        description_key: "settings.search.colorScheme.description",
    },
    SearchableSetting {
        id: "opacity",
        section: SettingsSection::Windows,
        title: "Window Opacity",
        keywords: "transparency,translucent,see-through,alpha",
        description: "Terminal window transparency",
        anchor_id: "opacity",
        title_key: "settings.search.opacity.title",
        keywords_key: "settings.search.opacity.keywords",
        description_key: "settings.search.opacity.description",
    },
    SearchableSetting {
        id: "appTheme",
        section: SettingsSection::Windows,
        title: "App Theme",
        keywords: "theme,system,light,dark,appearance",
        description: "Choose the Chau7 interface theme",
        anchor_id: "appTheme",
        title_key: "settings.search.appTheme.title",
        keywords_key: "settings.search.appTheme.keywords",
        description_key: "settings.search.appTheme.description",
    },
    SearchableSetting {
        id: "syntaxHighlight",
        section: SettingsSection::Display,
        title: "Syntax Highlighting",
        keywords: "code,colors,highlight",
        description: "Highlight code syntax in output",
        anchor_id: "syntaxHighlight",
        title_key: "settings.search.syntaxHighlight.title",
        keywords_key: "settings.search.syntaxHighlight.keywords",
        description_key: "settings.search.syntaxHighlight.description",
    },
    SearchableSetting {
        id: "clickableURLs",
        section: SettingsSection::Display,
        title: "Clickable URLs",
        keywords: "url,link,browser,open,click",
        description: "Make terminal URLs clickable",
        anchor_id: "clickableURLs",
        title_key: "settings.search.clickableURLs.title",
        keywords_key: "settings.search.clickableURLs.keywords",
        description_key: "settings.search.clickableURLs.description",
    },
    SearchableSetting {
        id: "inlineImages",
        section: SettingsSection::Display,
        title: "Inline Images",
        keywords: "image,imgcat,preview,inline",
        description: "Display inline terminal images",
        anchor_id: "inlineImages",
        title_key: "settings.search.inlineImages.title",
        keywords_key: "settings.search.inlineImages.keywords",
        description_key: "settings.search.inlineImages.description",
    },
    SearchableSetting {
        id: "prettyPrintJSON",
        section: SettingsSection::Display,
        title: "Pretty Print JSON",
        keywords: "json,format,pretty,indent",
        description: "Format JSON output for readability",
        anchor_id: "prettyPrintJSON",
        title_key: "settings.search.prettyPrintJSON.title",
        keywords_key: "settings.search.prettyPrintJSON.keywords",
        description_key: "settings.search.prettyPrintJSON.description",
    },
    SearchableSetting {
        id: "timestamps",
        section: SettingsSection::Display,
        title: "Line Timestamps",
        keywords: "time,date,clock",
        description: "Show timestamps for terminal lines",
        anchor_id: "timestamps",
        title_key: "settings.search.timestamps.title",
        keywords_key: "settings.search.timestamps.keywords",
        description_key: "settings.search.timestamps.description",
    },
    SearchableSetting {
        id: "menuBarOnlyMode",
        section: SettingsSection::Windows,
        title: "Menu Bar Only Mode",
        keywords: "menu bar,dock,accessory,hide app,launcher",
        description: "Run Chau7 from the menu bar without a Dock icon",
        anchor_id: "menuBarOnlyMode",
        title_key: "settings.search.menuBarOnlyMode.title",
        keywords_key: "settings.search.menuBarOnlyMode.keywords",
        description_key: "settings.search.menuBarOnlyMode.description",
    },
    SearchableSetting {
        id: "windowBlur",
        section: SettingsSection::Windows,
        title: "Window Blur",
        keywords: "blur,transparency,performance,memory,graphics,background",
        description: "Blur the desktop behind terminal windows",
        anchor_id: "windowBlur",
        title_key: "settings.search.windowBlur.title",
        keywords_key: "settings.search.windowBlur.keywords",
        description_key: "settings.search.windowBlur.description",
    },
    SearchableSetting {
        id: "windowFloating",
        section: SettingsSection::Windows,
        title: "Floating Window",
        keywords: "float,always on top,above,window",
        description: "Keep terminal windows above other apps",
        anchor_id: "windowFloating",
        title_key: "settings.search.windowFloating.title",
        keywords_key: "settings.search.windowFloating.keywords",
        description_key: "settings.search.windowFloating.description",
    },
    SearchableSetting {
        id: "overlayWindow",
        section: SettingsSection::Windows,
        title: "Overlay Window",
        keywords: "overlay,show,position,workspace,reset",
        description: "Show or reset the remembered overlay window position",
        anchor_id: "overlayWindow",
        title_key: "settings.search.overlayWindow.title",
        keywords_key: "settings.search.overlayWindow.keywords",
        description_key: "settings.search.overlayWindow.description",
    },
    SearchableSetting {
        id: "fullscreenToolbar",
        section: SettingsSection::Windows,
        title: "Fullscreen Toolbar",
        keywords: "fullscreen,toolbar,titlebar,window",
        description: "Keep the toolbar visible in fullscreen",
        anchor_id: "fullscreenToolbar",
        title_key: "settings.search.fullscreenToolbar.title",
        keywords_key: "settings.search.fullscreenToolbar.keywords",
        description_key: "settings.search.fullscreenToolbar.description",
    },
    SearchableSetting {
        id: "splitPanes",
        section: SettingsSection::Windows,
        title: "Split Panes",
        keywords: "split,divide,pane,horizontal,vertical",
        description: "Split terminal into panes",
        anchor_id: "splitPanes",
        title_key: "settings.search.splitPanes.title",
        keywords_key: "settings.search.splitPanes.keywords",
        description_key: "settings.search.splitPanes.description",
    },
    SearchableSetting {
        id: "newTabPosition",
        section: SettingsSection::Tabs,
        title: "New Tab Position",
        keywords: "new,tab,position,after,current,end",
        description: "Choose where new tabs are inserted",
        anchor_id: "newTabPosition",
        title_key: "settings.search.newTabPosition.title",
        keywords_key: "settings.search.newTabPosition.keywords",
        description_key: "settings.search.newTabPosition.description",
    },
    SearchableSetting {
        id: "lastTabClose",
        section: SettingsSection::Tabs,
        title: "Last Tab Close",
        keywords: "close,window,behavior,final",
        description: "What happens when closing the last tab",
        anchor_id: "lastTabClose",
        title_key: "settings.search.lastTabClose.title",
        keywords_key: "settings.search.lastTabClose.keywords",
        description_key: "settings.search.lastTabClose.description",
    },
    SearchableSetting {
        id: "tabCloseWarnings",
        section: SettingsSection::Tabs,
        title: "Tab Close Warnings",
        keywords: "warn,warning,close,running process,confirm",
        description: "Confirm before closing tabs or running processes",
        anchor_id: "tabCloseWarnings",
        title_key: "settings.search.tabCloseWarnings.title",
        keywords_key: "settings.search.tabCloseWarnings.keywords",
        description_key: "settings.search.tabCloseWarnings.description",
    },
    SearchableSetting {
        id: "newTabDirectory",
        section: SettingsSection::Tabs,
        title: "New Tab Directory",
        keywords: "current,working,directory,folder,inherit",
        description: "Open new tabs in the active tab's directory",
        anchor_id: "newTabDirectory",
        title_key: "settings.search.newTabDirectory.title",
        keywords_key: "settings.search.newTabDirectory.keywords",
        description_key: "settings.search.newTabDirectory.description",
    },
    SearchableSetting {
        id: "tabDisplay",
        section: SettingsSection::Tabs,
        title: "Tab Display",
        keywords: "tab,icons,path,git,cto,broadcast,custom title,indicator",
        description: "Choose which tab indicators are visible",
        anchor_id: "tabDisplay",
        title_key: "settings.search.tabDisplay.title",
        keywords_key: "settings.search.tabDisplay.keywords",
        description_key: "settings.search.tabDisplay.description",
    },
    SearchableSetting {
        id: "repoGrouping",
        section: SettingsSection::Tabs,
        title: "Repo Grouping",
        keywords: "repo,repository,group,git,tabs",
        description: "Group tabs by repository",
        anchor_id: "repoGrouping",
        title_key: "settings.search.repoGrouping.title",
        keywords_key: "settings.search.repoGrouping.keywords",
        description_key: "settings.search.repoGrouping.description",
    },
    SearchableSetting {
        id: "tabSwitchShortcut",
        section: SettingsSection::Tabs,
        title: "Switch-to-Tab Keys",
        keywords: "switch,tab,command number,function key,f1,f12,shortcut",
        description: "Choose keyboard shortcuts for jumping to tabs",
        anchor_id: "tabSwitchShortcut",
        title_key: "settings.search.tabSwitchShortcut.title",
        keywords_key: "settings.search.tabSwitchShortcut.keywords",
        description_key: "settings.search.tabSwitchShortcut.description",
    },
    SearchableSetting {
        id: "numberedShortcutsVisibleOnly",
        section: SettingsSection::Tabs,
        title: "Numbered Shortcuts Target Visible Tabs Only",
        keywords: "number,numbered,shortcut,cmd,command,visible,idle,repo,repository,collapsed",
        description: "Count only tabs shown in the tab bar when selecting a tab by number.",
        anchor_id: "numberedShortcutsVisibleOnly",
        title_key: "settings.tabs.numberedShortcutsVisibleOnly",
        keywords_key: "settings.search.numberedShortcutsVisibleOnly.keywords",
        description_key: "settings.tabs.numberedShortcutsVisibleOnly.help",
    },
    SearchableSetting {
        id: "shell",
        section: SettingsSection::Shell,
        title: "Shell",
        keywords: "zsh,bash,fish,terminal,command",
        description: "Choose which shell to use",
        anchor_id: "shell",
        title_key: "settings.search.shell.title",
        keywords_key: "settings.search.shell.keywords",
        description_key: "settings.search.shell.description",
    },
    SearchableSetting {
        id: "startupCommand",
        section: SettingsSection::Shell,
        title: "Startup Command",
        keywords: "init,run,execute,neofetch",
        description: "Command to run when terminal starts",
        anchor_id: "startupCommand",
        title_key: "settings.search.startupCommand.title",
        keywords_key: "settings.search.startupCommand.keywords",
        description_key: "settings.search.startupCommand.description",
    },
    SearchableSetting {
        id: "lsColors",
        section: SettingsSection::Shell,
        title: "ls Colors",
        keywords: "ls,colors,colorize,LSCOLORS,CLICOLOR",
        description: "Enable colored ls output in new sessions",
        anchor_id: "lsColors",
        title_key: "settings.search.lsColors.title",
        keywords_key: "settings.search.lsColors.keywords",
        description_key: "settings.search.lsColors.description",
    },
    SearchableSetting {
        id: "cursor",
        section: SettingsSection::Shell,
        title: "Cursor Style",
        keywords: "block,underline,bar,caret",
        description: "Terminal cursor appearance",
        anchor_id: "cursor",
        title_key: "settings.search.cursor.title",
        keywords_key: "settings.search.cursor.keywords",
        description_key: "settings.search.cursor.description",
    },
    SearchableSetting {
        id: "cursorBlink",
        section: SettingsSection::Shell,
        title: "Cursor Blink",
        keywords: "animate,flash,blink",
        description: "Animate cursor with blinking",
        anchor_id: "cursorBlink",
        title_key: "settings.search.cursorBlink.title",
        keywords_key: "settings.search.cursorBlink.keywords",
        description_key: "settings.search.cursorBlink.description",
    },
    SearchableSetting {
        id: "bell",
        section: SettingsSection::Shell,
        title: "Bell",
        keywords: "sound,beep,alert,audio",
        description: "Terminal bell sound",
        anchor_id: "bell",
        title_key: "settings.search.bell.title",
        keywords_key: "settings.search.bell.keywords",
        description_key: "settings.search.bell.description",
    },
    SearchableSetting {
        id: "scrollback",
        section: SettingsSection::ScrollbackPerf,
        title: "Scrollback Lines",
        keywords: "history,buffer,lines,scroll",
        description: "Lines to keep in scrollback",
        anchor_id: "scrollback",
        title_key: "settings.search.scrollback.title",
        keywords_key: "settings.search.scrollback.keywords",
        description_key: "settings.search.scrollback.description",
    },
    SearchableSetting {
        id: "smartScroll",
        section: SettingsSection::ScrollbackPerf,
        title: "Smart Scroll",
        keywords: "smart,scroll,autoscroll,position,preserve",
        description: "Preserve scroll position while output continues",
        anchor_id: "smartScroll",
        title_key: "settings.search.smartScroll.title",
        keywords_key: "settings.search.smartScroll.keywords",
        description_key: "settings.search.smartScroll.description",
    },
    SearchableSetting {
        id: "restoredScrollback",
        section: SettingsSection::ScrollbackPerf,
        title: "Restored Scrollback",
        keywords: "restore,recover,scrollback,lines,tabs",
        description: "Limit how much scrollback is restored for recovered tabs",
        anchor_id: "restoredScrollback",
        title_key: "settings.search.restoredScrollback.title",
        keywords_key: "settings.search.restoredScrollback.keywords",
        description_key: "settings.search.restoredScrollback.description",
    },
    SearchableSetting {
        id: "refreshCaps",
        section: SettingsSection::ScrollbackPerf,
        title: "Refresh Caps",
        keywords: "refresh,fps,rate,cap,battery,performance",
        description: "Limit active and background terminal refresh rates",
        anchor_id: "refreshCaps",
        title_key: "settings.search.refreshCaps.title",
        keywords_key: "settings.search.refreshCaps.keywords",
        description_key: "settings.search.refreshCaps.description",
    },
    SearchableSetting {
        id: "dangerousCommands",
        section: SettingsSection::DangerousCommands,
        title: "Command Safety",
        keywords: "dangerous,risky,destructive,rm,force,highlight,safety",
        description: "Highlight risky commands in the terminal",
        anchor_id: "dangerousCommands",
        title_key: "settings.search.dangerousCommands.title",
        keywords_key: "settings.search.dangerousCommands.keywords",
        description_key: "settings.search.dangerousCommands.description",
    },
    SearchableSetting {
        id: "sixel",
        section: SettingsSection::Graphics,
        title: "Sixel Graphics",
        keywords: "sixel,image,graphics,protocol",
        description: "Sixel graphics protocol support",
        anchor_id: "sixel",
        title_key: "settings.search.sixel.title",
        keywords_key: "settings.search.sixel.keywords",
        description_key: "settings.search.sixel.description",
    },
    SearchableSetting {
        id: "kittyGraphics",
        section: SettingsSection::Graphics,
        title: "Kitty Graphics",
        keywords: "kitty,image,graphics,protocol",
        description: "Kitty graphics protocol support",
        anchor_id: "kittyGraphics",
        title_key: "settings.search.kittyGraphics.title",
        keywords_key: "settings.search.kittyGraphics.keywords",
        description_key: "settings.search.kittyGraphics.description",
    },
    SearchableSetting {
        id: "shortcuts",
        section: SettingsSection::KeyboardMouse,
        title: "Keyboard Shortcuts",
        keywords: "hotkey,keybinding,key,command",
        description: "Customize keyboard shortcuts",
        anchor_id: "shortcuts",
        title_key: "settings.search.shortcuts.title",
        keywords_key: "settings.search.shortcuts.keywords",
        description_key: "settings.search.shortcuts.description",
    },
    SearchableSetting {
        id: "shortcutHelperHint",
        section: SettingsSection::KeyboardMouse,
        title: "Shortcut Helper Hint",
        keywords: "hint,overlay,helper,shortcuts,corner",
        description: "Show the shortcut helper hint in the terminal",
        anchor_id: "shortcutHelperHint",
        title_key: "settings.search.shortcutHelperHint.title",
        keywords_key: "settings.search.shortcutHelperHint.keywords",
        description_key: "settings.search.shortcutHelperHint.description",
    },
    SearchableSetting {
        id: "copyOnSelect",
        section: SettingsSection::KeyboardMouse,
        title: "Copy on Select",
        keywords: "clipboard,copy,selection",
        description: "Copy text when selected",
        anchor_id: "copyOnSelect",
        title_key: "settings.search.copyOnSelect.title",
        keywords_key: "settings.search.copyOnSelect.keywords",
        description_key: "settings.search.copyOnSelect.description",
    },
    SearchableSetting {
        id: "cmdClick",
        section: SettingsSection::KeyboardMouse,
        title: "Cmd+Click Paths",
        keywords: "click,open,file,editor",
        description: "Open file paths with Cmd+click",
        anchor_id: "cmdClick",
        title_key: "settings.search.cmdClick.title",
        keywords_key: "settings.search.cmdClick.keywords",
        description_key: "settings.search.cmdClick.description",
    },
    SearchableSetting {
        id: "urlHandler",
        section: SettingsSection::KeyboardMouse,
        title: "URL Handler",
        keywords: "browser,url,links,open",
        description: "Choose which browser opens URLs",
        anchor_id: "urlHandler",
        title_key: "settings.search.urlHandler.title",
        keywords_key: "settings.search.urlHandler.keywords",
        description_key: "settings.search.urlHandler.description",
    },
    SearchableSetting {
        id: "broadcast",
        section: SettingsSection::KeyboardMouse,
        title: "Broadcast Input",
        keywords: "multi,tabs,send,input",
        description: "Send input to all tabs",
        anchor_id: "broadcast",
        title_key: "settings.search.broadcast.title",
        keywords_key: "settings.search.broadcast.keywords",
        description_key: "settings.search.broadcast.description",
    },
    SearchableSetting {
        id: "keybindingPreset",
        section: SettingsSection::KeyboardMouse,
        title: "Keybinding Preset",
        keywords: "preset,vim,emacs,default,keybinding,shortcut",
        description: "Choose a built-in keyboard shortcut preset",
        anchor_id: "keybindingPreset",
        title_key: "settings.search.keybindingPreset.title",
        keywords_key: "settings.search.keybindingPreset.keywords",
        description_key: "settings.search.keybindingPreset.description",
    },
    SearchableSetting {
        id: "snippets",
        section: SettingsSection::SnippetsTools,
        title: "Snippets",
        keywords: "template,shortcut,text,expansion",
        description: "Reusable text snippets",
        anchor_id: "snippets",
        title_key: "settings.search.snippets.title",
        keywords_key: "settings.search.snippets.keywords",
        description_key: "settings.search.snippets.description",
    },
    SearchableSetting {
        id: "clipboard",
        section: SettingsSection::SnippetsTools,
        title: "Clipboard History",
        keywords: "copy,paste,history",
        description: "Access previous clipboard items",
        anchor_id: "clipboard",
        title_key: "settings.search.clipboard.title",
        keywords_key: "settings.search.clipboard.keywords",
        description_key: "settings.search.clipboard.description",
    },
    SearchableSetting {
        id: "bookmarks",
        section: SettingsSection::SnippetsTools,
        title: "Bookmarks",
        keywords: "save,position,mark",
        description: "Save terminal positions",
        anchor_id: "bookmarks",
        title_key: "settings.search.bookmarks.title",
        keywords_key: "settings.search.bookmarks.keywords",
        description_key: "settings.search.bookmarks.description",
    },
    SearchableSetting {
        id: "search",
        section: SettingsSection::SnippetsTools,
        title: "Semantic Search",
        keywords: "find,search,command",
        description: "Command-aware search",
        anchor_id: "search",
        title_key: "settings.search.search.title",
        keywords_key: "settings.search.search.keywords",
        description_key: "settings.search.search.description",
    },
    SearchableSetting {
        id: "findDefaults",
        section: SettingsSection::SnippetsTools,
        title: "Find Defaults",
        keywords: "find,case,regex,default",
        description: "Default settings for the find bar",
        anchor_id: "findDefaults",
        title_key: "settings.search.findDefaults.title",
        keywords_key: "settings.search.findDefaults.keywords",
        description_key: "settings.search.findDefaults.description",
    },
    SearchableSetting {
        id: "aiDetection",
        section: SettingsSection::AiDetection,
        title: "AI CLI Detection",
        keywords: "claude,codex,gemini,copilot,detect",
        description: "Detect AI CLIs automatically",
        anchor_id: "aiDetection",
        title_key: "settings.search.aiDetection.title",
        keywords_key: "settings.search.aiDetection.keywords",
        description_key: "settings.search.aiDetection.description",
    },
    SearchableSetting {
        id: "aiCustomDetection",
        section: SettingsSection::AiDetection,
        title: "Custom AI Detection",
        keywords: "custom,pattern,rules,detect",
        description: "Add custom AI CLI detection rules",
        anchor_id: "aiCustomDetection",
        title_key: "settings.search.aiCustomDetection.title",
        keywords_key: "settings.search.aiCustomDetection.keywords",
        description_key: "settings.search.aiCustomDetection.description",
    },
    SearchableSetting {
        id: "autoTabTheme",
        section: SettingsSection::AiDetection,
        title: "Auto Tab Themes",
        keywords: "color,tab,ai,theme",
        description: "Color tabs by AI model",
        anchor_id: "autoTabTheme",
        title_key: "settings.search.autoTabTheme.title",
        keywords_key: "settings.search.autoTabTheme.keywords",
        description_key: "settings.search.autoTabTheme.description",
    },
    SearchableSetting {
        id: "llmProvider",
        section: SettingsSection::AiDetection,
        title: "LLM Provider",
        keywords: "openai,anthropic,api,key,llm,byoai",
        description: "Configure LLM provider and API keys",
        anchor_id: "llmProvider",
        title_key: "settings.search.llmProvider.title",
        keywords_key: "settings.search.llmProvider.keywords",
        description_key: "settings.search.llmProvider.description",
    },
    SearchableSetting {
        id: "errorExplanation",
        section: SettingsSection::AiDetection,
        title: "Error Explanation",
        keywords: "error,explain,llm,ai,diagnose",
        description: "Use an LLM to explain terminal errors",
        anchor_id: "errorExplanation",
        title_key: "settings.search.errorExplanation.title",
        keywords_key: "settings.search.errorExplanation.keywords",
        description_key: "settings.search.errorExplanation.description",
    },
    SearchableSetting {
        id: "ctoMode",
        section: SettingsSection::TokenOptimization,
        title: "Context Mode",
        keywords: "cto,token,optimization,mode,wrapper,all,ai,manual",
        description: "Controls when context optimization is active",
        anchor_id: "ctoMode",
        title_key: "settings.search.ctoMode.title",
        keywords_key: "settings.search.ctoMode.keywords",
        description_key: "settings.search.ctoMode.description",
    },
    SearchableSetting {
        id: "ctoPrefix",
        section: SettingsSection::TokenOptimization,
        title: "Context Prefix",
        keywords: "cto,prefix,prepend,tab,override,integration",
        description: "Prefix text prepended to terminal commands",
        anchor_id: "ctoPrefix",
        title_key: "settings.search.ctoPrefix.title",
        keywords_key: "settings.search.ctoPrefix.keywords",
        description_key: "settings.search.ctoPrefix.description",
    },
    SearchableSetting {
        id: "ctoPerTab",
        section: SettingsSection::TokenOptimization,
        title: "Per-Tab Context Optimization",
        keywords: "tab,override,force,enable,disable,bolt",
        description: "Override context optimization per tab",
        anchor_id: "ctoPerTab",
        title_key: "settings.search.ctoPerTab.title",
        keywords_key: "settings.search.ctoPerTab.keywords",
        description_key: "settings.search.ctoPerTab.description",
    },
    SearchableSetting {
        id: "mcpServer",
        section: SettingsSection::McpControl,
        title: "Agent Server",
        keywords: "mcp,server,remote,agent,tabs,automation",
        description: "Enable agent control and tab creation",
        anchor_id: "mcpServer",
        title_key: "settings.search.mcpServer.title",
        keywords_key: "settings.search.mcpServer.keywords",
        description_key: "settings.search.mcpServer.description",
    },
    SearchableSetting {
        id: "mcpPermissions",
        section: SettingsSection::McpControl,
        title: "Agent Permissions",
        keywords: "permission,approval,allow,block,command,profile",
        description: "Configure agent command approval and allow/block lists",
        anchor_id: "mcpPermissions",
        title_key: "settings.search.mcpPermissions.title",
        keywords_key: "settings.search.mcpPermissions.keywords",
        description_key: "settings.search.mcpPermissions.description",
    },
    SearchableSetting {
        id: "mcpProfiles",
        section: SettingsSection::McpControl,
        title: "Agent Profiles",
        keywords: "profile,project,permissions,mcp",
        description: "Manage agent permission profiles",
        anchor_id: "mcpProfiles",
        title_key: "settings.search.mcpProfiles.title",
        keywords_key: "settings.search.mcpProfiles.keywords",
        description_key: "settings.search.mcpProfiles.description",
    },
    SearchableSetting {
        id: "remote",
        section: SettingsSection::RemoteControl,
        title: "Remote Access",
        keywords: "remote,ios,relay,pairing,qr",
        description: "Pair an iPhone and view terminal output remotely",
        anchor_id: "remote",
        title_key: "settings.search.remote.title",
        keywords_key: "settings.search.remote.keywords",
        description_key: "settings.search.remote.description",
    },
    SearchableSetting {
        id: "sshProfiles",
        section: SettingsSection::SshProfiles,
        title: "SSH Profiles",
        keywords: "ssh,config,host,profile,connection",
        description: "Manage SSH config entries and connections",
        anchor_id: "sshProfiles",
        title_key: "settings.search.sshProfiles.title",
        keywords_key: "settings.search.sshProfiles.keywords",
        description_key: "settings.search.sshProfiles.description",
    },
    SearchableSetting {
        id: "apiAnalytics",
        section: SettingsSection::ApiProxy,
        title: "API Tracking",
        keywords: "api,proxy,analytics,cost,token,tracking",
        description: "Track API calls and token usage",
        anchor_id: "apiAnalytics",
        title_key: "settings.search.apiAnalytics.title",
        keywords_key: "settings.search.apiAnalytics.keywords",
        description_key: "settings.search.apiAnalytics.description",
    },
    SearchableSetting {
        id: "promptInjection",
        section: SettingsSection::PromptInjection,
        title: "AI Context",
        keywords: "inject,prompt,context,prefix,prepend,append,system,repository,repo,rules",
        description: "Add custom context to AI requests per repository",
        anchor_id: "promptInjection",
        title_key: "settings.search.promptInjection.title",
        keywords_key: "settings.search.promptInjection.keywords",
        description_key: "settings.search.promptInjection.description",
    },
    SearchableSetting {
        id: "notificationStatus",
        section: SettingsSection::Notifications,
        title: "Alert Status",
        keywords: "permission,alert,system,status",
        description: "System alert permission status",
        anchor_id: "notificationStatus",
        title_key: "settings.search.notificationStatus.title",
        keywords_key: "settings.search.notificationStatus.keywords",
        description_key: "settings.search.notificationStatus.description",
    },
    SearchableSetting {
        id: "notificationTriggers",
        section: SettingsSection::Notifications,
        title: "Notification Triggers",
        keywords: "filter,event,type,toggle,task,complete,failed,trigger,enable,disable",
        description: "Enable triggers and configure alert actions",
        anchor_id: "notificationTriggers",
        title_key: "settings.search.notificationTriggers.title",
        keywords_key: "settings.search.notificationTriggers.keywords",
        description_key: "settings.search.notificationTriggers.description",
    },
    SearchableSetting {
        id: "triggerActions",
        section: SettingsSection::Notifications,
        title: "Trigger Actions",
        keywords: "action,webhook,slack,discord,script,sound,docker,notification,play,run",
        description: "Configure what happens when alert triggers fire",
        anchor_id: "notificationTriggers",
        title_key: "settings.search.triggerActions.title",
        keywords_key: "settings.search.triggerActions.keywords",
        description_key: "settings.search.triggerActions.description",
    },
    SearchableSetting {
        id: "shellThresholds",
        section: SettingsSection::Notifications,
        title: "Shell Event Thresholds",
        keywords: "long running,directory,git branch,threshold,seconds,shell",
        description: "Configure shell event detection thresholds",
        anchor_id: "shellThresholds",
        title_key: "settings.search.shellThresholds.title",
        keywords_key: "settings.search.shellThresholds.keywords",
        description_key: "settings.search.shellThresholds.description",
    },
    SearchableSetting {
        id: "appThresholds",
        section: SettingsSection::Notifications,
        title: "App Event Thresholds",
        keywords: "inactivity,memory,tab open,tab close,threshold,minutes",
        description: "Configure app event detection thresholds",
        anchor_id: "appThresholds",
        title_key: "settings.search.appThresholds.title",
        keywords_key: "settings.search.appThresholds.keywords",
        description_key: "settings.search.appThresholds.description",
    },
    SearchableSetting {
        id: "aiToolNotifications",
        section: SettingsSection::Notifications,
        title: "AI Tool Notifications",
        keywords: "claude,codex,cursor,windsurf,copilot,aider,cline,continue,ai",
        description: "Alerts from AI coding tools",
        anchor_id: "aiToolNotifications",
        title_key: "settings.search.aiToolNotifications.title",
        keywords_key: "settings.search.aiToolNotifications.keywords",
        description_key: "settings.search.aiToolNotifications.description",
    },
    SearchableSetting {
        id: "eventMonitoring",
        section: SettingsSection::Notifications,
        title: "Event Monitoring",
        keywords: "monitor,watch,ai,events,log,tailer,restart",
        description: "Monitor AI CLI events for alerts",
        anchor_id: "eventMonitoring",
        title_key: "settings.search.eventMonitoring.title",
        keywords_key: "settings.search.eventMonitoring.keywords",
        description_key: "settings.search.eventMonitoring.description",
    },
    SearchableSetting {
        id: "persistentHistory",
        section: SettingsSection::History,
        title: "Persistent History",
        keywords: "history,database,commands,persistent,storage",
        description: "Save command history across sessions",
        anchor_id: "persistentHistory",
        title_key: "settings.search.persistentHistory.title",
        keywords_key: "settings.search.persistentHistory.keywords",
        description_key: "settings.search.persistentHistory.description",
    },
    SearchableSetting {
        id: "telemetryRetention",
        section: SettingsSection::History,
        title: "Telemetry Retention",
        keywords: "telemetry,transcripts,history,retention,days,storage",
        description: "Control how long AI transcripts are kept",
        anchor_id: "telemetryRetention",
        title_key: "settings.search.telemetryRetention.title",
        keywords_key: "settings.search.telemetryRetention.keywords",
        description_key: "settings.search.telemetryRetention.description",
    },
    SearchableSetting {
        id: "historyLogs",
        section: SettingsSection::LogsHistory,
        title: "History Logs",
        keywords: "codex,claude,history,path,idle,stale,monitor",
        description: "Configure AI history log monitoring",
        anchor_id: "historyLogs",
        title_key: "settings.search.historyLogs.title",
        keywords_key: "settings.search.historyLogs.keywords",
        description_key: "settings.search.historyLogs.description",
    },
    SearchableSetting {
        id: "terminalLogs",
        section: SettingsSection::LogsHistory,
        title: "Terminal Logs",
        keywords: "terminal,log,path,ansi,normalize,prefill,monitor",
        description: "Configure PTY terminal log monitoring",
        anchor_id: "terminalLogs",
        title_key: "settings.search.terminalLogs.title",
        keywords_key: "settings.search.terminalLogs.keywords",
        description_key: "settings.search.terminalLogs.description",
    },
    SearchableSetting {
        id: "debugConsole",
        section: SettingsSection::LogsHistory,
        title: "Diagnostics",
        keywords: "debug,console,diagnostics,logs,troubleshooting,state,events,runtime,usage,cost,quota",
        description: "Open Chau7 diagnostics, runtime inspection, and usage monitor surfaces",
        anchor_id: "debugConsole",
        title_key: "debug.surface.diagnostics.title",
        keywords_key: "settings.search.debugConsole.keywords",
        description_key: "settings.search.debugConsole.description",
    },
    SearchableSetting {
        id: "ligatures",
        section: SettingsSection::FontColors,
        title: "Font Ligatures",
        keywords: "ligature,fira code,jetbrains,cascadia,coding font",
        description: "Multi-character ligature rendering for coding fonts",
        anchor_id: "ligatures",
        title_key: "settings.search.ligatures.title",
        keywords_key: "settings.search.ligatures.keywords",
        description_key: "settings.search.ligatures.description",
    },
    SearchableSetting {
        id: "suspendRendering",
        section: SettingsSection::ScrollbackPerf,
        title: "Suspend Background Rendering",
        keywords: "suspend,background,render,gpu,cpu,performance",
        description: "Pause rendering for inactive tabs",
        anchor_id: "suspendRendering",
        title_key: "settings.search.suspendRendering.title",
        keywords_key: "settings.search.suspendRendering.keywords",
        description_key: "settings.search.suspendRendering.description",
    },
    SearchableSetting {
        id: "metalRenderer",
        section: SettingsSection::ScrollbackPerf,
        title: "Metal Renderer",
        keywords: "metal,gpu,renderer,hardware,acceleration",
        description: "GPU-accelerated terminal rendering",
        anchor_id: "metalRenderer",
        title_key: "settings.search.metalRenderer.title",
        keywords_key: "settings.search.metalRenderer.keywords",
        description_key: "settings.search.metalRenderer.description",
    },
    SearchableSetting {
        id: "groupIdleTabs",
        section: SettingsSection::Tabs,
        title: "Group Idle Tabs",
        keywords: "idle,tabs,group,dropdown,declutter,threshold,minutes",
        description: "Collect idle tabs in a dropdown chip (configurable threshold)",
        anchor_id: "groupIdleTabs",
        title_key: "settings.search.groupIdleTabs.title",
        keywords_key: "settings.search.groupIdleTabs.keywords",
        description_key: "settings.search.groupIdleTabs.description",
    },
    SearchableSetting {
        id: "hoverCardSections",
        section: SettingsSection::HoverCard,
        title: "Hover Card Sections",
        keywords: "hover,card,preview,sections,directory,git,processes,notifications",
        description: "Choose which information appears in tab hover cards",
        anchor_id: "hoverCardSections",
        title_key: "settings.search.hoverCardSections.title",
        keywords_key: "settings.search.hoverCardSections.keywords",
        description_key: "settings.search.hoverCardSections.description",
    },
    SearchableSetting {
        id: "repositoryMetadata",
        section: SettingsSection::Repositories,
        title: "Repository Metadata",
        keywords: "repository,repo,metadata,description,labels,favorite files",
        description: "Manage repository descriptions, labels, and favorite files",
        anchor_id: "repositoryMetadata",
        title_key: "settings.search.repositoryMetadata.title",
        keywords_key: "settings.search.repositoryMetadata.keywords",
        description_key: "settings.search.repositoryMetadata.description",
    },
    SearchableSetting {
        id: "clickToPosition",
        section: SettingsSection::KeyboardMouse,
        title: "Click to Position Cursor",
        keywords: "click,cursor,position,input",
        description: "Click on input line to move cursor",
        anchor_id: "clickToPosition",
        title_key: "settings.search.clickToPosition.title",
        keywords_key: "settings.search.clickToPosition.keywords",
        description_key: "settings.search.clickToPosition.description",
    },
    SearchableSetting {
        id: "mouseReporting",
        section: SettingsSection::KeyboardMouse,
        title: "Mouse Reporting",
        keywords: "mouse,reporting,vim,tmux,click",
        description: "Forward mouse events to terminal apps",
        anchor_id: "mouseReporting",
        title_key: "settings.search.mouseReporting.title",
        keywords_key: "settings.search.mouseReporting.keywords",
        description_key: "settings.search.mouseReporting.description",
    },
    SearchableSetting {
        id: "textEditor",
        section: SettingsSection::Editor,
        title: "Text Editor",
        keywords: "editor,text,font,indentation,line numbers,word wrap",
        description: "Built-in text editor settings",
        anchor_id: "textEditor",
        title_key: "settings.search.textEditor.title",
        keywords_key: "settings.search.textEditor.keywords",
        description_key: "settings.search.textEditor.description",
    },
    SearchableSetting {
        id: "minimalMode",
        section: SettingsSection::MinimalMode,
        title: "Minimal Mode",
        keywords: "minimal,hide,tab bar,title bar,distraction free",
        description: "Hide UI elements for distraction-free mode",
        anchor_id: "minimalMode",
        title_key: "settings.search.minimalMode.title",
        keywords_key: "settings.search.minimalMode.keywords",
        description_key: "settings.search.minimalMode.description",
    },
];

/// Entries of `section` that match `query`.
pub fn matching_settings(section: SettingsSection, query: &str) -> Vec<&'static SearchableSetting> {
    matching_settings_in(l10n::current(), section, query)
}

pub fn matching_settings_in(
    lang: Lang,
    section: SettingsSection,
    query: &str,
) -> Vec<&'static SearchableSetting> {
    if query.is_empty() {
        return Vec::new();
    }
    SEARCHABLE_SETTINGS
        .iter()
        .filter(|s| s.section == section && s.matches_in(lang, query))
        .collect()
}

/// Sections with at least one match, in declaration order, with the match
/// count (`sectionsMatching`).
pub fn sections_matching(query: &str) -> Vec<(SettingsSection, usize)> {
    sections_matching_in(l10n::current(), query)
}

pub fn sections_matching_in(lang: Lang, query: &str) -> Vec<(SettingsSection, usize)> {
    SettingsSection::ALL
        .iter()
        .filter_map(|&section| {
            let count = matching_settings_in(lang, section, query).len();
            (count > 0).then_some((section, count))
        })
        .collect()
}

/// Resolve the same normalized row/header title used by Swift settings anchors.
pub fn search_anchor_id(title: &str, section: Option<SettingsSection>) -> Option<&'static str> {
    fn normalized(s: &str) -> String {
        s.split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
    }
    let title = normalized(title);
    SEARCHABLE_SETTINGS
        .iter()
        .find(|setting| {
            section.is_none_or(|s| s == setting.section)
                && normalized(&setting.localized_title()) == title
        })
        .map(|setting| setting.anchor_id)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsNavigation {
    pub selection: SettingsSection,
    pub search_query: String,
    pub anchor_id: Option<String>,
}

impl Default for SettingsNavigation {
    fn default() -> Self {
        Self {
            selection: SettingsSection::StartHere,
            search_query: String::new(),
            anchor_id: None,
        }
    }
}

impl SettingsNavigation {
    pub fn normalized(anchor_id: Option<&str>) -> Option<String> {
        anchor_id
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    }
    pub fn section_containing_anchor(anchor_id: Option<&str>) -> Option<SettingsSection> {
        let id = Self::normalized(anchor_id)?;
        SEARCHABLE_SETTINGS
            .iter()
            .find(|setting| setting.anchor_id == id || setting.id == id)
            .map(|setting| setting.section)
    }
    pub fn show(&mut self, section: Option<SettingsSection>, anchor_id: Option<&str>) {
        self.anchor_id = Self::normalized(anchor_id);
        self.selection = section
            .or_else(|| Self::section_containing_anchor(self.anchor_id.as_deref()))
            .unwrap_or(SettingsSection::StartHere);
        self.search_query.clear();
    }
    pub fn update_search_query(
        &mut self,
        query: String,
        first_matching_section: Option<SettingsSection>,
    ) {
        self.search_query = query;
        if !self.search_query.is_empty()
            && let Some(section) = first_matching_section
        {
            self.selection = section;
        }
        self.anchor_id = None;
    }
    pub fn focus_search_result(&mut self, setting: &SearchableSetting) {
        self.selection = setting.section;
        self.anchor_id = Some(setting.anchor_id.to_owned());
    }
    pub fn clear_anchor(&mut self) {
        self.anchor_id = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_28_sections_in_6_groups_and_100_entries() {
        assert_eq!(SettingsSection::ALL.len(), 28);
        assert_eq!(SettingsGroup::ALL.len(), 6);
        let grouped: usize = SettingsGroup::ALL.iter().map(|g| g.sections().len()).sum();
        assert_eq!(grouped, 28);
        assert_eq!(SEARCHABLE_SETTINGS.len(), 100);
        for section in SettingsSection::ALL {
            assert!(section.group().sections().contains(&section));
        }
    }

    #[test]
    fn empty_query_matches_nothing() {
        assert!(sections_matching_in(Lang::En, "").is_empty());
    }

    #[test]
    fn matches_title_keywords_and_description() {
        let by_title = sections_matching_in(Lang::En, "language");
        assert!(by_title.iter().any(|(s, _)| *s == SettingsSection::General));
        // Keyword only: "autostart" is a keyword of Launch at Login.
        let by_keyword = sections_matching_in(Lang::En, "AUTOSTART");
        assert_eq!(by_keyword, vec![(SettingsSection::General, 1)]);
        // Description only.
        let by_desc = sections_matching_in(Lang::En, "Cursor appearance");
        assert_eq!(by_desc, vec![(SettingsSection::Shell, 1)]);
    }

    #[test]
    fn counts_are_per_section() {
        let counts = sections_matching_in(Lang::En, "icloud");
        assert!(
            counts
                .iter()
                .any(|(s, c)| *s == SettingsSection::ProfilesBackup && *c >= 1)
        );
    }
    #[test]
    fn context_rules_have_current_source_identity_and_search() {
        assert_eq!(SettingsSection::PromptInjection.id(), "promptInjection");
        assert_eq!(SettingsSection::PromptInjection.title(), "AI Context");
        assert!(
            SettingsGroup::AiWorkflows
                .sections()
                .contains(&SettingsSection::PromptInjection)
        );
        for query in ["inject", "append", "prepend"] {
            assert!(
                sections_matching_in(Lang::En, query)
                    .iter()
                    .any(|(section, _)| *section == SettingsSection::PromptInjection)
            );
        }
    }
    #[test]
    fn navigation_matches_current_swift_selection_and_anchor_rules() {
        let mut navigation = SettingsNavigation::default();
        assert_eq!(navigation.selection, SettingsSection::StartHere);
        navigation.show(None, Some("  triggerActions\n"));
        assert_eq!(navigation.selection, SettingsSection::Notifications);
        assert_eq!(navigation.anchor_id.as_deref(), Some("triggerActions"));
        navigation.show(Some(SettingsSection::General), Some("notificationTriggers"));
        assert_eq!(navigation.selection, SettingsSection::General);
        navigation.update_search_query("notifications".into(), Some(SettingsSection::StartHere));
        assert_eq!(navigation.selection, SettingsSection::StartHere);
        assert_eq!(navigation.anchor_id, None);
        let alias = SEARCHABLE_SETTINGS
            .iter()
            .find(|s| s.id == "triggerActions")
            .unwrap();
        navigation.focus_search_result(alias);
        assert_eq!(navigation.selection, SettingsSection::Notifications);
        assert_eq!(
            navigation.anchor_id.as_deref(),
            Some("notificationTriggers")
        );
        navigation.update_search_query("".into(), None);
        assert_eq!(navigation.selection, SettingsSection::Notifications);
        assert_eq!(navigation.anchor_id, None);
        navigation.update_search_query("no-such-setting".into(), None);
        assert_eq!(navigation.selection, SettingsSection::Notifications);
        navigation.show(None, Some(" "));
        assert_eq!(navigation.selection, SettingsSection::StartHere);
        assert_eq!(navigation.anchor_id, None);
        assert!(navigation.search_query.is_empty());
    }

    #[test]
    fn current_metadata_has_unique_ids_and_explicit_alias_anchor() {
        let ids: std::collections::HashSet<_> = SEARCHABLE_SETTINGS.iter().map(|s| s.id).collect();
        assert_eq!(ids.len(), SEARCHABLE_SETTINGS.len());
        for setting in SEARCHABLE_SETTINGS {
            assert!(SettingsSection::ALL.contains(&setting.section));
            assert!(!setting.anchor_id.is_empty());
        }
        assert_eq!(
            SettingsNavigation::section_containing_anchor(Some("sshProfiles")),
            Some(SettingsSection::SshProfiles)
        );
        assert_eq!(
            SettingsNavigation::section_containing_anchor(Some("telemetryRetention")),
            Some(SettingsSection::History)
        );
        assert_eq!(
            SettingsNavigation::section_containing_anchor(Some("triggerActions")),
            Some(SettingsSection::Notifications)
        );
    }

    #[test]
    fn search_uses_actual_localized_keywords_without_changing_global_language() {
        let language = SEARCHABLE_SETTINGS
            .iter()
            .find(|s| s.id == "language")
            .unwrap();
        assert!(language.matches_in(Lang::Fr, "langue"));
        assert!(language.matches_in(Lang::En, "LOCALIZATION"));
        assert!(!language.matches_in(Lang::Fr, "__no_such_setting__"));
    }
}
