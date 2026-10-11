//! Settings sections, groups and the settings search.
//!
//! Port of `Settings/SettingsSearch.swift`: the 23 sections of the settings
//! window in 6 groups, and the 66 searchable entries (title, keywords,
//! description) that filter the sidebar and give the per-section match
//! counts. English strings only; translations are the Localization module.
//!
//! Generated from the Swift source once, then maintained by hand: add an
//! entry here when a setting gets a control in the window.

/// A settings window section (`SettingsSection`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SettingsSection {
    General,
    ProfilesBackup,
    About,
    FontColors,
    Display,
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
    ApiProxy,
    Notifications,
    LogsHistory,
}

/// A group of sections in the sidebar (`SettingsSectionGroup`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsGroup {
    Essentials,
    LookAndFeel,
    Terminal,
    InputProductivity,
    Integrations,
    Monitoring,
}

impl SettingsGroup {
    pub const ALL: [SettingsGroup; 6] = [
        SettingsGroup::Essentials,
        SettingsGroup::LookAndFeel,
        SettingsGroup::Terminal,
        SettingsGroup::InputProductivity,
        SettingsGroup::Integrations,
        SettingsGroup::Monitoring,
    ];

    pub fn title(self) -> &'static str {
        match self {
            SettingsGroup::Essentials => "ESSENTIALS",
            SettingsGroup::LookAndFeel => "LOOK & FEEL",
            SettingsGroup::Terminal => "TERMINAL",
            SettingsGroup::InputProductivity => "INPUT & PRODUCTIVITY",
            SettingsGroup::Integrations => "INTEGRATIONS",
            SettingsGroup::Monitoring => "MONITORING",
        }
    }

    /// Sections of the group, in sidebar order.
    pub fn sections(self) -> &'static [SettingsSection] {
        match self {
            SettingsGroup::Essentials => &[
                SettingsSection::General,
                SettingsSection::ProfilesBackup,
                SettingsSection::About,
            ],
            SettingsGroup::LookAndFeel => &[
                SettingsSection::FontColors,
                SettingsSection::Display,
                SettingsSection::Tabs,
                SettingsSection::HoverCard,
                SettingsSection::Repositories,
                SettingsSection::MinimalMode,
            ],
            SettingsGroup::Terminal => &[
                SettingsSection::Shell,
                SettingsSection::ScrollbackPerf,
                SettingsSection::DangerousCommands,
                SettingsSection::Graphics,
            ],
            SettingsGroup::InputProductivity => &[
                SettingsSection::KeyboardMouse,
                SettingsSection::SnippetsTools,
                SettingsSection::Editor,
            ],
            SettingsGroup::Integrations => &[
                SettingsSection::AiDetection,
                SettingsSection::TokenOptimization,
                SettingsSection::McpControl,
                SettingsSection::RemoteControl,
                SettingsSection::ApiProxy,
            ],
            SettingsGroup::Monitoring => {
                &[SettingsSection::Notifications, SettingsSection::LogsHistory]
            }
        }
    }
}

impl SettingsSection {
    /// Every section in declaration order (`allCases`).
    pub const ALL: [SettingsSection; 23] = [
        SettingsSection::General,
        SettingsSection::ProfilesBackup,
        SettingsSection::About,
        SettingsSection::FontColors,
        SettingsSection::Display,
        SettingsSection::Tabs,
        SettingsSection::HoverCard,
        SettingsSection::Repositories,
        SettingsSection::Shell,
        SettingsSection::ScrollbackPerf,
        SettingsSection::DangerousCommands,
        SettingsSection::Graphics,
        SettingsSection::KeyboardMouse,
        SettingsSection::SnippetsTools,
        SettingsSection::Editor,
        SettingsSection::MinimalMode,
        SettingsSection::AiDetection,
        SettingsSection::TokenOptimization,
        SettingsSection::McpControl,
        SettingsSection::RemoteControl,
        SettingsSection::ApiProxy,
        SettingsSection::Notifications,
        SettingsSection::LogsHistory,
    ];

    /// Stable id (the Swift raw value).
    pub fn id(self) -> &'static str {
        match self {
            SettingsSection::General => "general",
            SettingsSection::ProfilesBackup => "profilesBackup",
            SettingsSection::About => "about",
            SettingsSection::FontColors => "fontColors",
            SettingsSection::Display => "display",
            SettingsSection::Tabs => "tabs",
            SettingsSection::HoverCard => "hoverCard",
            SettingsSection::Repositories => "repositories",
            SettingsSection::Shell => "shell",
            SettingsSection::ScrollbackPerf => "scrollbackPerf",
            SettingsSection::DangerousCommands => "dangerousCommands",
            SettingsSection::Graphics => "graphics",
            SettingsSection::KeyboardMouse => "keyboardMouse",
            SettingsSection::SnippetsTools => "snippetsTools",
            SettingsSection::Editor => "editor",
            SettingsSection::MinimalMode => "minimalMode",
            SettingsSection::AiDetection => "aiDetection",
            SettingsSection::TokenOptimization => "tokenOptimization",
            SettingsSection::McpControl => "mcpControl",
            SettingsSection::RemoteControl => "remoteControl",
            SettingsSection::ApiProxy => "apiProxy",
            SettingsSection::Notifications => "notifications",
            SettingsSection::LogsHistory => "logsHistory",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            SettingsSection::General => "General",
            SettingsSection::ProfilesBackup => "Sync & Backup",
            SettingsSection::About => "About",
            SettingsSection::FontColors => "Font & Colors",
            SettingsSection::Display => "Display",
            SettingsSection::Tabs => "Tabs",
            SettingsSection::HoverCard => "Hover Card",
            SettingsSection::Repositories => "Repositories",
            SettingsSection::Shell => "Shell",
            SettingsSection::ScrollbackPerf => "Scrollback & Performance",
            SettingsSection::DangerousCommands => "Dangerous Commands",
            SettingsSection::Graphics => "Graphics",
            SettingsSection::KeyboardMouse => "Keyboard & Mouse",
            SettingsSection::SnippetsTools => "Snippets & Tools",
            SettingsSection::Editor => "Text Editor",
            SettingsSection::MinimalMode => "Minimal Mode",
            SettingsSection::AiDetection => "AI Detection",
            SettingsSection::TokenOptimization => "Token Optimization (CTO)",
            SettingsSection::McpControl => "MCP Control",
            SettingsSection::RemoteControl => "Remote Control",
            SettingsSection::ApiProxy => "API Proxy",
            SettingsSection::Notifications => "Notifications",
            SettingsSection::LogsHistory => "Logs & History",
        }
    }

    /// SF Symbol name of the sidebar icon.
    pub fn symbol(self) -> &'static str {
        match self {
            SettingsSection::General => "gearshape",
            SettingsSection::ProfilesBackup => "arrow.triangle.2.circlepath",
            SettingsSection::About => "info.circle",
            SettingsSection::FontColors => "paintbrush",
            SettingsSection::Display => "eye",
            SettingsSection::Tabs => "rectangle.stack",
            SettingsSection::HoverCard => "text.bubble",
            SettingsSection::Repositories => "folder.badge.gearshape",
            SettingsSection::Shell => "terminal",
            SettingsSection::ScrollbackPerf => "gauge.with.dots.needle.33percent",
            SettingsSection::DangerousCommands => "exclamationmark.triangle",
            SettingsSection::Graphics => "photo",
            SettingsSection::KeyboardMouse => "keyboard",
            SettingsSection::SnippetsTools => "bolt.fill",
            SettingsSection::Editor => "doc.text",
            SettingsSection::MinimalMode => "rectangle.compress.vertical",
            SettingsSection::AiDetection => "sparkles",
            SettingsSection::TokenOptimization => "bolt.horizontal.circle",
            SettingsSection::McpControl => "face.dashed",
            SettingsSection::RemoteControl => "antenna.radiowaves.left.and.right",
            SettingsSection::ApiProxy => "network",
            SettingsSection::Notifications => "bell.badge",
            SettingsSection::LogsHistory => "doc.text.magnifyingglass",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            SettingsSection::General => "Startup, language, and config file",
            SettingsSection::ProfilesBackup => {
                "Profile auto-switch, iCloud sync, and settings backup"
            }
            SettingsSection::About => "Version information and links",
            SettingsSection::FontColors => "Font, color scheme, opacity, and ligatures",
            SettingsSection::Display => "Syntax highlighting, URLs, images, and window layout",
            SettingsSection::Tabs => "Tab behavior and appearance",
            SettingsSection::HoverCard => "Choose which sections appear in the tab hover card",
            SettingsSection::Repositories => "Manage repo descriptions, labels, and favorite files",
            SettingsSection::Shell => "Shell, cursor, and bell",
            SettingsSection::ScrollbackPerf => "Scrollback buffer, rendering, and backend",
            SettingsSection::DangerousCommands => "Highlight and guard risky commands",
            SettingsSection::Graphics => "Sixel and Kitty graphics protocols",
            SettingsSection::KeyboardMouse => "Keyboard shortcuts and mouse behavior",
            SettingsSection::SnippetsTools => "Snippets, clipboard, bookmarks, and search",
            SettingsSection::Editor => "Built-in text editor font, indentation, and display",
            SettingsSection::MinimalMode => "Hide tab bar, title bar, and status elements",
            SettingsSection::AiDetection => "AI CLI detection, theming, and LLM provider",
            SettingsSection::TokenOptimization => {
                "CTO wrapper scripts, per-tab control, and prefix"
            }
            SettingsSection::McpControl => "MCP agent tab creation, limits, and approval",
            SettingsSection::RemoteControl => "Remote access, pairing, and SSH profiles",
            SettingsSection::ApiProxy => "API call tracking and analytics proxy",
            SettingsSection::Notifications => "Alert preferences and event filters",
            SettingsSection::LogsHistory => "Log files, session tracking, and command history",
        }
    }

    pub fn group(self) -> SettingsGroup {
        match self {
            SettingsSection::General => SettingsGroup::Essentials,
            SettingsSection::ProfilesBackup => SettingsGroup::Essentials,
            SettingsSection::About => SettingsGroup::Essentials,
            SettingsSection::FontColors => SettingsGroup::LookAndFeel,
            SettingsSection::Display => SettingsGroup::LookAndFeel,
            SettingsSection::Tabs => SettingsGroup::LookAndFeel,
            SettingsSection::HoverCard => SettingsGroup::LookAndFeel,
            SettingsSection::Repositories => SettingsGroup::LookAndFeel,
            SettingsSection::Shell => SettingsGroup::Terminal,
            SettingsSection::ScrollbackPerf => SettingsGroup::Terminal,
            SettingsSection::DangerousCommands => SettingsGroup::Terminal,
            SettingsSection::Graphics => SettingsGroup::Terminal,
            SettingsSection::KeyboardMouse => SettingsGroup::InputProductivity,
            SettingsSection::SnippetsTools => SettingsGroup::InputProductivity,
            SettingsSection::Editor => SettingsGroup::InputProductivity,
            SettingsSection::MinimalMode => SettingsGroup::LookAndFeel,
            SettingsSection::AiDetection => SettingsGroup::Integrations,
            SettingsSection::TokenOptimization => SettingsGroup::Integrations,
            SettingsSection::McpControl => SettingsGroup::Integrations,
            SettingsSection::RemoteControl => SettingsGroup::Integrations,
            SettingsSection::ApiProxy => SettingsGroup::Integrations,
            SettingsSection::Notifications => SettingsGroup::Monitoring,
            SettingsSection::LogsHistory => SettingsGroup::Monitoring,
        }
    }
}

/// One searchable setting (`SearchableSetting`).
#[derive(Debug, Clone, Copy)]
pub struct SearchableSetting {
    pub id: &'static str,
    pub section: SettingsSection,
    pub title: &'static str,
    pub keywords: &'static str,
    pub description: &'static str,
}

impl SearchableSetting {
    /// Case-insensitive substring match on title, description and keywords.
    pub fn matches(&self, query: &str) -> bool {
        let q = query.to_lowercase();
        self.title.to_lowercase().contains(&q)
            || self.description.to_lowercase().contains(&q)
            || self
                .keywords
                .split(',')
                .map(str::trim)
                .any(|k| k.to_lowercase().contains(&q))
    }
}

/// The searchable settings (`FeatureSettings.searchableSettings`).
pub const SEARCHABLE_SETTINGS: &[SearchableSetting] = &[
    SearchableSetting {
        id: "language",
        section: SettingsSection::General,
        title: "Language",
        keywords: "language,langue,français,english,i18n,localization,translation",
        description: "Application display language",
    },
    SearchableSetting {
        id: "launch",
        section: SettingsSection::General,
        title: "Launch at Login",
        keywords: "startup,login,autostart,boot",
        description: "Automatically start Chau7 when you log in",
    },
    SearchableSetting {
        id: "defaultDir",
        section: SettingsSection::General,
        title: "Default Directory",
        keywords: "path,folder,start,working",
        description: "Starting directory for new terminal tabs",
    },
    SearchableSetting {
        id: "configFile",
        section: SettingsSection::General,
        title: "Config File",
        keywords: "toml,config,file,repo,global",
        description: "Load settings from TOML config files",
    },
    SearchableSetting {
        id: "profileAutoSwitch",
        section: SettingsSection::ProfilesBackup,
        title: "Profile Auto-Switch",
        keywords: "auto,switch,rule,directory,git,ssh",
        description: "Automatically switch profiles based on rules",
    },
    SearchableSetting {
        id: "icloud",
        section: SettingsSection::ProfilesBackup,
        title: "iCloud Sync",
        keywords: "cloud,sync,backup,restore",
        description: "Sync settings across Macs via iCloud",
    },
    SearchableSetting {
        id: "export",
        section: SettingsSection::ProfilesBackup,
        title: "Export/Import Settings",
        keywords: "backup,restore,json,save,load",
        description: "Export or import settings as JSON",
    },
    SearchableSetting {
        id: "fontFamily",
        section: SettingsSection::FontColors,
        title: "Font Family",
        keywords: "typeface,menlo,monaco,monospace,text",
        description: "Choose the terminal font",
    },
    SearchableSetting {
        id: "fontSize",
        section: SettingsSection::FontColors,
        title: "Font Size",
        keywords: "text,size,big,small,zoom",
        description: "Terminal font size in points",
    },
    SearchableSetting {
        id: "defaultZoom",
        section: SettingsSection::FontColors,
        title: "Default Zoom",
        keywords: "scale,zoom,percent,size",
        description: "Default zoom percentage for new tabs",
    },
    SearchableSetting {
        id: "colorScheme",
        section: SettingsSection::FontColors,
        title: "Color Scheme",
        keywords: "theme,colors,dracula,solarized,nord,dark,light",
        description: "Terminal color palette",
    },
    SearchableSetting {
        id: "opacity",
        section: SettingsSection::FontColors,
        title: "Window Opacity",
        keywords: "transparency,translucent,see-through,alpha",
        description: "Terminal window transparency",
    },
    SearchableSetting {
        id: "syntaxHighlight",
        section: SettingsSection::Display,
        title: "Syntax Highlighting",
        keywords: "code,colors,highlight",
        description: "Highlight code syntax in output",
    },
    SearchableSetting {
        id: "timestamps",
        section: SettingsSection::Display,
        title: "Line Timestamps",
        keywords: "time,date,clock",
        description: "Show timestamps for terminal lines",
    },
    SearchableSetting {
        id: "splitPanes",
        section: SettingsSection::Display,
        title: "Split Panes",
        keywords: "split,divide,pane,horizontal,vertical",
        description: "Split terminal into panes",
    },
    SearchableSetting {
        id: "lastTabClose",
        section: SettingsSection::Tabs,
        title: "Last Tab Close",
        keywords: "close,window,behavior,final",
        description: "What happens when closing the last tab",
    },
    SearchableSetting {
        id: "newTabDirectory",
        section: SettingsSection::Tabs,
        title: "New Tab Directory",
        keywords: "current,working,directory,folder,inherit",
        description: "Open new tabs in the active tab's directory",
    },
    SearchableSetting {
        id: "shell",
        section: SettingsSection::Shell,
        title: "Shell",
        keywords: "zsh,bash,fish,terminal,command",
        description: "Choose which shell to use",
    },
    SearchableSetting {
        id: "startupCommand",
        section: SettingsSection::Shell,
        title: "Startup Command",
        keywords: "init,run,execute,neofetch",
        description: "Command to run when terminal starts",
    },
    SearchableSetting {
        id: "lsColors",
        section: SettingsSection::Shell,
        title: "ls Colors",
        keywords: "ls,colors,colorize,LSCOLORS,CLICOLOR",
        description: "Enable colored ls output in new sessions",
    },
    SearchableSetting {
        id: "cursor",
        section: SettingsSection::Shell,
        title: "Cursor Style",
        keywords: "block,underline,bar,caret",
        description: "Terminal cursor appearance",
    },
    SearchableSetting {
        id: "cursorBlink",
        section: SettingsSection::Shell,
        title: "Cursor Blink",
        keywords: "animate,flash,blink",
        description: "Animate cursor with blinking",
    },
    SearchableSetting {
        id: "bell",
        section: SettingsSection::Shell,
        title: "Bell",
        keywords: "sound,beep,alert,audio",
        description: "Terminal bell sound",
    },
    SearchableSetting {
        id: "scrollback",
        section: SettingsSection::ScrollbackPerf,
        title: "Scrollback Lines",
        keywords: "history,buffer,lines,scroll",
        description: "Lines to keep in scrollback",
    },
    SearchableSetting {
        id: "localEcho",
        section: SettingsSection::ScrollbackPerf,
        title: "Local Echo",
        keywords: "echo,typing,latency,input",
        description: "Render typed characters immediately",
    },
    SearchableSetting {
        id: "terminalBackend",
        section: SettingsSection::ScrollbackPerf,
        title: "Terminal Backend",
        keywords: "rust,metal,gpu,renderer",
        description: "Choose terminal rendering backend",
    },
    SearchableSetting {
        id: "dangerousCommands",
        section: SettingsSection::DangerousCommands,
        title: "Dangerous Commands",
        keywords: "dangerous,risky,destructive,rm,force,highlight,safety",
        description: "Highlight risky commands in the terminal",
    },
    SearchableSetting {
        id: "sixel",
        section: SettingsSection::Graphics,
        title: "Sixel Graphics",
        keywords: "sixel,image,graphics,protocol",
        description: "Sixel graphics protocol support",
    },
    SearchableSetting {
        id: "kittyGraphics",
        section: SettingsSection::Graphics,
        title: "Kitty Graphics",
        keywords: "kitty,image,graphics,protocol",
        description: "Kitty graphics protocol support",
    },
    SearchableSetting {
        id: "shortcuts",
        section: SettingsSection::KeyboardMouse,
        title: "Keyboard Shortcuts",
        keywords: "hotkey,keybinding,key,command",
        description: "Customize keyboard shortcuts",
    },
    SearchableSetting {
        id: "shortcutHelperHint",
        section: SettingsSection::KeyboardMouse,
        title: "Shortcut Helper Hint",
        keywords: "hint,overlay,helper,shortcuts,corner",
        description: "Show the shortcut helper hint in the terminal",
    },
    SearchableSetting {
        id: "copyOnSelect",
        section: SettingsSection::KeyboardMouse,
        title: "Copy on Select",
        keywords: "clipboard,copy,selection",
        description: "Copy text when selected",
    },
    SearchableSetting {
        id: "cmdClick",
        section: SettingsSection::KeyboardMouse,
        title: "Cmd+Click Paths",
        keywords: "click,open,file,editor",
        description: "Open file paths with Cmd+click",
    },
    SearchableSetting {
        id: "urlHandler",
        section: SettingsSection::KeyboardMouse,
        title: "URL Handler",
        keywords: "browser,url,links,open",
        description: "Choose which browser opens URLs",
    },
    SearchableSetting {
        id: "broadcast",
        section: SettingsSection::KeyboardMouse,
        title: "Broadcast Input",
        keywords: "multi,tabs,send,input",
        description: "Send input to all tabs",
    },
    SearchableSetting {
        id: "snippets",
        section: SettingsSection::SnippetsTools,
        title: "Snippets",
        keywords: "template,shortcut,text,expansion",
        description: "Reusable text snippets",
    },
    SearchableSetting {
        id: "clipboard",
        section: SettingsSection::SnippetsTools,
        title: "Clipboard History",
        keywords: "copy,paste,history",
        description: "Access previous clipboard items",
    },
    SearchableSetting {
        id: "bookmarks",
        section: SettingsSection::SnippetsTools,
        title: "Bookmarks",
        keywords: "save,position,mark",
        description: "Save terminal positions",
    },
    SearchableSetting {
        id: "search",
        section: SettingsSection::SnippetsTools,
        title: "Semantic Search",
        keywords: "find,search,command",
        description: "Command-aware search",
    },
    SearchableSetting {
        id: "findDefaults",
        section: SettingsSection::SnippetsTools,
        title: "Find Defaults",
        keywords: "find,case,regex,default",
        description: "Default settings for the find bar",
    },
    SearchableSetting {
        id: "aiDetection",
        section: SettingsSection::AiDetection,
        title: "AI CLI Detection",
        keywords: "claude,codex,gemini,copilot,detect",
        description: "Detect AI CLIs automatically",
    },
    SearchableSetting {
        id: "aiCustomDetection",
        section: SettingsSection::AiDetection,
        title: "Custom AI Detection",
        keywords: "custom,pattern,rules,detect",
        description: "Add custom AI CLI detection rules",
    },
    SearchableSetting {
        id: "autoTabTheme",
        section: SettingsSection::AiDetection,
        title: "Auto Tab Themes",
        keywords: "color,tab,ai,theme",
        description: "Color tabs by AI model",
    },
    SearchableSetting {
        id: "llmProvider",
        section: SettingsSection::AiDetection,
        title: "LLM Provider",
        keywords: "openai,anthropic,api,key,llm,byoai",
        description: "Configure LLM provider and API keys",
    },
    SearchableSetting {
        id: "ctoMode",
        section: SettingsSection::TokenOptimization,
        title: "Optimization Mode",
        keywords: "cto,token,optimization,mode,wrapper,all,ai,manual",
        description: "Controls when token-optimized output is active",
    },
    SearchableSetting {
        id: "ctoPrefix",
        section: SettingsSection::TokenOptimization,
        title: "CTO Prefix",
        keywords: "cto,prefix,prepend,tab,override,integration",
        description: "Prefix text prepended to terminal commands",
    },
    SearchableSetting {
        id: "ctoPerTab",
        section: SettingsSection::TokenOptimization,
        title: "Per-Tab CTO",
        keywords: "tab,override,force,enable,disable,bolt",
        description: "Override CTO settings per tab",
    },
    SearchableSetting {
        id: "remote",
        section: SettingsSection::RemoteControl,
        title: "Remote Control",
        keywords: "remote,ios,relay,pairing,qr",
        description: "Pair an iPhone and view terminal output remotely",
    },
    SearchableSetting {
        id: "sshProfiles",
        section: SettingsSection::RemoteControl,
        title: "SSH Profiles",
        keywords: "ssh,config,host,profile,connection",
        description: "Manage SSH config entries and connections",
    },
    SearchableSetting {
        id: "apiAnalytics",
        section: SettingsSection::ApiProxy,
        title: "API Analytics",
        keywords: "api,proxy,analytics,cost,token,tracking",
        description: "Track API calls and token usage",
    },
    SearchableSetting {
        id: "notificationStatus",
        section: SettingsSection::Notifications,
        title: "Notification Status",
        keywords: "permission,alert,system,status",
        description: "Notification permission status",
    },
    SearchableSetting {
        id: "notificationTriggers",
        section: SettingsSection::Notifications,
        title: "Notification Triggers",
        keywords: "filter,event,type,toggle,task,complete,failed,trigger,enable,disable",
        description: "Enable triggers and configure actions for notifications",
    },
    SearchableSetting {
        id: "triggerActions",
        section: SettingsSection::Notifications,
        title: "Trigger Actions",
        keywords: "action,webhook,slack,discord,script,sound,docker,notification,play,run",
        description: "Configure what happens when notification triggers fire",
    },
    SearchableSetting {
        id: "shellThresholds",
        section: SettingsSection::Notifications,
        title: "Shell Event Thresholds",
        keywords: "long running,directory,git branch,threshold,seconds,shell",
        description: "Configure shell event detection thresholds",
    },
    SearchableSetting {
        id: "appThresholds",
        section: SettingsSection::Notifications,
        title: "App Event Thresholds",
        keywords: "inactivity,memory,tab open,tab close,threshold,minutes",
        description: "Configure app event detection thresholds",
    },
    SearchableSetting {
        id: "aiToolNotifications",
        section: SettingsSection::Notifications,
        title: "AI Tool Notifications",
        keywords: "claude,codex,cursor,windsurf,copilot,aider,cline,continue,ai",
        description: "Notifications from AI coding tools",
    },
    SearchableSetting {
        id: "eventMonitoring",
        section: SettingsSection::Notifications,
        title: "Event Monitoring",
        keywords: "monitor,watch,ai,events,log,tailer,restart",
        description: "Monitor AI CLI events for notifications",
    },
    SearchableSetting {
        id: "persistentHistory",
        section: SettingsSection::LogsHistory,
        title: "Persistent History",
        keywords: "history,database,commands,persistent,storage",
        description: "Save command history across sessions",
    },
    SearchableSetting {
        id: "ligatures",
        section: SettingsSection::FontColors,
        title: "Font Ligatures",
        keywords: "ligature,fira code,jetbrains,cascadia,coding font",
        description: "Multi-character ligature rendering for coding fonts",
    },
    SearchableSetting {
        id: "suspendRendering",
        section: SettingsSection::ScrollbackPerf,
        title: "Suspend Background Rendering",
        keywords: "suspend,background,render,gpu,cpu,performance",
        description: "Pause rendering for inactive tabs",
    },
    SearchableSetting {
        id: "metalRenderer",
        section: SettingsSection::ScrollbackPerf,
        title: "Metal Renderer",
        keywords: "metal,gpu,renderer,hardware,acceleration",
        description: "GPU-accelerated terminal rendering",
    },
    SearchableSetting {
        id: "groupIdleTabs",
        section: SettingsSection::Tabs,
        title: "Group Idle Tabs",
        keywords: "idle,tabs,group,dropdown,declutter,threshold,minutes",
        description: "Collect idle tabs in a dropdown chip (configurable threshold)",
    },
    SearchableSetting {
        id: "clickToPosition",
        section: SettingsSection::KeyboardMouse,
        title: "Click to Position Cursor",
        keywords: "click,cursor,position,input",
        description: "Click on input line to move cursor",
    },
    SearchableSetting {
        id: "mouseReporting",
        section: SettingsSection::KeyboardMouse,
        title: "Mouse Reporting",
        keywords: "mouse,reporting,vim,tmux,click",
        description: "Forward mouse events to terminal apps",
    },
    SearchableSetting {
        id: "textEditor",
        section: SettingsSection::Editor,
        title: "Text Editor",
        keywords: "editor,text,font,indentation,line numbers,word wrap",
        description: "Built-in text editor settings",
    },
    SearchableSetting {
        id: "minimalMode",
        section: SettingsSection::MinimalMode,
        title: "Minimal Mode",
        keywords: "minimal,hide,tab bar,title bar,distraction free",
        description: "Hide UI elements for distraction-free mode",
    },
];

/// Entries of `section` that match `query`.
pub fn matching_settings(section: SettingsSection, query: &str) -> Vec<&'static SearchableSetting> {
    if query.is_empty() {
        return Vec::new();
    }
    SEARCHABLE_SETTINGS
        .iter()
        .filter(|s| s.section == section && s.matches(query))
        .collect()
}

/// Sections with at least one match, in declaration order, with the match
/// count (`sectionsMatching`).
pub fn sections_matching(query: &str) -> Vec<(SettingsSection, usize)> {
    SettingsSection::ALL
        .iter()
        .filter_map(|&section| {
            let count = matching_settings(section, query).len();
            (count > 0).then_some((section, count))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn has_23_sections_in_6_groups_and_66_entries() {
        assert_eq!(SettingsSection::ALL.len(), 23);
        assert_eq!(SettingsGroup::ALL.len(), 6);
        let grouped: usize = SettingsGroup::ALL.iter().map(|g| g.sections().len()).sum();
        assert_eq!(grouped, 23);
        assert_eq!(SEARCHABLE_SETTINGS.len(), 66);
        for section in SettingsSection::ALL {
            assert!(section.group().sections().contains(&section));
        }
    }

    #[test]
    fn empty_query_matches_nothing() {
        assert!(sections_matching("").is_empty());
    }

    #[test]
    fn matches_title_keywords_and_description() {
        let by_title = sections_matching("language");
        assert!(by_title.iter().any(|(s, _)| *s == SettingsSection::General));
        // Keyword only: "autostart" is a keyword of Launch at Login.
        let by_keyword = sections_matching("AUTOSTART");
        assert_eq!(by_keyword, vec![(SettingsSection::General, 1)]);
        // Description only.
        let by_desc = sections_matching("Terminal cursor appearance");
        assert_eq!(by_desc, vec![(SettingsSection::Shell, 1)]);
    }

    #[test]
    fn counts_are_per_section() {
        let counts = sections_matching("icloud");
        assert!(
            counts
                .iter()
                .any(|(s, c)| *s == SettingsSection::ProfilesBackup && *c >= 1)
        );
    }
}
