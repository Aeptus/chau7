import Foundation

/// Timing thresholds shared by the in-process main-thread monitor and the
/// independent watchdog process. The circuit breaker opens before sampling so
/// a recovering event loop can drain queued input before accepting more paint
/// work.
public struct MainThreadHangMonitorPolicy: Equatable, Sendable {
    public let stallThreshold: TimeInterval
    public let sampleThreshold: TimeInterval
    public let sampleCooldown: TimeInterval

    public init(
        stallThreshold: TimeInterval = 2,
        sampleThreshold: TimeInterval = 4,
        sampleCooldown: TimeInterval = 60
    ) {
        precondition(stallThreshold > 0)
        precondition(sampleThreshold >= stallThreshold)
        precondition(sampleCooldown >= 0)
        self.stallThreshold = stallThreshold
        self.sampleThreshold = sampleThreshold
        self.sampleCooldown = sampleCooldown
    }
}

/// Pure, token-based stall detector. A caller advances `progressToken` only
/// from the queue it is supervising. Observers can therefore run elsewhere
/// without synchronously asking the supervised queue whether it is alive.
public struct MainThreadHangMonitorState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case healthy
        case stalled
    }

    public struct Observation: Equatable, Sendable {
        public let phase: Phase
        public let staleFor: TimeInterval
        public let enteredStall: Bool
        public let recovered: Bool
        public let shouldSample: Bool
    }

    public private(set) var phase: Phase = .healthy

    private var progressToken: UInt64
    private var lastProgressAt: TimeInterval
    private var lastSampleAt: TimeInterval?
    private var sampledCurrentStall = false

    public init(initialProgressToken: UInt64, now: TimeInterval) {
        self.progressToken = initialProgressToken
        self.lastProgressAt = now
    }

    public mutating func observe(
        progressToken newProgressToken: UInt64,
        now: TimeInterval,
        policy: MainThreadHangMonitorPolicy = .init()
    ) -> Observation {
        if newProgressToken != progressToken {
            let wasStalled = phase == .stalled
            let stalledFor = wasStalled ? max(0, now - lastProgressAt) : 0
            progressToken = newProgressToken
            lastProgressAt = now
            phase = .healthy
            sampledCurrentStall = false
            return Observation(
                phase: .healthy,
                staleFor: stalledFor,
                enteredStall: false,
                recovered: wasStalled,
                shouldSample: false
            )
        }

        let staleFor = max(0, now - lastProgressAt)
        let enteredStall = phase == .healthy && staleFor >= policy.stallThreshold
        if enteredStall {
            phase = .stalled
        }

        var shouldSample = false
        if phase == .stalled,
           !sampledCurrentStall,
           staleFor >= policy.sampleThreshold,
           lastSampleAt.map({ now - $0 >= policy.sampleCooldown }) ?? true {
            sampledCurrentStall = true
            lastSampleAt = now
            shouldSample = true
        }

        return Observation(
            phase: phase,
            staleFor: staleFor,
            enteredStall: enteredStall,
            recovered: false,
            shouldSample: shouldSample
        )
    }
}

/// Validated arguments for Chau7's same-binary watchdog mode. Keeping parsing
/// pure makes accidental partial invocations fail closed instead of launching
/// a second GUI process.
public struct MainThreadHangWatchdogCommand: Equatable, Sendable {
    public let parentPID: Int32
    public let heartbeatPath: String
    public let outputDirectoryPath: String

    public init(parentPID: Int32, heartbeatPath: String, outputDirectoryPath: String) {
        self.parentPID = parentPID
        self.heartbeatPath = heartbeatPath
        self.outputDirectoryPath = outputDirectoryPath
    }

    public static func parse(arguments: [String]) -> MainThreadHangWatchdogCommand? {
        guard arguments.contains("--hang-watchdog"),
              let rawPID = value(after: "--parent-pid", in: arguments),
              let parsedPID = Int32(rawPID),
              parsedPID > 1,
              let heartbeatPath = normalizedPath(value(after: "--heartbeat", in: arguments)),
              let outputDirectoryPath = normalizedPath(value(after: "--output-directory", in: arguments)) else {
            return nil
        }
        return MainThreadHangWatchdogCommand(
            parentPID: parsedPID,
            heartbeatPath: heartbeatPath,
            outputDirectoryPath: outputDirectoryPath
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("--") else { return nil }
        return value
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
}
