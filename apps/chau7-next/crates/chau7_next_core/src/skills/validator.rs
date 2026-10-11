//! Source validation intentionally accepts unknown/provider-specific frontmatter keys.
use super::models::*;
use std::{collections::BTreeMap, path::Path};
pub fn valid_name(v: &str) -> bool {
    !v.is_empty()
        && !v.starts_with('-')
        && !v.ends_with('-')
        && !v.contains("--")
        && v.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}
pub fn validate(root: &Path) -> Vec<Issue> {
    if !root.exists() {
        return vec![Issue::error(
            "missing-folder",
            "Skill folder does not exist.",
            root,
        )];
    }
    if !root.is_dir() {
        return vec![Issue::error(
            "skill-path-not-folder",
            "Skill path must be a folder.",
            root,
        )];
    }
    let path = root.join("SKILL.md");
    let mut issues = Vec::new();
    if !path.is_file() {
        issues.push(Issue::error(
            "missing-skill-md",
            "SKILL.md is required.",
            &path,
        ));
    } else {
        match std::fs::read_to_string(&path) {
            Err(_) => issues.push(Issue::error(
                "unreadable-skill-md",
                "SKILL.md could not be read as UTF-8.",
                &path,
            )),
            Ok(content) => match frontmatter(&content) {
                Err((code, message)) => issues.push(Issue::error(code, message, &path)),
                Ok(values) => {
                    let name = values.get("name").map(|v| v.trim()).unwrap_or("");
                    if name.is_empty() {
                        issues.push(Issue::error(
                            "missing-name",
                            "SKILL.md frontmatter must include a non-empty name.",
                            &path,
                        ));
                    } else if !valid_name(name) {
                        issues.push(Issue::error(
                            "invalid-name",
                            "Skill name must be lowercase kebab-case.",
                            &path,
                        ));
                    } else if root.file_name().and_then(|s| s.to_str()) != Some(name) {
                        issues.push(Issue::error(
                            "directory-name-mismatch",
                            "Skill folder name must match the SKILL.md frontmatter name.",
                            root,
                        ));
                    }
                    if values
                        .get("description")
                        .is_none_or(|v| v.trim().is_empty())
                    {
                        issues.push(Issue::error(
                            "missing-description",
                            "SKILL.md frontmatter must include a non-empty description.",
                            &path,
                        ));
                    }
                }
            },
        }
    }
    for name in ["assets", "references", "scripts"] {
        let path = root.join(name);
        if path.exists() && !path.is_dir() {
            issues.push(Issue::error(
                "optional-path-not-directory",
                format!("{name} must be a directory when present."),
                path,
            ));
        }
    }
    issues
}
pub fn frontmatter(
    content: &str,
) -> Result<BTreeMap<String, String>, (&'static str, &'static str)> {
    let mut lines = content.trim_start_matches('\u{feff}').lines();
    if lines.next().map(str::trim) != Some("---") {
        return Err((
            "missing-frontmatter",
            "SKILL.md must start with YAML frontmatter.",
        ));
    }
    let mut values = BTreeMap::new();
    for line in lines {
        let line = line.trim();
        if line == "---" {
            return Ok(values);
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once(':') {
            let key = key.trim().to_lowercase();
            let mut value = value.trim();
            if value.len() >= 2
                && ((value.starts_with('"') && value.ends_with('"'))
                    || (value.starts_with('\'') && value.ends_with('\'')))
            {
                value = &value[1..value.len() - 1];
            }
            if !key.is_empty() {
                values.insert(key, value.to_string());
            }
        }
    }
    Err((
        "unterminated-frontmatter",
        "SKILL.md YAML frontmatter must end with ---.",
    ))
}
