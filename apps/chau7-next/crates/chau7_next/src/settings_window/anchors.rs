//! Nested GPUI scroll anchors corresponding to current settings metadata.
use chau7_next_core::settings_search::{SEARCHABLE_SETTINGS, SettingsSection};
use gpui::{IntoElement, ScrollAnchor, SharedString, div, prelude::*};
use std::{cell::RefCell, collections::HashMap, rc::Rc};
#[derive(Clone)]
struct Scope {
    section: SettingsSection,
    anchors: Rc<HashMap<&'static str, ScrollAnchor>>,
    labels: HashMap<String, &'static str>,
}
#[cfg(test)]
thread_local! { static RENDERED: RefCell<std::collections::HashSet<&'static str>> = RefCell::new(Default::default()); }
#[cfg(test)]
thread_local! { static OBSERVATION_IDS: RefCell<HashMap<&'static str, std::collections::HashSet<String>>> = RefCell::new(Default::default()); }
#[cfg(test)]
pub(super) fn observed_target_ids(id: &str) -> Vec<String> {
    OBSERVATION_IDS.with(|ids| {
        ids.borrow()
            .get(id)
            .map(|ids| ids.iter().cloned().collect())
            .unwrap_or_default()
    })
}
#[cfg(test)]
fn record_observation_ids(id: &'static str, ids: impl IntoIterator<Item = String>) {
    OBSERVATION_IDS.with(|seen| seen.borrow_mut().entry(id).or_default().extend(ids));
}
#[cfg(test)]
pub(super) fn take_rendered_targets() -> std::collections::HashSet<&'static str> {
    OBSERVATION_IDS.with(|ids| ids.borrow_mut().clear());
    RENDERED.with(|seen| std::mem::take(&mut *seen.borrow_mut()))
}
#[cfg(test)]
fn record_rendered_target(id: &'static str) {
    RENDERED.with(|seen| {
        seen.borrow_mut().insert(id);
    });
}
thread_local! { static ACTIVE: RefCell<Option<Scope>> = const { RefCell::new(None) }; }
fn normalized(title: &str) -> String {
    title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}
struct Restore(Option<Scope>);
impl Drop for Restore {
    fn drop(&mut self) {
        ACTIVE.with(|active| *active.borrow_mut() = self.0.take());
    }
}
/// Settings renderers use shared row/header widgets. A scoped registry supplies
/// their anchors without global app state or any filesystem work from rendering.
pub(super) fn with_scope<T>(
    section: SettingsSection,
    anchors: Rc<HashMap<&'static str, ScrollAnchor>>,
    render: impl FnOnce() -> T,
) -> T {
    let mut labels = HashMap::new();
    for setting in SEARCHABLE_SETTINGS
        .iter()
        .filter(|setting| setting.section == section)
    {
        labels
            .entry(normalized(setting.title))
            .or_insert(setting.anchor_id);
        labels
            .entry(normalized(&setting.localized_title()))
            .or_insert(setting.anchor_id);
    }
    for (label, id) in [
        ("Automatic profile switching", "profileAutoSwitch"),
        ("Version Information", "about"),
        ("System Information", "aboutDiagnostics"),
        ("Recent Repositories", "repositoryMetadata"),
        ("Dangerous commands", "dangerousCommands"),
        ("Sixel protocol", "sixel"),
        ("Cmd+click opens paths and URLs", "cmdClick"),
        ("Ctrl+click opens paths and URLs", "cmdClick"),
        ("Open links in", "urlHandler"),
        ("Semantic scrollback search", "search"),
        ("Find: case sensitive by default", "findDefaults"),
        ("Indentation", "textEditor"),
        ("SSH Config Sync", "sshProfiles"),
        ("Status & Permissions", "notificationStatus"),
        ("AI Notification Essentials", "aiToolNotifications"),
        ("Long-Running (seconds)", "shellThresholds"),
        ("Inactivity (minutes)", "appThresholds"),
        ("Telemetry History", "telemetryRetention"),
        ("Font", "fontFamily"),
        ("Custom font", "fontFamily"),
        ("Size", "fontSize"),
        ("Appearance", "appTheme"),
        ("Colors", "colorScheme"),
        ("Inline images (imgcat)", "inlineImages"),
        ("ls colors (CLICOLOR, LSCOLORS)", "lsColors"),
        ("Blinking cursor", "cursorBlink"),
        ("Cursor", "cursor"),
        ("New Tabs Use Current Directory", "newTabDirectory"),
        (
            "Warn When Closing Tab with Running Process",
            "tabCloseWarnings",
        ),
        ("Always Warn Before Closing Tab", "tabCloseWarnings"),
        ("Group Idle Tabs in Dropdown", "groupIdleTabs"),
        ("Keyboard Navigation", "tabSwitchShortcut"),
        (
            "Mouse reporting (hold Shift to select text)",
            "mouseReporting",
        ),
        ("Option+click moves the cursor", "clickToPosition"),
        ("Keyboard and mouse", "shortcuts"),
        ("Settings Backup", "export"),
        ("Hover Card: Visible Sections", "hoverCardSections"),
        ("Custom Detection Rules", "aiCustomDetection"),
        ("Built-in AI CLI Detection", "aiDetection"),
        ("General", "mcpServer"),
        ("Enable MCP", "mcpServer"),
        ("Command Permissions", "mcpPermissions"),
        ("MCP Profiles", "mcpProfiles"),
        ("API Call Tracking", "apiAnalytics"),
        ("Optimization Mode", "ctoMode"),
        ("Input Prefix", "ctoPrefix"),
        ("Per-Tab Control", "ctoPerTab"),
        (
            "Restored scrollback when tabs are recovered",
            "restoredScrollback",
        ),
    ] {
        if let Some(setting) = SEARCHABLE_SETTINGS.iter().find(|setting| {
            (setting.id == id || setting.anchor_id == id) && setting.section == section
        }) {
            labels.entry(normalized(label)).or_insert(setting.anchor_id);
            labels
                .entry(normalized(&crate::l10n::tr(label)))
                .or_insert(setting.anchor_id);
        }
    }
    if section == SettingsSection::SnippetsTools {
        labels.insert(normalized("Permissions"), "permissions");
    }
    let previous = ACTIVE.with(|active| {
        active.replace(Some(Scope {
            section,
            anchors,
            labels,
        }))
    });
    let _restore = Restore(previous);
    render()
}
pub(super) fn for_title(title: &str) -> Option<ScrollAnchor> {
    ACTIVE.with(|active| {
        let scope = active.borrow();
        let scope = scope.as_ref()?;
        let id = scope.labels.get(&normalized(title))?;
        let (key, anchor) = scope.anchors.get_key_value(id)?;
        #[cfg(test)]
        {
            record_rendered_target(key);
            record_observation_ids(
                key,
                [
                    format!("setting-label-{}", normalized(title)),
                    format!("setting-header-{title}"),
                ],
            );
        }
        #[cfg(not(test))]
        let _ = key;
        Some(anchor.clone())
    })
}
pub(super) fn for_id(id: &str) -> Option<ScrollAnchor> {
    ACTIVE.with(|active| {
        let scope = active.borrow();
        let scope = scope.as_ref()?;
        let present = SEARCHABLE_SETTINGS
            .iter()
            .any(|setting| setting.section == scope.section && setting.anchor_id == id)
            || (id == "permissions" && scope.section == SettingsSection::SnippetsTools);
        if present {
            let (key, anchor) = scope.anchors.get_key_value(id)?;
            #[cfg(test)]
            {
                record_rendered_target(key);
                record_observation_ids(key, [format!("setting-anchor-{id}")]);
            }
            #[cfg(not(test))]
            let _ = key;
            Some(anchor.clone())
        } else {
            None
        }
    })
}
pub(super) fn target(id: &str, element: impl IntoElement) -> gpui::Div {
    let target = div()
        .id(SharedString::from(format!("setting-anchor-{id}")))
        .anchor_scroll(for_id(id))
        .child(element);
    #[cfg(test)]
    let target = {
        use gpui_kit::test::TestSupportExt;
        target.test_support()
    };
    div().child(target)
}

pub(super) fn label_target(label: &str, element: impl IntoElement) -> gpui::Div {
    let target = div()
        .id(SharedString::from(format!(
            "setting-label-{}",
            normalized(label)
        )))
        .anchor_scroll(for_title(label))
        .child(element);
    #[cfg(test)]
    let target = {
        use gpui_kit::test::TestSupportExt;
        target.test_support()
    };
    div().child(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn anchors() -> Rc<HashMap<&'static str, ScrollAnchor>> {
        let handle = gpui::ScrollHandle::new();
        Rc::new(
            SEARCHABLE_SETTINGS
                .iter()
                .map(|setting| (setting.anchor_id, ScrollAnchor::for_handle(handle.clone())))
                .chain(std::iter::once((
                    "permissions",
                    ScrollAnchor::for_handle(handle.clone()),
                )))
                .collect(),
        )
    }
    #[test]
    fn title_aliases_are_section_scoped_and_scopes_restore() {
        assert!(for_title("Font").is_none());
        let anchors = anchors();
        with_scope(SettingsSection::FontColors, anchors.clone(), || {
            assert!(for_title("  FONT  ").is_some());
            assert!(for_title("Appearance").is_none());
            with_scope(SettingsSection::Windows, anchors.clone(), || {
                assert!(for_title("Appearance").is_some());
                assert!(for_title("Font").is_none());
                assert!(for_id("windowBlur").is_some());
            });
            assert!(for_title("Font").is_some());
        });
        assert!(for_title("Font").is_none());
        with_scope(SettingsSection::SnippetsTools, anchors, || {
            assert!(for_id("permissions").is_some())
        });
    }
}
