import CryptoKit
import Foundation

public struct DetectedInteractivePrompt: Equatable, Sendable {
    public let signature: String
    public let prompt: String
    public let detail: String?
    public let options: [RemoteInteractivePromptOption]
    /// Zero-based index of the option row carrying the selection cursor, from
    /// either the keyword or the structural pass; nil when no single cursor row
    /// was found (and for fallback matches). Internal detection metadata —
    /// never serialized to the wire, and never part of the signature (a cursor
    /// move must not mint a new prompt ID).
    public let selectedOptionIndex: Int?

    public init(
        signature: String,
        prompt: String,
        detail: String?,
        options: [RemoteInteractivePromptOption],
        selectedOptionIndex: Int? = nil
    ) {
        self.signature = signature
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.selectedOptionIndex = selectedOptionIndex
    }
}

public enum InteractivePromptDetector {
    private static let yesNoRegex = try? NSRegularExpression(
        pattern: #"[\[\(]\s*(y(?:es)?)\s*/\s*(n(?:o)?)\s*[\]\)]"#,
        options: [.caseInsensitive]
    )
    private static let numberedOptionRegex = try? NSRegularExpression(pattern: #"^[^A-Za-z0-9]*([0-9]+)\.\s+(.+?)$"#)

    public static func detect(in text: String, toolName: String) -> DetectedInteractivePrompt? {
        guard supports(toolName: toolName) else { return nil }

        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        let allLines = normalized.components(separatedBy: "\n")
        let lines = Array(allLines.suffix(80))

        guard let match = findPrompt(in: lines) else { return nil }
        let options = navigationOptions(for: match.options, selectedIndex: match.selectedOptionIndex)
            ?? match.options
        // The signature covers ids and labels only, so re-expressing a row's
        // response as arrows keeps the prompt's identity stable — the phone
        // sees updated responses under the same prompt ID, not a new card.
        let signature = signature(prompt: match.prompt, options: options)
        return DetectedInteractivePrompt(
            signature: signature,
            prompt: match.prompt,
            detail: match.detail,
            options: options,
            selectedOptionIndex: match.selectedOptionIndex
        )
    }

    public static func fallbackInputRequest(in text: String) -> DetectedInteractivePrompt? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        let allLines = normalized.components(separatedBy: "\n")
        let lines = Array(allLines.suffix(80))
        guard let match = findFallbackPrompt(in: lines) else { return nil }

        // Only surface a fallback when the tool showed an explicit yes/no
        // affordance we can turn into real choices. A bare question or a
        // colon-terminated line is indistinguishable from a normal end-of-turn
        // message (an AI turn routinely ends "…shall I proceed?"), so surfacing
        // those turned ordinary turns into phantom "interactive prompt" cards on
        // the phone with no options. Requiring options keeps the fallback to
        // what it can genuinely act on: a y/n confirmation the numbered-option
        // detector missed.
        let options = synthesizedYesNoOptions(prompt: match.prompt)
        guard !options.isEmpty else { return nil }

        return DetectedInteractivePrompt(
            signature: signature(prompt: match.prompt, options: options),
            prompt: match.prompt,
            detail: match.detail,
            options: options
        )
    }

    /// When a fallback prompt advertises an explicit yes/no affordance
    /// (`[y/n]`, `(Y/n)`, `[yes/no]`, …), offer Yes/No buttons that send exactly
    /// the tokens the tool showed. This is intentionally conservative: a bare
    /// "Proceed?" with no y/n hint yields no options, because guessing the key
    /// for a live terminal is worse than leaving the custom-reply field.
    static func synthesizedYesNoOptions(prompt: String) -> [RemoteInteractivePromptOption] {
        guard let regex = yesNoRegex else {
            return []
        }
        let range = NSRange(prompt.startIndex ..< prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, options: [], range: range),
              match.numberOfRanges == 3,
              let yesRange = Range(match.range(at: 1), in: prompt),
              let noRange = Range(match.range(at: 2), in: prompt) else {
            return []
        }

        let yesToken = String(prompt[yesRange]).lowercased()
        let noToken = String(prompt[noRange]).lowercased()
        // Neither side is flagged destructive: for a "[y/N]" affordance the
        // dangerous choice is often "Yes" (delete/overwrite/apply), the opposite
        // of the numbered-option case where the tool spells out a "No"/"Cancel"
        // label. We can't infer intent from y/n alone, so we don't mis-warn.
        return [
            RemoteInteractivePromptOption(id: "yes", label: "Yes", response: yesToken + "\r", isDestructive: false),
            RemoteInteractivePromptOption(id: "no", label: "No", response: noToken + "\r", isDestructive: false)
        ]
    }

    /// The arrow presses that move a menu's selection cursor from `selected`
    /// to `target`, followed by Enter to confirm.
    static func navigationResponse(from selected: Int, to target: Int) -> String {
        let delta = target - selected
        guard delta != 0 else { return "\r" }
        return String(repeating: delta > 0 ? "\u{1B}[B" : "\u{1B}[A", count: abs(delta)) + "\r"
    }

    /// Re-expresses numbered options as cursor navigation.
    ///
    /// A detected cursor glyph is the tool stating that arrow keys drive its
    /// selection, and several TUIs — Claude Code's permission prompt among
    /// them — act *only* on the cursor. There, a typed row number is swallowed
    /// and the Enter that follows confirms whatever row was already
    /// highlighted, silently answering a different option than the one tapped.
    /// Navigating with arrows drives the same selection state the user would,
    /// and works on digit-accepting menus too. iOS turns these into semantic
    /// KEY_INPUT presses via `RemoteMenuKeyHeuristics.semanticKeys`.
    ///
    /// Returns nil when no single cursor row was identified, which leaves the
    /// digit responses untouched: without knowing where the cursor is, a
    /// relative move cannot be computed, and digits remain the better guess.
    static func navigationOptions(
        for options: [RemoteInteractivePromptOption],
        selectedIndex: Int?
    ) -> [RemoteInteractivePromptOption]? {
        guard let selectedIndex, options.indices.contains(selectedIndex) else { return nil }
        return options.enumerated().map { offset, option in
            RemoteInteractivePromptOption(
                id: option.id,
                label: option.label,
                response: navigationResponse(from: selectedIndex, to: offset),
                isDestructive: option.isDestructive
            )
        }
    }

    private static func supports(toolName: String) -> Bool {
        AIToolRegistry.usesTerminalUIHeuristics(forName: toolName)
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private typealias PromptMatch = (
        prompt: String,
        detail: String?,
        options: [RemoteInteractivePromptOption],
        selectedOptionIndex: Int?
    )

    private static func findPrompt(in lines: [String]) -> PromptMatch? {
        // Keyword detection first: it anchors on explicit prompt wording, so
        // when both passes would match it is the higher-confidence read.
        if let keyword = findKeywordPrompt(in: lines) {
            return (keyword.prompt, keyword.detail, keyword.options, keyword.selectedOptionIndex)
        }
        return findStructuralPrompt(in: lines)
    }

    private typealias KeywordMatch = (
        prompt: String,
        detail: String?,
        options: [RemoteInteractivePromptOption],
        selectedOptionIndex: Int?
    )

    private static func findKeywordPrompt(in lines: [String]) -> KeywordMatch? {
        guard !lines.isEmpty else { return nil }

        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = cleanedLine(lines[index])
            guard isPromptLine(line) else { continue }

            let rows = parseOptions(in: lines, after: index)
            guard rows.count >= 2 else { continue }

            let detail = parseDetail(in: lines, aroundPromptAt: index)
            // Exactly one cursor row is the menu telling us where its selection
            // sits. None (a plain numbered list) or several (styling artefacts)
            // is not a reading we can navigate from, so the caller keeps the
            // digit responses.
            let cursorRows = rows.indices.filter { rows[$0].hasCursor }
            let selected = cursorRows.count == 1 ? cursorRows.first : nil
            return (line, detail, rows.map(\.option), selected)
        }

        return nil
    }

    private static func parseOptions(
        in lines: [String],
        after promptIndex: Int
    ) -> [(option: RemoteInteractivePromptOption, hasCursor: Bool)] {
        var options: [(option: RemoteInteractivePromptOption, hasCursor: Bool)] = []

        for offset in 1 ... 8 {
            let index = promptIndex + offset
            guard index < lines.count else { break }

            let raw = cleanedLine(lines[index])
            if raw.isEmpty {
                if !options.isEmpty { break }
                continue
            }

            if let option = parseOption(from: raw) {
                options.append(option)
                continue
            }

            if !options.isEmpty {
                break
            }
        }

        return options
    }

    private static func parseOption(
        from line: String
    ) -> (option: RemoteInteractivePromptOption, hasCursor: Bool)? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = numberedOptionRegex else { return nil }
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges == 3,
              let tokenRange = Range(match.range(at: 1), in: line),
              let labelRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let token = String(line[tokenRange])
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }

        return (
            RemoteInteractivePromptOption(
                id: token,
                label: label,
                response: token + "\r",
                isDestructive: isDestructiveLabel(label)
            ),
            // Same glyph test the structural pass uses: the cursor sits in the
            // non-alphanumeric prefix ahead of the row number.
            line[..<tokenRange.lowerBound].contains { cursorGlyphs.contains($0) }
        )
    }

    private static let destructiveWords = ["deny", "reject", "cancel", "abort", "stop", "no"]

    /// Shared destructive-option classification, also used by the structured
    /// prompt store so hook-sourced and scraped options flag consistently.
    public static func isDestructiveLabel(_ label: String) -> Bool {
        destructiveWords.contains { label.lowercased().contains($0) }
    }

    private static func parseDetail(in lines: [String], aroundPromptAt index: Int) -> String? {
        var details: [String] = []

        for offset in 1 ... 2 {
            let previousIndex = index - offset
            guard previousIndex >= 0 else { break }
            let candidate = cleanedLine(lines[previousIndex])
            guard !candidate.isEmpty, !isMetaLine(candidate), !isPromptLine(candidate) else { continue }
            details.insert(candidate, at: 0)
        }

        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    // MARK: - Structural detection (no prompt keyword required)

    /// Selection-cursor glyphs TUIs place on the highlighted option row.
    /// Deliberately excludes bare ">" — shell prompts and quoted text use it.
    private static let cursorGlyphs: Set<Character> = ["\u{276F}", "\u{203A}", "\u{25B8}"] // ❯ › ▸

    private static let structuralWindowLines = 30
    private static let maxStructuralOptions = 12
    private static let maxUnnumberedLabelLength = 60

    private static let structuralNumberedRegex = try? NSRegularExpression(
        pattern: #"^[^A-Za-z0-9]*?([0-9]+)[.)]\s+(.+?)$"#
    )

    /// Detects a selection menu by shape instead of prompt wording: a
    /// contiguous block of option rows at the tail of the snapshot, exactly
    /// one of which carries a selection-cursor glyph. The glyph requirement
    /// separates a live menu from a numbered list in ordinary prose; requiring
    /// ≥2 aligned option rows separates it from a starship/p10k shell prompt
    /// (`❯ git status`). This is what surfaces agent-authored questions
    /// (AskUserQuestion) whose wording matches no keyword.
    private static func findStructuralPrompt(in lines: [String]) -> PromptMatch? {
        let window = Array(lines.suffix(structuralWindowLines))

        // The block must sit at the snapshot tail: skip trailing empty and
        // meta lines ("Esc to cancel …"), then require option rows directly.
        var end = window.count - 1
        while end >= 0 {
            let cleaned = cleanedLine(window[end])
            if cleaned.isEmpty || isMetaLine(cleaned) {
                end -= 1
                continue
            }
            break
        }
        guard end >= 1 else { return nil }

        return numberedStructuralBlock(in: window, endingAt: end)
            ?? unnumberedStructuralBlock(in: window, endingAt: end)
    }

    private static func numberedStructuralBlock(in window: [String], endingAt end: Int) -> PromptMatch? {
        var rows: [(option: RemoteInteractivePromptOption, hasCursor: Bool)] = []
        var index = end
        while index >= 0, rows.count < maxStructuralOptions, let row = numberedOptionRow(window[index]) {
            rows.insert(row, at: 0)
            index -= 1
        }
        guard rows.count >= 2 else { return nil }
        // Real menus number 1..n consecutively; anything else is prose.
        guard rows.enumerated().allSatisfy({ Int($1.option.id) == $0 + 1 }) else { return nil }
        let cursorRows = rows.indices.filter { rows[$0].hasCursor }
        guard cursorRows.count == 1, let selected = cursorRows.first else { return nil }
        guard let context = promptContext(in: window, above: index) else { return nil }
        return (context.prompt, context.detail, rows.map(\.option), selected)
    }

    private static func numberedOptionRow(_ line: String) -> (option: RemoteInteractivePromptOption, hasCursor: Bool)? {
        let cleaned = cleanedLine(line)
        guard !cleaned.isEmpty, !isMetaLine(cleaned), let regex = structuralNumberedRegex else { return nil }
        let range = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
              match.numberOfRanges == 3,
              let tokenRange = Range(match.range(at: 1), in: cleaned),
              let labelRange = Range(match.range(at: 2), in: cleaned) else {
            return nil
        }
        let token = String(cleaned[tokenRange])
        let label = String(cleaned[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let hasCursor = cleaned[..<tokenRange.lowerBound].contains { cursorGlyphs.contains($0) }
        return (
            RemoteInteractivePromptOption(
                id: token,
                label: label,
                response: token + "\r",
                isDestructive: isDestructiveLabel(label)
            ),
            hasCursor
        )
    }

    private struct UnnumberedRow {
        let label: String
        let hasCursor: Bool
        let textColumn: Int
    }

    /// Arrow-only menus have no digits to type, so options respond with the
    /// arrow presses that move the cursor from the detected row to the target,
    /// then Enter. These ride the existing text input path: iOS splits the
    /// trailing CR into a separate Enter frame, and the Mac passes the CSI
    /// body raw with a delayed Enter (remoteInputPlan).
    private static func unnumberedStructuralBlock(in window: [String], endingAt end: Int) -> PromptMatch? {
        var rows: [UnnumberedRow] = []
        var index = end
        while index >= 0, rows.count < maxStructuralOptions, let row = unnumberedOptionRow(window[index]) {
            rows.insert(row, at: 0)
            index -= 1
        }
        guard rows.count >= 2 else { return nil }
        let cursorRows = rows.indices.filter { rows[$0].hasCursor }
        guard cursorRows.count == 1, let selected = cursorRows.first else { return nil }
        // All rows must align on the same text column — a menu's rows do, a
        // shell command followed by its output does not.
        let textColumn = rows[selected].textColumn
        guard rows.allSatisfy({ $0.textColumn == textColumn }) else { return nil }
        guard let context = promptContext(in: window, above: index) else { return nil }
        // Without digits, alignment alone is too weak (e.g. "❯ npm test"
        // above two indented result lines). Require a header that reads like
        // a question or menu title before trusting an unnumbered block.
        guard isLikelyMenuHeader(context.prompt) else { return nil }

        let options = rows.enumerated().map { offset, row in
            RemoteInteractivePromptOption(
                id: "opt-\(offset)",
                label: row.label,
                response: navigationResponse(from: selected, to: offset),
                isDestructive: isDestructiveLabel(row.label)
            )
        }
        return (context.prompt, context.detail, options, selected)
    }

    private static func unnumberedOptionRow(_ line: String) -> UnnumberedRow? {
        let normalized = line.replacingOccurrences(of: "\u{00A0}", with: " ")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMetaLine(trimmed) else { return nil }
        // Numbered rows belong to the numbered pass.
        guard numberedOptionRow(line) == nil else { return nil }
        let leadingSpaces = normalized.prefix(while: { $0 == " " }).count

        if let first = trimmed.first, cursorGlyphs.contains(first) {
            let afterGlyph = trimmed.dropFirst()
            let gap = afterGlyph.prefix(while: { $0 == " " }).count
            let label = String(afterGlyph).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= maxUnnumberedLabelLength else { return nil }
            return UnnumberedRow(label: label, hasCursor: true, textColumn: leadingSpaces + 1 + gap)
        }

        // Sibling rows: short, list-like, and free of sentence punctuation.
        guard trimmed.count <= maxUnnumberedLabelLength,
              !trimmed.hasSuffix("."), !trimmed.hasSuffix(":"), !trimmed.hasSuffix("?"),
              trimmed.rangeOfCharacter(from: .letters) != nil else {
            return nil
        }
        return UnnumberedRow(label: trimmed, hasCursor: false, textColumn: leadingSpaces)
    }

    private static func isLikelyMenuHeader(_ prompt: String) -> Bool {
        if prompt.hasSuffix("?") || prompt.hasSuffix(":") {
            return true
        }
        let lowered = prompt.lowercased()
        return ["select", "choose", "pick", "which"].contains { lowered.contains($0) }
    }

    /// Nearest preceding line that can serve as the prompt text: non-empty,
    /// not a meta line, and containing at least one letter (skips box-drawing
    /// borders and dividers). No candidate means no prompt — a menu without a
    /// question isn't actionable on the phone.
    private static func promptContext(in window: [String], above index: Int) -> (prompt: String, detail: String?)? {
        var promptIndex = index
        while promptIndex >= 0 {
            let cleaned = cleanedLine(window[promptIndex])
            if cleaned.isEmpty || isMetaLine(cleaned) || cleaned.rangeOfCharacter(from: .letters) == nil {
                promptIndex -= 1
                continue
            }
            return (cleaned, parseDetail(in: window, aroundPromptAt: promptIndex))
        }
        return nil
    }

    private static func findFallbackPrompt(in lines: [String]) -> (prompt: String, detail: String?)? {
        let cleaned = lines.map(cleanedLine)
        let nonEmpty = cleaned.enumerated().filter { !$0.element.isEmpty && !isMetaLine($0.element) }
        guard !nonEmpty.isEmpty else { return nil }

        let preferredPromptIndex = nonEmpty.last { _, line in
            isFallbackPromptCandidate(line)
        }?.offset

        let promptIndex = preferredPromptIndex ?? nonEmpty.last?.offset
        guard let promptIndex else { return nil }

        let prompt = cleaned[promptIndex]
        guard !prompt.isEmpty else { return nil }

        let detail = parseDetail(in: lines, aroundPromptAt: promptIndex)
        return (prompt, detail)
    }

    private static func cleanedLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMetaLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("esc to cancel") ||
            lowered.contains("tab to amend") ||
            lowered.contains("ctrl+e") ||
            lowered.contains("press ctrl") ||
            lowered.contains("ctrl+c")
    }

    private static func isPromptLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let keywords = [
            "do you want",
            "select an option",
            "choose an option",
            "which option",
            "continue",
            "proceed",
            "approve",
            "allow this"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private static func isFallbackPromptCandidate(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("?") {
            return true
        }

        let keywords = [
            "enter your",
            "type your",
            "waiting for",
            "input required",
            "provide",
            "respond",
            "reply",
            "what should",
            "how should",
            "continue:"
        ]
        if keywords.contains(where: { lowered.contains($0) }) {
            return true
        }

        return line.hasSuffix(":")
    }

    private static func signature(prompt: String, options: [RemoteInteractivePromptOption]) -> String {
        let basis = prompt + "\n" + options.map { "\($0.id):\($0.label)" }.joined(separator: "\n")
        return Data(SHA256.hash(data: Data(basis.utf8)).prefix(12)).base64EncodedString()
    }
}
