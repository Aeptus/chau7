import Foundation

/// Classifies terminal/command output as a likely **Full Disk Access denial**
/// rather than a bug in the AI CLI that produced it.
///
/// When Chau7 loses Full Disk Access, the child processes it spawns (codex,
/// claude, shells) fail with `EPERM` ("Operation not permitted" / Rust's
/// "os error 1") in protected folders — but the error surfaces as the CLI's,
/// which sends users debugging the wrong layer. This classifier requires *two*
/// independent signals before attributing the failure to FDA, so it does not
/// fire on the many unrelated causes of `EPERM`:
///   1. the output carries an `EPERM`-family marker, and
///   2. the command's working directory is under a TCC-protected root.
///
/// Pure logic; the protected roots are supplied by the caller (the app passes
/// `ProtectedPathPolicy.protectedRootsList()`).
public enum PermissionDenialClassifier {
    public struct Verdict: Equatable, Sendable {
        /// True only when both an EPERM marker and a protected cwd are present.
        public let isFullDiskAccessDenial: Bool
        /// The matched protected root (for messaging), when a denial is found.
        public let protectedRoot: String?

        public static let none = Verdict(isFullDiskAccessDenial: false, protectedRoot: nil)
    }

    /// `EPERM`-family substrings emitted by the CLIs/runtimes Chau7 hosts
    /// (POSIX, Rust/codex, Node, Swift). All matched case-insensitively.
    public static let denialMarkers: [String] = [
        "operation not permitted",
        "os error 1", // Rust std::io EPERM (codex)
        "eperm",
        "errno 1"
    ]

    public static func classify(output: String, cwd: String, protectedRoots: [String]) -> Verdict {
        guard let root = protectedRoot(for: cwd, in: protectedRoots) else { return .none }
        let lowered = output.lowercased()
        guard denialMarkers.contains(where: { lowered.contains($0) }) else { return .none }
        return Verdict(isFullDiskAccessDenial: true, protectedRoot: root)
    }

    /// Returns the protected root that `cwd` lives under, or nil. Matches on path
    /// *components* (so `/…/Downloads2` is not considered under `/…/Downloads`).
    public static func protectedRoot(for cwd: String, in roots: [String]) -> String? {
        let target = normalized(cwd)
        for root in roots {
            let base = normalized(root)
            guard !base.isEmpty else { continue }
            if target == base || target.hasPrefix(base + "/") {
                return root
            }
        }
        return nil
    }

    private static func normalized(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
