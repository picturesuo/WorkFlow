import AppKit
import Combine
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// The History window's cost guarantees: what is measured, published and
/// loaded when it opens and when a search runs.
@MainActor
final class HistoryPerformanceBehaviorTests: XCTestCase {
    // MARK: Window minimum size

    func testWindowMinimumSizeIsConstantAndDoesNotMeasureContent() {
        let counter = MeasureCounter()
        let controller = NSHostingController(rootView: FixedMinimumSizeLayout(
            minimum: CGSize(width: 440, height: 460), ideal: CGSize(width: 560, height: 720)
        ) {
            MeasuringProbe(counter: counter) { Color.clear }
        })

        XCTAssertEqual(controller.sizeThatFits(in: .zero), CGSize(width: 440, height: 460))
        XCTAssertEqual(controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)),
                       CGSize(width: 10_000, height: 10_000))
        XCTAssertEqual(counter.count, 0, "The window's size queries never measure the content")
    }
}

// MARK: - Helpers

private final class MeasureCounter {
    var count = 0
}

/// A layout that counts how often SwiftUI measures it.
private struct MeasuringProbe: Layout {
    let counter: MeasureCounter

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        counter.count += 1
        return CGSize(width: 100, height: 100)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
