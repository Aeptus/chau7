import Foundation
import Observation
import Chau7Core

/// Memory snapshot consumed by `TabHoverCardContent`.
///
/// All SQLite work happens on `loadQueue`; observable state is published on
/// the main queue. A monotonically increasing generation rejects results from
/// a tab that stopped being the hover target while its query was in flight.
@Observable
final class TabHoverCardAnalyticsModel {
    struct ToolSummary: Identifiable, Equatable, Sendable {
        let tool: String
        let count: Int

        var id: String {
            tool
        }
    }

    struct Snapshot: Sendable {
        let completedRun: TelemetryRun?
        let topTools: [ToolSummary]

        static let empty = Snapshot(completedRun: nil, topTools: [])
    }

    typealias Loader = (String) -> Snapshot

    var completedRun: TelemetryRun?
    var topTools: [ToolSummary] = []

    @ObservationIgnored private static let defaultLoadQueue = DispatchQueue(
        label: "com.chau7.hover-card.analytics",
        qos: .utility
    )
    @ObservationIgnored private let loadQueue: DispatchQueue
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var currentTabID: String?

    init(
        loadQueue: DispatchQueue = TabHoverCardAnalyticsModel.defaultLoadQueue,
        loader: @escaping Loader = TabHoverCardAnalyticsModel.loadSnapshot(tabID:)
    ) {
        self.loadQueue = loadQueue
        self.loader = loader
    }

    func refresh(tabID: String) {
        dispatchPrecondition(condition: .onQueue(.main))

        generation &+= 1
        let expectedGeneration = generation
        if currentTabID != tabID {
            currentTabID = tabID
            completedRun = nil
            topTools = []
        }

        let loader = loader
        loadQueue.async { [weak self] in
            let snapshot = loader(tabID)
            DispatchQueue.main.async {
                guard let self,
                      self.generation == expectedGeneration,
                      self.currentTabID == tabID else {
                    return
                }
                self.completedRun = snapshot.completedRun
                self.topTools = snapshot.topTools
            }
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
    }

    private static func loadSnapshot(tabID: String) -> Snapshot {
        guard let run = TelemetryStore.shared.latestRunForTab(tabID) else {
            return .empty
        }
        let tools = TelemetryStore.shared.toolCallSummary(runID: run.id).map {
            ToolSummary(tool: $0.tool, count: $0.count)
        }
        return Snapshot(completedRun: run, topTools: tools)
    }
}
