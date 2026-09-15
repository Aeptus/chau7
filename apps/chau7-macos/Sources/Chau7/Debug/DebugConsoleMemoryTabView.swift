import SwiftUI

/// The Debug Console "Memory" tab: an on-demand per-tab memory attribution
/// table (see `TerminalMemoryReport`). Captures on appear and on explicit
/// refresh only — no timers.
struct DebugConsoleMemoryTabView: View {
    let overlayModel: OverlayTabsModel

    @State private var report: TerminalMemoryReport?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(L("debug.memoryRefresh", "Refresh")) {
                    report = TerminalMemoryReport.capture(overlayModel: overlayModel)
                }
                .controlSize(.small)

                Spacer()

                if let report {
                    Text("\(L("debug.perfUpdated", "Updated")) \(report.capturedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(report?.formatted() ?? L("debug.memoryEmpty", "Press Refresh to capture a per-tab memory report."))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .onAppear {
            if report == nil {
                report = TerminalMemoryReport.capture(overlayModel: overlayModel)
            }
        }
    }
}
