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

    /// Fire-and-forget: runs `block` inline when already on main, otherwise
    /// hops with `main.async`. For Void side effects in property observers that
    /// usually fire on main but can fire elsewhere (e.g. from `deinit` when the
    /// last reference drops off-main) — bare `assumeIsolated` would trap there.
    static func run(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(block)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(block)
            }
        }
    }
}
