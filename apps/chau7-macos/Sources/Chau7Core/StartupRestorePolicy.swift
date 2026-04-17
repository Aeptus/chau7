import Foundation

public struct StartupRestoreSummary: Equatable {
    public let durationMs: Int
    public let protectedRoots: [String]
    public let protectedPathDeferrals: Int
    public let debouncedSnippetResolves: Int
    public let completedSnippetResolves: Int
    public let delayedResumePrefills: Int
    public let queuedResumePrefills: Int
    public let deliveredResumePrefills: Int
    public let restoreBootstrapStarted: Int
    public let restoreBootstrapSettled: Int
    public let restorePreviewShown: Int
    public let restorePreviewDiscarded: Int
    public let selectedTabLiveFrameCount: Int
    public let firstWindowVisibleMs: Int?
    public let firstSelectedTabLiveFrameSinceStartMs: Int?
    public let firstSelectedTabLiveFrameMs: Int?
    public let slowestSelectedTabLiveFrameMs: Int?

    public init(
        durationMs: Int,
        protectedRoots: [String],
        protectedPathDeferrals: Int,
        debouncedSnippetResolves: Int,
        completedSnippetResolves: Int,
        delayedResumePrefills: Int,
        queuedResumePrefills: Int,
        deliveredResumePrefills: Int,
        restoreBootstrapStarted: Int,
        restoreBootstrapSettled: Int,
        restorePreviewShown: Int,
        restorePreviewDiscarded: Int,
        selectedTabLiveFrameCount: Int,
        firstWindowVisibleMs: Int?,
        firstSelectedTabLiveFrameSinceStartMs: Int?,
        firstSelectedTabLiveFrameMs: Int?,
        slowestSelectedTabLiveFrameMs: Int?
    ) {
        self.durationMs = durationMs
        self.protectedRoots = protectedRoots
        self.protectedPathDeferrals = protectedPathDeferrals
        self.debouncedSnippetResolves = debouncedSnippetResolves
        self.completedSnippetResolves = completedSnippetResolves
        self.delayedResumePrefills = delayedResumePrefills
        self.queuedResumePrefills = queuedResumePrefills
        self.deliveredResumePrefills = deliveredResumePrefills
        self.restoreBootstrapStarted = restoreBootstrapStarted
        self.restoreBootstrapSettled = restoreBootstrapSettled
        self.restorePreviewShown = restorePreviewShown
        self.restorePreviewDiscarded = restorePreviewDiscarded
        self.selectedTabLiveFrameCount = selectedTabLiveFrameCount
        self.firstWindowVisibleMs = firstWindowVisibleMs
        self.firstSelectedTabLiveFrameSinceStartMs = firstSelectedTabLiveFrameSinceStartMs
        self.firstSelectedTabLiveFrameMs = firstSelectedTabLiveFrameMs
        self.slowestSelectedTabLiveFrameMs = slowestSelectedTabLiveFrameMs
    }
}

public struct StartupRestoreTracker: Equatable {
    public private(set) var isActive = false
    public private(set) var startedAt: Date?
    public private(set) var protectedRoots: Set<String> = []
    public private(set) var protectedPathDeferrals = 0
    public private(set) var debouncedSnippetResolves = 0
    public private(set) var completedSnippetResolves = 0
    public private(set) var delayedResumePrefills = 0
    public private(set) var queuedResumePrefills = 0
    public private(set) var deliveredResumePrefills = 0
    public private(set) var restoreBootstrapStarted = 0
    public private(set) var restoreBootstrapSettled = 0
    public private(set) var restorePreviewShown = 0
    public private(set) var restorePreviewDiscarded = 0
    public private(set) var selectedTabLiveFrameMsByWindow: [Int: Int] = [:]
    public private(set) var windowPreparedAtByNumber: [Int: Date] = [:]
    public private(set) var windowVisibleAtByNumber: [Int: Date] = [:]

    public init() {}

    public mutating func begin(at date: Date) {
        isActive = true
        startedAt = date
        protectedRoots.removeAll(keepingCapacity: true)
        protectedPathDeferrals = 0
        debouncedSnippetResolves = 0
        completedSnippetResolves = 0
        delayedResumePrefills = 0
        queuedResumePrefills = 0
        deliveredResumePrefills = 0
        restoreBootstrapStarted = 0
        restoreBootstrapSettled = 0
        restorePreviewShown = 0
        restorePreviewDiscarded = 0
        selectedTabLiveFrameMsByWindow.removeAll(keepingCapacity: true)
        windowPreparedAtByNumber.removeAll(keepingCapacity: true)
        windowVisibleAtByNumber.removeAll(keepingCapacity: true)
    }

    public mutating func noteProtectedPathDeferral(root: String) -> Bool {
        protectedPathDeferrals += 1
        return protectedRoots.insert(root).inserted
    }

    public mutating func noteSnippetResolveDebounced() {
        debouncedSnippetResolves += 1
    }

    public mutating func noteSnippetResolveCompleted() {
        completedSnippetResolves += 1
    }

    public mutating func noteResumePrefillDelayed() {
        delayedResumePrefills += 1
    }

    public mutating func noteResumePrefillQueued() {
        queuedResumePrefills += 1
    }

    public mutating func noteResumePrefillDelivered() {
        deliveredResumePrefills += 1
    }

    public mutating func noteRestoreBootstrapStarted() {
        restoreBootstrapStarted += 1
    }

    public mutating func noteRestoreBootstrapSettled() {
        restoreBootstrapSettled += 1
    }

    public mutating func noteRestorePreviewShown() {
        restorePreviewShown += 1
    }

    public mutating func noteRestorePreviewDiscarded() {
        restorePreviewDiscarded += 1
    }

    public mutating func noteWindowPrepared(windowNumber: Int, at date: Date) {
        if windowPreparedAtByNumber[windowNumber] == nil {
            windowPreparedAtByNumber[windowNumber] = date
        }
    }

    public mutating func noteWindowVisible(windowNumber: Int, at date: Date) {
        windowVisibleAtByNumber[windowNumber] = date
    }

    public mutating func noteSelectedTabLiveFrame(windowNumber: Int, at date: Date) -> Int? {
        guard selectedTabLiveFrameMsByWindow[windowNumber] == nil else { return nil }
        guard let preparedAt = windowPreparedAtByNumber[windowNumber] ?? windowVisibleAtByNumber[windowNumber] else {
            return nil
        }
        let elapsedMs = max(0, Int((date.timeIntervalSince(preparedAt) * 1000).rounded()))
        selectedTabLiveFrameMsByWindow[windowNumber] = elapsedMs
        return elapsedMs
    }

    public func isReadyForVisibleStartupCompletion(expectedWindowCount: Int) -> Bool {
        guard isActive else { return false }
        guard expectedWindowCount > 0 else { return false }
        guard selectedTabLiveFrameMsByWindow.count >= expectedWindowCount else { return false }
        return true
    }

    public func hasSelectedTabLiveFrame(windowNumber: Int) -> Bool {
        selectedTabLiveFrameMsByWindow[windowNumber] != nil
    }

    public mutating func end(at date: Date) -> StartupRestoreSummary? {
        guard isActive, let startedAt else { return nil }
        isActive = false
        self.startedAt = nil

        let durationMs = max(0, Int((date.timeIntervalSince(startedAt) * 1000).rounded()))
        let liveFrameSamples = selectedTabLiveFrameMsByWindow.values.sorted()
        let firstWindowVisibleMs = windowVisibleAtByNumber.values
            .map { max(0, Int(($0.timeIntervalSince(startedAt) * 1000).rounded())) }
            .min()
        let firstSelectedTabLiveFrameSinceStartMs = selectedTabLiveFrameMsByWindow.keys.compactMap { windowNumber -> Int? in
            guard let visibleAt = windowVisibleAtByNumber[windowNumber],
                  let elapsedMs = selectedTabLiveFrameMsByWindow[windowNumber] else { return nil }
            return max(0, Int((visibleAt.timeIntervalSince(startedAt) * 1000).rounded())) + elapsedMs
        }.min()
        return StartupRestoreSummary(
            durationMs: durationMs,
            protectedRoots: protectedRoots.sorted(),
            protectedPathDeferrals: protectedPathDeferrals,
            debouncedSnippetResolves: debouncedSnippetResolves,
            completedSnippetResolves: completedSnippetResolves,
            delayedResumePrefills: delayedResumePrefills,
            queuedResumePrefills: queuedResumePrefills,
            deliveredResumePrefills: deliveredResumePrefills,
            restoreBootstrapStarted: restoreBootstrapStarted,
            restoreBootstrapSettled: restoreBootstrapSettled,
            restorePreviewShown: restorePreviewShown,
            restorePreviewDiscarded: restorePreviewDiscarded,
            selectedTabLiveFrameCount: liveFrameSamples.count,
            firstWindowVisibleMs: firstWindowVisibleMs,
            firstSelectedTabLiveFrameSinceStartMs: firstSelectedTabLiveFrameSinceStartMs,
            firstSelectedTabLiveFrameMs: liveFrameSamples.first,
            slowestSelectedTabLiveFrameMs: liveFrameSamples.last
        )
    }
}

public enum StartupSnippetResolvePolicy {
    public static let debouncedDelay: TimeInterval = 0.12

    public static func shouldDebounce(
        isStartupRestoreActive: Bool,
        path: String,
        homePath: String
    ) -> Bool {
        guard isStartupRestoreActive else { return false }
        let normalizedHome = URL(fileURLWithPath: homePath).standardized.path
        let normalizedPath = URL(fileURLWithPath: path).standardized.path

        if normalizedPath == normalizedHome {
            return true
        }

        let parent = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        return parent == normalizedHome
    }
}

public enum StartupResumePrefillPolicy {
    public static let startupGraceAttempts = 3

    public enum NoViewDecision: Equatable {
        case retryWaitingForView
        case queueSessionPrefill
    }

    public static func noViewDecision(
        isStartupRestoreActive: Bool,
        remainingAttempts: Int,
        graceAttempts: Int = startupGraceAttempts
    ) -> NoViewDecision {
        guard isStartupRestoreActive, remainingAttempts > max(0, graceAttempts) else {
            return .queueSessionPrefill
        }
        return .retryWaitingForView
    }

    public static func shouldWarnAboutNotReady(isStartupRestoreActive: Bool) -> Bool {
        !isStartupRestoreActive
    }
}

public enum StartupWindowPresentationPolicy {
    public static let selectedTabRestoreDelay: TimeInterval = 0.05
    public static let backgroundTabRestoreDelay: TimeInterval = 0.05

    public static func restoreExecutionDelay(
        isStartupRestoreActive: Bool,
        isSelectedTab: Bool,
        defaultDelay: TimeInterval
    ) -> TimeInterval {
        guard isStartupRestoreActive else { return defaultDelay }
        _ = isSelectedTab
        return selectedTabRestoreDelay
    }

    public static func shouldKeepTabInLiveHierarchy(
        isStartupRestoreActive: Bool,
        isSelectedTab: Bool,
        isPreviousLiveTab: Bool,
        isMCPControlled: Bool,
        hasAttachedTerminalView: Bool,
        hasPendingRestoreBootstrap: Bool
    ) -> Bool {
        if isSelectedTab || isPreviousLiveTab {
            return true
        }

        if isMCPControlled && !hasAttachedTerminalView {
            return true
        }

        guard hasPendingRestoreBootstrap, !hasAttachedTerminalView else {
            return hasPendingRestoreBootstrap
        }
        _ = isStartupRestoreActive
        return true
    }

    public static func shouldRevealWindowImmediately(
        isStartupRestoreActive: Bool,
        isSelectedSurfaceLivePresentable: Bool
    ) -> Bool {
        guard isStartupRestoreActive else { return true }
        return isSelectedSurfaceLivePresentable
    }
}
