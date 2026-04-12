import Chau7Core
import Foundation
import Observation

@Observable
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
