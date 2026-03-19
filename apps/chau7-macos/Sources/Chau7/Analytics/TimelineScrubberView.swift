import SwiftUI
import Chau7Core

// MARK: - Timeline Scrubber View

/// Horizontal timeline bar for scrubbing through a terminal session.
/// Shows command blocks as colored segments, a draggable scrub handle,
/// timestamp display, and replay controls.
struct TimelineScrubberView: View {
    @ObservedObject var recorder: SessionRecorder
    let commandBlocks: [CommandBlock]
    let sessionStart: Date
    let sessionEnd: Date

    /// Current scrub position as a fraction (0...1) of total session duration
    @Binding var scrubPosition: Double

    /// Whether replay is currently playing
    @Binding var isPlaying: Bool

    /// Replay speed multiplier
    @Binding var playbackSpeed: Double

    /// Callback when the user scrubs to a new position
    var onScrub: ((Date) -> Void)?

    @State private var hoveredBlock: CommandBlock?
    @State private var isDragging = false

    private var totalDuration: TimeInterval {
        max(sessionEnd.timeIntervalSince(sessionStart), 1.0)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Mini-map: full session overview with viewport indicator
            miniMapView
                .frame(height: 8)

            // Main timeline bar
            HStack(spacing: 8) {
                // Recording indicator
                recordingIndicator

                // Replay controls
                replayControls

                // Timeline track
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 20)
                            .cornerRadius(4)

                        // Command block segments
                        commandBlockSegments(in: geometry.size.width)

                        // Scrub handle
                        scrubHandle(in: geometry.size.width)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let fraction = max(0, min(1, value.location.x / geometry.size.width))
                                scrubPosition = fraction
                                let date = sessionStart.addingTimeInterval(fraction * totalDuration)
                                onScrub?(date)
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Timeline scrubber", "Timeline scrubber"))
                    .accessibilityValue(timestampAtPosition)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            scrubPosition = min(1, scrubPosition + 0.05)
                        case .decrement:
                            scrubPosition = max(0, scrubPosition - 0.05)
                        @unknown default:
                            break
                        }
                        let date = sessionStart.addingTimeInterval(scrubPosition * totalDuration)
                        onScrub?(date)
                    }
                }
                .frame(height: 20)

                // Timestamp display
                Text(timestampAtPosition)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }

            // Hovered block tooltip
            if let block = hoveredBlock {
                blockTooltip(for: block)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var recordingIndicator: some View {
        if recorder.isRecording {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(isDragging ? 1.0 : 0.8)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: recorder.isRecording
                )
                .accessibilityLabel(L("Recording active", "Recording active"))
        }
    }

    private var replayControls: some View {
        HStack(spacing: 4) {
            // Play / Pause
            Button(action: { isPlaying.toggle() }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? L("timeline.pauseReplay", "Pause replay") : L("timeline.playReplay", "Play replay"))

            // Speed selector
            Menu {
                ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { speed in
                    Button(String(format: L("timeline.speedOption", "%.1fx"), speed)) {
                        playbackSpeed = speed
                    }
                }
            } label: {
                Text(String(format: L("timeline.speedLabel", "%.0fx"), playbackSpeed))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .accessibilityLabel(String(format: L("timeline.playbackSpeed", "Playback speed: %.1fx"), playbackSpeed))
        }
    }

    private var miniMapView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Full session background
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    .cornerRadius(2)

                // Activity density heatmap: bucket command blocks into columns
                // and vary opacity by how many overlap in each bucket
                activityDensityOverlay(width: geometry.size.width)

                // Command blocks in mini-map
                ForEach(commandBlocks) { block in
                    let startFrac = blockStartFraction(block)
                    let widthFrac = blockWidthFraction(block)

                    Rectangle()
                        .fill(blockColor(for: block).opacity(0.5))
                        .frame(
                            width: max(2, widthFrac * geometry.size.width),
                            height: 8
                        )
                        .offset(x: startFrac * geometry.size.width)
                }

                // Viewport indicator
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1)
                    .frame(width: max(10, geometry.size.width * 0.15))
                    .offset(x: scrubPosition * geometry.size.width * 0.85)
            }
        }
        .accessibilityHidden(true)
    }

    /// Renders a density heatmap showing activity hotspots across the timeline.
    /// Divides the timeline into buckets and varies opacity by command count.
    private func activityDensityOverlay(width: CGFloat) -> some View {
        let bucketCount = max(1, Int(width / 4))
        var buckets = [Int](repeating: 0, count: bucketCount)

        for block in commandBlocks {
            let startBucket = Int(blockStartFraction(block) * Double(bucketCount))
            let endBucket = min(bucketCount - 1, Int((blockStartFraction(block) + blockWidthFraction(block)) * Double(bucketCount)))
            for i in max(0, startBucket) ... max(0, endBucket) {
                buckets[i] += 1
            }
        }

        let maxDensity = max(1, buckets.max() ?? 1)

        return HStack(spacing: 0) {
            ForEach(0 ..< bucketCount, id: \.self) { i in
                Rectangle()
                    .fill(Color.accentColor.opacity(Double(buckets[i]) / Double(maxDensity) * 0.3))
                    .frame(width: width / CGFloat(bucketCount), height: 8)
            }
        }
    }

    private func commandBlockSegments(in totalWidth: CGFloat) -> some View {
        ForEach(commandBlocks) { block in
            let startFrac = blockStartFraction(block)
            let widthFrac = blockWidthFraction(block)

            Rectangle()
                .fill(blockColor(for: block))
                .frame(
                    width: max(4, widthFrac * totalWidth),
                    height: 16
                )
                .cornerRadius(2)
                .offset(x: startFrac * totalWidth)
                .onHover { isHovered in
                    hoveredBlock = isHovered ? block : nil
                }
                .accessibilityLabel(
                    String(
                        format: L("timeline.commandStatus", "Command: %@, %@"),
                        block.command,
                        blockStatusLabel(block)
                    )
                )
        }
    }

    private func scrubHandle(in totalWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 4, height: 24)
            .offset(x: scrubPosition * totalWidth - 2)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .animation(isDragging ? nil : .easeOut(duration: 0.15), value: scrubPosition)
    }

    private func blockTooltip(for block: CommandBlock) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(blockColor(for: block))
                .frame(width: 8, height: 8)

            Text(block.command)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)

            if !block.durationString.isEmpty {
                Text(block.durationString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let exitCode = block.exitCode {
                Text(String(format: L("timeline.exitCode", "exit %d"), exitCode))
                    .font(.system(size: 10))
                    .foregroundColor(exitCode == 0 ? .green : .red)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        .transition(.opacity)
    }

    // MARK: - Helpers

    private var timestampAtPosition: String {
        let date = sessionStart.addingTimeInterval(scrubPosition * totalDuration)
        let elapsed = date.timeIntervalSince(sessionStart)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func blockStartFraction(_ block: CommandBlock) -> Double {
        let offset = block.startTime.timeIntervalSince(sessionStart)
        return max(0, min(1, offset / totalDuration))
    }

    private func blockWidthFraction(_ block: CommandBlock) -> Double {
        let dur = block.duration ?? Date().timeIntervalSince(block.startTime)
        return max(0.005, min(1, dur / totalDuration))
    }

    private func blockColor(for block: CommandBlock) -> Color {
        if block.isRunning {
            return .blue
        } else if block.isSuccess {
            return .green
        } else {
            return .red
        }
    }

    private func blockStatusLabel(_ block: CommandBlock) -> String {
        if block.isRunning {
            return L("timeline.status.running", "running")
        } else if block.isSuccess {
            return L("timeline.status.succeeded", "succeeded")
        } else {
            return String(format: L("timeline.status.failed", "failed with exit code %d"), block.exitCode ?? -1)
        }
    }
}
