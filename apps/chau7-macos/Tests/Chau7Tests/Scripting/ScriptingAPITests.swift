import XCTest
@testable import Chau7
@testable import Chau7Core

@MainActor
final class ScriptingAPITests: XCTestCase {

    private var api: ScriptingAPI!
    private var defaultsSuiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        api = ScriptingAPI.shared
        defaultsSuiteName = "ScriptingAPITests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: defaultsSuiteName)
        isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        if let defaultsSuiteName {
            isolatedDefaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        isolatedDefaults = nil
        defaultsSuiteName = nil
        api = nil
        try await super.tearDown()
    }

    // MARK: - Request Parsing

    func testMissingMethodReturnsError() async {
        let request: [String: Any] = ["params": ["key": "value"]]
        let response = await api.handleRequest(request)
        XCTAssertNotNil(response["error"] as? String)
        XCTAssertEqual(response["error"] as? String, "missing method")
    }

    func testEmptyRequestReturnsError() async {
        let request: [String: Any] = [:]
        let response = await api.handleRequest(request)
        XCTAssertNotNil(response["error"] as? String)
        XCTAssertEqual(response["error"] as? String, "missing method")
    }

    func testValidMethodWithNoParams() async {
        let request: [String: Any] = ["method": "get_status"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        XCTAssertNotNil(response["result"])
    }

    // MARK: - Unknown Method

    func testUnknownMethodReturnsError() async {
        let request: [String: Any] = ["method": "nonexistent_method"]
        let response = await api.handleRequest(request)
        let error = response["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("unknown method") ?? false)
        XCTAssertTrue(error?.contains("nonexistent_method") ?? false)
    }

    func testAnotherUnknownMethod() async {
        let request: [String: Any] = ["method": "delete_everything"]
        let response = await api.handleRequest(request)
        let error = response["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("unknown method") ?? false)
    }

    // MARK: - list_tabs Response Format

    func testListTabsReturnsArray() async {
        let request: [String: Any] = ["method": "list_tabs"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        // result should be an array (possibly empty)
        let result = response["result"]
        XCTAssertNotNil(result)
        XCTAssertTrue(result is [[String: Any]])
    }

    // MARK: - get_status Response

    func testGetStatusResponseFormat() async {
        let request: [String: Any] = ["method": "get_status"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])

        guard let result = response["result"] as? [String: Any] else {
            XCTFail("get_status result should be a dictionary")
            return
        }

        // Verify expected keys exist
        XCTAssertNotNil(result["version"])
        XCTAssertNotNil(result["build"])
        XCTAssertNotNil(result["uptime_seconds"])
        XCTAssertNotNil(result["connected_clients"])
        XCTAssertNotNil(result["server_running"])
        XCTAssertNotNil(result["history_count"])
        XCTAssertNotNil(result["api_version"])
        XCTAssertNotNil(result["supported_methods"])

        // Verify types
        XCTAssertTrue(result["version"] is String)
        XCTAssertTrue(result["build"] is String)
        XCTAssertTrue(result["uptime_seconds"] is Int)
        XCTAssertTrue(result["connected_clients"] is Int)
        XCTAssertTrue(result["server_running"] is Bool)
        XCTAssertTrue(result["history_count"] is Int)
        XCTAssertTrue(result["api_version"] is Int)
        XCTAssertTrue(result["supported_methods"] is [String])
    }

    func testGetStatusIncludesUnifiedInteractiveMethods() async throws {
        let response = await api.handleRequest(["method": "get_status"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let methods = try XCTUnwrap(result["supported_methods"] as? [String])

        XCTAssertTrue(methods.contains("send_input"))
        XCTAssertTrue(methods.contains("press_key"))
        XCTAssertTrue(methods.contains("submit_prompt"))
    }

    func testGetStatusHidesLegacySessionMethodsFromDiscovery() async throws {
        let response = await api.handleRequest(["method": "get_status"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let methods = try XCTUnwrap(result["supported_methods"] as? [String])

        XCTAssertFalse(methods.contains("create_session"))
        XCTAssertFalse(methods.contains("get_session_events"))
        XCTAssertFalse(methods.contains("submit_session_turn"))
        XCTAssertFalse(methods.contains("get_session_result"))
        XCTAssertFalse(methods.contains("stop_session"))
    }

    // MARK: - get_history

    func testGetHistoryReturnsArray() async {
        let request: [String: Any] = ["method": "get_history", "params": ["limit": 10]]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        let result = response["result"]
        XCTAssertNotNil(result)
        XCTAssertTrue(result is [[String: Any]])
    }

    func testGetRepoEventsRequiresRepoPath() async {
        let response = await api.handleRequest(["method": "get_repo_events", "params": [:]])
        XCTAssertEqual(response["error"] as? String, "missing param: repo_path")
    }

    // MARK: - get_settings

    func testGetSettingsReturnsDict() async {
        let request: [String: Any] = ["method": "get_settings"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        XCTAssertTrue(response["result"] is [String: Any])
    }

    func testInitialEnabledDefaultsToTrueWhenUnset() {
        let defaults = isolatedDefaults!

        XCTAssertNil(defaults.object(forKey: ScriptingAPI.featureFlagKey))
        XCTAssertTrue(ScriptingAPI.initialEnabled(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: ScriptingAPI.featureFlagKey) as? Bool, true)
    }

    func testInitialEnabledRespectsPersistedFalse() {
        let defaults = isolatedDefaults!
        defaults.set(false, forKey: ScriptingAPI.featureFlagKey)

        XCTAssertFalse(ScriptingAPI.initialEnabled(defaults: defaults))
    }

    func testInitialEnabledRespectsPersistedTrue() {
        let defaults = isolatedDefaults!
        defaults.set(true, forKey: ScriptingAPI.featureFlagKey)

        XCTAssertTrue(ScriptingAPI.initialEnabled(defaults: defaults))
    }

    // MARK: - set_setting Validation

    func testSetSettingMissingKey() async {
        let request: [String: Any] = ["method": "set_setting", "params": ["value": true]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: key")
    }

    func testSetSettingMissingValue() async {
        let request: [String: Any] = ["method": "set_setting", "params": ["key": "feature.scriptingAPI"]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: value")
    }

    func testSetSettingDisallowedKey() async {
        let request: [String: Any] = [
            "method": "set_setting",
            "params": ["key": "some.private.setting", "value": true]
        ]
        let response = await api.handleRequest(request)
        let error = response["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("disallowed") ?? false)
    }

    // MARK: - Parameter Validation

    func testRunCommandMissingTabID() async {
        let request: [String: Any] = ["method": "run_command", "params": ["command": "ls"]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testRunCommandMissingCommand() async {
        let request: [String: Any] = ["method": "run_command", "params": ["tab_id": "t1"]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: command")
    }

    func testSendInputMissingTabID() async {
        let response = await api.handleRequest(["method": "send_input", "params": ["input": "hello"]])
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testSubmitPromptMissingTabID() async {
        let response = await api.handleRequest(["method": "submit_prompt", "params": [:]])
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testGetOutputMissingTabID() async {
        let request: [String: Any] = ["method": "get_output", "params": [:]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testCloseTabMissingID() async {
        let request: [String: Any] = ["method": "close_tab", "params": [:]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: id")
    }

    // MARK: - list_snippets

    func testListSnippetsReturnsArray() async {
        let request: [String: Any] = ["method": "list_snippets"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        XCTAssertTrue(response["result"] is [[String: Any]])
    }

    // MARK: - Removed Legacy Session API

    func testLegacySessionMethodsReturnUnknownMethod() async {
        for method in [
            "create_session",
            "get_session_events",
            "submit_session_turn",
            "get_session_result",
            "stop_session"
        ] {
            let response = await api.handleRequest(["method": method, "params": [:]])
            XCTAssertEqual(response["error"] as? String, "unknown method: \(method)")
        }
    }
}
