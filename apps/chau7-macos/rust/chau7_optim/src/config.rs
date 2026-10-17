use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub tracking: TrackingConfig,
    #[serde(default)]
    pub tee: crate::tee::TeeConfig,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct TrackingConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database_path: Option<PathBuf>,
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = get_config_path()?;

        if path.exists() {
            let content = std::fs::read_to_string(&path)?;
            let config: Config = toml::from_str(&content)?;
            Ok(config)
        } else {
            Ok(Config::default())
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = get_config_path()?;

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let content = toml::to_string_pretty(self)?;
        std::fs::write(&path, content)?;
        Ok(())
    }

    pub fn create_default() -> Result<PathBuf> {
        let config = Config::default();
        config.save()?;
        get_config_path()
    }
}

fn get_config_path() -> Result<PathBuf> {
    let config_dir = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
    Ok(config_dir.join("rtk").join("config.toml"))
}

pub fn show_config() -> Result<()> {
    let path = get_config_path()?;
    println!("Config: {}", path.display());
    println!();

    if path.exists() {
        let config = Config::load()?;
        println!("{}", toml::to_string_pretty(&config)?);
    } else {
        println!("(default config, file not created)");
        println!();
        let config = Config::default();
        println!("{}", toml::to_string_pretty(&config)?);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tee::TeeMode;

    #[test]
    fn updated_toml_preserves_default_config_bytes() {
        assert_eq!(toml::to_string_pretty(&Config::default()).unwrap(),
            "[tracking]\n\n[tee]\nenabled = true\nmode = \"failures\"\nmax_files = 20\nmax_file_size = 1048576\n");
    }

    #[test]
    fn updated_toml_keeps_explicit_disabled_zero_unicode_and_escaped_paths() {
        // Pure parse/serialize: never uses load/save or the user's config root.
        let source = r#"[tracking]
database_path = 'synthetic/été.sqlite'
[tee]
enabled = false
mode = "never"
max_files = 0
max_file_size = 0
directory = 'synthetic\quoted"directory'
"#;
        let parsed: Config = toml::from_str(source).unwrap();
        assert!(!parsed.tee.enabled);
        assert_eq!(parsed.tee.mode, TeeMode::Never);
        assert_eq!(parsed.tee.max_files, 0);
        assert_eq!(parsed.tee.max_file_size, 0);
        assert_eq!(
            parsed.tracking.database_path.as_deref(),
            Some(std::path::Path::new("synthetic/été.sqlite"))
        );
        let output = toml::to_string_pretty(&parsed).unwrap();
        let reopened: Config = toml::from_str(&output).unwrap();
        assert_eq!(
            reopened.tracking.database_path,
            parsed.tracking.database_path
        );
        assert_eq!(reopened.tee.directory, parsed.tee.directory);
        assert_eq!(toml::to_string_pretty(&reopened).unwrap(), output);
        assert!(toml::from_str::<Config>("[tee]\nenabled = true\nenabled = false\n").is_err());
        assert!(toml::from_str::<Config>("[tee]\nenabled = [\n").is_err());
    }
}
