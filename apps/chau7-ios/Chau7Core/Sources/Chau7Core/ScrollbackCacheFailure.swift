import Foundation

public enum ScrollbackCacheFailureKind: String, Sendable {
    case outOfSpace = "out_of_space"
    case permissionDenied = "permission_denied"
    case corruptData = "corrupt_data"
    case ioFailure = "io_failure"
}

public enum ScrollbackCacheFailureClassifier {
    public static func classify(_ error: Error) -> ScrollbackCacheFailureKind {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case 28:
                return .outOfSpace
            case 1, 13:
                return .permissionDenied
            default:
                return .ioFailure
            }
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return .outOfSpace
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied
            case NSFileReadCorruptFileError:
                return .corruptData
            default:
                return .ioFailure
            }
        }

        return .ioFailure
    }
}
