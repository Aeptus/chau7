import Foundation

// MARK: - Shell Escaping

/// Pure functions for safe shell argument escaping.
/// Use these to prevent command injection vulnerabilities.
public enum ShellEscaping {

    // MARK: - Shell Argument Escaping

    /// Escapes a string for safe use as a shell argument.
    /// Uses single quotes which prevent all shell interpretation.
    /// - Parameter argument: The string to escape
    /// - Returns: Safely escaped string wrapped in single quotes
    public static func escapeArgument(_ argument: String) -> String {
        // Single quotes prevent all shell interpretation except for single quotes themselves.
        // To include a single quote, we end the quoted string, add an escaped single quote,
        // then start a new quoted string: 'foo'\''bar' -> foo'bar
        let escaped = argument.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Escapes a file path for safe use in shell commands.
    /// - Parameter path: The file path to escape
    /// - Returns: Safely escaped path
    public static func escapePath(_ path: String) -> String {
        escapeArgument(path)
    }

    /// Escapes multiple arguments and joins them with spaces.
    /// - Parameter arguments: Array of arguments to escape
    /// - Returns: Space-separated escaped arguments
    public static func escapeArguments(_ arguments: [String]) -> String {
        arguments.map { escapeArgument($0) }.joined(separator: " ")
    }

    // MARK: - Validation

    /// Characters that have special meaning in shell and require escaping.
    public static let shellMetacharacters: Set<Character> = [
        " ", "\t", "\n", "\"", "'", "`", "$", "\\", "!", "&", "|",
        ";", "(", ")", "<", ">", "*", "?", "[", "]", "#", "~", "^"
    ]

    /// Checks if a string contains shell metacharacters that need escaping.
    /// - Parameter string: The string to check
    /// - Returns: True if the string contains metacharacters
    public static func containsMetacharacters(_ string: String) -> Bool {
        string.contains { shellMetacharacters.contains($0) }
    }

    /// Checks if a string is a safe identifier (alphanumeric, underscore, hyphen, dot).
    /// Safe identifiers don't need escaping in most contexts.
    /// - Parameter string: The string to check
    /// - Returns: True if the string is a safe identifier
    public static func isSafeIdentifier(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return string.unicodeScalars.allSatisfy { allowedChars.contains($0) }
    }

    // MARK: - SSH Option Validation

    /// Validates an SSH option string for safety.
    /// Allows only common safe SSH options, rejecting potentially dangerous ones.
    /// - Parameter options: The SSH options string to validate
    /// - Returns: ValidationResult with status and reason
    public enum SSHValidationIssue: Equatable {
        case dangerousOption(String)
        case commandSubstitution
        case shellRedirection
        case shellControlChars
    }

    public struct SSHValidationResult: Equatable {
        public let isValid: Bool
        public let issue: SSHValidationIssue?

        public init(isValid: Bool, issue: SSHValidationIssue? = nil) {
            self.isValid = isValid
            self.issue = issue
        }
    }

    /// Dangerous SSH options that could be used for command injection or exfiltration.
    public static let dangerousSSHOptions: Set = [
        "-o ProxyCommand", // Can execute arbitrary commands
        "-o LocalCommand", // Can execute local commands
        "-o PermitLocalCommand",
        "-W", // Stdio forwarding
        "ProxyCommand",
        "LocalCommand",
        "PermitLocalCommand"
    ]

    /// Validates SSH extra options for safety.
    /// - Parameter options: SSH options string from user input
    /// - Returns: Validation result
    public static func validateSSHOptions(_ options: String) -> SSHValidationResult {
        let trimmed = options.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty is valid
        guard !trimmed.isEmpty else {
            return SSHValidationResult(isValid: true)
        }

        // Check for dangerous options (case-insensitive)
        let lowercased = trimmed.lowercased()
        for dangerous in dangerousSSHOptions {
            if lowercased.contains(dangerous.lowercased()) {
                return SSHValidationResult(
                    isValid: false,
                    issue: .dangerousOption(dangerous)
                )
            }
        }

        // Check for command substitution attempts
        if trimmed.contains("$(") || trimmed.contains("`") {
            return SSHValidationResult(
                isValid: false,
                issue: .commandSubstitution
            )
        }

        // Check for shell redirection
        if trimmed.contains(">") || trimmed.contains("<") || trimmed.contains("|") {
            return SSHValidationResult(
                isValid: false,
                issue: .shellRedirection
            )
        }

        // Check for shell control characters
        if trimmed.contains(";") || trimmed.contains("&") || trimmed.contains("\n") || trimmed.contains("\r") {
            return SSHValidationResult(
                isValid: false,
                issue: .shellControlChars
            )
        }

        return SSHValidationResult(isValid: true)
    }

    // MARK: - Path Validation

    /// Validates a file path for safety.
    /// - Parameter path: The path to validate
    /// - Returns: True if the path appears safe
    public static func isValidPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must not be empty
        guard !trimmed.isEmpty else { return false }

        // Must not contain null bytes
        guard !trimmed.contains("\0") else { return false }

        // Must not contain command substitution
        guard !trimmed.contains("$("), !trimmed.contains("`") else { return false }

        // Must not contain path traversal components
        let components = trimmed.components(separatedBy: "/")
        guard !components.contains("..") else { return false }

        return true
    }

    /// Sanitizes a path by removing potentially dangerous elements.
    /// - Parameter path: The path to sanitize
    /// - Returns: Sanitized path
    public static func sanitizePath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove null bytes
        result = result.replacingOccurrences(of: "\0", with: "")

        // Remove command substitution attempts
        result = result.replacingOccurrences(of: "$(", with: "")
        result = result.replacingOccurrences(of: "`", with: "")

        // Strip path traversal components
        result = result.components(separatedBy: "/")
            .filter { $0 != ".." }
            .joined(separator: "/")

        return result
    }

    // MARK: - Environment Variable Safety

    /// Checks if an environment variable name is valid.
    /// - Parameter name: The environment variable name
    /// - Returns: True if valid
    public static func isValidEnvVarName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }

        // Must start with letter or underscore
        guard let first = name.first, first.isLetter || first == "_" else {
            return false
        }

        // Rest must be alphanumeric or underscore
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
