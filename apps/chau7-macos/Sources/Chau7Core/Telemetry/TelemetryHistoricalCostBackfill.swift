import Foundation

public enum TelemetryHistoricalCostBackfill {
    /// Repairs older runs that already have token usage but were persisted before
    /// the pricing table learned how to price their model family.
    public static func repairedRun(_ run: TelemetryRun) -> TelemetryRun? {
        guard run.costUSD == nil || run.costState == .missing || run.costSource == .unavailable else {
            return nil
        }
        guard run.tokenUsageState != .invalid, run.tokenUsage.hasAnyTokens else {
            return nil
        }
        guard let estimatedCost = ModelPricingTable.estimatedCostUSD(
            for: run.tokenUsage,
            modelID: run.model,
            providerHint: run.provider
        ) else {
            return nil
        }

        var repaired = run
        repaired.costUSD = estimatedCost
        repaired.costSource = .estimated
        repaired.costState = .estimated
        return repaired
    }
}
