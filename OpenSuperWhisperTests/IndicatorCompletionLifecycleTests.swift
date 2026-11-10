import XCTest
@testable import OpenSuperWhisper

@MainActor
final class IndicatorCompletionLifecycleTests: XCTestCase {
    func testDelayedOlderCompletionDoesNotDismissNewerIndicator() {
        let older = NSObject()
        let newer = NSObject()
        var current: AnyObject? = older
        var hideCount = 0
        let delayedOlderCompletion = {
            IndicatorWindowManager.finishDecoding(from: older, current: current) {
                hideCount += 1
                current = nil
            }
        }

        // A is still cleaning up when B takes over the indicator.
        current = newer
        delayedOlderCompletion()

        XCTAssertEqual(hideCount, 0)
        XCTAssertTrue(current === newer)
        IndicatorWindowManager.finishDecoding(from: newer, current: current) {
            hideCount += 1
            current = nil
        }
        XCTAssertEqual(hideCount, 1)
        XCTAssertNil(current)
    }

    func testLateTimerAfterDismissalCannotHideAnotherSession() {
        let dismissed = NSObject()
        var current: AnyObject?
        var hideCount = 0
        let expiredTimer = {
            IndicatorWindowManager.finishDecoding(from: dismissed, current: current) {
                hideCount += 1
                current = nil
            }
        }

        expiredTimer()
        XCTAssertEqual(hideCount, 0)

        let replacement = NSObject()
        current = replacement
        expiredTimer()
        XCTAssertEqual(hideCount, 0)
        XCTAssertTrue(current === replacement)
    }
}
