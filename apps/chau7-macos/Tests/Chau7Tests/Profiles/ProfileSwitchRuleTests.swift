import XCTest
@testable import Chau7Core

// MARK: - ProfileSwitchTrigger Tests

final class ProfileSwitchTriggerTests: XCTestCase {

    func testTypeDisplayNames() {
        XCTAssertEqual(ProfileSwitchTrigger.directory(path: "/tmp").typeDisplayName, "Directory")
        XCTAssertEqual(ProfileSwitchTrigger.gitRepository(name: "repo").typeDisplayName, "Git Repository")
        XCTAssertEqual(ProfileSwitchTrigger.sshHost(hostname: "host").typeDisplayName, "SSH Host")
        XCTAssertEqual(ProfileSwitchTrigger.processRunning(name: "vim").typeDisplayName, "Process")
        XCTAssertEqual(ProfileSwitchTrigger.environmentVariable(key: "K", value: "V").typeDisplayName, "Environment Variable")
    }

    func testDisplaySummaries() {
        XCTAssertEqual(ProfileSwitchTrigger.directory(path: "/tmp").displaySummary, "cd /tmp")
        XCTAssertEqual(ProfileSwitchTrigger.gitRepository(name: "myrepo").displaySummary, "repo: myrepo")
        XCTAssertEqual(ProfileSwitchTrigger.sshHost(hostname: "server.com").displaySummary, "ssh server.com")
        XCTAssertEqual(ProfileSwitchTrigger.processRunning(name: "node").displaySummary, "process: node")
        XCTAssertEqual(ProfileSwitchTrigger.environmentVariable(key: "ENV", value: "prod").displaySummary, "ENV=prod")
    }

    func testCodableRoundTrip() throws {
        let triggers: [ProfileSwitchTrigger] = [
            .directory(path: "/home/user"),
            .gitRepository(name: "my-project"),
            .sshHost(hostname: "prod.example.com"),
            .processRunning(name: "docker"),
            .environmentVariable(key: "NODE_ENV", value: "production")
        ]

        for original in triggers {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ProfileSwitchTrigger.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    func testEquality() {
        let a = ProfileSwitchTrigger.directory(path: "/tmp")
        let b = ProfileSwitchTrigger.directory(path: "/tmp")
        let c = ProfileSwitchTrigger.directory(path: "/home")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - ProfileSwitchRule Tests

final class ProfileSwitchRuleTests: XCTestCase {

    private func makeRule(
        trigger: ProfileSwitchTrigger,
        isEnabled: Bool = true,
        priority: Int = 0
    ) -> ProfileSwitchRule {
        ProfileSwitchRule(
            name: "Test Rule",
            isEnabled: isEnabled,
            trigger: trigger,
            profileName: "dark-theme",
            priority: priority
        )
    }

    // MARK: - matches: Disabled Rule

    func testDisabledRuleNeverMatches() {
        let rule = makeRule(trigger: .directory(path: "/tmp"), isEnabled: false)
        XCTAssertFalse(rule.matches(directory: "/tmp"))
    }

    // MARK: - matches: Directory Trigger

    func testDirectoryExactMatch() {
        let rule = makeRule(trigger: .directory(path: "/Users/dev/project"))
        XCTAssertTrue(rule.matches(directory: "/Users/dev/project"))
    }

    func testDirectoryNoMatch() {
        let rule = makeRule(trigger: .directory(path: "/Users/dev/project"))
        XCTAssertFalse(rule.matches(directory: "/Users/dev/other"))
    }

    func testDirectoryNilReturnsFalse() {
        let rule = makeRule(trigger: .directory(path: "/tmp"))
        XCTAssertFalse(rule.matches(directory: nil))
    }

    func testDirectoryWildcard() {
        let rule = makeRule(trigger: .directory(path: "/Users/*/project"))
        XCTAssertTrue(rule.matches(directory: "/Users/dev/project"))
        XCTAssertFalse(rule.matches(directory: "/Users/dev/other"))
    }

    func testDirectoryDoubleStarGlob() {
        let rule = makeRule(trigger: .directory(path: "/Users/**/node_modules"))
        XCTAssertTrue(rule.matches(directory: "/Users/dev/project/node_modules"))
        XCTAssertTrue(rule.matches(directory: "/Users/dev/deep/nested/node_modules"))
    }

    func testDirectoryTrailingSlashIgnored() {
        let rule = makeRule(trigger: .directory(path: "/tmp/"))
        XCTAssertTrue(rule.matches(directory: "/tmp"))
        XCTAssertTrue(rule.matches(directory: "/tmp/"))
    }

    // MARK: - matches: Git Repository Trigger

    func testGitRepoMatchesDirectoryBasename() {
        let rule = makeRule(trigger: .gitRepository(name: "my-project"))
        XCTAssertTrue(rule.matches(directory: "/Users/dev/my-project"))
    }

    func testGitRepoMatchesCaseInsensitive() {
        let rule = makeRule(trigger: .gitRepository(name: "MyProject"))
        XCTAssertTrue(rule.matches(directory: "/home/user/myproject"))
    }

    func testGitRepoNoMatch() {
        let rule = makeRule(trigger: .gitRepository(name: "my-project"))
        XCTAssertFalse(rule.matches(directory: "/Users/dev/other-project"))
    }

    func testGitRepoNilDirectoryReturnsFalse() {
        let rule = makeRule(trigger: .gitRepository(name: "repo"))
        XCTAssertFalse(rule.matches(directory: nil))
    }

    // MARK: - matches: SSH Host Trigger

    func testSSHHostExactMatch() {
        let rule = makeRule(trigger: .sshHost(hostname: "prod.example.com"))
        XCTAssertTrue(rule.matches(sshHost: "prod.example.com"))
    }

    func testSSHHostCaseInsensitive() {
        let rule = makeRule(trigger: .sshHost(hostname: "Prod.Example.COM"))
        XCTAssertTrue(rule.matches(sshHost: "prod.example.com"))
    }

    func testSSHHostNoMatch() {
        let rule = makeRule(trigger: .sshHost(hostname: "prod.example.com"))
        XCTAssertFalse(rule.matches(sshHost: "dev.example.com"))
    }

    func testSSHHostNilReturnsFalse() {
        let rule = makeRule(trigger: .sshHost(hostname: "host"))
        XCTAssertFalse(rule.matches(sshHost: nil))
    }

    // MARK: - matches: Process Running Trigger

    func testProcessRunningMatch() {
        let rule = makeRule(trigger: .processRunning(name: "docker"))
        XCTAssertTrue(rule.matches(processes: ["zsh", "docker", "node"]))
    }

    func testProcessRunningCaseInsensitive() {
        let rule = makeRule(trigger: .processRunning(name: "Docker"))
        XCTAssertTrue(rule.matches(processes: ["docker"]))
    }

    func testProcessRunningNoMatch() {
        let rule = makeRule(trigger: .processRunning(name: "docker"))
        XCTAssertFalse(rule.matches(processes: ["zsh", "node"]))
    }

    func testProcessRunningNilReturnsFalse() {
        let rule = makeRule(trigger: .processRunning(name: "vim"))
        XCTAssertFalse(rule.matches(processes: nil))
    }

    // MARK: - matches: Environment Variable Trigger

    func testEnvVarMatch() {
        let rule = makeRule(trigger: .environmentVariable(key: "NODE_ENV", value: "production"))
        XCTAssertTrue(rule.matches(environment: ["NODE_ENV": "production", "PATH": "/usr/bin"]))
    }

    func testEnvVarNoMatchWrongValue() {
        let rule = makeRule(trigger: .environmentVariable(key: "NODE_ENV", value: "production"))
        XCTAssertFalse(rule.matches(environment: ["NODE_ENV": "development"]))
    }

    func testEnvVarNoMatchMissingKey() {
        let rule = makeRule(trigger: .environmentVariable(key: "NODE_ENV", value: "production"))
        XCTAssertFalse(rule.matches(environment: ["PATH": "/usr/bin"]))
    }

    func testEnvVarNilReturnsFalse() {
        let rule = makeRule(trigger: .environmentVariable(key: "K", value: "V"))
        XCTAssertFalse(rule.matches(environment: nil))
    }

    // MARK: - matchesGlob (static)

    func testGlobExactPath() {
        XCTAssertTrue(ProfileSwitchRule.matchesGlob(path: "/usr/local/bin", pattern: "/usr/local/bin"))
    }

    func testGlobSingleStar() {
        XCTAssertTrue(ProfileSwitchRule.matchesGlob(path: "/Users/dev/project", pattern: "/Users/*/project"))
        XCTAssertFalse(ProfileSwitchRule.matchesGlob(path: "/Users/dev/other", pattern: "/Users/*/project"))
    }

    func testGlobDoubleStar() {
        XCTAssertTrue(ProfileSwitchRule.matchesGlob(path: "/a/b/c/d", pattern: "/a/**/d"))
        XCTAssertTrue(ProfileSwitchRule.matchesGlob(path: "/a/d", pattern: "/a/**/d"))
    }

    func testGlobNoMatch() {
        XCTAssertFalse(ProfileSwitchRule.matchesGlob(path: "/foo/bar", pattern: "/baz/qux"))
    }

    func testGlobDifferentDepth() {
        XCTAssertFalse(ProfileSwitchRule.matchesGlob(path: "/a/b/c", pattern: "/a/b"))
    }

    func testGlobPartialWildcard() {
        XCTAssertTrue(ProfileSwitchRule.matchesGlob(path: "/Users/dev/project-v2", pattern: "/Users/dev/project-*"))
    }

    // MARK: - sortedByPriority

    func testSortedByPriorityDescending() {
        let low = makeRule(trigger: .directory(path: "/a"), priority: 1)
        let high = makeRule(trigger: .directory(path: "/b"), priority: 10)
        let mid = makeRule(trigger: .directory(path: "/c"), priority: 5)

        let sorted = [low, high, mid].sortedByPriority()
        XCTAssertEqual(sorted.map(\.priority), [10, 5, 1])
    }

    func testSortedByPriorityTiebreaksByName() {
        let a = ProfileSwitchRule(name: "Alpha", trigger: .directory(path: "/a"), profileName: "p", priority: 5)
        let b = ProfileSwitchRule(name: "Beta", trigger: .directory(path: "/b"), profileName: "p", priority: 5)

        let sorted = [b, a].sortedByPriority()
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Beta"])
    }

    // MARK: - Codable / Equatable

    func testRuleCodableRoundTrip() throws {
        let original = ProfileSwitchRule(
            name: "Work Profile",
            isEnabled: true,
            trigger: .directory(path: "/Users/dev/work"),
            profileName: "work-theme",
            priority: 5
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProfileSwitchRule.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testRuleEquality() {
        let id = UUID()
        let a = ProfileSwitchRule(id: id, name: "R", trigger: .sshHost(hostname: "h"), profileName: "p")
        let b = ProfileSwitchRule(id: id, name: "R", trigger: .sshHost(hostname: "h"), profileName: "p")
        XCTAssertEqual(a, b)
    }
}
