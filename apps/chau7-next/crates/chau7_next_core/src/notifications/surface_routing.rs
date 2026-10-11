//! Eligibility policy from current Swift NotificationRoutingPolicy.
//! Platform/user/permission gates remain downstream. No relay sends here.
use super::canonical::NotificationSemanticKind as Kind;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Surface {
    MacLocal,
    TabStyle,
    IosPush,
    LiveActivity,
    McpSubscribers,
}
#[derive(Debug, Clone, Copy)]
pub struct Settings {
    pub push_task_completions: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            push_task_completions: true,
        }
    }
}
pub fn surfaces(kind: Kind, settings: Settings) -> Vec<Surface> {
    use Surface as S;
    match kind {
        Kind::PermissionRequired | Kind::WaitingForInput | Kind::AttentionRequired => vec![
            S::MacLocal,
            S::TabStyle,
            S::IosPush,
            S::LiveActivity,
            S::McpSubscribers,
        ],
        Kind::TaskFinished | Kind::TaskFailed => {
            let mut result = vec![S::MacLocal, S::TabStyle, S::LiveActivity, S::McpSubscribers];
            if settings.push_task_completions {
                result.push(S::IosPush)
            }
            result
        }
        Kind::Idle | Kind::AuthenticationSucceeded | Kind::ToolFailed | Kind::Informational => {
            vec![S::MacLocal, S::TabStyle, S::McpSubscribers]
        }
        Kind::Unknown => vec![],
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn current_semantic_surface_matrix_is_explicit() {
        for kind in Kind::ALL {
            let default = surfaces(kind, Settings::default());
            let disabled = surfaces(
                kind,
                Settings {
                    push_task_completions: false,
                },
            );
            assert_eq!(
                default.contains(&Surface::McpSubscribers),
                kind != Kind::Unknown
            );
            if matches!(kind, Kind::TaskFinished | Kind::TaskFailed) {
                assert!(default.contains(&Surface::IosPush));
                assert!(!disabled.contains(&Surface::IosPush));
            } else {
                assert_eq!(default, disabled);
            }
            assert_eq!(
                default.contains(&Surface::LiveActivity),
                matches!(
                    kind,
                    Kind::TaskFinished
                        | Kind::TaskFailed
                        | Kind::PermissionRequired
                        | Kind::WaitingForInput
                        | Kind::AttentionRequired
                )
            );
        }
    }
}
