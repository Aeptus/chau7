import Foundation
import Chau7Core

// MARK: - Latency Telemetry

// Extracted from TerminalSessionModel.swift
// Contains: AI timing metrics, input/output latency tracking,
// percentile calculations, lag event recording.

extension TerminalSessionModel {
    var inputLatencySummary: String {
        guard let last = inputLatencyMs else { return "n/a" }
        if let avg = inputLatencyAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    var outputLatencySummary: String {
        guard let last = outputLatencyMs else { return "n/a" }
        if let avg = outputLatencyAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    var dangerousHighlightLatencySummary: String {
        guard let last = dangerousHighlightDelayMs else { return "n/a" }
        if let avg = dangerousHighlightAverageMs {
            return "\(last)ms (avg \(avg)ms)"
        }
        return "\(last)ms"
    }

    var inputLatencyPercentilesSummary: String {
        latencyPercentilesSummary(for: inputLatencySamples)
    }

    var outputLatencyPercentilesSummary: String {
        latencyPercentilesSummary(for: outputLatencySamples)
    }

    var dangerousHighlightPercentilesSummary: String {
        latencyPercentilesSummary(for: dangerousHighlightSamples)
    }

    private func latencyPercentilesSummary(for buffer: LatencySampleBuffer) -> String {
        let samples = buffer.values()
        guard !samples.isEmpty else { return "n/a" }
        guard let p50 = percentileValue(from: samples, percentile: 0.50),
              let p95 = percentileValue(from: samples, percentile: 0.95) else {
            return "n/a"
        }
        return "\(p50)ms / \(p95)ms (n=\(samples.count))"
    }

    private func latencyPercentiles(for buffer: LatencySampleBuffer) -> (p50: Int?, p95: Int?, count: Int) {
        let samples = buffer.values()
        guard !samples.isEmpty else { return (nil, nil, 0) }
        let p50 = percentileValue(from: samples, percentile: 0.50)
        let p95 = percentileValue(from: samples, percentile: 0.95)
        return (p50, p95, samples.count)
    }

    func clearLagTimeline() {
        if Thread.isMainThread {
            lagTimeline.removeAll()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.lagTimeline.removeAll()
            }
        }
    }

    private func percentileValue(from samples: [Int], percentile: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let clamped = max(0.0, min(1.0, percentile))
        let sorted = samples.sorted()
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.toNearestOrEven))
        return sorted[index]
    }

    func maybeLogLatencySpike(
        kind: String,
        elapsedMs: Double,
        averageMs: Int?,
        samples: LatencySampleBuffer,
        thresholdMs: Double,
        lastLoggedAt: inout Date?
    ) {
        guard elapsedMs >= thresholdMs else { return }
        let now = Date()
        if let last = lastLoggedAt, now.timeIntervalSince(last) < latencyLogCooldownSeconds {
            return
        }
        lastLoggedAt = now
        let percentiles = latencyPercentilesSummary(for: samples)
        let tabName = (tabTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? tabTitleOverride!
            : title
        let appName = activeAppName ?? "shell"
        let avg = averageMs ?? -1
        Log.warn("Latency spike: \(kind)=\(Int(elapsedMs.rounded()))ms avg=\(avg)ms p50/p95=\(percentiles) tab=\(tabName) app=\(appName) cwd=\(tabPathDisplayName())")

        let percentileValues = latencyPercentiles(for: samples)
        recordLagEvent(
            kind: LagKind(rawValue: kind) ?? .input,
            elapsedMs: Int(elapsedMs.rounded()),
            averageMs: avg,
            p50: percentileValues.p50,
            p95: percentileValues.p95,
            sampleCount: percentileValues.count,
            tabTitle: tabName,
            appName: appName,
            cwd: tabPathDisplayName()
        )
    }

    private func recordLagEvent(
        kind: LagKind,
        elapsedMs: Int,
        averageMs: Int,
        p50: Int?,
        p95: Int?,
        sampleCount: Int,
        tabTitle: String,
        appName: String,
        cwd: String
    ) {
        let event = LagEvent(
            kind: kind,
            elapsedMs: elapsedMs,
            averageMs: averageMs,
            p50: p50,
            p95: p95,
            sampleCount: sampleCount,
            timestamp: Date(),
            tabTitle: tabTitle,
            appName: appName,
            cwd: cwd
        )
        let append = {
            self.lagTimeline.append(event)
            if self.lagTimeline.count > self.lagTimelineCapacity {
                self.lagTimeline.removeFirst(self.lagTimeline.count - self.lagTimelineCapacity)
            }
        }
        if Thread.isMainThread {
            append()
        } else {
            DispatchQueue.main.async(execute: append)
        }
    }
}
