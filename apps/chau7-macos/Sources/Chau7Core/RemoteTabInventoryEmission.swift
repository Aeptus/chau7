/// Semantic gate for the remote tab inventory channel.
///
/// Tab-model notifications are intentionally noisier than the wire inventory:
/// terminal output can update transient model state without changing any tab
/// descriptor. Keeping the last payload here lets the sender preserve those
/// notifications locally while emitting a new inventory only for a real wire
/// change.
public struct RemoteTabInventoryEmissionGate: Sendable {
    private var lastPayload: RemoteTabListPayload?

    public init() {}

    public mutating func shouldEmit(_ payload: RemoteTabListPayload) -> Bool {
        guard payload != lastPayload else { return false }
        lastPayload = payload
        return true
    }

    public mutating func reset() {
        lastPayload = nil
    }
}
