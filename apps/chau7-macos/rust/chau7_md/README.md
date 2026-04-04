# chau7_md

Terminal markdown renderer. Reads markdown from a file or stdin and outputs
ANSI-formatted text tuned for dark terminal backgrounds.

## Usage

```bash
# Render a file
chau7-md README.md

# Pipe from stdin
cat CHANGELOG.md | chau7-md
```

## What It Does

Uses [termimad](https://crates.io/crates/termimad) to render markdown with:
- Colored heading hierarchy (cyan → green → yellow → magenta → blue → red)
- Bold (white), italic (magenta)
- Inline code (yellow on dark grey), code blocks (dark grey background)
- Dimmed block quotes, cyan bullet points
- Slightly off-white body text for readability

## Building

From the Rust workspace root (`apps/chau7-macos/rust/`):

```bash
cargo build -p chau7_md           # debug
cargo build -p chau7_md --release # release
```

Binary lands in `target/{debug,release}/chau7-md`.
