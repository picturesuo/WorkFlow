import SwiftUI

/// What the record control shows. Every phase draws in the same frame, so
/// the window never shifts when a dictation starts or ends.
enum RecordButtonPhase: Equatable, CaseIterable {
    /// Press to start.
    case ready
    /// The microphone was asked to start and has not delivered audio yet.
    case connecting
    /// A dictation is recording; press to stop.
    case listening
    /// A meeting is recording; press to stop and save it.
    case meeting
    /// Transcribing or cleaning up; nothing to press.
    case working
    /// No microphone, or the speech model is still loading.
    case unavailable

    /// Recording audio right now.
    var isLive: Bool { self == .listening || self == .meeting }
    var isEnabled: Bool { self == .ready || isLive }
}

enum WFRecordControl {
    /// The control's frame in every phase.
    static let size: CGFloat = 52
    /// The disc inside it; the ring and the live halo use the space around it.
    static let disc: CGFloat = 40
    /// The stop square shown while recording.
    static let stopSquare: CGFloat = 12
    /// One turn of the progress arc.
    static let spinPeriod: TimeInterval = 1.1
}

/// The record control: an ink disc inside a hairline ring, like a camera
/// shutter. Listening keeps the same calm disc and swaps the microphone for
/// a small vermilion stop square, the one accent while recording. A faint
/// neutral halo grows with the microphone's real level, so it moves only
/// when the microphone hears you. Working states trace an arc around the
/// ring. Reduce Motion keeps the halo still and replaces the arc with a
/// steady ring.
struct RecordButtonFace: View {
    let phase: RecordButtonPhase
    /// Microphone level, 0...1; read only while live.
    var level: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @WFReduceMotion private var reduceMotion
    @State private var isHovered = false

    private var ink: Color { ThemePalette.ink(colorScheme) }
    private var signal: Color { ThemePalette.signal(colorScheme) }
    private var clampedLevel: CGFloat { min(max(level, 0), 1) }
    private var isLifted: Bool { isHovered && phase.isEnabled }

    var body: some View {
        ZStack {
            if phase.isLive { halo }
            ring
            disc
            glyph
        }
        .frame(width: WFRecordControl.size, height: WFRecordControl.size)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(WFMotion.unlessReduced(WFMotion.snap, reduceMotion), value: phase)
        .animation(WFMotion.unlessReduced(WFMotion.snap, reduceMotion), value: isLifted)
    }

    static func haloDiameter(level: CGFloat, reduceMotion: Bool) -> CGFloat {
        let level = min(max(level, 0), 1)
        let span = WFRecordControl.size - WFRecordControl.disc
        return reduceMotion ? WFRecordControl.size - 4 : WFRecordControl.disc + span * (0.18 + 0.82 * level)
    }

    static func haloOpacity(level: CGFloat, reduceMotion: Bool) -> Double {
        let level = Double(min(max(level, 0), 1))
        return reduceMotion ? 0.05 + 0.12 * level : 0.06 + 0.10 * level
    }

    // MARK: Layers

    /// A faint ink wash that grows from the disc to the frame edge with the
    /// voice. With Reduce Motion it keeps its size and the level changes only
    /// its strength.
    private var halo: some View {
        let diameter = Self.haloDiameter(level: clampedLevel, reduceMotion: reduceMotion)
        return Circle()
            .fill(ink.opacity(Self.haloOpacity(level: clampedLevel, reduceMotion: reduceMotion)))
            .frame(width: diameter, height: diameter)
            .animation(WFMotion.unlessReduced(WFMotion.level, reduceMotion), value: clampedLevel)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ring: some View {
        let base = Circle().strokeBorder(lineWidth: 1.5)
        switch phase {
        case .ready:
            base.foregroundStyle(ink.opacity(isLifted ? 0.34 : 0.18))
        case .listening, .meeting:
            base.foregroundStyle(ink.opacity(0.18))
        case .connecting, .working:
            if reduceMotion {
                base.foregroundStyle(ink.opacity(0.42))
            } else {
                ZStack {
                    base.foregroundStyle(ink.opacity(0.12))
                    ProgressArc(color: ink)
                }
            }
        case .unavailable:
            base.foregroundStyle(ink.opacity(0.10))
        }
    }

    private var disc: some View {
        Circle()
            .fill(ink)
            // A soft top light and a darker foot give the disc some depth;
            // the middle band stays the pure token color.
            .overlay(
                Circle().fill(LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12), location: 0),
                        .init(color: Color.white.opacity(0), location: 0.4),
                        .init(color: Color.black.opacity(0), location: 0.6),
                        .init(color: Color.black.opacity(0.10), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(
                Circle().strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(0.22), .clear],
                    startPoint: .top, endPoint: .center
                ), lineWidth: 1)
            )
            .frame(width: WFRecordControl.disc, height: WFRecordControl.disc)
            .shadow(color: shadowColor, radius: isLifted ? 5 : 2, y: isLifted ? 2 : 1)
            .scaleEffect(isLifted && !reduceMotion ? 1.04 : 1)
            .opacity(discOpacity)
    }

    private var shadowColor: Color {
        guard phase.isEnabled else { return .clear }
        return Color.black.opacity(colorScheme == .dark ? 0.0 : 0.22)
    }

    private var discOpacity: Double {
        switch phase {
        case .ready, .listening, .meeting: 1
        case .connecting: 0.85
        case .working: 0.45
        case .unavailable: 0.3
        }
    }

    @ViewBuilder
    private var glyph: some View {
        let onDisc = ThemePalette.onInk(colorScheme)
        Group {
            if phase.isLive {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(signal)
                    .frame(width: WFRecordControl.stopSquare, height: WFRecordControl.stopSquare)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(onDisc)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .ready, .connecting, .listening, .meeting: "mic.fill"
        case .working: "waveform"
        case .unavailable: "mic.slash.fill"
        }
    }
}

/// A quarter arc that turns around the ring, driven by the display clock
/// so it stops drawing when the control leaves the screen.
private struct ProgressArc: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / WFRecordControl.spinPeriod
            Circle()
                .inset(by: 0.75)
                .trim(from: 0, to: 0.26)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
        }
        .accessibilityHidden(true)
    }
}

/// The face, fed by the shared level meter only while it records, so the
/// rest of the window never redraws at the meter's rate.
struct LiveRecordButtonFace: View {
    let phase: RecordButtonPhase
    @ObservedObject private var meter = InputLevelMeter.shared

    var body: some View {
        RecordButtonFace(phase: phase, level: phase.isLive ? meter.level : 0)
    }
}
