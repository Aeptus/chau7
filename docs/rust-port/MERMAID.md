# Native Mermaid previews

Markdown preview renders fenced `mermaid` blocks as diagrams. Open a Markdown file and use Source/Runbook (Cmd+Shift+P on macOS). Other fences keep their existing behaviour. Mermaid blocks are display-only and excluded from Run All.

The default view keeps base text at least 12 px tall and allows scrolling when a chart is wide. The toolbar provides Fit, 100%, zoom from 10% to 400%, Expand/Collapse, Source/Diagram, and Copy SVG. Scroll the viewport to inspect large diagrams. Source direction is preserved during resizing. Errors show an inline message and the original source.

## Implementation

The unmodified Ondine Rust compiler is pinned by full Git revision in Cargo.toml and Cargo.lock. It runs in process, without Node, WebViews, subprocesses, JavaScript or runtime network requests. Compilation and rasterization run on GPUI's background executor after a 120 ms debounce. Generation checks discard obsolete source, width, theme or zoom results.

Each editor owns its diagram entities and discards them when opening another file. The memory-only SVG cache includes source, quantized panel width, theme and UTC date (for Gantt markers), with at most 32 entries and 8 MiB including source keys. Widths use 32 px increments.

The XML-aware native SVG adapter resolves browser CSS variables to explicit colours and monospace fonts and converts CSS rectangle radii into SVG attributes. It touches presentation attributes only, preserving labels and author colours. Colours follow the editor surface and app chrome.

Limits: 50,000 source bytes, 2,000 flowchart edges, 2 MB SVG output, and 16,384 px per diagram dimension. Raster images are capped at 4,096 px per side and 8 million pixels including GPUI's 2x raster scale. Very large diagrams may lose sharpness at high zoom; splitting them improves readability. Diagram links and external images are disabled; normal Markdown links keep working.

Ondine does not promise pixel-identical Mermaid.js layouts. JavaScript callbacks and browser HTML labels are not provided. Both Ondine and Pele-derived MIT notices ship in application resources.

## Validation

Core regressions cover common diagram types, Unicode/escaped labels, errors, limits, width/theme/date cache identity, eviction, and real usvg/resvg parsing and rasterization with light and dark colours. Native view regressions cover source replacement, zoom reset, and invalidation of pending work.

For patch-only delivery, core tests and native type checking do not establish live visual acceptance. Do not rebuild, install, stop or restart the running app without operator authorization.
