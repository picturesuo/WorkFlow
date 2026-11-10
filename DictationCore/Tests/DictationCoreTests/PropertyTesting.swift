import Foundation
import XCTest

/// SplitMix64: a tiny, fast, deterministic generator for reproducible traces.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < p
    }

    mutating func uuid() -> UUID {
        let a = next()
        let b = next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: a), UInt8(truncatingIfNeeded: a >> 8),
            UInt8(truncatingIfNeeded: a >> 16), UInt8(truncatingIfNeeded: a >> 24),
            UInt8(truncatingIfNeeded: a >> 32), UInt8(truncatingIfNeeded: a >> 40),
            UInt8(truncatingIfNeeded: a >> 48), UInt8(truncatingIfNeeded: a >> 56),
            UInt8(truncatingIfNeeded: b), UInt8(truncatingIfNeeded: b >> 8),
            UInt8(truncatingIfNeeded: b >> 16), UInt8(truncatingIfNeeded: b >> 24),
            UInt8(truncatingIfNeeded: b >> 32), UInt8(truncatingIfNeeded: b >> 40),
            UInt8(truncatingIfNeeded: b >> 48), UInt8(truncatingIfNeeded: b >> 56)
        ))
    }
}

/// A world model that generates the next step of a random trace and checks
/// invariants after applying each step.
///
/// `apply` must depend only on the steps applied so far (never on the random
/// generator), so a recorded trace replays exactly and can be truncated.
protocol PropertyModel {
    associatedtype Step

    init()
    /// Chooses the next step from the current world. May update bookkeeping
    /// that only steers generation.
    mutating func generate(_ rng: inout SplitMix64) -> Step
    /// Applies one step and returns the invariant violations it caused.
    mutating func apply(_ step: Step) -> [String]
    /// After the random steps: the next step that brings the world to rest,
    /// or nil once it is at rest.
    mutating func drain(_ rng: inout SplitMix64) -> Step?
    /// Invariants that hold once the world is at rest.
    func finalViolations() -> [String]
}

extension PropertyModel {
    mutating func drain(_ rng: inout SplitMix64) -> Step? { nil }
    func finalViolations() -> [String] { [] }
}

enum PropertyCheck {
    static let fixedSeeds: [UInt64] = [0, 1, 2, 3, 42, 0xDEAD_BEEF, 0x5EED_5EED, 0xFFFF_FFFF_FFFF_FFFF]

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Number of random sequences per machine (`DICTATION_CORE_ITERATIONS`, default 300).
    static var iterations: Int {
        environment["DICTATION_CORE_ITERATIONS"].flatMap(Int.init).map { max(1, $0) } ?? 300
    }

    /// Steps per sequence (`DICTATION_CORE_STEPS`, default 200).
    static var steps: Int {
        environment["DICTATION_CORE_STEPS"].flatMap(Int.init).map { max(1, $0) } ?? 200
    }

    /// The seeds to run, `iterations` in all: `DICTATION_CORE_SEED` first when
    /// set, then the fixed list, then derived seeds. Reproduce one failing
    /// sequence with `DICTATION_CORE_SEED=<seed> DICTATION_CORE_ITERATIONS=1`.
    static var seeds: [UInt64] {
        var result: [UInt64] = []
        if let raw = environment["DICTATION_CORE_SEED"], let seed = parseSeed(raw) {
            result.append(seed)
        }
        result.append(contentsOf: fixedSeeds)
        var derive = SplitMix64(seed: 0xD1C7_A710_C0DE)
        while result.count < iterations {
            result.append(derive.next())
        }
        return Array(result.prefix(iterations))
    }

    private static func parseSeed(_ raw: String) -> UInt64? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }

    /// Runs every seed, checking invariants after every step. On the first
    /// failing seed, replays shorter prefixes of its trace and reports the
    /// shortest one that still fails.
    static func run<M: PropertyModel>(
        _ model: M.Type,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let steps = Self.steps
        for seed in seeds {
            var rng = SplitMix64(seed: seed)
            var world = M()
            var trace: [M.Step] = []
            var violations: [String] = []

            for _ in 0..<steps {
                let step = world.generate(&rng)
                trace.append(step)
                violations = world.apply(step)
                if !violations.isEmpty { break }
            }
            if violations.isEmpty {
                var guardSteps = 0
                while let step = world.drain(&rng), guardSteps < 100_000 {
                    guardSteps += 1
                    trace.append(step)
                    violations = world.apply(step)
                    if !violations.isEmpty { break }
                }
                if violations.isEmpty, guardSteps >= 100_000 {
                    violations = ["the world did not come to rest"]
                }
            }
            if violations.isEmpty {
                violations = world.finalViolations()
            }
            guard !violations.isEmpty else { continue }

            let (prefix, prefixViolations) = shortestFailingPrefix(M.self, trace: trace) ?? (trace, violations)
            let lines = prefix.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            XCTFail(
                """
                \(name): invariant violated for seed \(seed) (0x\(String(seed, radix: 16))); \
                reproduce with DICTATION_CORE_SEED=\(seed) DICTATION_CORE_ITERATIONS=1
                violations:
                \(prefixViolations.map { "  - \($0)" }.joined(separator: "\n"))
                shortest failing prefix (\(prefix.count) of \(trace.count) steps):
                \(lines)
                """,
                file: file,
                line: line
            )
            return
        }
    }

    /// Simple prefix truncation: the shortest prefix whose replay violates an
    /// invariant (a per-step one, or a final one when the prefix is the whole trace).
    private static func shortestFailingPrefix<M: PropertyModel>(_ model: M.Type, trace: [M.Step]) -> ([M.Step], [String])? {
        var world = M()
        for (index, step) in trace.enumerated() {
            let violations = world.apply(step)
            if !violations.isEmpty {
                return (Array(trace[...index]), violations)
            }
        }
        let final = world.finalViolations()
        return final.isEmpty ? nil : (trace, final)
    }
}
