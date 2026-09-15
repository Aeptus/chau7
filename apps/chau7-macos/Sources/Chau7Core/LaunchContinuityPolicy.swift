public enum PreviousLaunchOutcome: String, Equatable, Sendable {
    case unknown
    case clean
    case abrupt
}

/// Interprets a marker written at launch and cleared during normal app
/// termination. An uncleared marker proves only an abrupt exit; it does not
/// distinguish a crash from force-quit, power loss, or process termination.
public enum LaunchContinuityPolicy {
    public static func previousOutcome(isRunningMarker: Bool?) -> PreviousLaunchOutcome {
        switch isRunningMarker {
        case true:
            return .abrupt
        case false:
            return .clean
        case nil:
            return .unknown
        }
    }
}
