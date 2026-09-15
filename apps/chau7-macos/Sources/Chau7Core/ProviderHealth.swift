import Foundation

/// Provider-agnostic service health used by every UI surface.
///
/// Raw vendor values are deliberately decoded at the boundary so callers do
/// not need to understand Statuspage or Google Cloud incident terminology.
public enum ProviderHealthSeverity: Int, Codable, CaseIterable, Sendable {
    case unknown = 0
    case operational = 1
    case degraded = 2
    case outage = 3

    public var isAlerting: Bool {
        self == .degraded || self == .outage
    }

    static func maximum<S: Sequence>(_ values: S) -> ProviderHealthSeverity
    where S.Element == ProviderHealthSeverity {
        values.max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
    }
}

/// One successful observation from a provider's official status source.
public struct ProviderHealthSnapshot: Equatable, Sendable {
    public let providerKey: String
    public let severity: ProviderHealthSeverity
    public let summary: String
    public let sourceURL: URL
    public let checkedAt: Date

    public init(
        providerKey: String,
        severity: ProviderHealthSeverity,
        summary: String,
        sourceURL: URL,
        checkedAt: Date
    ) {
        self.providerKey = providerKey
        self.severity = severity
        self.summary = summary
        self.sourceURL = sourceURL
        self.checkedAt = checkedAt
    }

    /// Alert state is intentionally suppressed after the observation becomes
    /// stale. A broken monitor must never be presented as a broken provider.
    public func activeAlert(
        at now: Date = Date(),
        maximumAge: TimeInterval
    ) -> ProviderHealthSeverity? {
        guard now.timeIntervalSince(checkedAt) >= 0,
              now.timeIntervalSince(checkedAt) <= maximumAge,
              severity.isAlerting else {
            return nil
        }
        return severity
    }
}

public enum ProviderHealthDecodingError: Error, Equatable {
    case noRelevantComponents
    case unsupportedComponentStatus(String)
}

/// Decodes Atlassian Statuspage-compatible summary feeds.
///
/// Anthropic, OpenAI, and GitHub expose the same broad schema but use
/// different component names. Callers supply component-name fragments so an
/// unrelated outage (for example OpenAI Images) does not mark Codex as down.
public enum StatusPageProviderHealthDecoder {
    public static func decode(
        _ data: Data,
        providerKey: String,
        relevantComponentNameFragments: [String],
        sourceURL: URL,
        checkedAt: Date = Date()
    ) throws -> ProviderHealthSnapshot {
        let document = try JSONDecoder().decode(StatusPageDocument.self, from: data)
        let fragments = relevantComponentNameFragments.map(normalize)
        let relevantComponents = document.components.filter { component in
            let name = normalize(component.name)
            return fragments.contains(where: name.contains)
        }

        guard !relevantComponents.isEmpty else {
            throw ProviderHealthDecodingError.noRelevantComponents
        }

        let severities = try relevantComponents.map { component in
            try severityForStatus(component.status)
        }
        let resolvedSeverity = ProviderHealthSeverity.maximum(severities)
        let relevantIDs = Set(relevantComponents.map(\.id))
        let summary = incidentSummary(
            in: document.incidents ?? [],
            affecting: relevantIDs,
            fallbackSeverity: resolvedSeverity
        )

        return ProviderHealthSnapshot(
            providerKey: providerKey,
            severity: resolvedSeverity,
            summary: summary,
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )
    }

    private static func severityForStatus(_ rawStatus: String) throws -> ProviderHealthSeverity {
        switch normalize(rawStatus) {
        case "operational":
            return .operational
        case "degraded_performance", "under_maintenance", "maintenance":
            return .degraded
        case "partial_outage", "major_outage":
            return .outage
        default:
            throw ProviderHealthDecodingError.unsupportedComponentStatus(rawStatus)
        }
    }

    private static func incidentSummary(
        in incidents: [StatusPageIncident],
        affecting relevantComponentIDs: Set<String>,
        fallbackSeverity: ProviderHealthSeverity
    ) -> String {
        if let incident = incidents.first(where: { incident in
            guard normalize(incident.status) != "resolved" else { return false }
            let affectedIDs = Set((incident.components ?? []).map(\.id))
            return !affectedIDs.isDisjoint(with: relevantComponentIDs)
        }) {
            return incident.name
        }

        switch fallbackSeverity {
        case .operational:
            return "All systems operational"
        case .degraded:
            return "Degraded performance"
        case .outage:
            return "Service outage"
        case .unknown:
            return "Status unavailable"
        }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Decodes Google Cloud's public incident history for active Vertex Gemini
/// incidents. Google AI Studio itself currently exposes status through a
/// browser-internal authenticated RPC, so Chau7 intentionally uses only this
/// anonymous public feed rather than embedding a browser API key.
public enum GoogleCloudProviderHealthDecoder {
    public static func decode(
        _ data: Data,
        providerKey: String,
        sourceURL: URL,
        checkedAt: Date = Date()
    ) throws -> ProviderHealthSnapshot {
        let incidents = try JSONDecoder().decode([GoogleCloudIncident].self, from: data)
        let activeGeminiIncidents = incidents.filter { incident in
            guard incident.end == nil else { return false }
            return (incident.affectedProducts ?? []).contains(where: {
                let title = normalize($0.title)
                return title.contains("gemini") || title.contains("vertex ai")
            }) || normalize(incident.externalDescription ?? "").contains("gemini")
        }

        guard !activeGeminiIncidents.isEmpty else {
            return ProviderHealthSnapshot(
                providerKey: providerKey,
                severity: .operational,
                summary: "All systems operational",
                sourceURL: sourceURL,
                checkedAt: checkedAt
            )
        }

        let severity = ProviderHealthSeverity.maximum(
            activeGeminiIncidents.map(severity(for:))
        )
        return ProviderHealthSnapshot(
            providerKey: providerKey,
            severity: severity,
            summary: activeGeminiIncidents[0].externalDescription ?? "Gemini service incident",
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )
    }

    private static func severity(for incident: GoogleCloudIncident) -> ProviderHealthSeverity {
        let impact = normalize(incident.statusImpact ?? "")
        let severity = normalize(incident.severity ?? "")
        if impact.contains("disruption") || severity == "high" || severity == "medium" {
            return .outage
        }
        return .degraded
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct StatusPageDocument: Decodable {
    let components: [StatusPageComponent]
    let incidents: [StatusPageIncident]?
}

private struct StatusPageComponent: Decodable {
    let id: String
    let name: String
    let status: String
}

private struct StatusPageIncident: Decodable {
    let name: String
    let status: String
    let components: [StatusPageIncidentComponent]?
}

private struct StatusPageIncidentComponent: Decodable {
    let id: String
}

private struct GoogleCloudIncident: Decodable {
    struct Product: Decodable {
        let title: String
    }

    let end: String?
    let externalDescription: String?
    let statusImpact: String?
    let severity: String?
    let affectedProducts: [Product]?

    enum CodingKeys: String, CodingKey {
        case end
        case externalDescription = "external_desc"
        case statusImpact = "status_impact"
        case severity
        case affectedProducts = "affected_products"
    }
}
