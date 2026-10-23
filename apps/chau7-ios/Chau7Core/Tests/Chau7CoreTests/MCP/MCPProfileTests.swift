import XCTest
@testable import Chau7Core

// MARK: - MCPProfile Tests

final class MCPProfileTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let profile = MCPProfile(
            name: "Work Project",
            isEnabled: true,
            trigger: .directory(path: "~/projects/work"),
            permissionMode: .askUnlisted,
            allowedCommands: ["git", "ls", "cat"],
            blockedCommands: ["rm", "sudo"],
            priority: 10
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(MCPProfile.self, from: data)

        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.isEnabled, profile.isEnabled)
        XCTAssertEqual(decoded.trigger, profile.trigger)
        XCTAssertEqual(decoded.permissionMode, profile.permissionMode)
        XCTAssertEqual(decoded.allowedCommands, profile.allowedCommands)
        XCTAssertEqual(decoded.blockedCommands, profile.blockedCommands)
        XCTAssertEqual(decoded.priority, profile.priority)
    }

    func testCodableArrayRoundTrip() throws {
        let profiles = [
            MCPProfile(name: "A", trigger: .directory(path: "/a"), priority: 1),
            MCPProfile(name: "B", trigger: .sshHost(hostname: "b.com"), permissionMode: .allowlist, priority: 2),
            MCPProfile(name: "C", trigger: .processRunning(name: "docker"), permissionMode: .allowAll, priority: 0)
        ]

        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([MCPProfile].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].name, "A")
        XCTAssertEqual(decoded[1].permissionMode, .allowlist)
        XCTAssertEqual(decoded[2].trigger, .processRunning(name: "docker"))
    }

    // MARK: - Profile Matching

    func testMatchesDirectory() {
        let profile = MCPProfile(name: "Test", trigger: .directory(path: "/Users/test/projects"))
        let ctx = MCPTabContext(directory: "/Users/test/projects")
        XCTAssertTrue(profile.matches(context: ctx))
    }

    func testDoesNotMatchDifferentDirectory() {
        let profile = MCPProfile(name: "Test", trigger: .directory(path: "/Users/test/projects"))
        let ctx = MCPTabContext(directory: "/Users/other/projects")
        XCTAssertFalse(profile.matches(context: ctx))
    }

    func testMatchesSshHost() {
        let profile = MCPProfile(name: "SSH", trigger: .sshHost(hostname: "prod.example.com"))
        let ctx = MCPTabContext(sshHost: "prod.example.com")
        XCTAssertTrue(profile.matches(context: ctx))
    }

    func testSshHostCaseInsensitive() {
        let profile = MCPProfile(name: "SSH", trigger: .sshHost(hostname: "Prod.Example.COM"))
        let ctx = MCPTabContext(sshHost: "prod.example.com")
        XCTAssertTrue(profile.matches(context: ctx))
    }

    func testMatchesProcess() {
        let profile = MCPProfile(name: "Docker", trigger: .processRunning(name: "docker"))
        let ctx = MCPTabContext(processes: ["bash", "docker", "node"])
        XCTAssertTrue(profile.matches(context: ctx))
    }

    func testMatchesEnvironmentVariable() {
        let profile = MCPProfile(name: "Prod", trigger: .environmentVariable(key: "NODE_ENV", value: "production"))
        let ctx = MCPTabContext(environment: ["NODE_ENV": "production", "PATH": "/usr/bin"])
        XCTAssertTrue(profile.matches(context: ctx))
    }

    func testDoesNotMatchWhenDisabled() {
        let profile = MCPProfile(name: "Disabled", isEnabled: false, trigger: .directory(path: "/tmp"))
        let ctx = MCPTabContext(directory: "/tmp")
        XCTAssertFalse(profile.matches(context: ctx))
    }

    func testDoesNotMatchNilContext() {
        let profile = MCPProfile(name: "Test", trigger: .directory(path: "/tmp"))
        let ctx = MCPTabContext()
        XCTAssertFalse(profile.matches(context: ctx))
    }

    func testMatchesGitRepository() {
        let profile = MCPProfile(name: "Repo", trigger: .gitRepository(name: "my-project"))
        let ctx = MCPTabContext(directory: "/Users/test/code/my-project")
        XCTAssertTrue(profile.matches(context: ctx))
    }

    // MARK: - bestMatch()

    func testBestMatchReturnHighestPriority() {
        let low = MCPProfile(name: "Low", trigger: .directory(path: "/tmp"), priority: 1)
        let high = MCPProfile(name: "High", trigger: .directory(path: "/tmp"), priority: 10)
        let ctx = MCPTabContext(directory: "/tmp")

        let result = [low, high].bestMatch(for: ctx)
        XCTAssertEqual(result?.name, "High")
    }

    func testBestMatchReturnNilForNoMatch() {
        let profile = MCPProfile(name: "A", trigger: .directory(path: "/a"))
        let ctx = MCPTabContext(directory: "/b")

        XCTAssertNil([profile].bestMatch(for: ctx))
    }

    func testBestMatchSkipsDisabled() {
        let disabled = MCPProfile(name: "Disabled", isEnabled: false, trigger: .directory(path: "/tmp"), priority: 100)
        let enabled = MCPProfile(name: "Enabled", trigger: .directory(path: "/tmp"), priority: 1)
        let ctx = MCPTabContext(directory: "/tmp")

        let result = [disabled, enabled].bestMatch(for: ctx)
        XCTAssertEqual(result?.name, "Enabled")
    }

    func testBestMatchTiebreakByName() {
        let b = MCPProfile(name: "BBB", trigger: .directory(path: "/tmp"), priority: 5)
        let a = MCPProfile(name: "AAA", trigger: .directory(path: "/tmp"), priority: 5)
        let ctx = MCPTabContext(directory: "/tmp")

        let result = [b, a].bestMatch(for: ctx)
        XCTAssertEqual(result?.name, "AAA")
    }

    func testBestMatchEmptyArray() {
        let ctx = MCPTabContext(directory: "/tmp")
        XCTAssertNil([MCPProfile]().bestMatch(for: ctx))
    }

    // MARK: - Equatable

    func testEqualityById() {
        let id = UUID()
        let a = MCPProfile(id: id, name: "A", trigger: .directory(path: "/a"))
        let b = MCPProfile(id: id, name: "B", trigger: .directory(path: "/b"))
        // MCPProfile uses synthesized Equatable — all fields must match
        XCTAssertNotEqual(a, b)

        let c = MCPProfile(id: id, name: "A", trigger: .directory(path: "/a"))
        XCTAssertEqual(a, c)
    }

    // MARK: - Default Values

    func testDefaultValues() {
        let profile = MCPProfile(name: "Default", trigger: .directory(path: "/tmp"))
        XCTAssertTrue(profile.isEnabled)
        XCTAssertEqual(profile.permissionMode, .askUnlisted)
        XCTAssertEqual(profile.allowedCommands, [])
        XCTAssertEqual(profile.blockedCommands, [])
        XCTAssertEqual(profile.priority, 0)
    }
}

// MARK: - MCPApprovalResult Tests

final class MCPApprovalResultTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let cases: [MCPApprovalResult] = [.denied, .allowedOnce, .alwaysAllow]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(MCPApprovalResult.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    func testRawValues() {
        XCTAssertEqual(MCPApprovalResult.denied.rawValue, "denied")
        XCTAssertEqual(MCPApprovalResult.allowedOnce.rawValue, "allowedOnce")
        XCTAssertEqual(MCPApprovalResult.alwaysAllow.rawValue, "alwaysAllow")
    }
}

// MARK: - MCPPermissionMode Tests

final class MCPPermissionModeTests: XCTestCase {

    func testCodableRoundTrip() throws {
        for mode in MCPPermissionMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(MCPPermissionMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(MCPPermissionMode.allowAll.displayName, "Allow All")
        XCTAssertEqual(MCPPermissionMode.allowlist.displayName, "Allowlist Only")
        XCTAssertEqual(MCPPermissionMode.askUnlisted.displayName, "Ask for Unlisted")
    }

    func testRawValues() {
        XCTAssertEqual(MCPPermissionMode.allowAll.rawValue, "allow_all")
        XCTAssertEqual(MCPPermissionMode.allowlist.rawValue, "allowlist")
        XCTAssertEqual(MCPPermissionMode.askUnlisted.rawValue, "ask_unlisted")
    }
}

// MARK: - MCPTabContext Tests

final class MCPTabContextTests: XCTestCase {

    func testEmptyContext() {
        let ctx = MCPTabContext()
        XCTAssertNil(ctx.directory)
        XCTAssertNil(ctx.gitBranch)
        XCTAssertNil(ctx.sshHost)
        XCTAssertNil(ctx.processes)
        XCTAssertNil(ctx.environment)
    }

    func testFullContext() {
        let ctx = MCPTabContext(
            directory: "/tmp",
            gitBranch: "main",
            sshHost: "server.com",
            processes: ["bash"],
            environment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(ctx.directory, "/tmp")
        XCTAssertEqual(ctx.gitBranch, "main")
        XCTAssertEqual(ctx.sshHost, "server.com")
        XCTAssertEqual(ctx.processes, ["bash"])
        XCTAssertEqual(ctx.environment, ["PATH": "/usr/bin"])
    }
}
