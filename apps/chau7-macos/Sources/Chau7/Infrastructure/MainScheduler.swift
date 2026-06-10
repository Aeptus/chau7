import Foundation

/// The narrow slice of main-queue scheduling the side-panel code depends on,
/// behind a protocol so tests can advance virtual time instead of spinning
/// the real run loop. Most callers should accept a `MainScheduler` in their
/// initializer and default to `SystemMainScheduler()`.
protocol MainScheduler {
    func async(_ work: @escaping () -> Void)
    func asyncAfter(seconds: TimeInterval, _ work: @escaping () -> Void)
}

/// Production impl: delegates straight to `DispatchQueue.main`. Stateless,
/// so it's safe to share a single instance.
struct SystemMainScheduler: MainScheduler {
    func async(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func asyncAfter(seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
