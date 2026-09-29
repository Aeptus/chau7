import Chau7Core
import Foundation
import Observation

/// `@MainActor` because both mutation sites already dispatch to main
/// explicitly (`TelemetryRecorder.publishLiveRun` / `removeLiveRun` hop via
/// `DispatchQueue.main.async`), and the SwiftUI surfaces that observe it read
/// it from the main actor. Isolating the type records that invariant in the
/// declaration instead of leaving it to be re-derived at each call site.
@Observable
@MainActor
final class TelemetryRunLiveStore {
    static let shared = TelemetryRunLiveStore()

    private(set) var runs: [String: TelemetryRunLive] = [:]

    func upsert(_ liveRun: TelemetryRunLive) {
        runs[liveRun.runID] = liveRun
    }

    func remove(runID: String) {
        runs.removeValue(forKey: runID)
    }
}

struct TelemetryRunLive: Sendable, Equatable {
    let runID: String
    let tabID: String?
    let sessionID: String?
    let provider: String
    let model: String?
    let tokenUsage: TokenUsage
    let turnCount: Int
    let estimatedCostUSD: Double?
    let tokenUsageSource: TokenUsageSource?
    let tokenUsageState: TelemetryMetricState
    let costSource: CostSource?
    let costState: TelemetryMetricState
    let updatedAt: Date
}
