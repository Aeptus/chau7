import SwiftUI
import AppKit

// MARK: - Graphics Settings

struct GraphicsSettingsView: View {
    @ObservedObject private var bridge = SixelKittyBridge.shared

    /// Tracks the slider value as Double for smooth interaction
    @State private var cacheSliderValue: Double = 256
    @State private var renderTestFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Sixel Protocol
            SettingsSectionHeader(L("Sixel Graphics Protocol"), icon: "photo")

            SettingsDescription(
                text: L(
                    "Sixel is a bitmap graphics format that allows programs to display images directly in the terminal using DCS escape sequences. Widely supported by tools like libsixel and ImageMagick."
                )
            )

            SettingsToggle(
                label: L("Enable Sixel Protocol"),
                help: L("Allow programs to display inline images using the Sixel graphics protocol (DCS sequences)"),
                isOn: $bridge.isSixelEnabled
            )
            .onChange(of: bridge.isSixelEnabled) { _ in
                bridge.saveSettings()
            }

            Divider()
                .padding(.vertical, 8)

            // Kitty Graphics Protocol
            SettingsSectionHeader(L("Kitty Graphics Protocol"), icon: "photo.artframe")

            SettingsDescription(
                text: L(
                    "The Kitty graphics protocol provides a modern, efficient way to display images in the terminal using APC escape sequences. Supports PNG, JPEG, and raw pixel data with features like image placement and animation."
                )
            )

            SettingsToggle(
                label: L("Enable Kitty Graphics"),
                help: L("Allow programs to display inline images using the Kitty graphics protocol (APC sequences)"),
                isOn: $bridge.isKittyGraphicsEnabled
            )
            .onChange(of: bridge.isKittyGraphicsEnabled) { _ in
                bridge.saveSettings()
            }

            SettingsSlider(
                label: L("Image Cache Size"),
                help: L("Maximum memory used to cache decoded Kitty images (64-1024 MB)"),
                value: $cacheSliderValue,
                range: 64 ... 1024,
                step: 64,
                format: "%.0f",
                suffix: " MB",
                width: 200,
                disabled: !bridge.isKittyGraphicsEnabled
            )
            .onChange(of: cacheSliderValue) { newValue in
                bridge.kittyCacheLimitMB = Int(newValue)
                bridge.saveSettings()
            }

            Divider()
                .padding(.vertical, 8)

            // Info Section
            SettingsSectionHeader(L("graphics.protocols.title", "Protocol Information"), icon: "info.circle")

            VStack(alignment: .leading, spacing: 8) {
                protocolInfoRow(
                    name: L("graphics.protocol.iterm2", "iTerm2 (imgcat)"),
                    statusText: L("graphics.status.alwaysEnabled", "Always enabled"),
                    detail: L("graphics.protocol.iterm2.detail", "ESC ] 1337 ; File = ... BEL"),
                    isEnabled: true
                )
                protocolInfoRow(
                    name: L("graphics.protocol.sixel", "Sixel"),
                    statusText: bridge.isSixelEnabled
                        ? L("status.enabled", "Enabled")
                        : L("status.disabled", "Disabled"),
                    detail: L("graphics.protocol.sixel.detail", "DCS P ... ST"),
                    isEnabled: bridge.isSixelEnabled
                )
                protocolInfoRow(
                    name: L("graphics.protocol.kitty", "Kitty Graphics"),
                    statusText: bridge.isKittyGraphicsEnabled
                        ? L("status.enabled", "Enabled")
                        : L("status.disabled", "Disabled"),
                    detail: L("graphics.protocol.kitty.detail", "APC G ... ST"),
                    isEnabled: bridge.isKittyGraphicsEnabled
                )
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Shortcut hints
            SettingsHint(icon: "terminal", text: L("graphics.hint.sixel", "Test Sixel: convert image.png sixel:- (requires ImageMagick)"))
            SettingsHint(icon: "terminal", text: L("graphics.hint.kitty", "Test Kitty: kitty +kitten icat image.png (requires Kitty tools)"))

            Divider()
                .padding(.vertical, 8)

            // Test Button
            HStack(spacing: 12) {
                SettingsButtonRow(buttons: [
                    .init(title: L("graphics.button.renderTestImage", "Render Test Image"), icon: "photo.badge.checkmark", style: .bordered) {
                        renderTestImage()
                    }
                ], alignment: .leading)

                if let feedback = renderTestFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            cacheSliderValue = Double(bridge.kittyCacheLimitMB)
        }
    }

    // MARK: - Protocol Info Row

    private func protocolInfoRow(name: String, statusText: String, detail: String, isEnabled: Bool) -> some View {
        HStack {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isEnabled ? .green : .secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    // MARK: - Test Image

    private func renderTestImage() {
        // Create a small gradient test image to verify rendering pipeline
        let size = NSSize(width: 128, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw a gradient with protocol labels
        let gradient = NSGradient(colors: [
            NSColor.systemBlue,
            NSColor.systemPurple,
            NSColor.systemPink
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 45)

        // Draw text label
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 10, weight: .bold)
        ]
        let text = "Graphics Test" as NSString
        text.draw(at: NSPoint(x: 24, y: 24), withAttributes: attrs)

        image.unlockFocus()

        // Copy to clipboard as a quick preview mechanism
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }

        Log.info("Graphics test image rendered and copied to clipboard")

        withAnimation {
            renderTestFeedback = L("graphics.testImage.copied", "Test image copied to clipboard")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { renderTestFeedback = nil }
        }
    }
}
