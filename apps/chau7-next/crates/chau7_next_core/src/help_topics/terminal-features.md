# Terminal Features

## Mouse Features

- **Option+Click**: Move cursor to clicked position
- **⌘+Click**: Open file path or URL
- **Select text**: Automatically copies if "Copy on Select" is enabled

## Inline Images

Display images directly in the terminal using the imgcat protocol:

```bash
imgcat image.png
cat image.png | imgcat
```

Enable/disable in Settings → Terminal → Inline Images.

## Syntax Highlighting

Chau7 provides automatic syntax highlighting for:
- JSON output
- URLs
- File paths
- Error messages

## Split Panes

Split the terminal view to work with multiple terminals:
- **⌘D**: Split horizontally
- **⇧⌘D**: Split vertically

## Scrollback

- Default: 10,000 lines
- Adjustable in Settings → Terminal → Scrollback
- **Scroll to Top**: Access via Command Palette
- **Scroll to Bottom**: Access via Command Palette
