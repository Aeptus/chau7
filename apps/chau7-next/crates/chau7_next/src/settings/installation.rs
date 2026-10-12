//! Positive first-install detection precedes every normal startup write.
//! Existing/uncertain profiles retain the legacy zero-day default. Configs
//! and histories are never rewritten to establish a new-install default.
use std::io::{Read, Write};

use chau7_next_core::data_root::DataRoot;

const POLICY: &[u8] = b"chau7-next-installation-v1\ntelemetry_retention_days=30\n";

pub(crate) struct FreshInstallation {
    root: DataRoot,
    positive: bool,
}
impl FreshInstallation {
    pub(crate) fn capture(root: &DataRoot) -> Self {
        Self {
            root: root.clone(),
            positive: [root.config_dir(), root.state_dir()]
                .into_iter()
                .all(|path| {
                    std::fs::symlink_metadata(path)
                        .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
                }),
        }
    }

    /// Call only after acquiring this root's instance lock, before other
    /// startup writers. Revalidate that nobody populated the fresh profile.
    pub(crate) fn initialize(self) -> std::io::Result<bool> {
        if !self.positive {
            return Ok(false);
        }
        for (directory, allowed) in [
            (self.root.config_dir(), Vec::new()),
            (
                self.root.state_dir(),
                vec![
                    self.root.instance_lock_file(),
                    self.root.instance_lock_file().with_extension("owner.json"),
                ],
            ),
        ] {
            if !std::fs::symlink_metadata(directory)?.file_type().is_dir() {
                return Ok(false);
            }
            for entry in std::fs::read_dir(directory)? {
                let entry = entry?;
                if !allowed.contains(&entry.path()) || !entry.file_type()?.is_file() {
                    return Ok(false);
                }
            }
        }
        let mut file = match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.root.installation_policy_file())
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
            Err(error) => return Err(error),
        };
        if let Err(error) = file.write_all(POLICY).and_then(|()| file.sync_all()) {
            // Leave this newly created descriptor invalid on write failure;
            // never delete or overwrite a concurrently replaced policy path.
            let _ = file.set_len(0);
            return Err(error);
        }
        Ok(true)
    }
}

pub(super) fn retention_default(root: &DataRoot) -> i64 {
    let path = root.installation_policy_file();
    let result = (|| {
        if !std::fs::symlink_metadata(&path)?.file_type().is_file() {
            return Ok(false);
        }
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NONBLOCK);
        }
        let file = options.open(path)?;
        if !file.metadata()?.is_file() {
            return Ok(false);
        }
        let mut content = Vec::new();
        file.take(POLICY.len() as u64 + 1)
            .read_to_end(&mut content)?;
        Ok::<_, std::io::Error>(content == POLICY)
    })();
    match result {
        Ok(true) => 30,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
        _ => {
            log::warn!("Installation retention policy unavailable; preserving legacy default");
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Settings;

    fn root(label: &str) -> DataRoot {
        DataRoot::with_home(
            std::env::temp_dir().join(format!(
                "chau7-next-install-policy-{label}-{}",
                uuid::Uuid::new_v4()
            )),
            true,
        )
    }
    fn initialize(root: &DataRoot) {
        let captured = FreshInstallation::capture(root);
        root.ensure_dirs().unwrap();
        let acquisition = chau7_next_core::instance::InstanceGuard::acquire(
            &root.instance_lock_file(),
            root.launch_continuity_file(),
        )
        .unwrap();
        let chau7_next_core::instance::Acquisition::Acquired(lock) = acquisition else {
            panic!("owned fresh lock must be available")
        };
        assert!(captured.initialize().unwrap());
        drop(lock);
    }
    #[test]
    fn positive_fresh_install_has_durable_thirty_days_without_a_config_write() {
        let root = root("fresh");
        initialize(&root);
        assert!(!root.config_file().exists());
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 30);
        assert!(!FreshInstallation::capture(&root).initialize().unwrap());
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 30);
        assert!(!root.config_file().exists());
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn any_existing_profile_even_empty_or_without_a_key_stays_unchanged() {
        for (index, text) in [
            None,
            Some(""),
            Some("[next]\nusage_monitoring = false\n"),
            Some("[next]\ntelemetry_retention_days = 0\n"),
            Some("[next]\ntelemetry_retention_days = 91\n"),
        ]
        .into_iter()
        .enumerate()
        {
            let root = root(&format!("old-{index}"));
            root.ensure_dirs().unwrap();
            if let Some(text) = text {
                std::fs::write(root.config_file(), text).unwrap();
            }
            std::fs::write(root.history_db(), b"owned preexisting history bytes").unwrap();
            assert!(!FreshInstallation::capture(&root).initialize().unwrap());
            assert_eq!(
                Settings::load(&root).general.telemetry_retention_days,
                if index == 4 { 91 } else { 0 }
            );
            assert!(!root.installation_policy_file().exists());
            assert_eq!(
                std::fs::read(root.history_db()).unwrap(),
                b"owned preexisting history bytes"
            );
            if let Some(text) = text {
                assert_eq!(std::fs::read(root.config_file()).unwrap(), text.as_bytes());
            } else {
                assert!(!root.config_file().exists());
            }
            std::fs::remove_dir_all(root.home()).unwrap();
        }
    }
    #[test]
    fn explicit_new_profile_settings_override_marker_without_rewriting_bytes() {
        let root = root("explicit");
        initialize(&root);
        for (text, expected) in [
            ("[next]\ntelemetry_retention_days = 0\n", 0),
            ("[next]\ntelemetry_retention_days = 91\n", 91),
            ("[next]\ntelemetry_retention_days = -1\n", 0),
            ("[next]\ntelemetry_retention_days = 9999\n", 3650),
            ("[next]\ntelemetry_retention_days = 'invalid'\n", 0),
            (
                "# imported owned config\n[general]\nshell = '/bin/sh'\n",
                30,
            ),
        ] {
            std::fs::write(root.config_file(), text).unwrap();
            assert_eq!(
                Settings::load(&root).general.telemetry_retention_days,
                expected
            );
            assert_eq!(std::fs::read(root.config_file()).unwrap(), text.as_bytes());
        }
        std::fs::remove_file(root.config_file()).unwrap();
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 30);
        std::fs::create_dir(root.config_file()).unwrap();
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 0);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn local_resets_and_portable_imports_preserve_installation_policy_and_explicit_choices() {
        for fresh in [false, true] {
            let root = root("resets");
            if fresh {
                initialize(&root);
            } else {
                root.ensure_dirs().unwrap();
            }
            let factory = if fresh { 30 } else { 0 };
            let mut settings = Settings::load(&root);
            settings.general.telemetry_retention_days = 91;
            let partial =
                Settings::from_profile_text_local("[next]\nusage_monitoring = false\n", &settings);
            assert_eq!(partial.general.telemetry_retention_days, 91);
            for value in [0, 61] {
                let mut imported = Settings::from_profile_text_local(
                    &format!("[next]\ntelemetry_retention_days = {value}\n"),
                    &settings,
                );
                assert_eq!(imported.general.telemetry_retention_days, value);
                imported.reset_section(chau7_next_core::settings_search::SettingsSection::General);
                assert_eq!(imported.general.telemetry_retention_days, factory);
                imported.general.telemetry_retention_days = 91;
                imported.reset_all();
                assert_eq!(imported.general.telemetry_retention_days, factory);
            }
            for malformed in [
                "[next",
                "[next]\ntelemetry_retention_days 30\n",
                "[next]\ntelemetry_retention_days = ",
            ] {
                std::fs::write(root.config_file(), malformed).unwrap();
                let mut loaded = Settings::load(&root);
                assert_eq!(loaded.general.telemetry_retention_days, 0);
                loaded.reset_all();
                assert_eq!(loaded.general.telemetry_retention_days, 0);
                assert_eq!(
                    std::fs::read_to_string(root.config_file()).unwrap(),
                    malformed
                );
            }
            std::fs::remove_dir_all(root.home()).unwrap();
        }
    }

    #[test]
    fn valid_native_config_shortcut_keys_and_legacy_comments_preserve_retention() {
        let root = root("legacy-syntax");
        initialize(&root);
        let config = "[keybindings]\ncmd+shift+q = \"newTab\" // owned legacy comment\n[next]\ntelemetry_retention_days = 91\n// duplicate keys use last numeric value\ntelemetry_retention_days = 61\n";
        std::fs::write(root.config_file(), config).unwrap();
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 61);
        let settings = Settings::load(&root);
        assert!(chau7_next_core::config::is_valid_config(
            &settings.to_profile_text()
        ));
        assert_eq!(std::fs::read_to_string(root.config_file()).unwrap(), config);
        std::fs::remove_dir_all(root.home()).unwrap();
    }

    #[test]
    fn late_population_or_preexisting_policy_never_gets_overwritten() {
        for marker in [false, true] {
            let root = root("race");
            let captured = FreshInstallation::capture(&root);
            root.ensure_dirs().unwrap();
            let path = if marker {
                root.installation_policy_file()
            } else {
                root.config_file()
            };
            std::fs::write(&path, b"owned raced bytes").unwrap();
            assert!(!captured.initialize().unwrap());
            assert_eq!(std::fs::read(&path).unwrap(), b"owned raced bytes");
            assert_eq!(Settings::load(&root).general.telemetry_retention_days, 0);
            std::fs::remove_dir_all(root.home()).unwrap();
        }
    }
    #[test]
    fn existing_one_root_or_non_directory_and_invalid_policy_are_conservative() {
        for state in [false, true] {
            let root = root("one-existing");
            std::fs::create_dir_all(if state {
                root.state_dir()
            } else {
                root.config_dir()
            })
            .unwrap();
            let captured = FreshInstallation::capture(&root);
            root.ensure_dirs().unwrap();
            assert!(!captured.initialize().unwrap());
            assert_eq!(Settings::load(&root).general.telemetry_retention_days, 0);
            std::fs::remove_dir_all(root.home()).unwrap();
        }
        let root = root("invalid-policy");
        initialize(&root);
        std::fs::write(root.installation_policy_file(), b"truncated").unwrap();
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 0);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn late_non_directory_and_symlink_roots_cannot_establish_a_policy() {
        let root = root("late-file");
        let captured = FreshInstallation::capture(&root);
        std::fs::create_dir_all(root.config_dir()).unwrap();
        std::fs::write(root.state_dir(), b"owned non-directory state").unwrap();
        assert!(!captured.initialize().unwrap());
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 0);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn existing_symlink_is_not_positive_fresh_even_when_target_is_empty() {
        let root = root("symlink-root");
        let target = root.home().join("owned-target");
        std::fs::create_dir_all(&target).unwrap();
        std::os::unix::fs::symlink(&target, root.config_dir()).unwrap();
        assert!(!FreshInstallation::capture(&root).initialize().unwrap());
        assert_eq!(Settings::load(&root).general.telemetry_retention_days, 0);
        std::fs::remove_dir_all(root.home()).unwrap();
    }
    #[test]
    fn automatic_retention_and_compaction_run_inside_existing_background_worker() {
        let source = include_str!("../usage.rs");
        let source = &source[source.find("pub fn refresh_latency(").unwrap()..];
        let background = source.find("cx.background_executor()").unwrap();
        let retention = source.find(".prune_retained(").unwrap();
        assert!(background < retention);
        assert!(source[..retention].contains(".spawn(async move"));
        assert!(source[..retention].contains("if retention_days > 0"));
    }
    #[test]
    fn startup_calls_capture_before_writes_and_initialize_only_after_lock() {
        let main = include_str!("../main.rs");
        let capture = main.find("FreshInstallation::capture(&root)").unwrap();
        let ensure = main.find("root.ensure_dirs()").unwrap();
        let lock = main.find("instance::acquire(&root)").unwrap();
        let initialize = main.find("installation.initialize()").unwrap();
        let logging = main.find("logging::init(&root)").unwrap();
        assert!(capture < ensure && ensure < lock && lock < initialize && initialize < logging);
    }
}
