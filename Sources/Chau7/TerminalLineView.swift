import SwiftUI

// MARK: - Reusable Terminal Line Components (Code Optimization)
// Consolidates duplicate line rendering logic from MainPanelView

/// A single terminal line with optional normalization and styling
struct TerminalLineView: View {
    let line: String
    var isInput: Bool = false
    var normalize: Bool = true
    var fontSize: CGFloat = 11

    var body: some View {
        Text(displayText)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(isInput ? .primary : .secondary)
            .textSelection(.enabled)
    }

    private var displayText: String {
        normalize ? TerminalNormalizer.normalize(line) : line
    }
}

/// A list of terminal lines with consistent styling
struct TerminalLinesView: View {
    let lines: [String]
    var normalize: Bool = true
    var fontSize: CGFloat = 11

    var body: some View {
        ForEach(lines.indices, id: \.self) { index in
            TerminalLineView(
                line: lines[index],
                normalize: normalize,
                fontSize: fontSize
            )
        }
    }
}

/// A scrollable container for terminal output
struct ScrollableTerminalView: View {
    let lines: [String]
    var normalize: Bool = true
    var fontSize: CGFloat = 11
    var maxHeight: CGFloat? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                TerminalLinesView(
                    lines: lines,
                    normalize: normalize,
                    fontSize: fontSize
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: maxHeight)
    }
}

/// History entry row with timestamp
struct HistoryEntryRow: View {
    let entry: HistoryEntry
    var showTimestamp: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showTimestamp {
                Text("\(Formatters.shortTime.string(from: Date(timeIntervalSince1970: entry.timestamp))) - \(entry.sessionId.prefix(8))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(entry.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
struct TerminalLineView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading) {
            TerminalLineView(line: "$ ls -la", isInput: true)
            TerminalLineView(line: "total 42")
            TerminalLineView(line: "drwxr-xr-x  5 user  staff  160 Jan 10 15:30 .")
        }
        .padding()
    }
}
#endif
