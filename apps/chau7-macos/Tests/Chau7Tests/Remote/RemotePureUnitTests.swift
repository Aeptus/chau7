import CryptoKit
import XCTest
@testable import Chau7Core

/// First test coverage for the pure remote-client units that moved from the
/// iOS app into Chau7Core (reconnect backoff, frame rate limiter, telemetry
/// buffer, deep-link parsing, ANSI stripping).
final class RemotePureUnitTests: XCTestCase {

    // MARK: - RemoteTerminalStreamingPolicy

    func testModernTerminalPresentationsUseExactlyOneWireRepresentation() {
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsOutputFrames(for: .text))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsTextSnapshots(for: .text))
        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsGridSnapshots(for: .text))
        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsGridCheckpointAfterOutput(for: .text))

        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsOutputFrames(for: .replay))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsTextSnapshots(for: .replay))
        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsGridSnapshots(for: .replay))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsGridSnapshots(for: .replay, alternateScreenActive: true))
        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsGridCheckpointAfterOutput(for: .replay))
        XCTAssertFalse(
            RemoteTerminalStreamingPolicy.sendsGridCheckpointAfterOutput(for: .replay, alternateScreenActive: true),
            "alternate-screen checkpoints are scheduled through the capped grid sender"
        )

        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsOutputFrames(for: .grid))
        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsTextSnapshots(for: .grid))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsGridSnapshots(for: .grid))
        XCTAssertFalse(RemoteTerminalStreamingPolicy.sendsGridCheckpointAfterOutput(for: .grid))
    }

    func testMissingPresentationPreservesLegacyDualStream() {
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsOutputFrames(for: nil))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsTextSnapshots(for: nil))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsGridSnapshots(for: nil))
        XCTAssertTrue(RemoteTerminalStreamingPolicy.sendsGridCheckpointAfterOutput(for: nil))
    }

    // MARK: - RemoteReconnectBackoff

    func testBackoffProducesExponentialDelaysThenExhausts() {
        var backoff = RemoteReconnectBackoff()
        var delays: [TimeInterval] = []
        while let delay = backoff.nextDelay() {
            delays.append(delay)
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32])
        XCTAssertFalse(backoff.hasRemainingAttempts)
        XCTAssertNil(backoff.nextDelay())
    }

    func testBackoffResetRestoresAttempts() {
        var backoff = RemoteReconnectBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.nextDelay(), 2)
    }

    // MARK: - RemoteFrameRateLimiter

    func testRateLimiterAllowsBurstUpToCapacityThenThrottles() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RemoteFrameRateLimiter(capacity: 4, refillPerSecond: 1, now: start)
        for _ in 0 ..< 4 {
            XCTAssertTrue(limiter.allow(now: start))
        }
        XCTAssertFalse(limiter.allow(now: start), "5th frame in the same instant must throttle")
    }

    func testRateLimiterRefillsOverTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RemoteFrameRateLimiter(capacity: 2, refillPerSecond: 1, now: start)
        XCTAssertTrue(limiter.allow(now: start))
        XCTAssertTrue(limiter.allow(now: start))
        XCTAssertFalse(limiter.allow(now: start))
        // 1 second later one token has refilled.
        XCTAssertTrue(limiter.allow(now: start.addingTimeInterval(1)))
        XCTAssertFalse(limiter.allow(now: start.addingTimeInterval(1)))
    }

    func testRateLimiterClampsToCapacity() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var limiter = RemoteFrameRateLimiter(capacity: 2, refillPerSecond: 100, now: start)
        // Long idle must not accumulate more than capacity.
        let later = start.addingTimeInterval(3600)
        XCTAssertTrue(limiter.allow(now: later))
        XCTAssertTrue(limiter.allow(now: later))
        XCTAssertFalse(limiter.allow(now: later))
    }

    // MARK: - RemoteTelemetryBuffer

    private func telemetryEvent(_ label: String) -> RemoteClientTelemetryEvent {
        RemoteClientTelemetryEvent(
            source: "ios",
            deviceID: "d",
            deviceName: "iPhone",
            appVersion: "1.0",
            sessionID: nil,
            eventType: .connectRequested,
            status: nil,
            tabID: nil,
            tabTitle: nil,
            message: label,
            metadata: [:],
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    func testTelemetryBufferEvictsOldestBeyondCapacity() {
        var buffer = RemoteTelemetryBuffer(maxEvents: 3)
        for label in ["a", "b", "c", "d"] {
            buffer.append(telemetryEvent(label))
        }
        let drained = buffer.drain()
        XCTAssertEqual(drained.map(\.message), ["b", "c", "d"], "oldest event must be evicted, FIFO order preserved")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTelemetryBufferDrainClearsAndPreservesOrder() {
        var buffer = RemoteTelemetryBuffer(maxEvents: 10)
        buffer.append(telemetryEvent("first"))
        buffer.append(telemetryEvent("second"))
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.drain().map(\.message), ["first", "second"])
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    // MARK: - RemoteActivityURLAction

    func testURLActionParsesAllHosts() {
        XCTAssertEqual(
            RemoteActivityURLAction(url: URL(string: "chau7remote://open?tab_id=3")!),
            .open(tabID: 3)
        )
        XCTAssertEqual(
            RemoteActivityURLAction(url: URL(string: "chau7remote://open")!),
            .open(tabID: nil)
        )
        XCTAssertEqual(
            RemoteActivityURLAction(url: URL(string: "chau7remote://switch?tab_id=7")!),
            .switchTab(tabID: 7)
        )
        XCTAssertEqual(
            RemoteActivityURLAction(url: URL(string: "chau7remote://approve?request_id=r1&tab_id=2")!),
            .approve(requestID: "r1", tabID: 2)
        )
        XCTAssertEqual(
            RemoteActivityURLAction(url: URL(string: "chau7remote://deny?request_id=r2")!),
            .deny(requestID: "r2", tabID: nil)
        )
    }

    func testURLActionRejectsInvalidInput() {
        XCTAssertNil(RemoteActivityURLAction(url: URL(string: "https://open?tab_id=3")!), "wrong scheme")
        XCTAssertNil(RemoteActivityURLAction(url: URL(string: "chau7remote://switch")!), "switch requires tab_id")
        XCTAssertNil(RemoteActivityURLAction(url: URL(string: "chau7remote://approve?tab_id=2")!), "approve requires request_id")
        XCTAssertNil(RemoteActivityURLAction(url: URL(string: "chau7remote://unknown")!), "unknown host")
    }

    // MARK: - ANSIStripper

    func testANSIStripperRemovesCSISequences() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[31mred\u{1B}[0m plain"), "red plain")
        XCTAssertEqual(ANSIStripper.strip("no escapes"), "no escapes")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[2J\u{1B}[Hcleared"), "cleared")
    }

    func testANSIStripperHandlesBareEscape() {
        XCTAssertEqual(ANSIStripper.strip("a\u{1B}b"), "ab")
    }

    /// OSC 7 (the cwd report zsh and fish emit on essentially every prompt),
    /// OSC 0/1/2 (title), and their 8-bit C1 form all used to leak their whole
    /// payload as visible text because only `ESC [` was understood.
    func testANSIStripperConsumesOSCThroughSTAndBEL() {
        XCTAssertEqual(
            ANSIStripper.strip("\u{1B}]7;file:///Users/me/proj\u{1B}\\next> "),
            "next> "
        )
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]7;file:///x\u{07}after"), "after")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]0;my title\u{07}after"), "after")
        // The backslash completing ST must not leak.
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]0;t\u{1B}\\ok"), "ok")
        // 8-bit C1 OSC.
        XCTAssertEqual(ANSIStripper.strip("\u{9D}0;t\u{07}after"), "after")
    }

    /// DCS / PM / APC are string-terminated and used to leak their payload.
    func testANSIStripperConsumesStringTerminatedSequences() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}Pqdata\u{1B}\\tail"), "tail")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}^pm\u{1B}\\tail"), "tail")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}_apc\u{1B}\\tail"), "tail")
    }

    /// `ESC ( B` is three bytes: the introducer plus a designator. Only the
    /// `ESC` used to be dropped, so `(B` rendered as visible text.
    func testANSIStripperConsumesCharsetDesignator() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}(Bok"), "ok")
        XCTAssertEqual(ANSIStripper.strip("\u{1B})0ok"), "ok")
    }

    /// 8-bit C1 CSI (`U+009B`) is equivalent to `ESC [`.
    func testANSIStripperHandlesEightBitCSI() {
        XCTAssertEqual(ANSIStripper.strip("\u{9B}31mred"), "red")
    }

    /// A sequence whose terminator never arrives must consume the remainder
    /// rather than replaying it as text.
    func testANSIStripperDropsUnterminatedSequences() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]7;abc"), "")
        XCTAssertEqual(ANSIStripper.strip("abc\u{1B}"), "abc")
    }

    /// Stripping must be transparent to non-ASCII content.
    func testANSIStripperPreservesMultibyteText() {
        XCTAssertEqual(ANSIStripper.strip("日本語 ✅ done"), "日本語 ✅ done")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[1m日本\u{1B}[0m ✅"), "日本 ✅")
    }
}

/// Vector tests mirroring `services/chau7-remote/internal/agent/relay_token_test.go`
/// and the relay verifier (`services/chau7-relay/src/token.js`). The three
/// implementations must produce/accept identical tokens.
final class RelayTokenTests: XCTestCase {

    /// Mirrors the hmacKey vector in Go's relay_token_test.go.
    private let vectorHMACKey = Data((1 ... 32).map(UInt8.init)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")

    func testTokenFormatMatchesRelayContract() throws {
        let pairing = RemotePairingPayload(
            relayURL: "wss://relay.example.com",
            deviceID: "11111111-2222-3333-4444-555555555555",
            macPub: "bWFjLXB1Yg==",
            pairingCode: "123456",
            expiresAt: "2026-07-01T12:30:00Z",
            relaySecret: vectorHMACKey, relayKeyID: "test-key"
        )
        let token = try XCTUnwrap(RelayToken.make(pairing: pairing, role: "ios", scope: "connect"))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 6)
        XCTAssertEqual(parts[0], "v3")
        XCTAssertNotNil(Int64(parts[2]), "timestamp must be integer seconds")
        XCTAssertEqual(parts[4], "connect")

        // Recompute the signature exactly as the relay does.
        let message = "v3:test-key:\(pairing.deviceID):ios:connect:\(parts[2]):\(parts[3])"
        let key = SymmetricKey(data: Data(vectorHMACKey.utf8))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(parts[5], expected)
    }

    func testDeterministicCoreMatchesKnownVector() {
        // Fixed-input vector: any implementation change that alters the
        // signature construction fails here before it breaks relay auth.
        let token = RelayToken.make(
            deviceID: "11111111-2222-3333-4444-555555555555",
            keyID: "test-key", secret: vectorHMACKey,
            role: "mac",
            scope: "connect",
            ts: "1751457600",
            nonce: "AAAAAAAAAAAAAAAAAAAAAA"
        )
        let message = "v3:test-key:11111111-2222-3333-4444-555555555555:mac:connect:1751457600:AAAAAAAAAAAAAAAAAAAAAA"
        let key = SymmetricKey(data: Data(vectorHMACKey.utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(token, "v3.test-key.1751457600.AAAAAAAAAAAAAAAAAAAAAA.connect.\(signature)")
    }

    func testLegacyWeakAndWrongRolePairingsFailClosed() {
        var pairing = RemotePairingPayload(relayURL: "wss://r", deviceID: "d", macPub: "m", pairingCode: "1", expiresAt: "e", relaySecret: vectorHMACKey)
        XCTAssertNil(RelayToken.make(pairing: pairing, role: "ios", scope: "connect"))
        pairing.relayKeyID = "test-key"
        XCTAssertNil(RelayToken.make(pairing: pairing, role: "mac", scope: "connect"))
        pairing.relaySecret = "weak"
        XCTAssertNil(RelayToken.make(pairing: pairing, role: "ios", scope: "connect"))
        XCTAssertFalse(RelayToken.isStrongCredential(vectorHMACKey + "="))
        XCTAssertFalse(RelayToken.isValidIdentifier("invalid:key", maximum: 32))
        XCTAssertFalse(RelayToken.isValidIdentifier("", maximum: 32))
    }

    func testSharedCrossLanguageV3Vector() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("services/chau7-remote/docs/fixtures/relay_credentials_v3.json")
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture))
        for role in ["mac", "ios"] {
            let hex = try XCTUnwrap(vector["\(role)_bytes_hex"])
            let bytes = try stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return try XCTUnwrap(UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16))
            }
            let token = try RelayToken.make(
                deviceID: XCTUnwrap(vector["device_id"]),
                keyID: XCTUnwrap(vector["key_id"]),
                secret: Data(bytes).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
                role: role,
                scope: "connect",
                ts: XCTUnwrap(vector["timestamp"]),
                nonce: XCTUnwrap(vector["nonce"])
            )
            XCTAssertEqual(token, vector["\(role)_token"])
        }
    }

    func testNoSecretReturnsNil() {
        let pairing = RemotePairingPayload(
            relayURL: "wss://relay.example.com",
            deviceID: "d",
            macPub: "m",
            pairingCode: "1",
            expiresAt: "e",
            relaySecret: nil
        )
        XCTAssertNil(RelayToken.make(pairing: pairing, role: "ios", scope: "connect"))
    }

    func testIssueScopeCanBeMintedFromLocalDeviceIdentity() throws {
        let token = try XCTUnwrap(
            RelayToken.make(
                deviceID: "11111111-2222-3333-4444-555555555555",
                keyID: "test-key", secret: vectorHMACKey,
                role: "mac",
                scope: "issues"
            )
        )
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 6)
        XCTAssertEqual(parts[0], "v3")
        XCTAssertEqual(parts[4], "issues")
    }

    func testNoncesAreUniqueAcrossMints() throws {
        let pairing = RemotePairingPayload(
            relayURL: "wss://r", deviceID: "d", macPub: "m",
            pairingCode: "1", expiresAt: "e", relaySecret: vectorHMACKey, relayKeyID: "test-key"
        )
        let a = try XCTUnwrap(RelayToken.make(pairing: pairing, role: "ios", scope: "push"))
        let b = try XCTUnwrap(RelayToken.make(pairing: pairing, role: "ios", scope: "push"))
        XCTAssertNotEqual(a.split(separator: ".")[3], b.split(separator: ".")[3])
    }
}
