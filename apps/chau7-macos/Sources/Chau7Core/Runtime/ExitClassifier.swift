import Foundation

/// Why a turn ended. Used in `turn_completed` event data.
public enum TurnExitReason: String, Codable, Sendable {
    case success           // Normal completion
    case error             // Agent reported error
    case interrupted       // Ctrl+C or external interrupt
    case approvalDenied    = "approval_denied"  // User/orchestrator denied a tool
    case stalled           // No activity for threshold duration
    case contextLimit      = "context_limit"    // Context window exhausted
}

/// Pure function that classifies turn exit reason from available signals.
///
/// Priority order (highest to lowest):
///   interrupted → approvalDenied → failed state → contextLimit → error patterns → success
public enum ExitClassifier {
    public static func classify(
        sessionState: RuntimeSessionStateMachine.State,
        lastDenied: Bool,
        terminalOutput: String?,
        wasInterrupted: Bool
    ) -> TurnExitReason {
        // 1. Interrupt takes absolute priority
        if wasInterrupted {
            return .interrupted
        }

        // 2. Explicit denial
        if lastDenied {
            return .approvalDenied
        }

        // 3. State machine says failed
        if sessionState == .failed {
            return .error
        }

        // 4. Scan terminal output for known patterns
        if let output = terminalOutput?.lowercased() {
            // Context limit patterns (Claude Code emits these)
            let contextPatterns = ["context window", "token limit", "context limit", "max context"]
            for pattern in contextPatterns {
                if output.contains(pattern) {
                    return .contextLimit
                }
            }

            // Error patterns (only if state machine didn't catch it)
            let errorPatterns = ["error:", "fatal:", "panic:", "unhandled exception"]
            for pattern in errorPatterns {
                if output.contains(pattern) {
                    return .error
                }
            }
        }

        // 5. Default: success
        return .success
    }
}
