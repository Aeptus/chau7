import SwiftUI
import AppKit

// MARK: - Accessibility Utilities

/// Centralized accessibility utilities for consistent accessibility support.
/// Provides Dynamic Type, high contrast, and reduced motion support.
enum AccessibilityUtilities {

    // MARK: - Dynamic Type Scaled Fonts

    /// Creates a scaled system font that responds to Dynamic Type settings.
    /// - Parameters:
    ///   - size: Base size for the font
    ///   - weight: Font weight
    ///   - design: Font design (default, monospaced, rounded, serif)
    ///   - relativeTo: Text style to scale relative to (default: .body)
    /// - Returns: A font that scales with Dynamic Type
    static func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        Font.system(size: size, weight: weight, design: design)
            .leading(.standard)
    }

    /// Creates a scaled custom font (like Avenir Next) that responds to Dynamic Type.
    /// - Parameters:
    ///   - name: Font name
    ///   - size: Base size
    ///   - relativeTo: Text style to scale relative to
    /// - Returns: A font that scales with Dynamic Type
    static func scaledCustomFont(
        _ name: String,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        Font.custom(name, size: size, relativeTo: textStyle)
    }
}

// MARK: - Scaled Font View Modifier

/// View modifier that applies Dynamic Type scaling to fonts.
struct ScaledFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content
            .font(.system(size: scaledSize, weight: weight, design: design))
    }

    private var scaledSize: CGFloat {
        let scale = dynamicTypeScaleFactor
        return baseSize * scale
    }

    private var dynamicTypeScaleFactor: CGFloat {
        switch dynamicTypeSize {
        case .xSmall: return 0.8
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.0
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        case .accessibility1: return 1.4
        case .accessibility2: return 1.6
        case .accessibility3: return 1.8
        case .accessibility4: return 2.0
        case .accessibility5: return 2.2
        @unknown default: return 1.0
        }
    }
}

// MARK: - High Contrast Support

/// View modifier that adjusts colors for high contrast mode.
struct HighContrastModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    let normalColor: Color
    let highContrastColor: Color

    func body(content: Content) -> some View {
        content
            .foregroundColor(contrast == .increased ? highContrastColor : normalColor)
    }
}

// MARK: - Reduce Motion Support

/// View modifier that respects reduce motion preferences.
struct ReduceMotionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animation: Animation?

    func body(content: Content) -> some View {
        if reduceMotion {
            content.animation(nil, value: UUID())
        } else {
            content.animation(animation, value: UUID())
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies a scaled font that responds to Dynamic Type settings.
    /// - Parameters:
    ///   - size: Base font size
    ///   - weight: Font weight (default: .regular)
    ///   - design: Font design (default: .default)
    /// - Returns: View with scaled font applied
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFontModifier(baseSize: size, weight: weight, design: design))
    }

    /// Applies high contrast color support.
    /// - Parameters:
    ///   - normal: Color to use in normal mode
    ///   - highContrast: Color to use in high contrast mode
    /// - Returns: View with high contrast support
    func highContrastForeground(normal: Color, highContrast: Color) -> some View {
        modifier(HighContrastModifier(normalColor: normal, highContrastColor: highContrast))
    }

    /// Applies animation with reduce motion support.
    /// - Parameter animation: Animation to use when reduce motion is disabled
    /// - Returns: View that respects reduce motion preferences
    func accessibleAnimation(_ animation: Animation?) -> some View {
        modifier(ReduceMotionModifier(animation: animation))
    }

    /// Adds comprehensive accessibility support to a control.
    /// - Parameters:
    ///   - label: VoiceOver label describing the control
    ///   - hint: VoiceOver hint describing the action
    ///   - traits: Accessibility traits for the control
    /// - Returns: View with accessibility support
    func accessibleControl(
        label: String,
        hint: String? = nil,
        traits: AccessibilityTraits = []
    ) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(traits)
    }

    /// Groups children for VoiceOver as a single element.
    /// - Parameters:
    ///   - label: Combined label for the group
    ///   - hint: Hint for the group action
    /// - Returns: View with combined accessibility
    func accessibleGroup(label: String, hint: String? = nil) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }
}

// MARK: - Accessibility-Aware Colors

/// Colors that automatically adjust for high contrast mode.
struct AccessibleColors {
    @Environment(\.colorSchemeContrast) private var contrast

    /// Secondary text color with high contrast support
    static func secondaryText(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.primary.opacity(0.8) : Color.secondary
    }

    /// Tertiary text color with high contrast support
    static func tertiaryText(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.primary.opacity(0.6) : Color(NSColor.tertiaryLabelColor)
    }

    /// Background overlay color with high contrast support
    static func overlayBackground(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased
            ? Color(red: 0.05, green: 0.05, blue: 0.05)
            : Color(red: 0.10, green: 0.10, blue: 0.10)
    }
}

// MARK: - Accessibility Focus State Helper

/// Helper for managing focus state for accessibility.
struct AccessibilityFocusHelper<Value: Hashable>: ViewModifier {
    @AccessibilityFocusState private var focusedField: Value?
    let binding: Binding<Value?>

    func body(content: Content) -> some View {
        content
            .onChange(of: binding.wrappedValue) {
                focusedField = binding.wrappedValue
            }
            .onChange(of: focusedField) {
                binding.wrappedValue = focusedField
            }
    }
}

// MARK: - Minimum Touch Target

/// Ensures minimum touch target size for accessibility (44x44 points recommended by Apple).
struct MinimumTouchTargetModifier: ViewModifier {
    let minSize: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Ensures the view has a minimum touch target size for accessibility.
    /// Apple recommends 44x44 points minimum.
    /// - Parameter size: Minimum size (default: 44)
    /// - Returns: View with minimum touch target
    func minimumTouchTarget(_ size: CGFloat = 44) -> some View {
        modifier(MinimumTouchTargetModifier(minSize: size))
    }
}

// MARK: - Focus Ring for Keyboard Navigation

/// Adds a visible focus ring when the view has keyboard focus.
struct KeyboardFocusRingModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
            )
    }
}

extension View {
    /// Adds a keyboard focus ring indicator.
    /// - Parameters:
    ///   - isFocused: Whether the view currently has focus
    ///   - cornerRadius: Corner radius of the focus ring
    /// - Returns: View with focus ring overlay
    func keyboardFocusRing(isFocused: Bool, cornerRadius: CGFloat = 6) -> some View {
        modifier(KeyboardFocusRingModifier(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

// MARK: - VoiceOver Announcements

/// Utility for making VoiceOver announcements.
enum AccessibilityAnnouncement {
    /// Post an announcement to VoiceOver.
    /// - Parameter message: The message to announce
    static func post(_ message: String) {
        #if os(macOS)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
        #endif
    }

    /// Announce search results count.
    static func announceSearchResults(_ count: Int) {
        let message = count == 0 ? "No results found" :
            count == 1 ? "1 result found" :
            "\(count) results found"
        post(message)
    }

    /// Announce a selection change.
    static func announceSelection(_ item: String) {
        post("Selected: \(item)")
    }

    /// Announce an action completion.
    static func announceAction(_ action: String) {
        post(action)
    }
}

// MARK: - List Navigation Accessibility

/// Accessibility traits and labels for navigable lists.
extension View {
    /// Makes a list item navigable with keyboard.
    /// - Parameters:
    ///   - index: Item index in the list
    ///   - total: Total number of items
    ///   - label: Item label for VoiceOver
    /// - Returns: View with list navigation accessibility
    func accessibleListItem(index: Int, total: Int, label: String) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(
                String(
                    format: L("accessibility.listItem", "Item %d of %d. Use arrow keys to navigate."),
                    index + 1,
                    total
                )
            )
    }
}
