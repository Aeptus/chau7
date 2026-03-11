import Foundation

public enum RemoteProtection {
    public static func flaggedTerminationAction(for input: String) -> String? {
        let lines = input.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !line.isEmpty else { continue }

            if (line.hasPrefix("kill ") || line.hasPrefix("killall ") || line.hasPrefix("pkill "))
                && line.contains("chau7") {
                return "Terminate Chau7 on Mac"
            }

            if line.hasPrefix("launchctl ") && line.contains("chau7") {
                return "Disable Chau7 launch services on Mac"
            }

            if line.hasPrefix("osascript ") && line.contains("quit") && line.contains("chau7") {
                return "Quit Chau7 on Mac"
            }
        }

        return nil
    }
}
