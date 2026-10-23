public enum RestoreSaveCommitResult: Equatable {
    case bundleNotPersisted
    case bundleOnly
    case bundleAndIndex
}

/// Publishes a restore save without exposing a newer lightweight index before
/// the full bundle that backs it is durable.
public enum RestoreSaveTransaction {
    @discardableResult
    public static func commit(
        indexPayloadIsReady: Bool,
        persistBundle: () throws -> Bool,
        publishIndexPayload: () -> Void,
        publishIndexToken: () -> Void
    ) rethrows -> RestoreSaveCommitResult {
        guard try persistBundle() else { return .bundleNotPersisted }
        guard indexPayloadIsReady else { return .bundleOnly }

        publishIndexPayload()
        // The token is the index commit marker and must be published last.
        publishIndexToken()
        return .bundleAndIndex
    }
}
