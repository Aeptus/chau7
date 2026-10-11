//! Current Swift restore freshness and integrity contracts, without I/O.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceDecision {
    BundleCurrent,
    BundleAheadOfIndex,
    IndexCurrent,
}

pub fn source_decision(
    bundle: Option<&str>,
    previous: Option<&str>,
    index: Option<&str>,
) -> SourceDecision {
    let Some(index) = index else {
        return SourceDecision::BundleCurrent;
    };
    let Some(bundle) = bundle else {
        return SourceDecision::IndexCurrent;
    };
    if bundle == index {
        SourceDecision::BundleCurrent
    } else if previous == Some(index) {
        SourceDecision::BundleAheadOfIndex
    } else {
        SourceDecision::IndexCurrent
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextRef {
    pub sha256: String,
    pub byte_count: usize,
}
impl ContextRef {
    pub fn new(bytes: &[u8]) -> Self {
        Self {
            sha256: format!("{:x}", Sha256::digest(bytes)),
            byte_count: bytes.len(),
        }
    }
    pub fn valid_name(&self) -> bool {
        self.sha256.len() == 64
            && self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }
    pub fn verifies(&self, bytes: &[u8]) -> bool {
        self.valid_name() && self == &Self::new(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn equality_not_timestamp_proves_freshness() {
        assert_eq!(
            source_decision(Some("a"), None, Some("a")),
            SourceDecision::BundleCurrent
        );
        assert_eq!(
            source_decision(Some("b"), Some("a"), Some("a")),
            SourceDecision::BundleAheadOfIndex
        );
        assert_eq!(
            source_decision(Some("b"), Some("older"), Some("a")),
            SourceDecision::IndexCurrent
        );
        assert_eq!(
            source_decision(None, None, Some("a")),
            SourceDecision::IndexCurrent
        );
        assert_eq!(
            source_decision(Some("a"), None, None),
            SourceDecision::BundleCurrent
        );
    }
    #[test]
    fn immutable_context_requires_exact_bytes_and_safe_digest() {
        let reference = ContextRef::new("résumé\n".as_bytes());
        assert!(reference.verifies("résumé\n".as_bytes()));
        assert!(!reference.verifies("résumé!".as_bytes()));
        assert!(
            !ContextRef {
                sha256: "../escape".into(),
                byte_count: 0
            }
            .valid_name()
        );
        assert!(
            !ContextRef {
                sha256: "A".repeat(64),
                byte_count: 0
            }
            .valid_name()
        );
    }
}
