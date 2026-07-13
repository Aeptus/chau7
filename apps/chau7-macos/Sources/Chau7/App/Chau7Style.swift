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
        static let pageSectionSpacing = Spacing.small
        static let rowSpacing = Spacing.small
        static let compactRowSpacing = Spacing.small
        static let inlineControlSpacing = Spacing.small
        static let looseControlSpacing = Spacing.medium
        static let rowVerticalPadding = Spacing.xxSmall
        static let sectionTopPadding = Spacing.xSmall
        static let sectionBottomPadding: CGFloat = 0
        static let separatorVerticalPadding = Spacing.xSmall
        static let contentPadding = Spacing.medium
        static let hintPadding = Spacing.small
        static let searchHorizontalPadding = Spacing.medium
        static let searchVerticalPadding = Spacing.small
        static let cardPadding = Spacing.small

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
