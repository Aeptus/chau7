# Chau7 UI Styling Guide

A practical reference for maintaining consistent, accessible interfaces across the app.

---

## Quick Reference

| Element | Value |
|---------|-------|
| **Section spacing** | `16pt` |
| **Label width** | `220pt` |
| **Label-control gap** | `16pt` |
| **Card padding** | `12pt` |
| **Card corner radius** | `8pt` |
| **Row vertical padding** | `4pt` |
| **Divider padding** | `.vertical(8)` |

---

## 1. Layout Structure

### Settings Page Template

```swift
VStack(alignment: .leading, spacing: 16) {
    // Section 1
    SettingsSectionHeader("Section Title", icon: "sf.symbol")

    SettingsToggle(label: "...", help: "...", isOn: $binding)
    SettingsPicker(label: "...", help: "...", selection: $binding, options: [...])

    Divider()
        .padding(.vertical, 8)

    // Section 2
    SettingsSectionHeader("Next Section", icon: "another.symbol")
    // ...
}
```

### Row Pattern

All settings rows follow this structure:
```swift
HStack(alignment: .top, spacing: 16) {
    // Label column (fixed width)
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(.system(size: 13))
        Text(help)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .frame(width: 220, alignment: .leading)

    // Control column (flexible)
    Control()

    Spacer()
}
.padding(.vertical, 4)
```

---

## 2. Typography

| Style | Size | Usage |
|-------|------|-------|
| **Headline** | 11pt | Section headers |
| **Body** | 13pt | Labels, primary text |
| **Caption** | 11pt | Help text, hints |
| **Monospaced** | 12pt | Code, paths, shortcuts |

### Rules

- **Labels**: `.font(.system(size: 13))`
- **Help text**: `.font(.caption).foregroundStyle(.secondary)`
- **Values/Numbers**: Always monospaced (`.monospacedDigit()` or `.monospaced`)
- **Shortcuts**: `.font(.system(.caption, design: .monospaced))`

---

## 3. Colors

### Text Colors

| Color | Usage |
|-------|-------|
| `.primary` | Main text, control values |
| `.secondary` | Help text, descriptions, icons in headers |
| `.accentColor` | Interactive elements, links |
| `.red` | Destructive actions |

### Background Opacity Patterns

```swift
Color.secondary.opacity(0.05)    // Very subtle (hover hint)
Color.secondary.opacity(0.1)     // Subtle (shortcut badges, cards)
Color.accentColor.opacity(0.08)  // Active/selected state
```

### System Colors

```swift
Color(NSColor.controlBackgroundColor)  // Cards, containers
Color(NSColor.windowBackgroundColor)   // Window backgrounds
```

---

## 4. Spacing Constants

| Value | Usage |
|-------|-------|
| `2pt` | Label ↔ help text gap |
| `4pt` | Row vertical padding |
| `6pt` | Icon ↔ text gap in headers |
| `8pt` | Divider vertical padding, card internal spacing |
| `12pt` | Card padding, button row spacing |
| `16pt` | Section spacing (primary), label ↔ control gap |

---

## 5. Component Dimensions

| Component | Width |
|-----------|-------|
| **Labels** | 220pt (fixed) |
| **Sliders** | 150pt |
| **Pickers** | 150pt |
| **Text fields** | 200pt (default) |
| **Number fields** | 100pt |
| **Steppers** | 60pt |

---

## 6. Corner Radius

| Radius | Usage |
|--------|-------|
| `2pt` | Tiny elements (color squares) |
| `4pt` | Badges, keyboard shortcuts |
| `6pt` | List items, small cards |
| `8pt` | Cards, info boxes, grouped settings |
| `10pt` | Large containers, terminal preview |

---

## 7. Reusable Components

Always use the existing components from `SettingsComponents.swift`:

| Component | When to Use |
|-----------|-------------|
| `SettingsSectionHeader` | Start of every section |
| `SettingsToggle` | Boolean on/off settings |
| `SettingsPicker` | Selection from options |
| `SettingsSlider` | Numeric range with visual feedback |
| `SettingsStepper` | Numeric input with +/- buttons |
| `SettingsTextField` | Text input |
| `SettingsNumberField` | Numeric-only input |
| `SettingsInfoRow` | Read-only display |
| `SettingsButtonRow` | Action buttons |
| `SettingsCard` | Featured/grouped content |
| `SettingsHint` | Informational messages |

---

## 8. Button Styles

| Style | Usage |
|-------|-------|
| `.bordered` | Secondary actions |
| `.borderedProminent` | Primary actions |
| `.plain` | Inline text actions |

All buttons in settings panels: `.controlSize(.small)`

---

## 9. SF Symbols

### Common Icons by Category

**Navigation & Actions**
- `plus.circle` - Add
- `trash` - Delete
- `arrow.counterclockwise` - Reset
- `xmark.circle.fill` - Clear/close

**Settings Categories**
- `gear` - General
- `paintpalette` - Appearance
- `terminal` - Terminal
- `keyboard` - Input
- `bell.badge` - Notifications
- `sparkles` - AI Integration

**Status**
- `checkmark.circle.fill` - Success
- `exclamationmark.triangle.fill` - Warning
- `xmark.circle.fill` - Error

### Icon Rules

- In headers: `.foregroundStyle(.secondary)`
- In buttons: Use `Label("Text", systemImage: "icon")`
- Standalone: Consider `.imageScale(.small)` for density

---

## 10. Accessibility Checklist

Every interactive element must have:

```swift
.accessibilityLabel("What it is")
.accessibilityHint("What it does")  // For non-obvious actions
.accessibilityValue("Current state") // For controls with state
```

### Grouping

```swift
.accessibilityElement(children: .combine)  // Group label + control
```

### Announcements

```swift
AccessibilityAnnouncement.post("Action completed")
```

---

## 11. Common Patterns

### Divider Between Sections

```swift
Divider()
    .padding(.vertical, 8)
```

### Card with Action

```swift
SettingsCard(
    title: "Feature Name",
    description: "What it does",
    icon: "symbol.name",
    actionTitle: "Configure",
    action: { /* ... */ }
)
```

### Button Row (Multiple Actions)

```swift
SettingsButtonRow(buttons: [
    .init(title: "Action 1", icon: "icon1") { /* ... */ },
    .init(title: "Action 2", icon: "icon2") { /* ... */ }
])
```

### Keyboard Shortcut Display

```swift
Text("⌘D")
    .font(.system(.caption, design: .monospaced))
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.secondary.opacity(0.1))
    .cornerRadius(4)
```

---

## 12. Do's and Don'ts

### Do

- **Do** use standard components (`SettingsToggle`, `SettingsRow`, `SettingsPicker`, etc.)
- **Do** keep settings views flat - rows directly in the main `VStack`
- **Do** use `Divider().padding(.vertical, 8)` to separate sections
- **Do** add help text to every interactive control
- **Do** use section header labels (`.font(.caption).fontWeight(.medium)`) to group related items
- **Do** align all controls using the 220pt label width pattern

### Don't

- **Don't** use background boxes on settings rows (no `.background(Color.secondary.opacity(...))` wrappers)
- **Don't** nest content in decorative containers or cards in settings views
- **Don't** create custom row layouts - use `SettingsRow` or `SettingsToggle` for alignment
- **Don't** use arbitrary spacing values (stick to 2, 4, 6, 8, 12, 16)
- **Don't** hardcode colors (use semantic colors like `.primary`, `.secondary`)
- **Don't** forget help text for settings (every control needs explanation)
- **Don't** create new components when existing ones work
- **Don't** use proportional fonts for numbers/code
- **Don't** skip accessibility labels on interactive elements
- **Don't** use opacity below 0.05 (invisible on some displays)

---

## 13. File References

| File | Contains |
|------|----------|
| `SettingsComponents.swift` | All reusable UI components |
| `AccessibilityUtilities.swift` | A11y helpers and scaled fonts |
| `TerminalColorScheme.swift` | Terminal color presets |
| `Localization.swift` | `L()` function for i18n |

---

## Example: Complete Settings Section

```swift
// MARK: - Example Feature Section

SettingsSectionHeader(L("settings.example.title", "Example Feature"), icon: "star")

SettingsToggle(
    label: L("settings.example.enabled", "Enable Feature"),
    help: L("settings.example.enabled.help", "Turn on the example feature"),
    isOn: $settings.exampleEnabled
)

SettingsPicker(
    label: L("settings.example.mode", "Mode"),
    help: L("settings.example.mode.help", "Choose how the feature behaves"),
    selection: $settings.exampleMode,
    options: ExampleMode.allCases.map { ($0.rawValue, $0.displayName) }
)

SettingsSlider(
    label: L("settings.example.intensity", "Intensity"),
    help: L("settings.example.intensity.help", "Adjust the feature intensity"),
    value: $settings.exampleIntensity,
    range: 0...100,
    step: 5,
    suffix: "%"
)

Divider()
    .padding(.vertical, 8)
```

---

*Last updated: January 2026*
