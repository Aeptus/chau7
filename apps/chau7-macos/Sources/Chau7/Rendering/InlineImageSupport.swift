import Foundation
import AppKit
import Chau7Core

// MARK: - iTerm2 Image Protocol Handler

/// Handles inline image display using the iTerm2 image protocol.
/// Protocol: ESC ] 1337 ; File = [args] : base64data BEL
/// See: https://iterm2.com/documentation-images.html
final class InlineImageHandler {
    static let shared = InlineImageHandler()

    /// Image display settings
    var isEnabled: Bool {
        FeatureSettings.shared.isInlineImagesEnabled
    }

    var maxImageWidth: CGFloat = 800
    var maxImageHeight: CGFloat = 600

    private init() {}

    // MARK: - Protocol Detection

    /// Checks if data contains an iTerm2 image sequence start
    func containsImageSequence(_ data: Data) -> Bool {
        // Look for ESC ] 1337 ; File =
        let marker = "\u{1b}]1337;File="
        guard let str = String(data: data, encoding: .utf8) else { return false }
        return str.contains(marker)
    }

    /// Parse and extract image data from the escape sequence
    func parseImageSequence(_ text: String) -> InlineImage? {
        // Match: ESC ] 1337 ; File = [args] : base64data BEL
        // BEL is \u{07} or ESC \
        let pattern = #"\x1b\]1337;File=([^:]*):([^\x07\x1b]*)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        else {
            return nil
        }

        // Extract arguments and base64 data
        guard let argsRange = Range(match.range(at: 1), in: text),
              let dataRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }

        let argsString = String(text[argsRange])
        let base64String = String(text[dataRange])

        // Parse arguments
        var args = InlineImageArgs()
        for arg in argsString.split(separator: ";") {
            let parts = arg.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            let value = String(parts[1])

            switch key {
            case "name":
                args.name = value.removingPercentEncoding ?? value
            case "size":
                args.size = Int(value)
            case "width":
                args.width = parseDimension(value)
            case "height":
                args.height = parseDimension(value)
            case "preserveaspectratio":
                args.preserveAspectRatio = value != "0"
            case "inline":
                args.inline = value == "1"
            default:
                break
            }
        }

        // Decode base64 image data
        guard let imageData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            Log.warn("InlineImage: Failed to decode base64 data")
            return nil
        }

        // Create NSImage
        guard let image = NSImage(data: imageData) else {
            Log.warn("InlineImage: Failed to create image from data")
            return nil
        }

        return InlineImage(image: image, args: args)
    }

    private func parseDimension(_ value: String) -> InlineImageDimension {
        if value.hasSuffix("%") {
            let num = String(value.dropLast())
            return .percent(Int(num) ?? 100)
        } else if value.hasSuffix("px") {
            let num = String(value.dropLast(2))
            return .pixels(Int(num) ?? 0)
        } else if value == "auto" {
            return .auto
        } else {
            // Assume cells
            return .cells(Int(value) ?? 0)
        }
    }

    // MARK: - Image Rendering

    /// Render an inline image to the appropriate size
    func renderImage(_ inlineImage: InlineImage, cellSize: NSSize, maxCells: (width: Int, height: Int)) -> NSImage? {
        let image = inlineImage.image
        let args = inlineImage.args

        // Calculate target size
        var targetWidth: CGFloat
        var targetHeight: CGFloat

        switch args.width {
        case .auto:
            targetWidth = image.size.width
        case .pixels(let px):
            targetWidth = CGFloat(px)
        case .percent(let pct):
            targetWidth = CGFloat(maxCells.width) * cellSize.width * CGFloat(pct) / 100
        case .cells(let cells):
            targetWidth = CGFloat(cells) * cellSize.width
        }

        switch args.height {
        case .auto:
            targetHeight = image.size.height
        case .pixels(let px):
            targetHeight = CGFloat(px)
        case .percent(let pct):
            targetHeight = CGFloat(maxCells.height) * cellSize.height * CGFloat(pct) / 100
        case .cells(let cells):
            targetHeight = CGFloat(cells) * cellSize.height
        }

        // Apply max constraints
        targetWidth = min(targetWidth, maxImageWidth)
        targetHeight = min(targetHeight, maxImageHeight)

        // Preserve aspect ratio if requested
        if args.preserveAspectRatio {
            let aspectRatio = image.size.width / image.size.height
            if targetWidth / targetHeight > aspectRatio {
                targetWidth = targetHeight * aspectRatio
            } else {
                targetHeight = targetWidth / aspectRatio
            }
        }

        // Create scaled image
        let scaledImage = NSImage(size: NSSize(width: targetWidth, height: targetHeight))
        scaledImage.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        scaledImage.unlockFocus()

        return scaledImage
    }
}

// MARK: - Supporting Types

struct InlineImage {
    let image: NSImage
    let args: InlineImageArgs
}

struct InlineImageArgs {
    var name: String?
    var size: Int?
    var width: InlineImageDimension = .auto
    var height: InlineImageDimension = .auto
    var preserveAspectRatio = true
    var inline = true
}

enum InlineImageDimension {
    case auto
    case pixels(Int)
    case percent(Int)
    case cells(Int)
}

// MARK: - Inline Image View

/// A view that displays an inline image in the terminal
final class InlineImageView: NSView {
    private let imageView: NSImageView
    private var image: InlineImage

    init(image: InlineImage, frame: NSRect) {
        self.image = image
        self.imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        imageView.image = image.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        // Add context menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("inlineImage.context.copy", "Copy Image"), action: #selector(copyImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("inlineImage.context.save", "Save Image..."), action: #selector(saveImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("inlineImage.context.preview", "Open in Preview"), action: #selector(openInPreview), keyEquivalent: ""))
        self.menu = menu
    }

    func setImage(_ image: NSImage) {
        self.image = InlineImage(image: image, args: self.image.args)
        imageView.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiff = image.image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = image.args.name ?? L("inlineImage.defaultFilename", "image.png")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }

            if let tiff = image.image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let data = bitmap.representation(using: .png, properties: [:]) {
                FileOperations.writeData(data, to: url)
            }
        }
    }

    @objc private func openInPreview() {
        // Save to temp file and open
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(image.args.name ?? "image.png")

        if let tiff = image.image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let data = bitmap.representation(using: .png, properties: [:]),
           FileOperations.writeData(data, to: tempURL) {
            NSWorkspace.shared.open(tempURL)
        }
    }
}

// MARK: - imgcat Script Generator

/// Generates the imgcat script for users
enum ImgcatScript {
    static let script = """
    #!/bin/bash
    # imgcat - Display images inline in Chau7 terminal
    # Based on iTerm2's imgcat protocol
    # Usage: imgcat [options] <image_file>
    #        cat image.png | imgcat

    print_image() {
        local file="$1"
        local name="${2:-$(basename "$file")}"

        if [ -z "$file" ] || [ "$file" = "-" ]; then
            # Read from stdin
            local data=$(base64)
            name="${name:-image}"
        else
            if [ ! -f "$file" ]; then
                echo "imgcat: $file: No such file" >&2
                return 1
            fi
            local data=$(base64 < "$file")
        fi

        # Get file size
        local size=${#data}

        # Print iTerm2 image escape sequence
        printf '\\e]1337;File=name=%s;size=%d;inline=1:%s\\a' \\
            "$(echo -n "$name" | base64)" "$size" "$data"
    }

    # Handle options
    while getopts "h" opt; do
        case $opt in
            h)
                echo "Usage: imgcat [options] <image_file>"
                echo "       cat image.png | imgcat"
                echo ""
                echo "Display images inline in the terminal."
                echo ""
                echo "Options:"
                echo "  -h    Show this help message"
                exit 0
                ;;
        esac
    done
    shift $((OPTIND-1))

    # Main
    if [ $# -eq 0 ]; then
        # Read from stdin
        print_image "-"
    elif [ "$1" = "-" ]; then
        print_image "-"
    else
        for file in "$@"; do
            print_image "$file"
        done
    fi

    echo ""  # Newline after image
    """

    /// Install the imgcat script to ~/bin or /usr/local/bin
    static func install(to directory: String = "~/bin") -> Bool {
        let expandedPath = RuntimeIsolation.expandTilde(in: directory)
        let scriptPath = (expandedPath as NSString).appendingPathComponent("imgcat")

        do {
            // Create directory if needed
            try FileManager.default.createDirectory(
                atPath: expandedPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Write script
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            // Make executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptPath
            )

            Log.info("Installed imgcat to \(scriptPath)")
            return true
        } catch {
            Log.error("Failed to install imgcat: \(error)")
            return false
        }
    }
}
