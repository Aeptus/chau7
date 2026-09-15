import SwiftUI

// MARK: - Status Bar Panel Visual Tokens

enum StatusBarPanelStyle {
    enum Fonts {
        static let confirmationTitle = Font.system(size: 12, weight: .medium)
        static let version = Font.system(size: 10)
        static let heroIcon = Font.system(size: 18, weight: .semibold)
        static let heroTitle = Font.system(size: 17, weight: .semibold)
        static let heroDetail = Font.system(size: 11)
        static let sectionHeader = Font.system(size: 12, weight: .semibold)
        static let sectionActionIcon = Font.system(size: 11, weight: .medium)
        static let rowIcon = Font.system(size: 12, weight: .semibold)
        static let rowTitle = Font.system(size: 12, weight: .medium)
        static let rowDetail = Font.system(size: 10)
        static let rowMetadata = Font.system(size: 9)
        static let snippetIcon = Font.system(size: 11, weight: .semibold)
        static let snippetTitle = Font.system(size: 12, weight: .medium)
        static let snippetAction = Font.system(size: 11, weight: .medium)
        static let timelineIcon = Font.system(size: 10)
        static let timelineTitle = Font.system(size: 11, weight: .medium)
        static let timelineDetail = Font.system(size: 10)
        static let timelineTimestamp = Font.system(size: 9, design: .monospaced)
    }

    enum Colors {
        static let approval = Color(nsColor: .systemRed)
        static let waiting = Color(nsColor: .systemOrange)
        static let paused = Color(nsColor: .systemGray)
        static let running = Color(nsColor: .systemBlue)
        static let sessionRunning = Color(nsColor: .systemOrange)
        static let input = Color(nsColor: .systemBlue)
        static let quiet = Color(nsColor: .systemGreen)
        static let stuck = Color(nsColor: .systemYellow)
        static let success = Color(nsColor: .systemGreen)
        static let destructive = Color(nsColor: .systemRed)
        static let accent = Color.accentColor
        static let attentionBackground = Color(nsColor: .systemYellow).opacity(0.08)
        static let rowHitTargetBackground = Color.primary.opacity(0.001)
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
    }
}
