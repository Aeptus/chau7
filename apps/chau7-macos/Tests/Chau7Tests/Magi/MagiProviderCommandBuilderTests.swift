import Chau7Core
import XCTest

final class MagiProviderCommandBuilderTests: XCTestCase {
    func testCodexClassAndReasoningAffectCommand() {
        let command = MagiProviderCommandBuilder.command(for: member(
            provider: "codex",
            modelClass: .strongest,
            reasoning: .max
        ))

        XCTAssertEqual(command.executable, "codex")
        XCTAssertEqual(command.arguments, ["--model", "gpt-5.5", "-c", "model_reasoning_effort=\"xhigh\""])
        XCTAssertEqual(command.commandLine, "codex --model gpt-5.5 -c 'model_reasoning_effort=\"xhigh\"'")
        XCTAssertEqual(command.resolvedModel, "gpt-5.5")
        XCTAssertEqual(command.resolvedReasoning, "xhigh")
    }

    func testCodexExplicitModelOverridesClassDefault() {
        let command = MagiProviderCommandBuilder.command(for: member(
            provider: "Codex",
            modelClass: .fast,
            reasoning: .high,
            modelName: "gpt-5.3-codex-spark"
        ))

        XCTAssertEqual(command.arguments, ["--model", "gpt-5.3-codex-spark", "-c", "model_reasoning_effort=\"high\""])
        XCTAssertEqual(command.resolvedModel, "gpt-5.3-codex-spark")
        XCTAssertEqual(command.resolvedReasoning, "high")
    }

    func testClaudeUsesClassAliasAndEffort() {
        let command = MagiProviderCommandBuilder.command(for: member(
            provider: "claude",
            modelClass: .fast,
            reasoning: .low
        ))

        XCTAssertEqual(command.commandLine, "claude --model fable --effort low")
        XCTAssertEqual(command.resolvedModel, "fable")
        XCTAssertEqual(command.resolvedReasoning, "low")
    }

    func testGeminiUsesClassModel() {
        let command = MagiProviderCommandBuilder.command(for: member(
            provider: "gemini",
            modelClass: .balanced,
            reasoning: .max
        ))

        XCTAssertEqual(command.commandLine, "gemini --model gemini-2.5-flash")
        XCTAssertEqual(command.resolvedModel, "gemini-2.5-flash")
        XCTAssertNil(command.resolvedReasoning)
    }

    func testProviderModelClassMatrix() {
        XCTAssertEqual(
            MagiModelClass.allCases.map {
                MagiProviderCommandBuilder.resolvedModel(provider: .codex, modelClass: $0, explicitModelName: nil)
            },
            ["gpt-5.4-mini", "gpt-5.4", "gpt-5.5"]
        )
        XCTAssertEqual(
            MagiModelClass.allCases.map {
                MagiProviderCommandBuilder.resolvedModel(provider: .claude, modelClass: $0, explicitModelName: nil)
            },
            ["fable", "sonnet", "opus"]
        )
        XCTAssertEqual(
            MagiModelClass.allCases.map {
                MagiProviderCommandBuilder.resolvedModel(provider: .gemini, modelClass: $0, explicitModelName: nil)
            },
            ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro"]
        )
    }

    func testProviderReasoningMatrixAffectsSupportedProviderCommands() {
        let codex = MagiReasoningLevel.allCases.map {
            MagiProviderCommandBuilder.command(for: member(provider: "codex", modelClass: .balanced, reasoning: $0)).resolvedReasoning
        }
        let claude = MagiReasoningLevel.allCases.map {
            MagiProviderCommandBuilder.command(for: member(provider: "claude", modelClass: .balanced, reasoning: $0)).resolvedReasoning
        }
        let gemini = MagiReasoningLevel.allCases.map {
            MagiProviderCommandBuilder.command(for: member(provider: "gemini", modelClass: .balanced, reasoning: $0)).resolvedReasoning
        }

        XCTAssertEqual(codex, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(claude, ["low", "medium", "high", "max"])
        XCTAssertEqual(gemini, [nil, nil, nil, nil])
    }

    func testCustomProviderCommandIsPreserved() {
        let command = MagiProviderCommandBuilder.command(for: member(
            provider: "custom-agent --profile magi",
            modelClass: .strongest,
            reasoning: .max,
            modelName: "ignored"
        ))

        XCTAssertEqual(command.commandLine, "custom-agent --profile magi")
        XCTAssertTrue(command.usesRawCommand)
        XCTAssertNil(command.resolvedModel)
        XCTAssertNil(command.resolvedReasoning)
    }

    func testShellQuotesExplicitModelNames() {
        let command = MagiProviderCommandBuilder.command(for: member(
            provider: "gemini",
            modelClass: .balanced,
            reasoning: .max,
            modelName: "model with spaces"
        ))

        XCTAssertEqual(command.commandLine, "gemini --model 'model with spaces'")
    }

    private func member(
        provider: String,
        modelClass: MagiModelClass,
        reasoning: MagiReasoningLevel,
        modelName: String? = nil
    ) -> MagiMember {
        MagiMember(
            id: .melchior,
            persona: MagiPersona(memberID: .melchior, lens: "test", prompt: "test"),
            provider: provider,
            modelClass: modelClass,
            reasoning: reasoning,
            modelName: modelName
        )
    }
}
