//! Port of `apps/chau7-macos/Sources/Chau7Core/DirectoryPathMatcher.swift`.

/// Lexically standardizes a path like `URL(fileURLWithPath:).standardized.path`:
/// relative paths resolve against the current directory, `.` and empty
/// segments are dropped, `..` pops a segment and a trailing slash goes away.
fn standardized_path(path: &str) -> String {
    let absolute = if path.starts_with('/') {
        path.to_string()
    } else {
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string());
        format!("{cwd}/{path}")
    };
    let mut parts: Vec<&str> = Vec::new();
    for segment in absolute.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

/// Returns a rank describing how closely two directory paths match
/// (`DirectoryPathMatcher.bidirectionalPrefixRank`). `Some(0)` means exact
/// match, `Some(1)` means one directory is nested inside the other and `None`
/// means unrelated.
pub fn bidirectional_prefix_rank(target_path: &str, candidate_path: &str) -> Option<u8> {
    let target = standardized_path(target_path);
    let candidate = standardized_path(candidate_path);
    if target.is_empty() || candidate.is_empty() {
        return None;
    }
    if target == candidate {
        return Some(0);
    }
    if target.starts_with(&format!("{candidate}/")) || candidate.starts_with(&format!("{target}/"))
    {
        return Some(1);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bidirectional_prefix_rank_matches_exact_directory() {
        assert_eq!(
            bidirectional_prefix_rank("/tmp/chau7", "/tmp/chau7"),
            Some(0)
        );
    }

    #[test]
    fn bidirectional_prefix_rank_matches_nested_directories_in_either_direction() {
        assert_eq!(
            bidirectional_prefix_rank("/tmp/chau7", "/tmp/chau7/apps/chau7-macos"),
            Some(1)
        );
        assert_eq!(
            bidirectional_prefix_rank("/tmp/chau7/apps/chau7-macos", "/tmp/chau7"),
            Some(1)
        );
    }

    #[test]
    fn bidirectional_prefix_rank_standardizes_paths_before_comparing() {
        assert_eq!(
            bidirectional_prefix_rank("/tmp/chau7/../chau7", "/tmp/chau7"),
            Some(0)
        );
    }

    #[test]
    fn bidirectional_prefix_rank_rejects_unrelated_directories() {
        assert_eq!(bidirectional_prefix_rank("/tmp/chau7", "/tmp/mockup"), None);
    }

    #[test]
    fn bidirectional_prefix_rank_does_not_match_sibling_with_shared_prefix() {
        assert_eq!(
            bidirectional_prefix_rank("/tmp/chau7", "/tmp/chau7-next"),
            None
        );
    }

    #[test]
    fn bidirectional_prefix_rank_ignores_trailing_slash() {
        assert_eq!(
            bidirectional_prefix_rank("/tmp/chau7/", "/tmp/chau7"),
            Some(0)
        );
    }
}
