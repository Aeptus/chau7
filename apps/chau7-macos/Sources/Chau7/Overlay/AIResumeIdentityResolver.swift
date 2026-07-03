import Chau7Core
import Foundation

/// Pure AI-resume identity vocabulary extracted from `OverlayTabsModel`:
/// provider/session-id normalization and resume-command construction.
///
/// This is the closed, self-contained subset of the resume-metadata cluster —
/// it depends only on `AIResumeParser` / `AIToolRegistry` (Chau7Core), never on
/// `OverlayTabsModel` instance state, the session-finder registry, or the
/// `ResumePrefillDelivery` normalization helpers. The wider resolution paths
/// (`resolveResumeMetadata`, `sanitizeRestoredAIResumeOwnership`,
/// `resolveAIResumeMetadata`, the session-finder registry) stay on
/// `OverlayTabsModel` because they are entangled with live model state and the
/// mutable finder registry; `OverlayTabsModel` keeps thin forwarders to the
/// members here so existing call sites are undisturbed.
enum AIResumeIdentityResolver {

    static func normalizedAIProvider(from value: String?) -> String? {
        guard let value else { return nil }
        return AIResumeParser.normalizeProviderName(value)
    }

    static func normalizeAISessionId(_ sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(trimmed) else { return nil }
        return trimmed
    }

    static func normalizePersistedAISessionId(
        _ sessionId: String?,
        source: AISessionIdentitySource?
    ) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if AIResumeParser.isValidSessionId(trimmed) {
            return trimmed
        }
        if source == .synthetic, trimmed.hasPrefix("synth:") {
            return trimmed
        }
        return nil
    }

    static func buildAIResumeCommand(provider: String?, sessionId: String?) -> String? {
        buildAIResumeCommand(provider: provider, sessionId: sessionId, sessionIdSource: nil)
    }

    static func buildAIResumeCommand(
        provider: String?,
        sessionId: String?,
        sessionIdSource: AISessionIdentitySource?
    ) -> String? {
        if sessionIdSource == .synthetic {
            return nil
        }
        guard let provider = normalizedAIProvider(from: provider),
              let sessionId = normalizeAISessionId(sessionId) else {
            return nil
        }

        guard let tool = AIToolRegistry.allTools.first(where: { $0.resumeProviderKey == provider }) else {
            // Provider normalized cleanly and we have a valid session ID,
            // but the tool isn't in our registry at all. Log once per
            // unique provider so users can see why their resume didn't
            // fire on a CLI we haven't wired up.
            logResumeUnsupportedOnce(provider: provider, reason: "tool_not_in_registry")
            return nil
        }
        guard let format = tool.resumeFormat else {
            // Tool is known but has no resumeFormat configured — this
            // matches providers where we intentionally haven't added a
            // resume command format (e.g. some CLIs have no --resume
            // equivalent). Surface it so adding a new provider without
            // wiring resume is obvious.
            logResumeUnsupportedOnce(provider: provider, reason: "no_resume_format")
            return nil
        }
        return format.buildCommand(sessionId: sessionId)
    }

    private static var loggedUnsupportedResumeProviders: Set<String> = []
    private static let loggedUnsupportedResumeProvidersLock = NSLock()
    private static func logResumeUnsupportedOnce(provider: String, reason: String) {
        loggedUnsupportedResumeProvidersLock.lock()
        let alreadyLogged = loggedUnsupportedResumeProviders.contains(provider)
        if !alreadyLogged {
            loggedUnsupportedResumeProviders.insert(provider)
        }
        loggedUnsupportedResumeProvidersLock.unlock()
        if !alreadyLogged {
            Log.info("buildAIResumeCommand: resume unsupported for provider=\(provider) reason=\(reason)")
        }
    }
}
