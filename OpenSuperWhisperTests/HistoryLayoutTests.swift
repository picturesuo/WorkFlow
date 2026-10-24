import AppKit
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Renders the production History rows and dictation bar without opening,
/// activating, or capturing a window. `MainWindowLayoutTests` renders them
/// inside the whole window.
/// Attachments use synthetic transcripts and are safe to share for visual review.
@MainActor
final class HistoryLayoutTests: XCTestCase {
    func testHistoryAtCompactAndWideSizes() throws {
        for width in [440.0, 640.0] {
            for scheme in [ColorScheme.light, .dark] {
                let content = HistoryFixture(scheme: scheme)
                    .frame(width: width, height: 720)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "history-\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertFalse(window.isVisible, "Visual verification must stay offscreen")
            }
        }
    }
}

private struct HistoryFixture: View {
    let scheme: ColorScheme

    private var recordings: [Recording] {
        let now = Date(timeIntervalSince1970: 1_789_257_600)
        return [
            Recording(id: UUID(), timestamp: now, fileName: "fixture-one.wav",
                      transcription: "Make the search faster, keep every detail, and give the words a little more room.",
                      duration: 18, status: .completed, progress: 1,
                      cleanupSource: .bedrock, cleanupInputTokens: 230, cleanupOutputTokens: 42,
                      cleanupModelID: "us.amazon.nova-micro-v1:0", cleanupMode: .technical,
                      rawTokenEstimate: 73, finalTokenEstimate: 42,
                      tokenEstimatorID: LocalTokenEstimator.identifier),
            Recording(id: UUID(), timestamp: now.addingTimeInterval(-1800), fileName: "fixture-two.wav",
                      transcription: "A small plan\nKeep the details\nMake it clear\nLeave room to think",
                      duration: 9, status: .completed, progress: 1, cleanupSource: .disabled),
            Recording(id: UUID(), timestamp: now.addingTimeInterval(-3600), fileName: "fixture-three.wav",
                      transcription: "We agreed to simplify the recording flow and review the first version on Friday. Keep the current shortcuts, make failures easy to recover from, and give every recording a stable home in the history.",
                      duration: 246, status: .completed, progress: 1, cleanupSource: .disabled,
                      title: "Product review", mode: .meeting)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(recordings) { recording in
                        HistoryRow(recording: recording, searchQuery: "", isPlaying: false,
                                      onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {})
                        HistoryRowSeparator()
                    }
                }
            }
            .background(ThemePalette.contentBackground(scheme))
            DictationDock(status: .ready, shortcut: "fn", writingSelection: .constant(.builtIn(.technical)), onRecord: {})
        }
        .background(ThemePalette.chromeBackground(scheme))
    }
}
