import Foundation

public enum CodeReviewTaskTemplate {
    public static let defaultPolicy = RuntimeDelegationPolicy(
        maxTurns: 1,
        allowChildDelegation: false,
        maxDelegationDepth: 0,
        blockedTools: ["Write", "Edit", "NotebookEdit"],
        allowFileWrites: false
    )

    public static let resultSchema = JSONValue.object([
        "type": .string("object"),
        "required": .array([
            .string("summary"),
            .string("findings"),
            .string("recommendations"),
            .string("confidence")
        ]),
        "properties": .object([
            "summary": .object([
                "type": .string("string")
            ]),
            "findings": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([
                        .string("severity"),
                        .string("file"),
                        .string("message")
                    ]),
                    "properties": .object([
                        "severity": .object(["type": .string("string")]),
                        "file": .object(["type": .string("string")]),
                        "line": .object(["type": .string("integer")]),
                        "message": .object(["type": .string("string")]),
                        "recommendation": .object(["type": .string("string")])
                    ])
                ])
            ]),
            "recommendations": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string")
                ])
            ]),
            "confidence": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("low"),
                    .string("medium"),
                    .string("high")
                ])
            ])
        ])
    ])

    public static func prompt(baseCommit: String, headCommit: String, extraInstructions: String? = nil) -> String {
        var lines = [
            "Review commits \(baseCommit)..\(headCommit).",
            "Work read-only. Do not edit files. Do not delegate to another reviewer.",
            "Focus on correctness, regressions, security, and missing tests.",
            "Return concise prose findings first, then end with a fenced JSON block that matches the requested schema."
        ]
        if let extraInstructions,
           !extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Additional instructions: \(extraInstructions)")
        }
        return lines.joined(separator: "\n")
    }
}
