import Foundation

/// Authoritative risk tier for a command awaiting approval.
///
/// Classified on the Mac at approval-emit time and carried on the wire
/// (`ApprovalRequestPayload.severity`) so every surface renders the same tier.
/// iOS prefers the wire value and falls back to `classify` locally only when
/// the field is absent (an older Mac that predates it) — one classifier, two
/// callers, no drift. Stored on the wire as a raw string so an unknown future
/// tier degrades to the fallback rather than failing JSON decode.
public enum ApprovalSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    /// Ordinary command that just needs a yes/no — e.g. an unlisted command
    /// under ask-unlisted mode.
    case standard
    /// A protected action: a self-protective "Protect Chau7" match, or a remote
    /// input flagged because it targets a Chau7-managed process or path
    /// (`flaggedCommand != command`).
    case protected
    /// Irreversible or history-rewriting — force-push, hard reset, recursive
    /// force-remove, disk wipes, SQL drops. Warrants a deliberate confirm.
    case destructive

    /// Classify a pending approval from what the Mac already knows at emit time.
    /// `reason` is the command-filter / self-protection rationale when available
    /// (e.g. `"Protect Chau7: …"`).
    public static func classify(
        command: String,
        flaggedCommand: String,
        reason: String? = nil
    ) -> ApprovalSeverity {
        if isDestructive(command) || isDestructive(flaggedCommand) {
            return .destructive
        }
        // A rewritten flag means a protection layer substituted the command it
        // actually objected to (self-protection / remote-termination guard).
        if flaggedCommand != command {
            return .protected
        }
        if let reason, reason.range(of: "Protect Chau7", options: .caseInsensitive) != nil {
            return .protected
        }
        return .standard
    }

    /// Heuristic match for irreversible operations. Deliberately conservative:
    /// a false negative just drops the card to a lower tier (still a normal
    /// approval the user sees and decides), while the patterns here are the
    /// ones a pocket mis-tap must never wave through.
    public static func isDestructive(_ command: String) -> Bool {
        let c = command.lowercased()
        return isGitHistoryRewrite(c)
            || isRecursiveForceRemove(c)
            || isDiskDestroyer(c)
            || isSQLDrop(c)
    }

    // MARK: - Pattern groups

    /// Force-push, hard reset, and forced clean — operations that discard or
    /// rewrite committed/working state with no reflog-free recovery.
    private static func isGitHistoryRewrite(_ c: String) -> Bool {
        guard c.contains("git") else { return false }
        if c.contains("push"), c.contains("--force") || hasFlag(c, "f") { return true }
        if c.contains("reset"), c.contains("--hard") { return true }
        if c.contains("clean"), hasFlag(c, "f") { return true }
        return false
    }

    /// `rm` (or `rm`-alike) invoked recursively AND forcibly.
    private static func isRecursiveForceRemove(_ c: String) -> Bool {
        guard hasWord(c, "rm") || c.contains("rm -") else { return false }
        let recursive = hasFlag(c, "r") || c.contains("-rf") || c.contains("-fr")
        let forced = hasFlag(c, "f") || c.contains("-rf") || c.contains("-fr")
        return recursive && forced
    }

    /// Raw block-device / filesystem destroyers.
    private static func isDiskDestroyer(_ c: String) -> Bool {
        // `mkfs` is safe as a plain substring — it also catches the common
        // `mkfs.ext4` / `mkfs.vfat` / `/sbin/mkfs` single-token forms.
        if c.contains("mkfs") { return true }
        if c.contains("diskutil"), c.contains("erase") { return true }
        // `dd` must be a whole token (not "add"/"odd") and actually write.
        if hasWord(c, "dd"), c.contains("of=") { return true }
        if c.contains("> /dev/") { return true }
        return false
    }

    /// Destructive SQL: dropping or truncating tables/databases.
    private static func isSQLDrop(_ c: String) -> Bool {
        c.contains("drop table")
            || c.contains("drop database")
            || c.contains("truncate table")
    }

    // MARK: - Token helpers

    /// True when `flag` appears as a short option: either bundled (`-rf`) or
    /// standalone (`-f`). Guards against matching letters inside other words.
    private static func hasFlag(_ c: String, _ flag: Character) -> Bool {
        for token in c.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard token.hasPrefix("-"), !token.hasPrefix("--") else { continue }
            if token.dropFirst().contains(flag) { return true }
        }
        return false
    }

    /// True when `word` appears as a whitespace-delimited token (not a
    /// substring of another word — so `rm` does not match `chmod`).
    private static func hasWord(_ c: String, _ word: String) -> Bool {
        c.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "/" })
            .contains { $0 == Substring(word) }
    }
}
