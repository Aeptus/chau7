import Foundation
import XCTest
@testable import Chau7Core

/// The replay guard's recovery path is reachable by anyone who can put a frame
/// on the wire, because HELLO is cleartext and a decrypt failure costs 36
/// bytes. These lock in that recovery stays rate limited, so a hostile relay
/// cannot spin the session indefinitely with injected frames.
final class RemoteReplayGuardEpochLimitTests: XCTestCase {

    private func guardWithNonce(_ nonce: Data, at now: Date) -> RemoteReplayGuard {
        var guardUnderTest = RemoteReplayGuard()
        guardUnderTest.setNow(now)
        _ = guardUnderTest.evaluateHello(macNonce: nonce, hasCryptoSession: false)
        return guardUnderTest
    }

    func testUnchangedNonceWhileSessionActiveIsAccepted() {
        let nonce = Data(repeating: 0x11, count: 16)
        var guardUnderTest = guardWithNonce(nonce, at: Date())
        guard guardUnderTest.evaluateHello(macNonce: nonce, hasCryptoSession: true) == .accept else {
            return XCTFail("a matching nonce must not reset the session")
        }
    }

    func testEpochResetsAreAdmittedUpToTheBudgetThenEscalate() {
        let start = Date()
        var guardUnderTest = RemoteReplayGuard()
        guardUnderTest.setNow(start)
        var seenNonce = Data(repeating: 0x00, count: 16)
        _ = guardUnderTest.evaluateHello(macNonce: seenNonce, hasCryptoSession: false)

        var resets = 0
        var escalations = 0
        for step in 0 ..< (RemoteReplayGuard.maxEpochResetsInWindow + 3) {
            // A fresh nonce every time is what an injected HELLO looks like.
            seenNonce = Data(repeating: UInt8(step + 1), count: 16)
            switch guardUnderTest.evaluateHello(macNonce: seenNonce, hasCryptoSession: true) {
            case .resetSession:
                resets += 1
            case .escalate:
                escalations += 1
            case .accept, .drop:
                XCTFail("a changed nonce with an active session must reset or escalate")
            }
            guardUnderTest.setNow(start.addingTimeInterval(1))
        }

        XCTAssertEqual(resets, RemoteReplayGuard.maxEpochResetsInWindow)
        XCTAssertEqual(escalations, 3, "everything past the budget must escalate")
    }

    func testDecryptFailuresAlsoShareTheSameBudget() {
        let start = Date()
        var guardUnderTest = RemoteReplayGuard()
        guardUnderTest.setNow(start)

        // The stale-key net fires every 8 failures, and the epoch budget is
        // only 3 resets, so junk ciphertext alone exhausts recovery.
        var resets = 0
        var escalations = 0
        for _ in 0 ..< (RemoteReplayGuard.maxEpochResetsInWindow + 2)
            * RemoteReplayGuard.decryptFailureThreshold {
            switch guardUnderTest.noteDecryptFailure() {
            case .resetSession: resets += 1
            case .escalate: escalations += 1
            case .accept, .drop: break
            }
        }

        XCTAssertEqual(resets, RemoteReplayGuard.maxEpochResetsInWindow)
        XCTAssertGreaterThan(escalations, 0, "the budget must stop runaway recovery")
    }

    func testBudgetRecoversAfterAWindowElapses() {
        let start = Date()
        var guardUnderTest = RemoteReplayGuard()
        guardUnderTest.setNow(start)
        // Exhaust the budget.
        for _ in 0 ..< (RemoteReplayGuard.maxEpochResetsInWindow + 2)
            * RemoteReplayGuard.decryptFailureThreshold {
            _ = guardUnderTest.noteDecryptFailure()
        }

        // Past the window the timestamps age out, so a session that re-handshooks
        // hours later must reset rather than escalate forever.
        guardUnderTest.setNow(start.addingTimeInterval(RemoteReplayGuard.epochResetWindow + 1))
        var outcome: RemoteReplayGuard.Action = .accept
        for _ in 0 ..< RemoteReplayGuard.decryptFailureThreshold {
            outcome = guardUnderTest.noteDecryptFailure()
        }
        guard case .resetSession = outcome else {
            return XCTFail("an aged-out window must not escalate, got \(outcome)")
        }
    }

    func testSuccessfulDecryptionRestoresTheBudget() {
        let start = Date()
        var guardUnderTest = RemoteReplayGuard()
        guardUnderTest.setNow(start)

        // Burn the whole budget with junk ciphertext.
        for _ in 0 ..< (RemoteReplayGuard.maxEpochResetsInWindow + 2) {
            for _ in 0 ..< RemoteReplayGuard.decryptFailureThreshold {
                _ = guardUnderTest.noteDecryptFailure()
            }
        }
        // One good frame proves the epoch is the peer's.
        guardUnderTest.noteDecryptSuccess()
        // Budget restored: another run of failures must reset, not escalate.
        var outcome: RemoteReplayGuard.Action = .accept
        for _ in 0 ..< RemoteReplayGuard.decryptFailureThreshold {
            outcome = guardUnderTest.noteDecryptFailure()
        }
        guard case .resetSession = outcome else {
            return XCTFail("a successful frame must restore the reset budget, got \(outcome)")
        }
    }

    func testExplicitResetClearsTheBudget() {
        let start = Date()
        var guardUnderTest = RemoteReplayGuard()
        guardUnderTest.setNow(start)
        for _ in 0 ..< (RemoteReplayGuard.maxEpochResetsInWindow + 2) {
            for _ in 0 ..< RemoteReplayGuard.decryptFailureThreshold {
                _ = guardUnderTest.noteDecryptFailure()
            }
        }
        guardUnderTest.reset()
        var outcome: RemoteReplayGuard.Action = .accept
        for _ in 0 ..< RemoteReplayGuard.decryptFailureThreshold {
            outcome = guardUnderTest.noteDecryptFailure()
        }
        guard case .resetSession = outcome else {
            return XCTFail("reset() must clear the epoch budget, got \(outcome)")
        }
    }
}
