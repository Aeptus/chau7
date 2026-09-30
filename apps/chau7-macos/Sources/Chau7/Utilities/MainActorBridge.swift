import Foundation

/// Brief synchronous access to UI-owned state from a background service.
/// Waiting and I/O stay on the caller's queue, outside this closure.
enum MainActorBridge {
    static func sync<T>(_ block: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(block)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(block)
        }
    }
}
