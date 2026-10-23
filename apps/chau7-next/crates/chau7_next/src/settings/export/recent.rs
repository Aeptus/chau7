//! External recent-root registry projection into the current Swift settings JSON.
//! This is distinct from the fifty-item metadata store and is never a Settings copy.
use super::Settings;
use serde_json::{Value, json};
use std::{
    fs::OpenOptions,
    io::{self, Read},
    path::Path,
};

pub const MAX_SETTINGS_BYTES: usize = 8 * 1024 * 1024;

pub fn export_json_with_recent(
    settings: &Settings,
    home: &str,
    roots: &[String],
) -> Result<String, String> {
    let mut value: Value = serde_json::from_str(&super::export_json(settings, home))
        .map_err(|error| error.to_string())?;
    value
        .as_object_mut()
        .ok_or("Settings document must be an object")?
        .insert("recentRepoRoots".into(), json!(roots));
    let text = serde_json::to_string_pretty(&value).map_err(|error| error.to_string())?;
    validate_document_size(&text)?;
    Ok(text)
}

pub fn validate_document_size(text: &str) -> Result<(), String> {
    if text.len() > MAX_SETTINGS_BYTES {
        return Err("Settings document exceeds the eight MiB limit".into());
    }
    Ok(())
}

/// Validate the entire document before returning any external registry mutation.
pub fn import_json_with_recent(
    settings: &mut Settings,
    text: &str,
    home: &str,
) -> Result<Option<Vec<String>>, String> {
    validate_document_size(text)?;
    super::import_json(settings, text, home)?;
    Ok(recent_roots_from_json(text))
}

/// Call only after typed settings/version/freshness validation succeeds.
/// Swift assigns the imported array as-is; only recording a new root caps it.
pub fn recent_roots_from_json(text: &str) -> Option<Vec<String>> {
    validate_document_size(text).ok()?;
    let value: Value = serde_json::from_str(text).ok()?;
    serde_json::from_value(value.get("recentRepoRoots")?.clone()).ok()
}

/// File picker and registry worker only; no blocking reads in GPUI callbacks.
pub fn read_settings_document(path: &Path) -> io::Result<String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Settings input must be a regular file",
        ));
    }
    if metadata.len() > MAX_SETTINGS_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Settings document exceeds the eight MiB limit",
        ));
    }
    let mut text = String::new();
    file.take(MAX_SETTINGS_BYTES as u64 + 1)
        .read_to_string(&mut text)?;
    validate_document_size(&text)
        .map_err(|reason| io::Error::new(io::ErrorKind::InvalidData, reason))?;
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    #[test]
    fn external_recent_roots_replace_template_without_normalizing_or_truncating() {
        let mut settings = Settings::default();
        settings.appearance.font_size = 17.0;
        let mut roots: Vec<_> = (0..25).map(|i| format!("/repo/{i}/./")).collect();
        roots.push(roots[0].clone());
        let text = export_json_with_recent(&settings, "/home/test", &roots).unwrap();
        assert_eq!(recent_roots_from_json(&text), Some(roots));
        let mut restored = Settings::default();
        super::super::import_json(&mut restored, &text, "/home/test").unwrap();
        assert_eq!(restored.appearance.font_size, 17.0);
    }
    #[test]
    fn missing_and_invalid_recent_arrays_preserve_the_registry_but_empty_clears() {
        for text in [
            "{}",
            "{\"recentRepoRoots\":null}",
            "{\"recentRepoRoots\":1}",
            "{\"recentRepoRoots\":[\"/a\",1]}",
        ] {
            assert_eq!(recent_roots_from_json(text), None);
        }
        assert_eq!(
            recent_roots_from_json("{\"recentRepoRoots\":[]}"),
            Some(vec![])
        );
    }
    #[test]
    fn bounded_file_reader_rejects_oversized_input() {
        let path = std::env::temp_dir().join(format!("c7n-settings-size-{}", uuid::Uuid::new_v4()));
        let file = File::create(&path).unwrap();
        file.set_len(MAX_SETTINGS_BYTES as u64 + 1).unwrap();
        drop(file);
        assert_eq!(
            read_settings_document(&path).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        std::fs::write(&path, b"{\"fontFamily\":\"SF Mono\"}").unwrap();
        assert!(
            read_settings_document(&path)
                .unwrap()
                .contains("fontFamily")
        );
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn recent_import_is_returned_only_after_whole_document_validation() {
        let mut settings = Settings::default();
        settings.appearance.font_size = 19.0;
        for document in [
            json!({"recentRepoRoots":["/must-not-apply"]}),
            json!({"fontFamily":"SF Mono","recentRepoRoots":["/must-not-apply"],"chau7Next":{"version":2,"config":""}}),
        ] {
            assert!(
                import_json_with_recent(&mut settings, &document.to_string(), "/home/test")
                    .is_err()
            );
            assert_eq!(settings.appearance.font_size, 19.0);
        }
        let valid =
            json!({"fontFamily":"SF Mono","recentRepoRoots":["/first","/first","/second/./"]});
        assert_eq!(
            import_json_with_recent(&mut settings, &valid.to_string(), "/home/test").unwrap(),
            Some(vec!["/first".into(), "/first".into(), "/second/./".into()])
        );
        assert_eq!(
            import_json_with_recent(&mut settings, "{\"fontFamily\":\"SF Mono\"}", "/home/test")
                .unwrap(),
            None
        );
    }
    /// Every field of the former Swift app's `ExportableSettings` document,
    /// so documents stay compatible with settings files that app exported.
    const SHARED_EXPORT_FIELDS: [&str; 117] = [
        "fontFamily",
        "fontSize",
        "defaultZoomPercent",
        "colorSchemeName",
        "customColorScheme",
        "shellType",
        "customShellPath",
        "startupCommand",
        "isLsColorsEnabled",
        "customShortcuts",
        "isShortcutHelperHintEnabled",
        "notificationTriggerState",
        "notificationFilters",
        "triggerActionBindings",
        "notificationRateLimitConfig",
        "triggerConditions",
        "groupActionBindings",
        "groupConditions",
        "findCaseSensitiveDefault",
        "findRegexDefault",
        "lastTabCloseBehavior",
        "newTabPosition",
        "newTabsUseCurrentDirectory",
        "alwaysShowTabBar",
        "alwaysShowToolbarInFullscreen",
        "appTheme",
        "launchAtLogin",
        "menuBarOnlyMode",
        "windowFloating",
        "appLanguage",
        "windowOpacity",
        "windowBlurEnabled",
        "enableLigatures",
        "cursorStyle",
        "cursorBlink",
        "scrollbackLines",
        "shellHistoryMaxLines",
        "restoredScrollbackLines",
        "bellEnabled",
        "bellSound",
        "isDangerousCommandHighlightEnabled",
        "dangerousCommandHighlightScope",
        "dangerousCommandPatterns",
        "dangerousCommandProtectChau7Enabled",
        "dangerousCommandProtectChau7Level",
        "dangerousCommandProtectedProcessPatterns",
        "dangerousOutputHighlightIdleDelayMs",
        "dangerousOutputHighlightMaxIntervalMs",
        "dangerousOutputHighlightLowPowerEnabled",
        "defaultStartDirectory",
        "isAutoTabThemeEnabled",
        "showTabIcons",
        "showTabPath",
        "showTabGitIndicator",
        "showTabCTOIndicator",
        "allowTabCTOToggle",
        "showTabBroadcastIndicator",
        "showProviderHealthBorder",
        "hoverCardShowDirectory",
        "hoverCardShowGitBranch",
        "hoverCardShowShellIntegration",
        "hoverCardShowDevServer",
        "hoverCardShowLastCommand",
        "hoverCardShowAISession",
        "hoverCardShowRepoStats",
        "hoverCardShowProcesses",
        "hoverCardShowTokenOptimization",
        "hoverCardShowBroadcast",
        "hoverCardShowConflicts",
        "hoverCardShowNotificationState",
        "hoverCardShowFooter",
        "customTitleOnly",
        "isCopyOnSelectEnabled",
        "isLineTimestampsEnabled",
        "timestampFormat",
        "isLastCommandBadgeEnabled",
        "isCmdClickPathsEnabled",
        "cmdClickOpensInternalEditor",
        "isOptionClickCursorEnabled",
        "defaultEditor",
        "urlHandler",
        "activePollingRateCap",
        "customAIDetectionRules",
        "isBroadcastEnabled",
        "isClipboardHistoryEnabled",
        "clipboardHistoryMaxItems",
        "isBookmarksEnabled",
        "maxBookmarksPerTab",
        "isSnippetsEnabled",
        "isRepoSnippetsEnabled",
        "allowProtectedFolderAccess",
        "recentRepoRoots",
        "repoSnippetPath",
        "snippetInsertMode",
        "snippetPlaceholdersEnabled",
        "isSyntaxHighlightEnabled",
        "isClickableURLsEnabled",
        "isInlineImagesEnabled",
        "isJSONPrettyPrintEnabled",
        "isSemanticSearchEnabled",
        "isSplitPanesEnabled",
        "keybindingPreset",
        "mcpEnabled",
        "mcpMaxTabs",
        "mcpRequiresApproval",
        "mcpShowTabIndicator",
        "mcpPermissionMode",
        "mcpAllowedCommands",
        "mcpBlockedCommands",
        "mcpProfiles",
        "isRemoteEnabled",
        "remoteRelayURL",
        "isCTOEnabled",
        "ctoPrefix",
        "ctoTabOverrides",
        "exportVersion",
        "exportedAt",
    ];

    #[test]
    fn shared_document_contains_every_shared_export_field() {
        let value: Value = serde_json::from_str(
            &export_json_with_recent(&Settings::default(), "/home/test", &[]).unwrap(),
        )
        .unwrap();
        for field in SHARED_EXPORT_FIELDS {
            assert!(
                value.get(field).is_some(),
                "Missing shared export field {field}"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn bounded_reader_refuses_pipe_input_without_waiting_for_a_writer() {
        use std::os::unix::ffi::OsStrExt;
        let path = std::env::temp_dir().join(format!("c7n-settings-pipe-{}", uuid::Uuid::new_v4()));
        let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: temporary owned fixture path, valid NUL-terminated bytes.
        assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);
        let result = read_settings_document(&path);
        std::fs::remove_file(&path).unwrap();
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidData);
    }
}
