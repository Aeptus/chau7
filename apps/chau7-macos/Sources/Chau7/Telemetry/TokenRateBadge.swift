import SwiftUI

@MainActor
struct TokenRateBadge: View {
    let tabID: String

    private var reading: TokenRateReading? {
        TokenRateStore.shared.reading(for: tabID)
    }

    var body: some View {
        if let reading {
            Text(reading.formattedRate)
                .font(StatusBarPanelStyle.Fonts.tokenRate)
                .foregroundStyle(reading.source.isEstimated ? StatusBarPanelStyle.Colors.telemetryEstimate : StatusBarPanelStyle.Colors.telemetryMeasured)
                .lineLimit(1)
                .help(reading.detail)
                .accessibilityLabel(reading.detail)
        }
    }
}
