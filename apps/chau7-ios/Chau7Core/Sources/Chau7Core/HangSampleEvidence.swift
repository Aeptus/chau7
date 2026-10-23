import Foundation

/// Sampling evidence, not a diagnosis. Unchanged file tokens do not prove a
/// runtime deadlock; advanced tokens mean the capture overlaps UI progress.
public struct HangSampleEvidence: Codable, Equatable, Sendable {
    public enum HeartbeatProgress: String, Codable, Sendable {
        case advanced
        case unchanged
        case unavailable
    }

    public let heartbeatProgressDuringCapture: HeartbeatProgress
    public let captureDurationSeconds: TimeInterval

    public init(beforeToken: UInt64?, afterToken: UInt64?, startedUptime: TimeInterval, completedUptime: TimeInterval) {
        if let beforeToken, let afterToken {
            self.heartbeatProgressDuringCapture = beforeToken == afterToken ? .unchanged : .advanced
        } else {
            self.heartbeatProgressDuringCapture = .unavailable
        }
        self.captureDurationSeconds = max(0, completedUptime - startedUptime)
    }
}

/// Recognizes stack families only inside the sampled main-thread section. These
/// labels describe observed frames and deliberately make no root-cause claim.
public struct MainThreadStackObservations: Codable, Equatable, Sendable {
    public enum Family: String, Codable, Sendable {
        case objectiveCBlockTeardown = "objective_c_block_teardown"
        case modalDialog = "modal_dialog"
        case viewLayout = "view_layout"
        case repositoryStatistics = "repository_statistics"
        case socketWrite = "socket_write"
    }

    public static let maximumInputBytes = 1024 * 1024
    public let mainThreadFound: Bool
    public let mainThreadSampleCount: Int?
    public let observedFamilies: [Family]
    public let inputTruncated: Bool

    public init(sampleText: String) {
        let bytes = sampleText.utf8
        self.inputTruncated = bytes.count > Self.maximumInputBytes
        let bounded = String(decoding: bytes.prefix(Self.maximumInputBytes), as: UTF8.self)
        var mainLines: [String] = []
        var found = false
        var samples: Int?
        for line in bounded.split(separator: "\n", omittingEmptySubsequences: false) {
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            let threadHeader = tokens.count >= 2 && Int(tokens[0]) != nil && tokens[1].hasPrefix("Thread_")
            if threadHeader {
                if found { break }
                if line.contains("com.apple.main-thread") {
                    found = true
                    samples = Int(tokens[0])
                }
                continue
            }
            if found { mainLines.append(String(line)) }
        }
        self.mainThreadFound = found
        self.mainThreadSampleCount = samples
        let main = mainLines.joined(separator: "\n")
        var families: [Family] = []
        if main.contains("_Block_release"), main.contains("objc_destructInstance"), main.contains("_object_remove_associations") {
            families.append(.objectiveCBlockTeardown)
        }
        if main.contains("runModal"), main.contains("NSAlert") { families.append(.modalDialog) }
        if main.contains("NSHostingView"), main.localizedCaseInsensitiveContains("layout") { families.append(.viewLayout) }
        if main.contains("GitStatsSnapshotStore"), main.contains("loadRepositoryStats") { families.append(.repositoryStatistics) }
        if main.contains("send"), main.contains("MCPSession") || main.contains("BoundedSocketWriter") { families.append(.socketWrite) }
        self.observedFamilies = families
    }
}
