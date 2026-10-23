import XCTest
@testable import Chau7Core

final class ProviderHealthTests: XCTestCase {
    private let sourceURL = URL(string: "https://status.example.test/api/v2/summary.json")!
    private let checkedAt = Date(timeIntervalSince1970: 1000)

    func testStatusPageDecoderReturnsRelevantOutageAndIncidentSummary() throws {
        let snapshot = try StatusPageProviderHealthDecoder.decode(
            Data(
                """
                {
                  "components": [
                    {"id":"console","name":"Claude Console","status":"operational"},
                    {"id":"api","name":"Claude API (api.anthropic.com)","status":"major_outage"},
                    {"id":"code","name":"Claude Code","status":"partial_outage"}
                  ],
                  "incidents": [{
                    "name":"Elevated errors across all models",
                    "status":"investigating",
                    "components":[{"id":"api"},{"id":"code"}]
                  }]
                }
                """.utf8
            ),
            providerKey: "anthropic",
            relevantComponentNameFragments: ["Claude API", "Claude Code"],
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.severity, .outage)
        XCTAssertEqual(snapshot.summary, "Elevated errors across all models")
        XCTAssertEqual(snapshot.providerKey, "anthropic")
    }

    func testUnrelatedStatusPageOutageDoesNotPoisonProviderHealth() throws {
        let snapshot = try StatusPageProviderHealthDecoder.decode(
            Data(
                """
                {
                  "components": [
                    {"id":"images","name":"Images","status":"major_outage"},
                    {"id":"responses","name":"Responses","status":"operational"},
                    {"id":"codex","name":"Codex API","status":"operational"}
                  ],
                  "incidents": [{
                    "name":"Image generation unavailable",
                    "status":"investigating",
                    "components":[{"id":"images"}]
                  }]
                }
                """.utf8
            ),
            providerKey: "openai",
            relevantComponentNameFragments: ["Responses", "Codex API"],
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.severity, .operational)
        XCTAssertEqual(snapshot.summary, "All systems operational")
    }

    func testStatusPageDegradedPerformanceMapsToWarning() throws {
        let snapshot = try StatusPageProviderHealthDecoder.decode(
            Data(
                """
                {
                  "components": [
                    {"id":"copilot","name":"Copilot","status":"degraded_performance"}
                  ],
                  "incidents":[]
                }
                """.utf8
            ),
            providerKey: "github",
            relevantComponentNameFragments: ["Copilot"],
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.severity, .degraded)
        XCTAssertEqual(snapshot.summary, "Degraded performance")
    }

    func testStatusPageRequiresAtLeastOneKnownRelevantComponent() {
        XCTAssertThrowsError(
            try StatusPageProviderHealthDecoder.decode(
                Data(#"{"components":[{"id":"x","name":"Images","status":"operational"}],"incidents":[]}"#.utf8),
                providerKey: "openai",
                relevantComponentNameFragments: ["Codex API"],
                sourceURL: sourceURL,
                checkedAt: checkedAt
            )
        ) { error in
            XCTAssertEqual(error as? ProviderHealthDecodingError, .noRelevantComponents)
        }
    }

    func testGoogleCloudDecoderIgnoresResolvedGeminiIncident() throws {
        let snapshot = try GoogleCloudProviderHealthDecoder.decode(
            Data(
                """
                [{
                  "end":"2026-03-01T00:00:00Z",
                  "external_desc":"Vertex Gemini API errors",
                  "status_impact":"SERVICE_DISRUPTION",
                  "severity":"medium",
                  "affected_products":[{"title":"Vertex Gemini API"}]
                }]
                """.utf8
            ),
            providerKey: "google",
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.severity, .operational)
    }

    func testGoogleCloudDecoderMapsActiveGeminiDisruptionToOutage() throws {
        let snapshot = try GoogleCloudProviderHealthDecoder.decode(
            Data(
                """
                [{
                  "end":null,
                  "external_desc":"Vertex AI Gemini API is experiencing increased errors.",
                  "status_impact":"SERVICE_DISRUPTION",
                  "severity":"medium",
                  "affected_products":[{"title":"Vertex Gemini API"}]
                }]
                """.utf8
            ),
            providerKey: "google",
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.severity, .outage)
        XCTAssertEqual(snapshot.summary, "Vertex AI Gemini API is experiencing increased errors.")
    }

    func testStaleOrOperationalSnapshotsDoNotProduceActiveAlert() {
        let outage = ProviderHealthSnapshot(
            providerKey: "anthropic",
            severity: .outage,
            summary: "Outage",
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )
        let operational = ProviderHealthSnapshot(
            providerKey: "openai",
            severity: .operational,
            summary: "Operational",
            sourceURL: sourceURL,
            checkedAt: checkedAt
        )

        XCTAssertEqual(
            outage.activeAlert(at: checkedAt.addingTimeInterval(299), maximumAge: 300),
            .outage
        )
        XCTAssertNil(outage.activeAlert(at: checkedAt.addingTimeInterval(301), maximumAge: 300))
        XCTAssertNil(operational.activeAlert(at: checkedAt, maximumAge: 300))
    }
}
