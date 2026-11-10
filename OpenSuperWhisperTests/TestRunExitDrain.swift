import XCTest
@testable import OpenSuperWhisper

/// Closes the native-call gate when the test run ends, before XCTest calls
/// exit, so background whisper.cpp work finishes while its statics still exist.
@objc(TestRunExitDrain)
final class TestRunExitDrain: NSObject, XCTestObservation {
    nonisolated(unsafe) static var isInstalled = false

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        Self.isInstalled = true
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        ProcessExitGate.shared.shutdown()
    }
}
