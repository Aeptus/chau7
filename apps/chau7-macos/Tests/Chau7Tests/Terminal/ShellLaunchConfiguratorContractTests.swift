@testable import Chau7
import XCTest

/// Swift half of the Codex correlation wire contract.
///
/// The proxy's `correlation_contract_test.go` reads the same
/// `Contracts/proxy-correlation.json`. Keeping both suites pointed at one file
/// is deliberate: the wrapper and the proxy are separately testable and each
/// passed on its own while the deployed pair was broken, because nothing
/// compared what one side emits against what the other side accepts.
final class ShellLaunchConfiguratorContractTests: XCTestCase {
    private struct Contract: Decodable {
        struct Case: Decodable {
            let name: String
            let projectPath: String
            let token: String
            let requestPath: String
            let forwardedPath: String
        }

        let prefix: String
        let encoding: String
        let healthCapability: String
        let cases: [Case]
    }

    /// `apps/chau7-macos/Contracts/proxy-correlation.json`, resolved from this
    /// file rather than a bundle resource so the test reads the same bytes the
    /// Go suite does instead of a copy that could drift.
    private static var contractURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Terminal
            .deletingLastPathComponent() // Chau7Tests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // chau7-macos
            .appendingPathComponent("Contracts/proxy-correlation.json")
    }

    private func loadContract() throws -> Contract {
        let url = Self.contractURL
        let data = try Data(contentsOf: url)
        let contract = try JSONDecoder().decode(Contract.self, from: data)
        XCTAssertFalse(contract.cases.isEmpty, "correlation contract declares no cases")
        return contract
    }

    func testProxyProjectPathMatchesContractForEveryCase() throws {
        let contract = try loadContract()

        for testCase in contract.cases {
            let expected = contract.prefix + testCase.token
            XCTAssertEqual(
                ShellLaunchConfigurator.proxyProjectPath(testCase.projectPath),
                expected,
                "case \"\(testCase.name)\": wrapper would emit a path the proxy cannot decode"
            )
        }
    }

    /// The wrapper appends `/v1` to the correlated prefix, so the full request
    /// path Codex produces must be exactly what the proxy's cases expect.
    func testWrapperRequestPathMatchesContractForEveryCase() throws {
        let contract = try loadContract()

        for testCase in contract.cases {
            let endpoint = testCase.forwardedPath.hasPrefix("/v1")
                ? String(testCase.forwardedPath.dropFirst("/v1".count))
                : testCase.forwardedPath
            let composed = ShellLaunchConfigurator.proxyProjectPath(testCase.projectPath) + "/v1" + endpoint

            XCTAssertEqual(
                composed,
                testCase.requestPath,
                "case \"\(testCase.name)\": composed request path diverges from the proxy's fixture"
            )
        }
    }

    /// Pins the capability name the app requires at startup to the shared file,
    /// so renaming it on one side cannot silently disable the skew check.
    func testHealthCapabilityMatchesRequiredCapability() throws {
        let contract = try loadContract()

        XCTAssertTrue(
            ProxyManager.requiredCapabilities.contains(contract.healthCapability),
            "app does not require \(contract.healthCapability); a stale proxy would go undetected"
        )
    }

    func testContractDeclaresUnpaddedBase64URLEncoding() throws {
        let contract = try loadContract()

        // proxyProjectPath strips '=' and swaps +/ for -_; the proxy decodes
        // with base64.RawURLEncoding, which rejects padding outright.
        XCTAssertEqual(contract.encoding, "base64url-unpadded")
        for testCase in contract.cases {
            XCTAssertFalse(testCase.token.contains("="), "case \"\(testCase.name)\": token retains padding")
            XCTAssertFalse(testCase.token.contains("+"), "case \"\(testCase.name)\": token is not url-safe")
            XCTAssertFalse(testCase.token.contains("/"), "case \"\(testCase.name)\": token is not url-safe")
        }
    }
}
