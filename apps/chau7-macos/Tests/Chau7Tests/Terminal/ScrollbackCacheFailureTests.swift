import Foundation
import XCTest
@testable import Chau7Core

final class ScrollbackCacheFailureTests: XCTestCase {
    func testClassifiesActionableDiskFailures() {
        XCTAssertEqual(
            ScrollbackCacheFailureClassifier.classify(
                NSError(domain: NSPOSIXErrorDomain, code: 28)
            ),
            .outOfSpace
        )
        XCTAssertEqual(
            ScrollbackCacheFailureClassifier.classify(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            ScrollbackCacheFailureClassifier.classify(
                NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
            ),
            .corruptData
        )
        XCTAssertEqual(
            ScrollbackCacheFailureClassifier.classify(
                NSError(domain: NSPOSIXErrorDomain, code: 5)
            ),
            .ioFailure
        )
    }
}
