import Foundation

public enum ClaudeCodeStatusLineConfiguration {
    public static let helperName = "chau7-claude-statusline"
    private static let iso8601 = DateFormatters.iso8601

    private static let iso8601Basic = DateFormatters.iso8601NoFractional

    public static func helperScript(
        latestStatusPayloadPath: String,
        originalStatusLinePath: String
    ) -> String {
        """
        #!/bin/sh
        INPUT=$(cat)

        LATEST_STATUS_PAYLOAD_FILE=\(quotedShellString(latestStatusPayloadPath))
        ORIGINAL_STATUSLINE_FILE=\(quotedShellString(originalStatusLinePath))

        write_snapshot() {
            TARGET_DIR=$(dirname "$LATEST_STATUS_PAYLOAD_FILE")
            mkdir -p "$TARGET_DIR" || return 0
            TMP_FILE="${LATEST_STATUS_PAYLOAD_FILE}.tmp.$$"
            printf '%s' "$INPUT" > "$TMP_FILE" && mv "$TMP_FILE" "$LATEST_STATUS_PAYLOAD_FILE"
        }

        delegate_original() {
            [ ! -f "$ORIGINAL_STATUSLINE_FILE" ] && return 0
            ORIG_CMD=$(/usr/bin/plutil -extract command raw -o - "$ORIGINAL_STATUSLINE_FILE" 2>/dev/null)
            [ -z "$ORIG_CMD" ] && return 0
            printf '%s' "$INPUT" | eval "$ORIG_CMD"
        }

        write_snapshot
        delegate_original
        """
    }

    public static func quotaSnapshot(
        fromStatusJSON data: Data,
        capturedAt: Date,
        rawSourceRef: String = "statusLine"
    ) -> ProviderQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else {
            return nil
        }

        var windows: [ProviderQuotaWindowSnapshot] = []
        if let fiveHour = rateLimits["five_hour"] as? [String: Any],
           let usedPercent = doubleValue(fiveHour["used_percentage"] ?? fiveHour["used_percent"]) {
            windows.append(
                ProviderQuotaWindowSnapshot(
                    id: "five_hour",
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: parseDate(fiveHour["resets_at"])
                )
            )
        }
        if let sevenDay = rateLimits["seven_day"] as? [String: Any],
           let usedPercent = doubleValue(sevenDay["used_percentage"] ?? sevenDay["used_percent"]) {
            windows.append(
                ProviderQuotaWindowSnapshot(
                    id: "seven_day",
                    usedPercent: usedPercent,
                    windowMinutes: 10080,
                    resetsAt: parseDate(sevenDay["resets_at"])
                )
            )
        }

        guard !windows.isEmpty else { return nil }
        return ProviderQuotaSnapshot(
            provider: "claude",
            capturedAt: capturedAt,
            source: "claude_statusline",
            planType: root["plan_type"] as? String,
            credits: doubleValue(root["credits"]),
            rawSourceRef: rawSourceRef,
            windows: windows
        )
    }

    public static func statusLineIncludesHelper(in jsonData: Data, helperPath: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command == helperPath
    }

    public static func currentStatusLineData(in jsonData: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let statusLine = root["statusLine"] else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: statusLine, options: [.prettyPrinted, .sortedKeys])
    }

    public static func upsertStatusLine(in jsonData: Data, helperPath: String) -> Data? {
        let rootObject = (try? JSONSerialization.jsonObject(with: jsonData)) ?? [:]
        guard var root = rootObject as? [String: Any] else { return nil }

        root["statusLine"] = [
            "type": "command",
            "command": helperPath
        ] as [String: Any]

        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func restoreStatusLine(in jsonData: Data, backupStatusLineData: Data?) -> Data? {
        let rootObject = (try? JSONSerialization.jsonObject(with: jsonData)) ?? [:]
        guard var root = rootObject as? [String: Any] else { return nil }

        if let backupStatusLineData,
           let statusLine = try? JSONSerialization.jsonObject(with: backupStatusLineData) {
            root["statusLine"] = statusLine
        } else {
            root.removeValue(forKey: "statusLine")
        }

        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func quotedShellString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        switch raw {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            return iso8601.date(from: value) ?? iso8601Basic.date(from: value)
        default:
            return nil
        }
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}
