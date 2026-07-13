import SwiftUI

// MARK: - Shared Visual Tokens

enum Chau7Style {
    static let goldenRatio: CGFloat = 1.618_033_988_75

    enum Spacing {
        static let base: CGFloat = 8

        static let xxxSmall = rounded(base / pow(Chau7Style.goldenRatio, 3))
        static let xxSmall = rounded(base / pow(Chau7Style.goldenRatio, 2))
        static let xSmall = rounded(base / Chau7Style.goldenRatio)
        static let small = base
        static let medium = rounded(base * Chau7Style.goldenRatio)
        static let large = rounded(base * pow(Chau7Style.goldenRatio, 2))
        static let xLarge = rounded(base * pow(Chau7Style.goldenRatio, 3))
        static let xxLarge = rounded(base * pow(Chau7Style.goldenRatio, 4))
    }

    enum Radius {
        static let xSmall = Spacing.xxSmall
        static let small = Spacing.xSmall
        static let medium = Spacing.small
        static let large = Spacing.medium
    }

    enum Control {
        static let minimumWidth: CGFloat = 160
        static let compactTitlebarHeight = Spacing.large
        static let badgeDot = Spacing.small
        static let statusDot = Spacing.medium
    }

    enum Settings {
        static let labelWidth: CGFloat = 220
        static let rowSpacing = Spacing.medium
        static let compactRowSpacing = Spacing.small
        static let rowVerticalPadding = Spacing.xSmall
        static let sectionTopPadding = Spacing.small
        static let sectionBottomPadding = Spacing.xSmall
        static let contentPadding = Spacing.large
        static let hintPadding = Spacing.medium
        static let searchHorizontalPadding = Spacing.medium
        static let searchVerticalPadding = Spacing.small
        static let cardPadding = Spacing.medium

        static let windowMinWidth: CGFloat = 720
        static let windowMinHeight: CGFloat = 500
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarIdealWidth: CGFloat = 240
        static let sidebarMaxWidth: CGFloat = 300
        static let detailMinWidth: CGFloat = 360
        static let detailIdealWidth: CGFloat = 680
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        value.rounded()
    }
}
