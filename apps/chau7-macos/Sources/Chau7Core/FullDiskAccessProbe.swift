import Foundation

/// Detects whether the current process holds macOS **Full Disk Access** (the
/// TCC grant `kTCCServiceSystemPolicyAllFiles`).
///
/// This is distinct from `ProtectedPathPolicy`, which manages per-folder
/// *security-scoped bookmarks* for Chau7 itself. Full Disk Access is what gets
/// inherited by **child processes** (the shell, codex, claude, …) via the
/// responsible-process attribution: when Chau7's FDA grant is lost — e.g. after
/// the app's code signature changes from a re-sign or rebuild — those children
/// start failing with `EPERM` ("Operation not permitted") in protected folders
/// like `~/Downloads`, even though nothing in Chau7 itself changed.
///
/// The probe reads an FDA-gated canary file and maps the result. It is
/// deliberately conservative: only an explicit permission error counts as
/// `.denied`; anything ambiguous is `.indeterminate` so we never raise a false
/// alarm. All policy is pure and the file accessor is injectable for tests.
public enum FullDiskAccessProbe {
    public enum Status: String, Equatable, Sendable {
        /// An FDA-gated file was readable — Full Disk Access is in effect.
        case granted
        /// An FDA-gated file returned a permission error — FDA is not in effect.
        case denied
        /// Could not determine (no canary readable, none explicitly denied).
        case indeterminate
    }

    /// Outcome of attempting to access a single canary path.
    public enum AccessResult: Equatable, Sendable {
        case ok
        case denied
        case missing
        case otherError
    }

    public typealias Accessor = (_ absolutePath: String) -> AccessResult

    /// Home-relative paths that require Full Disk Access to read. `TCC.db` is the
    /// authoritative canary (always present, FDA-gated); the others are
    /// fallbacks that may legitimately be absent on some systems.
    public static let defaultCanaries: [String] = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
        "Library/Cookies/Cookies.binarycookies",
    ]

    /// Determines Full Disk Access status from the given canaries.
    ///
    /// A single readable canary proves access (`.granted`) and takes priority
    /// over a denial, so a flaky/edge-case path can never produce a false
    /// `.denied`. Only an explicit permission error yields `.denied`.
    public static func evaluate(
        home: String,
        canaries: [String] = defaultCanaries,
        accessor: Accessor
    ) -> Status {
        var sawDenied = false
        for relative in canaries {
            let path = home.hasSuffix("/") ? home + relative : home + "/" + relative
            switch accessor(path) {
            case .ok:
                return .granted
            case .denied:
                sawDenied = true
            case .missing, .otherError:
                continue
            }
        }
        return sawDenied ? .denied : .indeterminate
    }

    /// Live probe against the real filesystem in the current process.
    public static func probe(
        home: String = RuntimeIsolation.homeDirectory().path,
        canaries: [String] = defaultCanaries
    ) -> Status {
        evaluate(home: home, canaries: canaries, accessor: posixAccessor)
    }

    /// Maps a low-level `open(2)` attempt to an `AccessResult`. TCC denials
    /// surface as `EPERM`; classic unix denials as `EACCES`. We never read the
    /// file's contents — only whether it can be opened.
    public static func posixAccessor(_ absolutePath: String) -> AccessResult {
        let fd = open(absolutePath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .ok
        }
        switch errno {
        case EPERM, EACCES:
            return .denied
        case ENOENT, ENOTDIR:
            return .missing
        default:
            return .otherError
        }
    }
}
