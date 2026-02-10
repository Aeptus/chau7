import XCTest
@testable import Chau7Core

final class SSHConfigParserTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseStandardConfig() {
        let config = """
        Host myserver
            HostName 192.168.1.100
            User admin
            Port 2222
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].host, "myserver")
        XCTAssertEqual(entries[0].hostname, "192.168.1.100")
        XCTAssertEqual(entries[0].user, "admin")
        XCTAssertEqual(entries[0].port, 2222)
    }

    func testParseHostNameUserPortIdentityFile() {
        let config = """
        Host production
            HostName prod.example.com
            User deploy
            Port 22
            IdentityFile ~/.ssh/id_ed25519
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].host, "production")
        XCTAssertEqual(entries[0].hostname, "prod.example.com")
        XCTAssertEqual(entries[0].user, "deploy")
        XCTAssertEqual(entries[0].port, 22)
        XCTAssertEqual(entries[0].identityFile, "~/.ssh/id_ed25519")
    }

    func testParseProxyJumpAndForwardAgent() {
        let config = """
        Host internal
            HostName 10.0.0.5
            ProxyJump bastion
            ForwardAgent yes
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].proxyJump, "bastion")
        XCTAssertEqual(entries[0].forwardAgent, true)
    }

    func testParseForwardAgentNo() {
        let config = """
        Host noagent
            HostName example.com
            ForwardAgent no
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].forwardAgent, false)
    }

    func testParseWildcardHost() {
        let config = """
        Host *
            ServerAliveInterval 60
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].host, "*")
        XCTAssertNil(entries[0].hostname)
    }

    func testParseCommentsAndEmptyLinesSkipped() {
        let config = """
        # This is a comment
        
        Host myhost
            # Another comment
            HostName example.com
        
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].host, "myhost")
        XCTAssertEqual(entries[0].hostname, "example.com")
    }

    func testParseExtraOptionsPreserved() {
        let config = """
        Host custom
            HostName example.com
            ServerAliveInterval 60
            ServerAliveCountMax 3
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].extraOptions["ServerAliveInterval"], "60")
        XCTAssertEqual(entries[0].extraOptions["ServerAliveCountMax"], "3")
    }

    func testParseMultiEntryConfig() {
        let config = """
        Host server1
            HostName 10.0.0.1
            User alice

        Host server2
            HostName 10.0.0.2
            User bob
            Port 2222

        Host server3
            HostName 10.0.0.3
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].host, "server1")
        XCTAssertEqual(entries[0].user, "alice")
        XCTAssertEqual(entries[1].host, "server2")
        XCTAssertEqual(entries[1].user, "bob")
        XCTAssertEqual(entries[1].port, 2222)
        XCTAssertEqual(entries[2].host, "server3")
        XCTAssertEqual(entries[2].hostname, "10.0.0.3")
    }

    // MARK: - Serialization Tests

    func testSerializationRoundTrip() {
        let original = SSHConfigEntry(
            host: "roundtrip",
            hostname: "192.168.1.50",
            user: "testuser",
            port: 2222,
            identityFile: "~/.ssh/test_key",
            proxyJump: "bastion",
            forwardAgent: true
        )

        let serialized = SSHConfigParser.serialize([original])
        let parsed = SSHConfigParser.parse(serialized)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].host, original.host)
        XCTAssertEqual(parsed[0].hostname, original.hostname)
        XCTAssertEqual(parsed[0].user, original.user)
        XCTAssertEqual(parsed[0].port, original.port)
        XCTAssertEqual(parsed[0].identityFile, original.identityFile)
        XCTAssertEqual(parsed[0].proxyJump, original.proxyJump)
        XCTAssertEqual(parsed[0].forwardAgent, original.forwardAgent)
    }

    func testSerializeMultipleEntries() {
        let entries = [
            SSHConfigEntry(host: "host1", hostname: "1.1.1.1"),
            SSHConfigEntry(host: "host2", hostname: "2.2.2.2", user: "admin")
        ]

        let serialized = SSHConfigParser.serialize(entries)
        XCTAssertTrue(serialized.contains("Host host1"))
        XCTAssertTrue(serialized.contains("Host host2"))
        XCTAssertTrue(serialized.contains("HostName 1.1.1.1"))
        XCTAssertTrue(serialized.contains("User admin"))
    }

    func testSerializeOmitsNilFields() {
        let entry = SSHConfigEntry(host: "minimal", hostname: "example.com")
        let serialized = SSHConfigParser.serialize([entry])

        XCTAssertTrue(serialized.contains("Host minimal"))
        XCTAssertTrue(serialized.contains("HostName example.com"))
        XCTAssertFalse(serialized.contains("User"))
        XCTAssertFalse(serialized.contains("Port"))
        XCTAssertFalse(serialized.contains("IdentityFile"))
        XCTAssertFalse(serialized.contains("ProxyJump"))
        XCTAssertFalse(serialized.contains("ForwardAgent"))
    }

    // MARK: - Display Name Tests

    func testDisplayNameWithUserAndHostname() {
        let entry = SSHConfigEntry(host: "myhost", hostname: "example.com", user: "admin")
        XCTAssertEqual(entry.displayName, "admin@example.com")
    }

    func testDisplayNameWithHostnameOnly() {
        let entry = SSHConfigEntry(host: "myhost", hostname: "example.com")
        XCTAssertEqual(entry.displayName, "example.com")
    }

    func testDisplayNameFallsBackToHost() {
        let entry = SSHConfigEntry(host: "myhost")
        XCTAssertEqual(entry.displayName, "myhost")
    }

    // MARK: - Edge Cases

    func testParseEmptyString() {
        let entries = SSHConfigParser.parse("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseOnlyComments() {
        let config = """
        # Just a comment
        # Another comment
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseOptionsBeforeFirstHost() {
        let config = """
        ServerAliveInterval 60
        Host actual
            HostName example.com
        """
        let entries = SSHConfigParser.parse(config)
        // Options before first Host are ignored
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].host, "actual")
    }

    func testEntryEquatable() {
        let id = UUID()
        let entry1 = SSHConfigEntry(id: id, host: "test", hostname: "example.com")
        let entry2 = SSHConfigEntry(id: id, host: "test", hostname: "example.com")
        XCTAssertEqual(entry1, entry2)
    }

    func testEntryCodable() throws {
        let entry = SSHConfigEntry(
            host: "codable",
            hostname: "example.com",
            user: "test",
            port: 22,
            extraOptions: ["Compression": "yes"]
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SSHConfigEntry.self, from: data)
        XCTAssertEqual(decoded.host, entry.host)
        XCTAssertEqual(decoded.hostname, entry.hostname)
        XCTAssertEqual(decoded.user, entry.user)
        XCTAssertEqual(decoded.port, entry.port)
        XCTAssertEqual(decoded.extraOptions["Compression"], "yes")
    }
}
