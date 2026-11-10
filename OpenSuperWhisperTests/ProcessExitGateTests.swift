import Foundation
import XCTest
@testable import OpenSuperWhisper

/// ProcessExitGate through its injectable initializer: it admits work while
/// open, refuses it once shutdown begins, and lets shutdown wait for the
/// calls in flight, bounded by its timeout. The expected behavior is
/// ExitGateCore's transition table.
final class ProcessExitGateTests: XCTestCase {
    /// A lock-guarded value shared with other threads.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func read() -> Value { lock.withLock { value } }
        func update<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&value) } }
    }

    private func gate(timeout: TimeInterval = 10, abandons: Locked<Int> = Locked(0)) -> ProcessExitGate {
        ProcessExitGate(drainTimeout: timeout, onAbandon: { abandons.update { $0 += 1 } })
    }

    /// The hosted bundle's principal class closes the shared gate when the
    /// run ends, before XCTest calls exit.
    func testTheExitDrainObserverIsInstalled() {
        XCTAssertTrue(TestRunExitDrain.isInstalled)
    }

    func testAdmitsAndRunsBeforeShutdown() {
        let gate = gate()
        XCTAssertEqual(gate.run { 42 }, 42)
        XCTAssertFalse(gate.isExiting)
        XCTAssertEqual(gate.inFlightCount, 0)
    }

    func testRefusesAfterShutdownWithoutRunningTheBody() {
        let gate = gate()
        gate.shutdown()
        let ran = Locked(false)
        let result: Int? = gate.run {
            ran.update { $0 = true }
            return 1
        }
        XCTAssertNil(result)
        XCTAssertFalse(ran.read())
        XCTAssertTrue(gate.isExiting)
    }

    func testShutdownWithNothingInFlightReturnsAtOnce() {
        let abandons = Locked(0)
        let gate = gate(timeout: 10, abandons: abandons)
        let start = Date()
        gate.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertEqual(abandons.read(), 0)
    }

    func testShutdownWaitsForAnInFlightBody() {
        let abandons = Locked(0)
        let gate = gate(timeout: 10, abandons: abandons)
        let entered = DispatchSemaphore(value: 0)
        let bodyFinished = Locked<Date?>(nil)
        Thread.detachNewThread {
            _ = gate.run {
                entered.signal()
                Thread.sleep(forTimeInterval: 0.3)
                bodyFinished.update { $0 = Date() }
            }
        }
        entered.wait()

        let start = Date()
        gate.shutdown()
        let returned = Date()

        let finished = bodyFinished.read()
        XCTAssertNotNil(finished, "The body finished before shutdown returned")
        if let finished { XCTAssertLessThanOrEqual(finished, returned) }
        XCTAssertGreaterThanOrEqual(returned.timeIntervalSince(start), 0.2)
        XCTAssertEqual(abandons.read(), 0)
        XCTAssertEqual(gate.inFlightCount, 0)
    }

    func testShutdownPastItsTimeoutAbandonsExactlyOnceAndReturns() {
        let abandons = Locked(0)
        let gate = gate(timeout: 0.2, abandons: abandons)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let left = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = gate.run {
                entered.signal()
                release.wait()
            }
            left.signal()
        }
        entered.wait()

        let start = Date()
        gate.shutdown()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 2)
        XCTAssertEqual(abandons.read(), 1)

        gate.shutdown()
        XCTAssertEqual(abandons.read(), 1, "A later shutdown never abandons again")

        release.signal()
        XCTAssertEqual(left.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gate.inFlightCount, 0, "The abandoned call still leaves the gate")
        XCTAssertEqual(abandons.read(), 1)
    }

    func testSecondShutdownIsANoOp() {
        let abandons = Locked(0)
        let gate = gate(timeout: 10, abandons: abandons)
        gate.shutdown()
        let start = Date()
        gate.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertTrue(gate.isExiting)
        XCTAssertNil(gate.run { 1 })
        XCTAssertEqual(abandons.read(), 0)
    }

    func testTwoShutdownsBothWaitForTheInFlightBody() {
        let abandons = Locked(0)
        let gate = gate(timeout: 10, abandons: abandons)
        let entered = DispatchSemaphore(value: 0)
        let bodyFinished = Locked<Date?>(nil)
        Thread.detachNewThread {
            _ = gate.run {
                entered.signal()
                Thread.sleep(forTimeInterval: 0.3)
                bodyFinished.update { $0 = Date() }
            }
        }
        entered.wait()

        let returns = Locked<[Date]>([])
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            Thread.detachNewThread {
                gate.shutdown()
                returns.update { $0.append(Date()) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let finished = bodyFinished.read()
        XCTAssertNotNil(finished, "The body finished")
        XCTAssertEqual(returns.read().count, 2)
        if let finished {
            for returned in returns.read() {
                XCTAssertGreaterThanOrEqual(returned, finished, "No shutdown returns before the body has finished")
            }
        }
        XCTAssertEqual(abandons.read(), 0)
    }

    func testTwoShutdownsPastTheTimeoutBothReturnAndAbandonOnce() {
        let abandons = Locked(0)
        let gate = gate(timeout: 0.2, abandons: abandons)
        let entered = DispatchSemaphore(value: 0)
        let left = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = gate.run {
                entered.signal()
                Thread.sleep(forTimeInterval: 1)
            }
            left.signal()
        }
        entered.wait()

        let start = Date()
        let returns = Locked<[Date]>([])
        let group = DispatchGroup()
        for delay in [0.0, 0.05] {
            group.enter()
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: delay)
                gate.shutdown()
                returns.update { $0.append(Date()) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let returned = returns.read()
        XCTAssertEqual(returned.count, 2)
        if let first = returned.min(), let last = returned.max() {
            XCTAssertLessThan(last.timeIntervalSince(first), 0.1, "The later caller is released with the first, not at its own deadline")
            XCTAssertLessThan(last.timeIntervalSince(start), 0.9, "Both returned on the timeout, before the body finished")
        }
        XCTAssertEqual(abandons.read(), 1)

        XCTAssertEqual(left.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(abandons.read(), 1)
    }

    func testAThrowingBodyStillLeavesTheGate() {
        struct Failure: Error {}
        let gate = gate()
        XCTAssertThrowsError(try gate.run { () throws -> Int in throw Failure() })
        XCTAssertEqual(gate.inFlightCount, 0)
        let start = Date()
        gate.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Nothing is left in flight to wait for")
    }

    /// Eight threads run calls in a loop while another thread shuts the gate:
    /// no body starts after shutdown has returned, and every thread finishes.
    func testNoBodyStartsAfterShutdownReturnsUnderConcurrency() {
        let gate = gate(timeout: 10)
        let shutdownReturned = Locked(false)
        let started = Locked(0)
        let startedAfterShutdown = Locked(0)
        let group = DispatchGroup()

        for _ in 0..<8 {
            group.enter()
            Thread.detachNewThread {
                while true {
                    let admitted = gate.run { () -> Bool in
                        started.update { $0 += 1 }
                        if shutdownReturned.read() {
                            startedAfterShutdown.update { $0 += 1 }
                        }
                        usleep(100)
                        return true
                    }
                    if admitted == nil { break }
                }
                group.leave()
            }
        }

        let shutdownDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            usleep(50_000)
            gate.shutdown()
            shutdownReturned.update { $0 = true }
            shutdownDone.signal()
        }

        XCTAssertEqual(shutdownDone.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertGreaterThan(started.read(), 8)
        XCTAssertEqual(startedAfterShutdown.read(), 0)
        XCTAssertEqual(gate.inFlightCount, 0)
    }
}
