import Chau7Core
import Foundation

/// Owns the general terminal behavior domain: cursor, scrollback, runtime
/// journal limits, usage monitoring toggles, bell, dangerous-command
/// highlighting/protection, and the default start directory.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains.
@Observable
final class TerminalBehaviorStore {

    enum Keys {
        static let cursorStyle = "terminal.cursorStyle"
        static let cursorBlink = "terminal.cursorBlink"
        static let cursorBlinkRate = "terminal.cursorBlinkRate"
        static let cursorColor = "terminal.cursorColor"
        static let unicodeAmbiguousWidth = "terminal.unicodeAmbiguousWidth"
        static let scrollbackLines = "terminal.scrollbackLines"
        static let shellHistoryMaxLines = "terminal.shellHistoryMaxLines"
        static let restoredScrollbackLines = "terminal.restoredScrollbackLines"
        static let runtimeEventJournalCapacity = "runtime.eventJournalCapacity"
        static let runtimeOutputChunkLimit = "runtime.outputChunkLimit"
        static let runtimeCostThresholdsUSD = "runtime.costThresholdsUSD"
        static let usageMonitoringEnabled = "usage.monitoring.enabled"
        static let claudeStatusLineQuotaCaptureEnabled = "usage.claude.statusLine.enabled"
        static let usageQuotaWarningsEnabled = "usage.quotaWarnings.enabled"
        static let bellEnabled = "terminal.bellEnabled"
        static let bellSound = "terminal.bellSound"
        static let bellVisual = "terminal.bellVisual"
        static let bellRateLimitSeconds = "terminal.bellRateLimitSeconds"
        static let dangerousCommandHighlightEnabled = "terminal.dangerousCommandHighlightEnabled"
        static let dangerousCommandHighlightScope = "terminal.dangerousCommandHighlightScope"
        static let dangerousCommandPatterns = "terminal.dangerousCommandPatterns"
        static let dangerousCommandProtectChau7Enabled = "terminal.dangerousCommandProtectChau7Enabled"
        static let dangerousCommandProtectChau7Level = "terminal.dangerousCommandProtectChau7Level"
        static let dangerousCommandProtectedProcessPatterns = "terminal.dangerousCommandProtectedProcessPatterns"
        static let dangerousOutputHighlightIdleDelayMs = "terminal.dangerousOutputHighlightIdleDelayMs"
        static let dangerousOutputHighlightMaxIntervalMs = "terminal.dangerousOutputHighlightMaxIntervalMs"
        static let dangerousOutputHighlightLowPowerEnabled = "terminal.dangerousOutputHighlightLowPowerEnabled"
        static let defaultStartDirectory = "terminal.defaultStartDirectory"
    }

    static let defaultDangerousCommandPatterns: [String] = [
        // Filesystem destruction
        "rm -rf",
        "rm -r -f",
        "rm -fr",
        "rm --no-preserve-root",
        "rm -rf /",
        "rm -rf ~",
        "rm -rf $home",
        "rm -rf *",
        "rm -rf .",
        "rm -rf ..",
        "rm -rf ./",
        "rm -rf ../",
        "find / -delete",
        "find . -delete",
        "find .. -delete",
        "chmod -r 777 /",
        "chmod -r 777 ~",
        "chown -r",
        "chgrp -r",
        "mv /",
        "mv ~",
        "dd if=",
        "dd of=/dev/",
        "mkfs",
        "mkfs.ext",
        "mkfs.xfs",
        "mkfs.btrfs",
        "mkfs.fat",
        "mkfs.vfat",
        "mkswap",
        "wipefs",
        "blkdiscard",
        "shred ",
        "sgdisk --zap-all",
        "sfdisk",
        "fdisk",
        "parted rm",
        "parted mklabel",
        "diskutil erasedisk",
        "diskutil erasevolume",
        "diskutil partitiondisk",
        "diskutil apfs deletevolume",
        "diskutil apfs deletecontainer",
        "diskutil secureerase",
        "zpool destroy",
        "btrfs subvolume delete",
        "cryptsetup luksformat",
        "cryptsetup lukserase",
        "dmsetup remove",
        "lvremove",
        "vgremove",
        "pvremove",
        "swapoff -a",

        // System power/process
        "shutdown -r",
        "shutdown -h",
        "reboot",
        "poweroff",
        "halt",
        "init 0",
        "init 6",
        "kill -9 -1",
        "kill -kill -1",
        "killall -9",
        "pkill -9",

        // Git/VCS
        "git reset --hard",
        "git clean -fd",
        "git clean -fdx",
        "git clean -ffdx",
        "git push -f",
        "git push --force",
        "git push --force-with-lease",
        "git push origin :",
        "git branch -d",
        "git branch -d -f",
        "git branch -d --force",
        "git branch -d -D",
        "git tag -d",
        "git reflog expire --expire=now --all",
        "git gc --prune=now",
        "git checkout -- .",
        "git restore --staged",
        "git rm -r",
        "svn delete",
        "hg strip",

        // GitHub CLI
        "gh repo delete",
        "gh api repos/ -x delete",
        "gh codespace delete",
        "gh release delete",
        "gh gist delete",

        // Containers & Kubernetes
        "docker system prune -a",
        "docker system prune --volumes",
        "docker volume prune",
        "docker network prune",
        "docker container prune",
        "docker image prune -a",
        "docker builder prune -a",
        "docker rm -f",
        "docker rmi -f",
        "docker-compose down -v",
        "docker compose down -v",
        "kubectl delete namespace",
        "kubectl delete ns",
        "kubectl delete all --all",
        "kubectl delete --all --all-namespaces",
        "kubectl delete -f",
        "kubectl delete pods --all",
        "kubectl delete pvc --all",
        "kubectl delete pv --all",
        "helm uninstall",

        // IaC
        "terraform destroy",
        "terraform apply -destroy",
        "pulumi destroy",
        "cdk destroy",

        // Cloud provider CLIs
        "aws s3 rm --recursive",
        "aws s3 rb",
        "aws s3api delete-bucket",
        "aws s3api delete-object",
        "aws s3api delete-objects",
        "aws ec2 terminate-instances",
        "aws autoscaling delete-auto-scaling-group",
        "aws rds delete-db-instance",
        "aws rds delete-db-cluster",
        "aws cloudformation delete-stack",
        "aws dynamodb delete-table",
        "aws iam delete-user",
        "aws iam delete-role",
        "aws kms schedule-key-deletion",
        "aws eks delete-cluster",
        "aws ecs delete-cluster",
        "aws lambda delete-function",
        "aws logs delete-log-group",
        "gcloud projects delete",
        "gcloud compute instances delete",
        "gcloud compute disks delete",
        "gcloud sql instances delete",
        "gcloud sql databases delete",
        "gcloud container clusters delete",
        "gcloud storage rm -r",
        "gcloud storage buckets delete",
        "gcloud dns managed-zones delete",
        "az group delete",
        "az vm delete",
        "az aks delete",
        "az storage account delete",
        "az storage container delete",
        "az storage blob delete",
        "az sql db delete",
        "az cosmosdb delete",
        "az webapp delete",
        "doctl compute droplet delete",
        "doctl k8s cluster delete",
        "doctl database delete",

        // PaaS/DB services
        "heroku apps:destroy",
        "heroku pipelines:destroy",
        "vercel remove",
        "vercel project rm",
        "vercel projects remove",
        "railway project delete",
        "fly apps destroy",
        "supabase projects delete",
        "supabase db reset",
        "supabase db drop",
        "firebase projects:delete",
        "firebase hosting:delete",
        "firebase functions:delete",
        "netlify sites:delete",
        "cloudflare zones delete",

        // Backup tools
        "rclone delete",
        "rclone purge",
        "restic forget --prune",
        "restic prune",

        // Databases/SQL
        "drop database",
        "drop schema",
        "drop table",
        "truncate table",
        "delete from"
    ]

    static let defaultDangerousProtectedProcessPatterns: [String] = [
        "chau7",
        "chau7-mcp-bridge"
    ]

    @ObservationIgnored private let defaults: UserDefaults

    var cursorStyle: String {
        didSet { defaults.set(cursorStyle, forKey: Keys.cursorStyle) }
    }

    var cursorBlink: Bool {
        didSet { defaults.set(cursorBlink, forKey: Keys.cursorBlink) }
    }

    /// Cursor blink interval in seconds (0.3–2.0). Only applies when cursorBlink is true.
    var cursorBlinkRate: Double {
        didSet {
            let clamped = max(0.3, min(cursorBlinkRate, 2.0))
            if cursorBlinkRate != clamped { cursorBlinkRate = clamped
                return
            }
            defaults.set(cursorBlinkRate, forKey: Keys.cursorBlinkRate)
        }
    }

    /// Custom cursor color as hex string (e.g. "#FF6600"). Empty = use theme default.
    var cursorColor: String {
        didSet { defaults.set(cursorColor, forKey: Keys.cursorColor) }
    }

    /// Unicode ambiguous-width treatment: 1 = single-width (Western), 2 = double-width (East Asian).
    /// Affects terminal grid layout for characters in the Unicode Ambiguous width category.
    var unicodeAmbiguousWidth: Int {
        didSet {
            let clamped = (unicodeAmbiguousWidth == 2) ? 2 : 1
            if unicodeAmbiguousWidth != clamped { unicodeAmbiguousWidth = clamped
                return
            }
            defaults.set(unicodeAmbiguousWidth, forKey: Keys.unicodeAmbiguousWidth)
        }
    }

    var scrollbackLines: Int {
        didSet {
            let clamped = max(100, min(scrollbackLines, 100_000))
            if scrollbackLines != clamped {
                scrollbackLines = clamped
                return
            }
            defaults.set(scrollbackLines, forKey: Keys.scrollbackLines)
        }
    }

    /// Total command-history lines retained across closed ("orphan") tabs. Per-tab
    /// shell history accrues one file per tab ever opened; this caps the combined
    /// closed-tab corpus. When over the cap, the oldest commands are dropped first,
    /// but each tab keeps at least a few of its most recent ones (see
    /// `TerminalSessionModel.pruneOrphanShellHistory`). 0 keeps only that per-tab
    /// minimum. Active/restorable tabs are never pruned.
    var shellHistoryMaxLines: Int {
        didSet {
            let clamped = max(0, min(shellHistoryMaxLines, 1_000_000))
            if shellHistoryMaxLines != clamped {
                shellHistoryMaxLines = clamped
                return
            }
            defaults.set(shellHistoryMaxLines, forKey: Keys.shellHistoryMaxLines)
        }
    }

    /// Maximum number of scrollback lines restored when tabs are recovered.
    /// Set to 0 to disable scrollback restoration.
    var restoredScrollbackLines: Int {
        didSet {
            let clamped = max(0, min(restoredScrollbackLines, 10000))
            if restoredScrollbackLines != clamped {
                restoredScrollbackLines = clamped
                return
            }
            defaults.set(restoredScrollbackLines, forKey: Keys.restoredScrollbackLines)
        }
    }

    /// Maximum runtime events retained per session journal.
    var runtimeEventJournalCapacity: Int {
        get {
            let raw = defaults.object(forKey: Keys.runtimeEventJournalCapacity) as? Int ?? 1000
            return max(100, min(raw, 10000))
        }
        set {
            let clamped = max(100, min(newValue, 10000))
            defaults.set(clamped, forKey: Keys.runtimeEventJournalCapacity)
        }
    }

    /// Maximum characters stored per output_chunk journal event.
    var runtimeOutputChunkLimit: Int {
        get {
            let raw = defaults.object(forKey: Keys.runtimeOutputChunkLimit) as? Int ?? 8192
            return max(1024, min(raw, 65536))
        }
        set {
            let clamped = max(1024, min(newValue, 65536))
            defaults.set(clamped, forKey: Keys.runtimeOutputChunkLimit)
        }
    }

    var runtimeCostThresholdsUSD: [Double] {
        get {
            let raw = defaults.array(forKey: Keys.runtimeCostThresholdsUSD) as? [Double] ?? [1, 5, 10]
            return Array(Set(raw.filter { $0 > 0 })).sorted()
        }
        set {
            let normalized = Array(Set(newValue.filter { $0 > 0 })).sorted()
            defaults.set(normalized, forKey: Keys.runtimeCostThresholdsUSD)
        }
    }

    var isUsageMonitoringEnabled: Bool {
        get { defaults.object(forKey: Keys.usageMonitoringEnabled) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.usageMonitoringEnabled)
            NotificationCenter.default.post(name: .usageMonitoringSettingsChanged, object: nil)
        }
    }

    var isClaudeStatusLineQuotaCaptureEnabled: Bool {
        get { defaults.object(forKey: Keys.claudeStatusLineQuotaCaptureEnabled) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.claudeStatusLineQuotaCaptureEnabled)
            NotificationCenter.default.post(name: .usageMonitoringSettingsChanged, object: nil)
        }
    }

    var isUsageQuotaWarningsEnabled: Bool {
        get { defaults.object(forKey: Keys.usageQuotaWarningsEnabled) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.usageQuotaWarningsEnabled)
            NotificationCenter.default.post(name: .usageMonitoringSettingsChanged, object: nil)
        }
    }

    var bellEnabled: Bool {
        didSet { defaults.set(bellEnabled, forKey: Keys.bellEnabled) }
    }

    var bellSound: String {
        didSet { defaults.set(bellSound, forKey: Keys.bellSound) }
    }

    /// Visual flash on bell (combinable with audible bell)
    var bellVisual: Bool {
        didSet { defaults.set(bellVisual, forKey: Keys.bellVisual) }
    }

    /// Minimum seconds between bell triggers (rate limiting to prevent spam)
    var bellRateLimitSeconds: Double {
        didSet {
            let clamped = max(0, min(bellRateLimitSeconds, 60))
            if bellRateLimitSeconds != clamped { bellRateLimitSeconds = clamped
                return
            }
            defaults.set(bellRateLimitSeconds, forKey: Keys.bellRateLimitSeconds)
        }
    }

    var dangerousCommandHighlightScope: DangerousCommandHighlightScope {
        didSet {
            defaults.set(dangerousCommandHighlightScope.rawValue, forKey: Keys.dangerousCommandHighlightScope)
            NotificationCenter.default.post(name: .terminalDangerousCommandHighlightChanged, object: nil)
        }
    }

    var dangerousCommandPatterns: [String] {
        didSet {
            if let data = JSONOperations.encode(dangerousCommandPatterns, context: "dangerousCommandPatterns") {
                defaults.set(data, forKey: Keys.dangerousCommandPatterns)
            }
            NotificationCenter.default.post(name: .terminalDangerousCommandHighlightChanged, object: nil)
        }
    }

    var dangerousCommandProtectChau7Enabled: Bool {
        didSet { defaults.set(dangerousCommandProtectChau7Enabled, forKey: Keys.dangerousCommandProtectChau7Enabled) }
    }

    var dangerousCommandProtectChau7Level: DangerousCommandProtectionLevel {
        didSet { defaults.set(dangerousCommandProtectChau7Level.rawValue, forKey: Keys.dangerousCommandProtectChau7Level) }
    }

    var dangerousCommandProtectedProcessPatterns: [String] {
        didSet {
            let cleaned = dangerousCommandProtectedProcessPatterns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if dangerousCommandProtectedProcessPatterns != cleaned {
                dangerousCommandProtectedProcessPatterns = cleaned
                return
            }
            if let data = JSONOperations.encode(cleaned, context: "dangerousCommandProtectedProcessPatterns") {
                defaults.set(data, forKey: Keys.dangerousCommandProtectedProcessPatterns)
            }
        }
    }

    var dangerousOutputHighlightIdleDelayMs: Int {
        didSet {
            let clamped = max(0, min(dangerousOutputHighlightIdleDelayMs, 5000))
            if dangerousOutputHighlightIdleDelayMs != clamped {
                dangerousOutputHighlightIdleDelayMs = clamped
                return
            }
            defaults.set(dangerousOutputHighlightIdleDelayMs, forKey: Keys.dangerousOutputHighlightIdleDelayMs)
        }
    }

    var dangerousOutputHighlightMaxIntervalMs: Int {
        didSet {
            let clamped = max(250, min(dangerousOutputHighlightMaxIntervalMs, 10000))
            if dangerousOutputHighlightMaxIntervalMs != clamped {
                dangerousOutputHighlightMaxIntervalMs = clamped
                return
            }
            defaults.set(dangerousOutputHighlightMaxIntervalMs, forKey: Keys.dangerousOutputHighlightMaxIntervalMs)
        }
    }

    var dangerousOutputHighlightLowPowerEnabled: Bool {
        didSet {
            defaults.set(dangerousOutputHighlightLowPowerEnabled, forKey: Keys.dangerousOutputHighlightLowPowerEnabled)
            NotificationCenter.default.post(name: .terminalDangerousCommandHighlightChanged, object: nil)
        }
    }

    var defaultStartDirectory: String {
        didSet {
            let trimmed = defaultStartDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty
                ? RuntimeIsolation.homePath()
                : trimmed
            if defaultStartDirectory != normalized {
                defaultStartDirectory = normalized
                return
            }
            defaults.set(defaultStartDirectory, forKey: Keys.defaultStartDirectory)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cursorStyle = defaults.string(forKey: Keys.cursorStyle) ?? "block"
        self.cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        self.cursorBlinkRate = defaults.object(forKey: Keys.cursorBlinkRate) as? Double ?? 0.6
        self.cursorColor = defaults.string(forKey: Keys.cursorColor) ?? ""
        self.unicodeAmbiguousWidth = defaults.object(forKey: Keys.unicodeAmbiguousWidth) as? Int ?? 1
        self.scrollbackLines = defaults.object(forKey: Keys.scrollbackLines) as? Int ?? 10000
        self.shellHistoryMaxLines = defaults.object(forKey: Keys.shellHistoryMaxLines) as? Int ?? 1000
        self.restoredScrollbackLines = defaults.object(forKey: Keys.restoredScrollbackLines) as? Int ?? 500
        self.bellEnabled = defaults.object(forKey: Keys.bellEnabled) as? Bool ?? true
        self.bellSound = defaults.string(forKey: Keys.bellSound) ?? "default"
        self.bellVisual = defaults.object(forKey: Keys.bellVisual) as? Bool ?? false
        self.bellRateLimitSeconds = defaults.object(forKey: Keys.bellRateLimitSeconds) as? Double ?? 0.1
        if let raw = defaults.string(forKey: Keys.dangerousCommandHighlightScope),
           let scope = DangerousCommandHighlightScope(rawValue: raw) {
            self.dangerousCommandHighlightScope = scope
        } else {
            let enabled = defaults.object(forKey: Keys.dangerousCommandHighlightEnabled) as? Bool ?? true
            self.dangerousCommandHighlightScope = enabled ? .allOutputs : .none
        }
        if let data = defaults.data(forKey: Keys.dangerousCommandPatterns),
           let patterns = JSONOperations.decode([String].self, from: data, context: "dangerousCommandPatterns") {
            self.dangerousCommandPatterns = patterns
        } else {
            self.dangerousCommandPatterns = Self.defaultDangerousCommandPatterns
        }
        self.dangerousCommandProtectChau7Enabled = defaults.object(forKey: Keys.dangerousCommandProtectChau7Enabled) as? Bool ?? true
        if let raw = defaults.string(forKey: Keys.dangerousCommandProtectChau7Level),
           let level = DangerousCommandProtectionLevel(rawValue: raw) {
            self.dangerousCommandProtectChau7Level = level
        } else {
            self.dangerousCommandProtectChau7Level = .blocking
        }
        if let data = defaults.data(forKey: Keys.dangerousCommandProtectedProcessPatterns),
           let patterns = JSONOperations.decode([String].self, from: data, context: "dangerousCommandProtectedProcessPatterns") {
            self.dangerousCommandProtectedProcessPatterns = patterns
        } else {
            self.dangerousCommandProtectedProcessPatterns = Self.defaultDangerousProtectedProcessPatterns
        }
        self.dangerousOutputHighlightIdleDelayMs = defaults.object(forKey: Keys.dangerousOutputHighlightIdleDelayMs) as? Int ?? 500
        self.dangerousOutputHighlightMaxIntervalMs = defaults.object(forKey: Keys.dangerousOutputHighlightMaxIntervalMs) as? Int ?? 2000
        self.dangerousOutputHighlightLowPowerEnabled = defaults.object(forKey: Keys.dangerousOutputHighlightLowPowerEnabled) as? Bool ?? true
        self.defaultStartDirectory = defaults.string(forKey: Keys.defaultStartDirectory) ?? RuntimeIsolation.homePath()
    }

    /// Reset by deriving from the loader (single source of defaults).
    func resetToDefaults() {
        for key in [
            Keys.cursorStyle, Keys.cursorBlink, Keys.cursorBlinkRate,
            Keys.cursorColor, Keys.unicodeAmbiguousWidth, Keys.scrollbackLines,
            Keys.shellHistoryMaxLines, Keys.restoredScrollbackLines,
            Keys.runtimeEventJournalCapacity, Keys.runtimeOutputChunkLimit,
            Keys.runtimeCostThresholdsUSD, Keys.usageMonitoringEnabled,
            Keys.claudeStatusLineQuotaCaptureEnabled, Keys.usageQuotaWarningsEnabled,
            Keys.bellEnabled, Keys.bellSound, Keys.bellVisual,
            Keys.bellRateLimitSeconds, Keys.dangerousCommandHighlightEnabled,
            Keys.dangerousCommandHighlightScope, Keys.dangerousCommandPatterns,
            Keys.dangerousCommandProtectChau7Enabled, Keys.dangerousCommandProtectChau7Level,
            Keys.dangerousCommandProtectedProcessPatterns,
            Keys.dangerousOutputHighlightIdleDelayMs, Keys.dangerousOutputHighlightMaxIntervalMs,
            Keys.dangerousOutputHighlightLowPowerEnabled, Keys.defaultStartDirectory
        ] {
            defaults.removeObject(forKey: key)
        }
        let fresh = TerminalBehaviorStore(defaults: defaults)
        cursorStyle = fresh.cursorStyle
        cursorBlink = fresh.cursorBlink
        cursorBlinkRate = fresh.cursorBlinkRate
        cursorColor = fresh.cursorColor
        unicodeAmbiguousWidth = fresh.unicodeAmbiguousWidth
        scrollbackLines = fresh.scrollbackLines
        shellHistoryMaxLines = fresh.shellHistoryMaxLines
        restoredScrollbackLines = fresh.restoredScrollbackLines
        bellEnabled = fresh.bellEnabled
        bellSound = fresh.bellSound
        bellVisual = fresh.bellVisual
        bellRateLimitSeconds = fresh.bellRateLimitSeconds
        dangerousCommandHighlightScope = fresh.dangerousCommandHighlightScope
        dangerousCommandPatterns = fresh.dangerousCommandPatterns
        dangerousCommandProtectChau7Enabled = fresh.dangerousCommandProtectChau7Enabled
        dangerousCommandProtectChau7Level = fresh.dangerousCommandProtectChau7Level
        dangerousCommandProtectedProcessPatterns = fresh.dangerousCommandProtectedProcessPatterns
        dangerousOutputHighlightIdleDelayMs = fresh.dangerousOutputHighlightIdleDelayMs
        dangerousOutputHighlightMaxIntervalMs = fresh.dangerousOutputHighlightMaxIntervalMs
        dangerousOutputHighlightLowPowerEnabled = fresh.dangerousOutputHighlightLowPowerEnabled
        defaultStartDirectory = fresh.defaultStartDirectory
    }
}
