import CryptoKit
import XCTest
@testable import Chau7Core

/// First test coverage for the pure remote-client units that moved from the
/// iOS app into Chau7Core (reconnect backoff, frame rate limiter, telemetry
/// buffer, deep-link parsing, ANSI stripping).
final class RemotePureUnitTests: XCTestCase {

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
}

/// Vector tests mirroring `services/chau7-remote/internal/agent/relay_token_test.go`
/// and the relay verifier (`services/chau7-relay/src/token.js`). The three
/// implementations must produce/accept identical tokens.
final class RelayTokenTests: XCTestCase {

    /// Mirrors the hmacKey vector in Go's relay_token_test.go.
    private let vectorHMACKey = "unit-test-hmac-key-0001"

    func testTokenFormatMatchesRelayContract() throws {
        let pairing = RemotePairingPayload(
            relayURL: "wss://relay.example.com",
            deviceID: "11111111-2222-3333-4444-555555555555",
            macPub: "bWFjLXB1Yg==",
            pairingCode: "123456",
            expiresAt: "2026-07-01T12:30:00Z",
            relaySecret: vectorHMACKey
        )
        let token = try XCTUnwrap(RelayToken.make(pairing: pairing, role: "ios", scope: "connect"))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0], "v2")
        XCTAssertNotNil(Int64(parts[1]), "timestamp must be integer seconds")
        XCTAssertEqual(parts[3], "connect")

        // Recompute the signature exactly as the relay does.
        let message = "v2:\(pairing.deviceID):ios:connect:\(parts[1]):\(parts[2])"
        let key = SymmetricKey(data: Data(vectorHMACKey.utf8))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(parts[4], expected)
    }

    func testDeterministicCoreMatchesKnownVector() {
        // Fixed-input vector: any implementation change that alters the
        // signature construction fails here before it breaks relay auth.
        let token = RelayToken.make(
            deviceID: "11111111-2222-3333-4444-555555555555",
            secret: vectorHMACKey,
            role: "mac",
            scope: "connect",
            ts: "1751457600",
            nonce: "AAAAAAAAAAAAAAAAAAAAAA"
        )
        let message = "v2:11111111-2222-3333-4444-555555555555:mac:connect:1751457600:AAAAAAAAAAAAAAAAAAAAAA"
        let key = SymmetricKey(data: Data(vectorHMACKey.utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(token, "v2.1751457600.AAAAAAAAAAAAAAAAAAAAAA.connect.\(signature)")
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

    func testNoncesAreUniqueAcrossMints() throws {
        let pairing = RemotePairingPayload(
            relayURL: "wss://r", deviceID: "d", macPub: "m",
            pairingCode: "1", expiresAt: "e", relaySecret: "s"
        )
        let a = try XCTUnwrap(RelayToken.make(pairing: pairing, role: "ios", scope: "push"))
        let b = try XCTUnwrap(RelayToken.make(pairing: pairing, role: "ios", scope: "push"))
        XCTAssertNotEqual(a.split(separator: ".")[2], b.split(separator: ".")[2])
    }
}
