import Foundation
import AppKit
import Chau7Core

// MARK: - Search

// Extracted from TerminalSessionModel.swift
// Contains: find in terminal, search state, highlight management,
// case sensitivity, regex search, semantic search.

extension TerminalSessionModel {
    /// Returns cached buffer data or fetches fresh data if needed (memory optimization).
    private func getBufferData() -> Data? {
        guard let view = activeTerminalView else { return nil }

        if bufferNeedsRefresh || cachedBufferData == nil {
            cachedBufferData = view.getBufferAsData()
            bufferNeedsRefresh = false
            if let data = cachedBufferData {
                updateBufferLineCount(from: data)
            }
        }
        return cachedBufferData
    }

    func captureRemoteSnapshot() -> Data? {
        guard let view = activeTerminalView else { return nil }
        let data = view.getBufferAsData()
        cachedBufferData = data
        bufferNeedsRefresh = false
        if let data { updateBufferLineCount(from: data) }
        return data
    }

    func captureRemoteGridSnapshot() -> Data? {
        activeTerminalView?.captureRemoteGridSnapshotPayload()
    }

    private func updateBufferLineCount(from bufferData: Data) {
        let newlineCount = bufferData.reduce(0) { count, byte in
            count + (byte == 0x0A ? 1 : 0)
        }
        bufferLineCount = max(1, newlineCount + 1)
    }

    func updateSearch(query: String, maxMatches: Int, maxPreviewLines: Int, caseSensitive: Bool = false, regexEnabled: Bool = false, wholeWord: Bool = false) -> SearchSummary {
        let previousQuery = searchQuery
        let previousCaseSensitive = searchCaseSensitive
        let previousRegex = searchRegexEnabled
        searchQuery = query
        searchCaseSensitive = caseSensitive
        searchRegexEnabled = regexEnabled
        searchWholeWord = wholeWord

        guard let bufferData = getBufferData() else {
            searchMatches = []
            activeSearchIndex = 0
            return SearchSummary(count: 0, previewLines: [], error: nil)
        }

        // Use cached buffer data (refreshed only when new output arrives)
        let computed: (matches: [SearchMatch], previewLines: [String], error: String?)
        // Whole-word mode: promote to regex with \b boundaries.
        // For plain text, escape the query to avoid regex metacharacter issues.
        let effectiveRegex = regexEnabled || wholeWord
        let effectivePattern: String
        if wholeWord && !regexEnabled {
            effectivePattern = "\\b" + NSRegularExpression.escapedPattern(for: query) + "\\b"
        } else if wholeWord {
            effectivePattern = "\\b(?:" + query + ")\\b"
        } else {
            effectivePattern = query
        }

        if effectiveRegex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: effectivePattern, options: options) else {
                searchMatches = []
                activeSearchIndex = 0
                return SearchSummary(count: 0, previewLines: [], error: "Invalid regex")
            }
            let result = computeRegexMatches(
                regex: regex,
                maxMatches: maxMatches,
                maxPreviewLines: maxPreviewLines,
                bufferData: bufferData
            )
            computed = (result.matches, result.previewLines, nil)
        } else {
            let result = computeSearchMatches(
                query: query,
                maxMatches: maxMatches,
                maxPreviewLines: maxPreviewLines,
                bufferData: bufferData,
                caseSensitive: caseSensitive
            )
            computed = (result.matches, result.previewLines, nil)
        }

        searchMatches = computed.matches
        if previousQuery != query || previousCaseSensitive != caseSensitive || previousRegex != regexEnabled {
            activeSearchIndex = 0
        } else if activeSearchIndex >= computed.matches.count {
            activeSearchIndex = max(0, computed.matches.count - 1)
        }
        highlightView?.scheduleDisplay() // Use batched display for better latency
        return SearchSummary(count: computed.matches.count, previewLines: computed.previewLines, error: computed.error)
    }

    func updateSemanticSearch(query: String, maxMatches: Int, maxPreviewLines: Int) -> SearchSummary {
        searchQuery = query
        searchCaseSensitive = false
        searchRegexEnabled = false

        _ = getBufferData()
        let blocks = semanticDetector.search(query: query)
        let limited = Array(blocks.prefix(maxMatches))

        searchMatches = limited.map { block in
            SearchMatch(row: block.startRow, col: 0, length: max(1, block.command.count))
        }
        activeSearchIndex = 0
        highlightView?.scheduleDisplay() // Use batched display for better latency

        let previews = limited.prefix(maxPreviewLines).map { block -> String in
            if let exitCode = block.exitCode {
                return "\(block.command) (exit \(exitCode))"
            }
            return block.command
        }
        return SearchSummary(count: searchMatches.count, previewLines: previews, error: nil)
    }

    func scheduleSearchRefresh() {
        guard !searchQuery.isEmpty else { return }

        // Use cached buffer data (refreshed only when new output arrives)
        guard let bufferData = getBufferData() else { return }
        let query = searchQuery
        let caseSensitive = searchCaseSensitive
        let regexEnabled = searchRegexEnabled

        searchUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let computed: (matches: [SearchMatch], previewLines: [String])
            if regexEnabled {
                let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                    return
                }
                computed = computeRegexMatches(
                    regex: regex,
                    maxMatches: 400,
                    maxPreviewLines: 12,
                    bufferData: bufferData
                )
            } else {
                computed = computeSearchMatches(
                    query: query,
                    maxMatches: 400,
                    maxPreviewLines: 12,
                    bufferData: bufferData,
                    caseSensitive: caseSensitive
                )
            }

            DispatchQueue.main.async {
                guard self.searchQuery == query else { return }
                self.searchMatches = computed.matches
                if self.activeSearchIndex >= computed.matches.count {
                    self.activeSearchIndex = max(0, computed.matches.count - 1)
                }
                self.highlightView?.scheduleDisplay() // Use batched display for better latency
            }
        }
        searchUpdateWorkItem = work
        // Adaptive debounce based on buffer size (latency optimization)
        // Smaller buffers get faster updates, larger buffers need more debounce
        let debounceInterval: TimeInterval
        if bufferLineCount < 1000 {
            debounceInterval = 0.05 // 50ms for small buffers
        } else if bufferLineCount < 5000 {
            debounceInterval = 0.1 // 100ms for medium buffers
        } else {
            debounceInterval = 0.15 // 150ms for large buffers (was 200ms)
        }
        searchQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex + 1) % searchMatches.count
        highlightView?.scheduleDisplay() // Use batched display for better latency
        scrollToActiveMatch()
    }

    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        activeSearchIndex = (activeSearchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightView?.scheduleDisplay() // Use batched display for better latency
        scrollToActiveMatch()
    }

    func currentMatch() -> SearchMatch? {
        guard !searchMatches.isEmpty else { return nil }
        let index = max(0, min(activeSearchIndex, searchMatches.count - 1))
        return searchMatches[index]
    }

    private func scrollToActiveMatch() {
        guard let view = activeTerminalView, let match = currentMatch() else { return }
        let visibleRows = max(1, view.terminalRows)
        let maxScrollback = max(1, bufferLineCount - visibleRows)
        let clampedRow = max(0, min(match.row, maxScrollback))
        let position = Double(clampedRow) / Double(maxScrollback)
        view.scroll(toPosition: position)
    }

    /// Computes search matches from pre-captured buffer data (thread-safe).
    /// Supports case-sensitive and case-insensitive search (Issue #23).
    /// Memory-optimized: uses Substring to avoid copies, case-insensitive option instead of lowercased()
    private func computeSearchMatches(
        query: String,
        maxMatches: Int,
        maxPreviewLines: Int,
        bufferData: Data,
        caseSensitive: Bool = false
    ) -> (matches: [SearchMatch], previewLines: [String]) {
        guard !query.isEmpty else {
            return ([], [])
        }

        // Decode buffer data to string
        let text = String(decoding: bufferData, as: UTF8.self)

        // Pre-allocate with reasonable capacity
        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxMatches, 100))
        var previews: [String] = []
        previews.reserveCapacity(maxPreviewLines)

        // Search options - use case insensitive option instead of creating lowercased copies
        let searchOptions: String.CompareOptions = caseSensitive ? [] : .caseInsensitive

        // Process line by line using Substring (no copy) instead of String
        var lineStart = text.startIndex
        var row = 0

        while lineStart < text.endIndex, matches.count < maxMatches {
            // Find end of current line
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex

            // Use Substring directly - no memory copy
            let lineSlice = text[lineStart ..< lineEnd]

            if !lineSlice.isEmpty {
                var searchStart = lineSlice.startIndex

                // Search within the slice without creating copies
                while searchStart < lineSlice.endIndex {
                    guard let range = lineSlice.range(
                        of: query,
                        options: searchOptions,
                        range: searchStart ..< lineSlice.endIndex
                    ) else { break }

                    let col = lineSlice.distance(from: lineSlice.startIndex, to: range.lowerBound)
                    matches.append(SearchMatch(row: row, col: col, length: query.count))

                    if matches.count >= maxMatches { break }
                    searchStart = range.upperBound
                }

                // Only create String copy for preview lines
                if !matches.isEmpty, matches.last?.row == row, previews.count < maxPreviewLines {
                    previews.append(String(lineSlice))
                }
            }

            // Move to next line
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            row += 1
        }

        return (matches, previews)
    }

    private func computeRegexMatches(
        regex: NSRegularExpression,
        maxMatches: Int,
        maxPreviewLines: Int,
        bufferData: Data
    ) -> (matches: [SearchMatch], previewLines: [String]) {
        // Decode buffer data to string
        let text = String(decoding: bufferData, as: UTF8.self)

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(maxMatches, 100))
        var previews: [String] = []
        previews.reserveCapacity(maxPreviewLines)

        var lineStart = text.startIndex
        var row = 0

        while lineStart < text.endIndex, matches.count < maxMatches {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let lineSlice = text[lineStart ..< lineEnd]

            if !lineSlice.isEmpty {
                let lineString = String(lineSlice)
                let nsLine = lineString as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                regex.enumerateMatches(in: lineString, options: [], range: range) { match, _, stop in
                    guard let match = match else { return }
                    let col = match.range.location
                    let length = match.range.length
                    matches.append(SearchMatch(row: row, col: col, length: length))
                    if matches.count >= maxMatches {
                        stop.pointee = true
                    }
                }

                if !matches.isEmpty, matches.last?.row == row, previews.count < maxPreviewLines {
                    previews.append(lineString)
                }
            }

            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            row += 1
        }

        return (matches, previews)
    }

}
