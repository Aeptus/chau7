import XCTest
@testable import Chau7
import Chau7Core

/// SPM-runnable tests for `AIResumeIdentityResolver`, the pure provider/session
/// normalization + resume-command construction cluster extracted from
/// `OverlayTabsModel`. These paths are self-contained (only `AIResumeParser` /
/// `AIToolRegistry`), so they exercise the resolver directly rather than through
/// the `OverlayTabsModel` forwarders.
final class AIResumeIdentityResolverTests: XCTestCase {

    // MARK: - buildAIResumeCommand

    func testBuildResumeCommandForClaude() {
        let command = AIResumeIdentityResolver.buildAIResumeCommand(
            provider: "claude",
            sessionId: "abc-123"
        )
        XCTAssertEqual(command, "claude --resume abc-123")
    }

    func testBuildResumeCommandForCodex() {
        let command = AIResumeIdentityResolver.buildAIResumeCommand(
            provider: "codex",
            sessionId: "sess-9"
        )
        XCTAssertEqual(command, "codex resume sess-9")
    }

    func testBuildResumeCommandNormalizesProviderDisplayName() {
        // A display-cased provider string still routes to the registry key.
        let command = AIResumeIdentityResolver.buildAIResumeCommand(
            provider: "Claude",
            sessionId: "xyz"
        )
        XCTAssertEqual(command, "claude --resume xyz")
    }

    func testBuildResumeCommandRejectsSyntheticSessionSource() {
        let command = AIResumeIdentityResolver.buildAIResumeCommand(
            provider: "claude",
            sessionId: "synth:claude:abc123",
            sessionIdSource: .synthetic
        )
        XCTAssertNil(command, "Synthetic session identities never produce a resume command")
    }

    func testBuildResumeCommandReturnsNilForMissingInputs() {
        XCTAssertNil(AIResumeIdentityResolver.buildAIResumeCommand(provider: nil, sessionId: "abc"))
        XCTAssertNil(AIResumeIdentityResolver.buildAIResumeCommand(provider: "claude", sessionId: nil))
        XCTAssertNil(AIResumeIdentityResolver.buildAIResumeCommand(provider: "claude", sessionId: "   "))
    }

    func testBuildResumeCommandReturnsNilForUnsupportedProvider() {
        // A provider that has no resumeProviderKey in the registry.
        XCTAssertNil(AIResumeIdentityResolver.buildAIResumeCommand(
            provider: "totally-unknown-cli",
            sessionId: "abc-123"
        ))
    }

    // MARK: - normalizedAIProvider

    func testNormalizedAIProviderCanonicalizesKnownNames() {
        XCTAssertEqual(AIResumeIdentityResolver.normalizedAIProvider(from: "Claude"), "claude")
        XCTAssertEqual(AIResumeIdentityResolver.normalizedAIProvider(from: "codex"), "codex")
    }

    func testNormalizedAIProviderReturnsNilForNil() {
        XCTAssertNil(AIResumeIdentityResolver.normalizedAIProvider(from: nil))
    }

    // MARK: - normalizeAISessionId

    func testNormalizeAISessionIdTrimsAndValidates() {
        XCTAssertEqual(
            AIResumeIdentityResolver.normalizeAISessionId("  550e8400-e29b-41d4-a716-446655440000  "),
            "550e8400-e29b-41d4-a716-446655440000"
        )
    }

    func testNormalizeAISessionIdRejectsInvalid() {
        XCTAssertNil(AIResumeIdentityResolver.normalizeAISessionId(nil))
        XCTAssertNil(AIResumeIdentityResolver.normalizeAISessionId(""))
    }

    // MARK: - normalizePersistedAISessionId

    func testNormalizePersistedSessionIdKeepsSyntheticWhenSourceMatches() {
        let value = AIResumeIdentityResolver.normalizePersistedAISessionId(
            "synth:claude:abc123",
            source: .synthetic
        )
        XCTAssertEqual(value, "synth:claude:abc123", "Synthetic ids survive persistence normalization")
    }

    func testNormalizePersistedSessionIdRejectsSyntheticPrefixWithoutSyntheticSource() {
        let value = AIResumeIdentityResolver.normalizePersistedAISessionId(
            "synth:claude:abc123",
            source: .explicit
        )
        XCTAssertNil(value, "A synth: prefix is only valid when the source is .synthetic")
    }

    // MARK: - Forwarder parity

    func testOverlayTabsModelForwardersMatchResolver() {
        XCTAssertEqual(
            OverlayTabsModel.buildAIResumeCommand(provider: "codex", sessionId: "s1"),
            AIResumeIdentityResolver.buildAIResumeCommand(provider: "codex", sessionId: "s1")
        )
        XCTAssertEqual(
            OverlayTabsModel.normalizedAIProvider(from: "Claude"),
            AIResumeIdentityResolver.normalizedAIProvider(from: "Claude")
        )
    }
}
