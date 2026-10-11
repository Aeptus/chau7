//! Port of `NotificationActionCatalog.swift`.
//!
//! Catalog of the 25 notification action types with their categories, config
//! fields, defaults and display strings, plus the persisted per-action config
//! (`NotificationActionConfig`) and trigger bindings (`TriggerActionBinding`).
//!
//! Raw values (`show_notification`, `time_tracking`, config keys such as
//! `focusTab`) are persisted in settings and must never change. The `ALL`
//! table below was generated mechanically from the Swift source so strings,
//! defaults and ordering match exactly.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Swift `UUID` encodes as an upper-case hyphenated string. Serialize that way
/// so files written by either app are byte-identical; parsing accepts any case.
pub(crate) mod uuid_upper {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(id: &Uuid, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(id.hyphenated().encode_upper(&mut Uuid::encode_buffer()))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Uuid, D::Error> {
        let raw = String::deserialize(d)?;
        Uuid::parse_str(&raw).map_err(serde::de::Error::custom)
    }
}

// MARK: - Action Types

/// All available notification actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NotificationActionType {
    // Basic actions
    #[serde(rename = "show_notification")]
    ShowNotification,
    #[serde(rename = "play_sound")]
    PlaySound,
    #[serde(rename = "focus_window")]
    FocusWindow,
    #[serde(rename = "dock_bounce")]
    DockBounce,
    #[serde(rename = "badge_tab")]
    BadgeTab,
    #[serde(rename = "style_tab")]
    StyleTab,
    // Script & automation
    #[serde(rename = "run_script")]
    RunScript,
    #[serde(rename = "run_shortcut")]
    RunShortcut,
    #[serde(rename = "execute_snippet")]
    ExecuteSnippet,
    // Network & integration
    #[serde(rename = "webhook")]
    Webhook,
    #[serde(rename = "send_slack")]
    SendSlack,
    #[serde(rename = "send_discord")]
    SendDiscord,
    // Docker & DevOps
    #[serde(rename = "docker_bump")]
    DockerBump,
    #[serde(rename = "docker_compose")]
    DockerCompose,
    #[serde(rename = "kubernetes_rollout")]
    KubernetesRollout,
    // Productivity
    #[serde(rename = "copy_to_clipboard")]
    CopyToClipboard,
    #[serde(rename = "write_to_file")]
    WriteToFile,
    #[serde(rename = "open_url")]
    OpenUrl,
    #[serde(rename = "git_commit")]
    GitCommit,
    // Accessibility & UX
    #[serde(rename = "voice_announce")]
    VoiceAnnounce,
    #[serde(rename = "flash_screen")]
    FlashScreen,
    #[serde(rename = "menu_bar_alert")]
    MenuBarAlert,
    // Time tracking
    #[serde(rename = "start_timer")]
    StartTimer,
    #[serde(rename = "stop_timer")]
    StopTimer,
    #[serde(rename = "log_time")]
    LogTime,
}

impl NotificationActionType {
    /// Swift `CaseIterable.allCases`, in declaration order.
    pub const ALL_CASES: [NotificationActionType; 25] = [
        Self::ShowNotification,
        Self::PlaySound,
        Self::FocusWindow,
        Self::DockBounce,
        Self::BadgeTab,
        Self::StyleTab,
        Self::RunScript,
        Self::RunShortcut,
        Self::ExecuteSnippet,
        Self::Webhook,
        Self::SendSlack,
        Self::SendDiscord,
        Self::DockerBump,
        Self::DockerCompose,
        Self::KubernetesRollout,
        Self::CopyToClipboard,
        Self::WriteToFile,
        Self::OpenUrl,
        Self::GitCommit,
        Self::VoiceAnnounce,
        Self::FlashScreen,
        Self::MenuBarAlert,
        Self::StartTimer,
        Self::StopTimer,
        Self::LogTime,
    ];

    /// The persisted raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::ShowNotification => "show_notification",
            Self::PlaySound => "play_sound",
            Self::FocusWindow => "focus_window",
            Self::DockBounce => "dock_bounce",
            Self::BadgeTab => "badge_tab",
            Self::StyleTab => "style_tab",
            Self::RunScript => "run_script",
            Self::RunShortcut => "run_shortcut",
            Self::ExecuteSnippet => "execute_snippet",
            Self::Webhook => "webhook",
            Self::SendSlack => "send_slack",
            Self::SendDiscord => "send_discord",
            Self::DockerBump => "docker_bump",
            Self::DockerCompose => "docker_compose",
            Self::KubernetesRollout => "kubernetes_rollout",
            Self::CopyToClipboard => "copy_to_clipboard",
            Self::WriteToFile => "write_to_file",
            Self::OpenUrl => "open_url",
            Self::GitCommit => "git_commit",
            Self::VoiceAnnounce => "voice_announce",
            Self::FlashScreen => "flash_screen",
            Self::MenuBarAlert => "menu_bar_alert",
            Self::StartTimer => "start_timer",
            Self::StopTimer => "stop_timer",
            Self::LogTime => "log_time",
        }
    }

    /// Swift `Identifiable.id`.
    pub fn id(self) -> &'static str {
        self.raw_value()
    }
}

// MARK: - Action Metadata

/// Static metadata for one action type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotificationActionInfo {
    pub action_type: NotificationActionType,
    pub label_key: &'static str,
    pub label_fallback: &'static str,
    pub description_key: &'static str,
    pub description_fallback: &'static str,
    pub icon: &'static str,
    pub category: ActionCategory,
    pub requires_config: bool,
    pub config_fields: &'static [ActionConfigField],
}

impl NotificationActionInfo {
    pub fn id(&self) -> &'static str {
        self.action_type.raw_value()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ActionCategory {
    #[serde(rename = "basic")]
    Basic,
    #[serde(rename = "automation")]
    Automation,
    #[serde(rename = "integration")]
    Integration,
    #[serde(rename = "devops")]
    Devops,
    #[serde(rename = "productivity")]
    Productivity,
    #[serde(rename = "accessibility")]
    Accessibility,
    #[serde(rename = "time_tracking")]
    TimeTracking,
}

impl ActionCategory {
    /// Swift `CaseIterable.allCases`.
    pub const ALL_CASES: [ActionCategory; 7] = [
        Self::Basic,
        Self::Automation,
        Self::Integration,
        Self::Devops,
        Self::Productivity,
        Self::Accessibility,
        Self::TimeTracking,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Basic => "basic",
            Self::Automation => "automation",
            Self::Integration => "integration",
            Self::Devops => "devops",
            Self::Productivity => "productivity",
            Self::Accessibility => "accessibility",
            Self::TimeTracking => "time_tracking",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Basic => "Basic",
            Self::Automation => "Automation",
            Self::Integration => "Integrations",
            Self::Devops => "DevOps",
            Self::Productivity => "Productivity",
            Self::Accessibility => "Accessibility",
            Self::TimeTracking => "Time Tracking",
        }
    }

    /// SF Symbol name used by the macOS app.
    pub fn icon(self) -> &'static str {
        match self {
            Self::Basic => "bell",
            Self::Automation => "gearshape.2",
            Self::Integration => "network",
            Self::Devops => "server.rack",
            Self::Productivity => "tray.full",
            Self::Accessibility => "accessibility",
            Self::TimeTracking => "clock",
        }
    }
}

// MARK: - Action Configuration

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionConfigField {
    pub id: &'static str,
    pub label_key: &'static str,
    pub label_fallback: &'static str,
    pub field_type: ConfigFieldType,
    pub required: bool,
    pub default_value: Option<&'static str>,
    pub placeholder: Option<&'static str>,
    pub options: Option<&'static [ConfigOption]>,
}

/// Raw values are the Swift case names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ConfigFieldType {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "textArea")]
    TextArea,
    #[serde(rename = "number")]
    Number,
    #[serde(rename = "toggle")]
    Toggle,
    #[serde(rename = "picker")]
    Picker,
    #[serde(rename = "filePath")]
    FilePath,
    #[serde(rename = "soundPicker")]
    SoundPicker,
    #[serde(rename = "secretText")]
    SecretText,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConfigOption {
    pub id: &'static str,
    pub label: &'static str,
}

// MARK: - Action Instance Configuration

/// One configured action instance. JSON keys: `id`, `actionType`, `enabled`,
/// `config` (matches the Swift `Codable` output).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationActionConfig {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    #[serde(rename = "actionType")]
    pub action_type: NotificationActionType,
    pub enabled: bool,
    pub config: BTreeMap<String, String>,
}

impl NotificationActionConfig {
    /// Swift `init(id:actionType:enabled:config:)` with its defaults
    /// (fresh UUID, enabled, empty config).
    pub fn new(action_type: NotificationActionType) -> Self {
        Self {
            id: Uuid::new_v4(),
            action_type,
            enabled: true,
            config: BTreeMap::new(),
        }
    }

    pub fn with_enabled(mut self, enabled: bool) -> Self {
        self.enabled = enabled;
        self
    }

    pub fn with_config<I, K, V>(mut self, entries: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        self.config = entries
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect();
        self
    }

    pub fn config_value(&self, key: &str) -> Option<&str> {
        self.config.get(key).map(String::as_str)
    }

    /// `"true"` (any case) or `"1"` is true; any other present value is false.
    pub fn config_bool(&self, key: &str, default: bool) -> bool {
        match self.config.get(key) {
            None => default,
            Some(value) => value.to_lowercase() == "true" || value == "1",
        }
    }

    /// Unparseable values fall back to `default`.
    pub fn config_int(&self, key: &str, default: i64) -> i64 {
        match self.config.get(key) {
            None => default,
            Some(value) => value.parse::<i64>().unwrap_or(default),
        }
    }
}

// MARK: - Trigger Action Binding

/// Actions bound to one trigger id. JSON keys: `id`, `triggerId`, `actions`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TriggerActionBinding {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    #[serde(rename = "triggerId")]
    pub trigger_id: String,
    pub actions: Vec<NotificationActionConfig>,
}

impl TriggerActionBinding {
    pub fn new(trigger_id: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            trigger_id: trigger_id.into(),
            actions: Vec::new(),
        }
    }

    pub fn with_actions(mut self, actions: Vec<NotificationActionConfig>) -> Self {
        self.actions = actions;
        self
    }
}

// MARK: - Action Catalog

/// Lookup helpers over [`ALL`] (Swift `NotificationActionCatalog`).
pub fn action_for(action_type: NotificationActionType) -> Option<&'static NotificationActionInfo> {
    ALL.iter().find(|info| info.action_type == action_type)
}

pub fn actions_in(category: ActionCategory) -> Vec<&'static NotificationActionInfo> {
    ALL.iter()
        .filter(|info| info.category == category)
        .collect()
}

/// Non-empty categories in declaration order with their actions.
pub fn by_category() -> Vec<(ActionCategory, Vec<&'static NotificationActionInfo>)> {
    ActionCategory::ALL_CASES
        .iter()
        .filter_map(|&category| {
            let actions = actions_in(category);
            if actions.is_empty() {
                None
            } else {
                Some((category, actions))
            }
        })
        .collect()
}

/// Every action, in the Swift catalog order.
pub static ALL: [NotificationActionInfo; 25] = [
    NotificationActionInfo {
        action_type: NotificationActionType::ShowNotification,
        label_key: "action.showNotification.label",
        label_fallback: "Show Notification",
        description_key: "action.showNotification.description",
        description_fallback: "Display a macOS notification with title and message",
        icon: "bell.badge",
        category: ActionCategory::Basic,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "customTitle",
                label_key: "action.field.customTitle",
                label_fallback: "Custom Title",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("Leave empty for default"),
                options: None,
            },
            ActionConfigField {
                id: "customBody",
                label_key: "action.field.customBody",
                label_fallback: "Custom Message",
                field_type: ConfigFieldType::TextArea,
                required: false,
                default_value: None,
                placeholder: Some("Use ${message}, ${type}, ${tool} variables"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::PlaySound,
        label_key: "action.playSound.label",
        label_fallback: "Play Sound",
        description_key: "action.playSound.description",
        description_fallback: "Play a custom sound effect",
        icon: "speaker.wave.3",
        category: ActionCategory::Basic,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "sound",
                label_key: "action.field.sound",
                label_fallback: "Sound",
                field_type: ConfigFieldType::SoundPicker,
                required: true,
                default_value: Some("default"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "volume",
                label_key: "action.field.volume",
                label_fallback: "Volume",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("100"),
                placeholder: Some("0-100"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::FocusWindow,
        label_key: "action.focusWindow.label",
        label_fallback: "Focus Window",
        description_key: "action.focusWindow.description",
        description_fallback: "Bring the app window to the front and focus the relevant tab",
        icon: "macwindow",
        category: ActionCategory::Basic,
        requires_config: false,
        config_fields: &[ActionConfigField {
            id: "focusTab",
            label_key: "action.field.focusTab",
            label_fallback: "Focus Source Tab",
            field_type: ConfigFieldType::Toggle,
            required: false,
            default_value: Some("true"),
            placeholder: None,
            options: None,
        }],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::DockBounce,
        label_key: "action.dockBounce.label",
        label_fallback: "Dock Bounce",
        description_key: "action.dockBounce.description",
        description_fallback: "Bounce the dock icon to attract attention",
        icon: "arrow.up.arrow.down",
        category: ActionCategory::Basic,
        requires_config: false,
        config_fields: &[ActionConfigField {
            id: "critical",
            label_key: "action.field.critical",
            label_fallback: "Critical (continuous bounce)",
            field_type: ConfigFieldType::Toggle,
            required: false,
            default_value: Some("false"),
            placeholder: None,
            options: None,
        }],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::BadgeTab,
        label_key: "action.badgeTab.label",
        label_fallback: "Badge Tab",
        description_key: "action.badgeTab.description",
        description_fallback: "Show a badge indicator on the source tab",
        icon: "tag.circle",
        category: ActionCategory::Basic,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "badgeText",
                label_key: "action.field.badgeText",
                label_fallback: "Badge Text",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("! or custom text"),
                options: None,
            },
            ActionConfigField {
                id: "badgeColor",
                label_key: "action.field.badgeColor",
                label_fallback: "Badge Color",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("red"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "red",
                        label: "Red",
                    },
                    ConfigOption {
                        id: "orange",
                        label: "Orange",
                    },
                    ConfigOption {
                        id: "yellow",
                        label: "Yellow",
                    },
                    ConfigOption {
                        id: "green",
                        label: "Green",
                    },
                    ConfigOption {
                        id: "blue",
                        label: "Blue",
                    },
                ]),
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::StyleTab,
        label_key: "action.styleTab.label",
        label_fallback: "Style Tab",
        description_key: "action.styleTab.description",
        description_fallback: "Apply visual styling to the tab (color, italic, pulse animation)",
        icon: "paintbrush",
        category: ActionCategory::Basic,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "style",
                label_key: "action.field.style",
                label_fallback: "Style Preset",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("waiting"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "waiting",
                        label: "Waiting (orange italic + pulse)",
                    },
                    ConfigOption {
                        id: "error",
                        label: "Error (red bold)",
                    },
                    ConfigOption {
                        id: "success",
                        label: "Success (green)",
                    },
                    ConfigOption {
                        id: "attention",
                        label: "Attention (yellow bold + pulse)",
                    },
                    ConfigOption {
                        id: "custom",
                        label: "Custom (use config fields below)",
                    },
                    ConfigOption {
                        id: "clear",
                        label: "Clear Style",
                    },
                ]),
            },
            ActionConfigField {
                id: "customColor",
                label_key: "action.field.customColor",
                label_fallback: "Custom Color (optional)",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: None,
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "",
                        label: "Use preset",
                    },
                    ConfigOption {
                        id: "red",
                        label: "Red",
                    },
                    ConfigOption {
                        id: "orange",
                        label: "Orange",
                    },
                    ConfigOption {
                        id: "yellow",
                        label: "Yellow",
                    },
                    ConfigOption {
                        id: "green",
                        label: "Green",
                    },
                    ConfigOption {
                        id: "blue",
                        label: "Blue",
                    },
                    ConfigOption {
                        id: "purple",
                        label: "Purple",
                    },
                    ConfigOption {
                        id: "pink",
                        label: "Pink",
                    },
                ]),
            },
            ActionConfigField {
                id: "italic",
                label_key: "action.field.italic",
                label_fallback: "Italic",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("false"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "bold",
                label_key: "action.field.bold",
                label_fallback: "Bold",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("false"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "pulse",
                label_key: "action.field.pulse",
                label_fallback: "Pulse Animation",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("false"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "borderWidth",
                label_key: "action.field.borderWidth",
                label_fallback: "Border Width",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("0"),
                placeholder: Some("0 = no border"),
                options: None,
            },
            ActionConfigField {
                id: "borderStyle",
                label_key: "action.field.borderStyle",
                label_fallback: "Border Style",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("solid"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "solid",
                        label: "Solid",
                    },
                    ConfigOption {
                        id: "dotted",
                        label: "Dotted",
                    },
                    ConfigOption {
                        id: "dashed",
                        label: "Dashed",
                    },
                ]),
            },
            ActionConfigField {
                id: "autoClearSeconds",
                label_key: "action.field.autoClearSeconds",
                label_fallback: "Auto-clear after (seconds)",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: None,
                placeholder: Some("0 = never"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::RunScript,
        label_key: "action.runScript.label",
        label_fallback: "Run Script",
        description_key: "action.runScript.description",
        description_fallback: "Execute a shell script or command with event data as environment variables",
        icon: "terminal",
        category: ActionCategory::Automation,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "script",
                label_key: "action.field.script",
                label_fallback: "Script/Command",
                field_type: ConfigFieldType::TextArea,
                required: true,
                default_value: None,
                placeholder: Some("echo \"Task $CHAU7_TYPE completed\""),
                options: None,
            },
            ActionConfigField {
                id: "shell",
                label_key: "action.field.shell",
                label_fallback: "Shell",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("/bin/zsh"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "/bin/zsh",
                        label: "zsh",
                    },
                    ConfigOption {
                        id: "/bin/bash",
                        label: "bash",
                    },
                    ConfigOption {
                        id: "/bin/sh",
                        label: "sh",
                    },
                ]),
            },
            ActionConfigField {
                id: "timeout",
                label_key: "action.field.timeout",
                label_fallback: "Timeout (seconds)",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("30"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "workingDir",
                label_key: "action.field.workingDir",
                label_fallback: "Working Directory",
                field_type: ConfigFieldType::FilePath,
                required: false,
                default_value: None,
                placeholder: Some("Default: event source directory"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::RunShortcut,
        label_key: "action.runShortcut.label",
        label_fallback: "Run Shortcut",
        description_key: "action.runShortcut.description",
        description_fallback: "Execute a macOS Shortcut with event data as input",
        icon: "square.on.square.badge.person.crop",
        category: ActionCategory::Automation,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "shortcutName",
                label_key: "action.field.shortcutName",
                label_fallback: "Shortcut Name",
                field_type: ConfigFieldType::Text,
                required: true,
                default_value: None,
                placeholder: Some("My Shortcut"),
                options: None,
            },
            ActionConfigField {
                id: "passEventData",
                label_key: "action.field.passEventData",
                label_fallback: "Pass Event Data",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("true"),
                placeholder: None,
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::ExecuteSnippet,
        label_key: "action.executeSnippet.label",
        label_fallback: "Execute Snippet",
        description_key: "action.executeSnippet.description",
        description_fallback: "Run a saved snippet in the source terminal tab",
        icon: "doc.text",
        category: ActionCategory::Automation,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "snippetId",
                label_key: "action.field.snippetId",
                label_fallback: "Snippet ID",
                field_type: ConfigFieldType::Text,
                required: true,
                default_value: None,
                placeholder: Some("my-snippet-id"),
                options: None,
            },
            ActionConfigField {
                id: "autoExecute",
                label_key: "action.field.autoExecute",
                label_fallback: "Auto Execute (press Enter)",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("false"),
                placeholder: None,
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::Webhook,
        label_key: "action.webhook.label",
        label_fallback: "Webhook",
        description_key: "action.webhook.description",
        description_fallback: "Send an HTTP request to a URL with event data as JSON payload",
        icon: "arrow.up.forward.app",
        category: ActionCategory::Integration,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "url",
                label_key: "action.field.url",
                label_fallback: "Webhook URL",
                field_type: ConfigFieldType::Text,
                required: true,
                default_value: None,
                placeholder: Some("https://example.com/webhook"),
                options: None,
            },
            ActionConfigField {
                id: "method",
                label_key: "action.field.method",
                label_fallback: "HTTP Method",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("POST"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "POST",
                        label: "POST",
                    },
                    ConfigOption {
                        id: "PUT",
                        label: "PUT",
                    },
                    ConfigOption {
                        id: "GET",
                        label: "GET",
                    },
                ]),
            },
            ActionConfigField {
                id: "headers",
                label_key: "action.field.headers",
                label_fallback: "Headers (JSON)",
                field_type: ConfigFieldType::TextArea,
                required: false,
                default_value: None,
                placeholder: Some("{\"Authorization\": \"Bearer token\"}"),
                options: None,
            },
            ActionConfigField {
                id: "customPayload",
                label_key: "action.field.customPayload",
                label_fallback: "Custom Payload (JSON)",
                field_type: ConfigFieldType::TextArea,
                required: false,
                default_value: None,
                placeholder: Some("Leave empty for default event JSON"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::SendSlack,
        label_key: "action.sendSlack.label",
        label_fallback: "Send to Slack",
        description_key: "action.sendSlack.description",
        description_fallback: "Post a message to a Slack channel via webhook",
        icon: "bubble.left.and.bubble.right",
        category: ActionCategory::Integration,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "webhookUrl",
                label_key: "action.field.webhookUrl",
                label_fallback: "Slack Webhook URL",
                field_type: ConfigFieldType::SecretText,
                required: true,
                default_value: None,
                placeholder: Some("https://hooks.slack.com/services/..."),
                options: None,
            },
            ActionConfigField {
                id: "channel",
                label_key: "action.field.channel",
                label_fallback: "Channel Override",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("#general"),
                options: None,
            },
            ActionConfigField {
                id: "username",
                label_key: "action.field.username",
                label_fallback: "Bot Username",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: Some("Chau7"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "emoji",
                label_key: "action.field.emoji",
                label_fallback: "Bot Emoji",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: Some(":computer:"),
                placeholder: None,
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::SendDiscord,
        label_key: "action.sendDiscord.label",
        label_fallback: "Send to Discord",
        description_key: "action.sendDiscord.description",
        description_fallback: "Post a message to a Discord channel via webhook",
        icon: "bubble.left.and.bubble.right.fill",
        category: ActionCategory::Integration,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "webhookUrl",
                label_key: "action.field.webhookUrl",
                label_fallback: "Discord Webhook URL",
                field_type: ConfigFieldType::SecretText,
                required: true,
                default_value: None,
                placeholder: Some("https://discord.com/api/webhooks/..."),
                options: None,
            },
            ActionConfigField {
                id: "username",
                label_key: "action.field.username",
                label_fallback: "Bot Username",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: Some("Chau7"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "avatarUrl",
                label_key: "action.field.avatarUrl",
                label_fallback: "Avatar URL",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("https://example.com/avatar.png"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::DockerBump,
        label_key: "action.dockerBump.label",
        label_fallback: "Docker Bump",
        description_key: "action.dockerBump.description",
        description_fallback: "Restart a Docker container or rebuild and restart",
        icon: "shippingbox",
        category: ActionCategory::Devops,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "container",
                label_key: "action.field.container",
                label_fallback: "Container Name/ID",
                field_type: ConfigFieldType::Text,
                required: true,
                default_value: None,
                placeholder: Some("my-container"),
                options: None,
            },
            ActionConfigField {
                id: "operation",
                label_key: "action.field.operation",
                label_fallback: "Operation",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("restart"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "restart",
                        label: "Restart",
                    },
                    ConfigOption {
                        id: "stop",
                        label: "Stop",
                    },
                    ConfigOption {
                        id: "start",
                        label: "Start",
                    },
                    ConfigOption {
                        id: "rebuild",
                        label: "Rebuild & Restart",
                    },
                ]),
            },
            ActionConfigField {
                id: "dockerPath",
                label_key: "action.field.dockerPath",
                label_fallback: "Docker Path",
                field_type: ConfigFieldType::FilePath,
                required: false,
                default_value: Some("/usr/local/bin/docker"),
                placeholder: None,
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::DockerCompose,
        label_key: "action.dockerCompose.label",
        label_fallback: "Docker Compose",
        description_key: "action.dockerCompose.description",
        description_fallback: "Run docker-compose commands (up, down, restart, etc.)",
        icon: "square.stack.3d.up",
        category: ActionCategory::Devops,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "composePath",
                label_key: "action.field.composePath",
                label_fallback: "docker-compose.yml Path",
                field_type: ConfigFieldType::FilePath,
                required: true,
                default_value: None,
                placeholder: Some("/path/to/docker-compose.yml"),
                options: None,
            },
            ActionConfigField {
                id: "operation",
                label_key: "action.field.operation",
                label_fallback: "Operation",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("restart"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "up",
                        label: "Up (detached)",
                    },
                    ConfigOption {
                        id: "down",
                        label: "Down",
                    },
                    ConfigOption {
                        id: "restart",
                        label: "Restart",
                    },
                    ConfigOption {
                        id: "build",
                        label: "Build",
                    },
                    ConfigOption {
                        id: "pull",
                        label: "Pull",
                    },
                ]),
            },
            ActionConfigField {
                id: "services",
                label_key: "action.field.services",
                label_fallback: "Services (comma-separated)",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("Leave empty for all services"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::KubernetesRollout,
        label_key: "action.kubernetesRollout.label",
        label_fallback: "Kubernetes Rollout",
        description_key: "action.kubernetesRollout.description",
        description_fallback: "Trigger a Kubernetes deployment rollout restart",
        icon: "helm",
        category: ActionCategory::Devops,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "deployment",
                label_key: "action.field.deployment",
                label_fallback: "Deployment Name",
                field_type: ConfigFieldType::Text,
                required: true,
                default_value: None,
                placeholder: Some("my-deployment"),
                options: None,
            },
            ActionConfigField {
                id: "namespace",
                label_key: "action.field.namespace",
                label_fallback: "Namespace",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: Some("default"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "context",
                label_key: "action.field.context",
                label_fallback: "kubectl Context",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("Leave empty for current context"),
                options: None,
            },
            ActionConfigField {
                id: "operation",
                label_key: "action.field.operation",
                label_fallback: "Operation",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("restart"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "restart",
                        label: "Rollout Restart",
                    },
                    ConfigOption {
                        id: "scale",
                        label: "Scale (requires replicas)",
                    },
                    ConfigOption {
                        id: "status",
                        label: "Check Status",
                    },
                ]),
            },
            ActionConfigField {
                id: "replicas",
                label_key: "action.field.replicas",
                label_fallback: "Replicas (for scale)",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: None,
                placeholder: Some("3"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::CopyToClipboard,
        label_key: "action.copyToClipboard.label",
        label_fallback: "Copy to Clipboard",
        description_key: "action.copyToClipboard.description",
        description_fallback: "Copy event message or custom text to the clipboard",
        icon: "doc.on.clipboard",
        category: ActionCategory::Productivity,
        requires_config: false,
        config_fields: &[ActionConfigField {
            id: "content",
            label_key: "action.field.content",
            label_fallback: "Content to Copy",
            field_type: ConfigFieldType::TextArea,
            required: false,
            default_value: None,
            placeholder: Some("Use ${message}, ${type}, ${tool} or leave empty for message"),
            options: None,
        }],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::WriteToFile,
        label_key: "action.writeToFile.label",
        label_fallback: "Write to File",
        description_key: "action.writeToFile.description",
        description_fallback: "Append event data to a log file",
        icon: "doc.badge.plus",
        category: ActionCategory::Productivity,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "filePath",
                label_key: "action.field.filePath",
                label_fallback: "File Path",
                field_type: ConfigFieldType::FilePath,
                required: true,
                default_value: None,
                placeholder: Some("~/chau7-events.log"),
                options: None,
            },
            ActionConfigField {
                id: "format",
                label_key: "action.field.format",
                label_fallback: "Format",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("text"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "text",
                        label: "Text (one line per event)",
                    },
                    ConfigOption {
                        id: "json",
                        label: "JSON (one object per line)",
                    },
                    ConfigOption {
                        id: "csv",
                        label: "CSV",
                    },
                ]),
            },
            ActionConfigField {
                id: "template",
                label_key: "action.field.template",
                label_fallback: "Custom Template",
                field_type: ConfigFieldType::TextArea,
                required: false,
                default_value: None,
                placeholder: Some("[${timestamp}] ${type}: ${message}"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::OpenUrl,
        label_key: "action.openURL.label",
        label_fallback: "Open URL",
        description_key: "action.openURL.description",
        description_fallback: "Open a URL in the default browser",
        icon: "safari",
        category: ActionCategory::Productivity,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "url",
                label_key: "action.field.url",
                label_fallback: "URL",
                field_type: ConfigFieldType::Text,
                required: true,
                default_value: None,
                placeholder: Some("https://example.com/dashboard?event=${type}"),
                options: None,
            },
            ActionConfigField {
                id: "browser",
                label_key: "action.field.browser",
                label_fallback: "Browser",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("default"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "default",
                        label: "System Default",
                    },
                    ConfigOption {
                        id: "safari",
                        label: "Safari",
                    },
                    ConfigOption {
                        id: "chrome",
                        label: "Chrome",
                    },
                    ConfigOption {
                        id: "firefox",
                        label: "Firefox",
                    },
                    ConfigOption {
                        id: "arc",
                        label: "Arc",
                    },
                ]),
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::GitCommit,
        label_key: "action.gitCommit.label",
        label_fallback: "Git Commit",
        description_key: "action.gitCommit.description",
        description_fallback: "Auto-commit changes in the working directory",
        icon: "arrow.triangle.branch",
        category: ActionCategory::Productivity,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "message",
                label_key: "action.field.message",
                label_fallback: "Commit Message",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: Some("Auto-commit: ${type} - ${message}"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "addAll",
                label_key: "action.field.addAll",
                label_fallback: "Stage All Changes",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("true"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "push",
                label_key: "action.field.push",
                label_fallback: "Push After Commit",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("false"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "repoPath",
                label_key: "action.field.repoPath",
                label_fallback: "Repository Path",
                field_type: ConfigFieldType::FilePath,
                required: false,
                default_value: None,
                placeholder: Some("Default: event source directory"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::VoiceAnnounce,
        label_key: "action.voiceAnnounce.label",
        label_fallback: "Voice Announcement",
        description_key: "action.voiceAnnounce.description",
        description_fallback: "Read the notification aloud using macOS text-to-speech",
        icon: "speaker.wave.2.bubble.left",
        category: ActionCategory::Accessibility,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "text",
                label_key: "action.field.text",
                label_fallback: "Text to Speak",
                field_type: ConfigFieldType::TextArea,
                required: false,
                default_value: None,
                placeholder: Some("Use ${message}, ${type} or leave empty for default"),
                options: None,
            },
            ActionConfigField {
                id: "voice",
                label_key: "action.field.voice",
                label_fallback: "Voice",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("default"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "default",
                        label: "System Default",
                    },
                    ConfigOption {
                        id: "Alex",
                        label: "Alex",
                    },
                    ConfigOption {
                        id: "Samantha",
                        label: "Samantha",
                    },
                    ConfigOption {
                        id: "Victoria",
                        label: "Victoria",
                    },
                    ConfigOption {
                        id: "Daniel",
                        label: "Daniel (UK)",
                    },
                    ConfigOption {
                        id: "Karen",
                        label: "Karen (AU)",
                    },
                ]),
            },
            ActionConfigField {
                id: "rate",
                label_key: "action.field.rate",
                label_fallback: "Speech Rate",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("175"),
                placeholder: Some("150-250 words per minute"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::FlashScreen,
        label_key: "action.flashScreen.label",
        label_fallback: "Flash Screen",
        description_key: "action.flashScreen.description",
        description_fallback: "Briefly flash the screen for visual attention (accessibility feature)",
        icon: "lightbulb.max",
        category: ActionCategory::Accessibility,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "color",
                label_key: "action.field.color",
                label_fallback: "Flash Color",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("white"),
                placeholder: None,
                options: Some(&[
                    ConfigOption {
                        id: "white",
                        label: "White",
                    },
                    ConfigOption {
                        id: "yellow",
                        label: "Yellow",
                    },
                    ConfigOption {
                        id: "red",
                        label: "Red",
                    },
                    ConfigOption {
                        id: "green",
                        label: "Green",
                    },
                    ConfigOption {
                        id: "blue",
                        label: "Blue",
                    },
                ]),
            },
            ActionConfigField {
                id: "duration",
                label_key: "action.field.duration",
                label_fallback: "Duration (ms)",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("200"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "count",
                label_key: "action.field.count",
                label_fallback: "Flash Count",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("2"),
                placeholder: None,
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::MenuBarAlert,
        label_key: "action.menuBarAlert.label",
        label_fallback: "Menu Bar Alert",
        description_key: "action.menuBarAlert.description",
        description_fallback: "Show a temporary alert badge in the menu bar icon",
        icon: "menubar.arrow.up.rectangle",
        category: ActionCategory::Accessibility,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "duration",
                label_key: "action.field.duration",
                label_fallback: "Duration (seconds)",
                field_type: ConfigFieldType::Number,
                required: false,
                default_value: Some("5"),
                placeholder: None,
                options: None,
            },
            ActionConfigField {
                id: "animate",
                label_key: "action.field.animate",
                label_fallback: "Animate Icon",
                field_type: ConfigFieldType::Toggle,
                required: false,
                default_value: Some("true"),
                placeholder: None,
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::StartTimer,
        label_key: "action.startTimer.label",
        label_fallback: "Start Timer",
        description_key: "action.startTimer.description",
        description_fallback: "Start a time tracking timer for the current task",
        icon: "play.circle",
        category: ActionCategory::TimeTracking,
        requires_config: false,
        config_fields: &[
            ActionConfigField {
                id: "timerName",
                label_key: "action.field.timerName",
                label_fallback: "Timer Name",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("Use ${tool} or ${type} for dynamic names"),
                options: None,
            },
            ActionConfigField {
                id: "project",
                label_key: "action.field.project",
                label_fallback: "Project",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: None,
                placeholder: Some("Project name for grouping"),
                options: None,
            },
        ],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::StopTimer,
        label_key: "action.stopTimer.label",
        label_fallback: "Stop Timer",
        description_key: "action.stopTimer.description",
        description_fallback: "Stop the currently running timer",
        icon: "stop.circle",
        category: ActionCategory::TimeTracking,
        requires_config: false,
        config_fields: &[ActionConfigField {
            id: "timerName",
            label_key: "action.field.timerName",
            label_fallback: "Timer Name",
            field_type: ConfigFieldType::Text,
            required: false,
            default_value: None,
            placeholder: Some("Leave empty to stop the most recent timer"),
            options: None,
        }],
    },
    NotificationActionInfo {
        action_type: NotificationActionType::LogTime,
        label_key: "action.logTime.label",
        label_fallback: "Log Time Entry",
        description_key: "action.logTime.description",
        description_fallback: "Log a time entry to a file or time tracking service",
        icon: "clock.badge.checkmark",
        category: ActionCategory::TimeTracking,
        requires_config: true,
        config_fields: &[
            ActionConfigField {
                id: "service",
                label_key: "action.field.service",
                label_fallback: "Service",
                field_type: ConfigFieldType::Picker,
                required: false,
                default_value: Some("file"),
                placeholder: None,
                options: Some(&[ConfigOption {
                    id: "file",
                    label: "Local File",
                }]),
            },
            ActionConfigField {
                id: "filePath",
                label_key: "action.field.filePath",
                label_fallback: "Log File Path",
                field_type: ConfigFieldType::FilePath,
                required: false,
                default_value: None,
                placeholder: Some("~/time-log.csv"),
                options: None,
            },
            ActionConfigField {
                id: "description",
                label_key: "action.field.description",
                label_fallback: "Entry Description",
                field_type: ConfigFieldType::Text,
                required: false,
                default_value: Some("${type}: ${message}"),
                placeholder: None,
                options: None,
            },
        ],
    },
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn cfg(t: NotificationActionType) -> NotificationActionConfig {
        NotificationActionConfig::new(t)
    }

    // NotificationActionTypeTests

    #[test]
    fn test_all_cases_unique() {
        let raw: Vec<_> = NotificationActionType::ALL_CASES
            .iter()
            .map(|t| t.raw_value())
            .collect();
        assert_eq!(raw.len(), raw.iter().collect::<HashSet<_>>().len());
    }

    #[test]
    fn test_action_type_count() {
        assert_eq!(NotificationActionType::ALL_CASES.len(), 25);
    }

    #[test]
    fn test_action_type_identifiable() {
        let a = NotificationActionType::ShowNotification;
        assert_eq!(a.id(), a.raw_value());
    }

    #[test]
    fn test_action_type_codable_round_trip() {
        for t in NotificationActionType::ALL_CASES {
            let json = serde_json::to_string(&t).unwrap();
            assert_eq!(json, format!("\"{}\"", t.raw_value()));
            let back: NotificationActionType = serde_json::from_str(&json).unwrap();
            assert_eq!(back, t);
        }
    }

    // ActionCategoryTests

    #[test]
    fn test_all_categories_unique() {
        let raw: Vec<_> = ActionCategory::ALL_CASES
            .iter()
            .map(|c| c.raw_value())
            .collect();
        assert_eq!(raw.len(), raw.iter().collect::<HashSet<_>>().len());
    }

    #[test]
    fn test_category_count() {
        assert_eq!(ActionCategory::ALL_CASES.len(), 7);
    }

    #[test]
    fn test_display_names() {
        assert_eq!(ActionCategory::Basic.display_name(), "Basic");
        assert_eq!(ActionCategory::Automation.display_name(), "Automation");
        assert_eq!(ActionCategory::Integration.display_name(), "Integrations");
        assert_eq!(ActionCategory::Devops.display_name(), "DevOps");
        assert_eq!(ActionCategory::Productivity.display_name(), "Productivity");
        assert_eq!(
            ActionCategory::Accessibility.display_name(),
            "Accessibility"
        );
        assert_eq!(ActionCategory::TimeTracking.display_name(), "Time Tracking");
    }

    #[test]
    fn test_icons() {
        for c in ActionCategory::ALL_CASES {
            assert!(!c.icon().is_empty());
        }
    }

    #[test]
    fn test_category_codable_round_trip() {
        for c in ActionCategory::ALL_CASES {
            let json = serde_json::to_string(&c).unwrap();
            assert_eq!(json, format!("\"{}\"", c.raw_value()));
            let back: ActionCategory = serde_json::from_str(&json).unwrap();
            assert_eq!(back, c);
        }
    }

    // NotificationActionCatalogTests

    #[test]
    fn test_catalog_covers_all_action_types() {
        let catalog: HashSet<_> = ALL.iter().map(|i| i.action_type).collect();
        let all: HashSet<_> = NotificationActionType::ALL_CASES.into_iter().collect();
        assert_eq!(catalog, all);
        assert_eq!(ALL.len(), 25);
    }

    #[test]
    fn test_catalog_order_matches_declaration_order() {
        let order: Vec<_> = ALL.iter().map(|i| i.action_type).collect();
        assert_eq!(order, NotificationActionType::ALL_CASES.to_vec());
    }

    #[test]
    fn test_action_lookup_by_type() {
        let info = action_for(NotificationActionType::Webhook).unwrap();
        assert_eq!(info.action_type, NotificationActionType::Webhook);
        assert_eq!(info.category, ActionCategory::Integration);
    }

    #[test]
    fn test_action_lookup_returns_nil_for_none() {
        assert!(action_for(NotificationActionType::ShowNotification).is_some());
    }

    #[test]
    fn test_actions_in_category() {
        let basic = actions_in(ActionCategory::Basic);
        assert!(!basic.is_empty());
        for a in basic {
            assert_eq!(a.category, ActionCategory::Basic);
        }
    }

    #[test]
    fn test_actions_in_category_dev_ops() {
        let types: Vec<_> = actions_in(ActionCategory::Devops)
            .iter()
            .map(|a| a.action_type)
            .collect();
        assert!(types.contains(&NotificationActionType::DockerBump));
        assert!(types.contains(&NotificationActionType::DockerCompose));
        assert!(types.contains(&NotificationActionType::KubernetesRollout));
    }

    #[test]
    fn test_actions_in_category_time_tracking() {
        let types: Vec<_> = actions_in(ActionCategory::TimeTracking)
            .iter()
            .map(|a| a.action_type)
            .collect();
        assert!(types.contains(&NotificationActionType::StartTimer));
        assert!(types.contains(&NotificationActionType::StopTimer));
        assert!(types.contains(&NotificationActionType::LogTime));
    }

    #[test]
    fn test_by_category_covers_all_categories() {
        let cats: Vec<_> = by_category().iter().map(|(c, _)| *c).collect();
        for c in ActionCategory::ALL_CASES {
            assert!(cats.contains(&c), "{c:?} should appear in by_category");
        }
    }

    #[test]
    fn test_by_category_actions_match_category() {
        for (category, actions) in by_category() {
            for a in actions {
                assert_eq!(a.category, category);
            }
        }
    }

    #[test]
    fn test_by_category_total_matches_all() {
        let total: usize = by_category().iter().map(|(_, a)| a.len()).sum();
        assert_eq!(total, ALL.len());
    }

    #[test]
    fn test_all_actions_have_labels() {
        for a in ALL.iter() {
            assert!(!a.label_fallback.is_empty());
            assert!(!a.label_key.is_empty());
        }
    }

    #[test]
    fn test_all_actions_have_descriptions() {
        for a in ALL.iter() {
            assert!(!a.description_fallback.is_empty());
            assert!(!a.description_key.is_empty());
        }
    }

    #[test]
    fn test_all_actions_have_icons() {
        for a in ALL.iter() {
            assert!(!a.icon.is_empty());
        }
    }

    #[test]
    fn test_requires_config_actions_have_config_fields() {
        for a in ALL.iter().filter(|a| a.requires_config) {
            assert!(!a.config_fields.is_empty(), "{:?}", a.action_type);
        }
    }

    // Spot checks of the generated table against the Swift source.

    #[test]
    fn test_catalog_spot_checks() {
        let sound = action_for(NotificationActionType::PlaySound).unwrap();
        assert_eq!(sound.label_fallback, "Play Sound");
        assert!(sound.requires_config);
        assert_eq!(sound.config_fields.len(), 2);
        assert_eq!(sound.config_fields[0].id, "sound");
        assert_eq!(
            sound.config_fields[0].field_type,
            ConfigFieldType::SoundPicker
        );
        assert!(sound.config_fields[0].required);
        assert_eq!(sound.config_fields[0].default_value, Some("default"));
        assert_eq!(sound.config_fields[1].default_value, Some("100"));

        let style = action_for(NotificationActionType::StyleTab).unwrap();
        assert_eq!(style.config_fields.len(), 8);
        assert_eq!(style.config_fields[0].options.unwrap().len(), 6);
        assert_eq!(style.config_fields[1].options.unwrap()[0].id, "");

        let script = action_for(NotificationActionType::RunScript).unwrap();
        assert_eq!(
            script.config_fields[0].placeholder,
            Some("echo \"Task $CHAU7_TYPE completed\"")
        );
        assert_eq!(script.config_fields[1].default_value, Some("/bin/zsh"));

        let slack = action_for(NotificationActionType::SendSlack).unwrap();
        assert_eq!(
            slack.config_fields[0].field_type,
            ConfigFieldType::SecretText
        );

        let total_fields: usize = ALL.iter().map(|a| a.config_fields.len()).sum();
        assert_eq!(total_fields, 70);
        let total_options: usize = ALL
            .iter()
            .flat_map(|a| a.config_fields.iter())
            .map(|f| f.options.map_or(0, |o| o.len()))
            .sum();
        assert_eq!(total_options, 60);
    }

    // NotificationActionConfigTests

    #[test]
    fn test_config_value_present() {
        let c = cfg(NotificationActionType::Webhook).with_config([("url", "https://example.com")]);
        assert_eq!(c.config_value("url"), Some("https://example.com"));
    }

    #[test]
    fn test_config_value_missing() {
        let c = cfg(NotificationActionType::Webhook);
        assert_eq!(c.config_value("url"), None);
    }

    #[test]
    fn test_config_bool_true() {
        let c = cfg(NotificationActionType::FocusWindow).with_config([("focusTab", "true")]);
        assert!(c.config_bool("focusTab", false));
    }

    #[test]
    fn test_config_bool_one() {
        let c = cfg(NotificationActionType::FocusWindow).with_config([("focusTab", "1")]);
        assert!(c.config_bool("focusTab", false));
    }

    #[test]
    fn test_config_bool_false() {
        let c = cfg(NotificationActionType::FocusWindow).with_config([("focusTab", "false")]);
        assert!(!c.config_bool("focusTab", false));
    }

    #[test]
    fn test_config_bool_missing_uses_default() {
        let c = cfg(NotificationActionType::FocusWindow);
        assert!(!c.config_bool("focusTab", false));
        assert!(c.config_bool("focusTab", true));
    }

    #[test]
    fn test_config_bool_case_insensitive() {
        let c = cfg(NotificationActionType::FocusWindow).with_config([("enabled", "TRUE")]);
        assert!(c.config_bool("enabled", false));
    }

    #[test]
    fn test_config_int_valid() {
        let c = cfg(NotificationActionType::PlaySound).with_config([("volume", "75")]);
        assert_eq!(c.config_int("volume", 0), 75);
    }

    #[test]
    fn test_config_int_invalid() {
        let c = cfg(NotificationActionType::PlaySound).with_config([("volume", "loud")]);
        assert_eq!(c.config_int("volume", 0), 0);
    }

    #[test]
    fn test_config_int_missing_uses_default() {
        let c = cfg(NotificationActionType::PlaySound);
        assert_eq!(c.config_int("volume", 0), 0);
        assert_eq!(c.config_int("volume", 50), 50);
    }

    #[test]
    fn test_config_codable_round_trip() {
        let original = cfg(NotificationActionType::Webhook)
            .with_config([("url", "https://example.com"), ("method", "POST")]);
        let json = serde_json::to_string(&original).unwrap();
        let decoded: NotificationActionConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn test_config_json_shape_matches_swift() {
        let json = r#"{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","actionType":"focus_window","enabled":false,"config":{"focusTab":"false"}}"#;
        let decoded: NotificationActionConfig = serde_json::from_str(json).unwrap();
        assert_eq!(decoded.action_type, NotificationActionType::FocusWindow);
        assert!(!decoded.enabled);
        assert_eq!(serde_json::to_string(&decoded).unwrap(), json);
    }

    #[test]
    fn test_config_identifiable() {
        let a = cfg(NotificationActionType::Webhook);
        let b = cfg(NotificationActionType::Webhook);
        assert_ne!(a.id, b.id);
    }

    // TriggerActionBindingTests

    #[test]
    fn test_binding_init() {
        let b = TriggerActionBinding::new("events_log.finished");
        assert_eq!(b.trigger_id, "events_log.finished");
        assert!(b.actions.is_empty());
    }

    #[test]
    fn test_binding_with_actions() {
        let b = TriggerActionBinding::new("events_log.finished")
            .with_actions(vec![cfg(NotificationActionType::ShowNotification)]);
        assert_eq!(b.actions.len(), 1);
        assert_eq!(
            b.actions[0].action_type,
            NotificationActionType::ShowNotification
        );
    }

    #[test]
    fn test_binding_codable_round_trip() {
        let action = cfg(NotificationActionType::PlaySound).with_config([("sound", "default")]);
        let original = TriggerActionBinding::new("claude_code.finished").with_actions(vec![action]);
        let json = serde_json::to_string(&original).unwrap();
        assert!(json.contains("\"triggerId\":\"claude_code.finished\""));
        let decoded: TriggerActionBinding = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn test_binding_equality() {
        let id = Uuid::new_v4();
        let mut a = TriggerActionBinding::new("t1");
        let mut b = TriggerActionBinding::new("t1");
        a.id = id;
        b.id = id;
        assert_eq!(a, b);
    }

    // ActionConfigFieldTests

    #[test]
    fn test_field_identifiable() {
        let f = action_for(NotificationActionType::Webhook)
            .unwrap()
            .config_fields[0];
        assert_eq!(f.id, "url");
        assert!(f.required);
    }

    #[test]
    fn test_field_equality() {
        let a = action_for(NotificationActionType::Webhook)
            .unwrap()
            .config_fields[0];
        let b = action_for(NotificationActionType::Webhook)
            .unwrap()
            .config_fields[0];
        assert_eq!(a, b);
    }

    #[test]
    fn test_field_with_options() {
        let f = action_for(NotificationActionType::Webhook)
            .unwrap()
            .config_fields[1];
        assert_eq!(f.field_type, ConfigFieldType::Picker);
        assert_eq!(f.options.map(|o| o.len()), Some(3));
    }
}
