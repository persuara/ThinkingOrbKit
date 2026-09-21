//
// TransitionTests.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
//
//  Morphing between states. These pin the properties that make a morph SEAMLESS:
//  it begins and ends on exactly the frames it connects, every dot is accounted
//  for, motion has no jumps, and interrupting one does not pop.
//

import Foundation
import Testing

@testable import ThinkingOrbKit

/// A dot as a comparable row of numbers.
private func row(_ d: Dot) -> [Double] { [d.z, d.x, d.y, d.r, d.white, d.a] }

/// Dots as a SORTED list of rows, so two frames compare equal regardless of the
/// order in which equal-depth dots happen to be listed.
private func multiset(_ dots: [Dot]) -> [[Double]] {
    dots.map(row).sorted { lhs, rhs in
        for (l, r) in zip(lhs, rhs) where l != r { return l < r }
        return false
    }
}

private func raw(_ state: OrbState, size: OrbSize = .px64, at t: Double) -> (Resolved, RawFrame) {
    let resolved = Resolved(state: state, size: size)
    let frame = resolved.mode.rawFrame(size: Double(size.points), time: t * resolved.speed, options: resolved.opts)
    return (resolved, frame)
}

private func plan(_ a: RawFrame, _ b: RawFrame, size: Double = 64) -> TransitionPlan {
    TransitionPlan(from: a, to: b, center: SIMD2(repeating: size / 2))
}

/// Every ordered pair of DIFFERENT states.
private let allPairs: [(OrbState, OrbState)] = OrbState.allCases.flatMap { a in
    OrbState.allCases.filter { $0 != a }.map { (a, $0) }
}

@Suite("Raw frames")
struct RawFrameTests {
    @Test("a mode's raw dot count never depends on time", arguments: OrbState.allCases)
    func countIsConstant(state: OrbState) {
        for size in [OrbSize.px64, .px20, 40] {
            let counts = Set(
                (0..<600).map { i in raw(state, size: size, at: Double(i) * 0.173).1.dots.count })
            #expect(counts.count == 1, "\(state) @\(size.points): \(counts.sorted())")
        }
    }

    @Test("finishing a raw frame gives exactly the frame the mode reports")
    func finalizeMatchesFrame() {
        for state in OrbState.allCases {
            let resolved = Resolved(state: state, size: .px64)
            let viaRaw = finalizeFrame(resolved.mode.rawFrame(size: 64, time: 1.7, options: resolved.opts))
            let direct = resolved.mode.frame(size: 64, time: 1.7, options: resolved.opts)
            #expect(viaRaw.dots.map(row) == direct.dots.map(row), "\(state)")
        }
    }
}

@Suite("Transition plan")
struct TransitionPlanTests {
    @Test("every dot of both frames is used, and only the extras are spawned or vanished")
    func coversBothFrames() {
        for (a, b) in allPairs {
            let (_, from) = raw(a, at: 1.3)
            let (_, to) = raw(b, at: 1.3)
            let pairs = plan(from, to).pairs
            let (nOut, nIn) = (from.dots.count, to.dots.count)

            #expect(pairs.count == max(nOut, nIn), "\(a)→\(b)")
            #expect(Set(pairs.map(\.from)) == Set(0..<nOut), "\(a)→\(b): every outgoing dot is used")
            #expect(Set(pairs.map(\.to)) == Set(0..<nIn), "\(a)→\(b): every incoming dot is used")

            if nIn >= nOut {
                // the larger (incoming) side appears exactly once each
                #expect(pairs.map(\.to).sorted() == Array(0..<nIn), "\(a)→\(b)")
                #expect(pairs.allSatisfy { !$0.vanishes })
                // each outgoing dot has exactly ONE real successor; the rest are spawns
                #expect(pairs.filter { !$0.spawns }.count == nOut, "\(a)→\(b)")
            } else {
                #expect(pairs.map(\.from).sorted() == Array(0..<nOut), "\(a)→\(b)")
                #expect(pairs.allSatisfy { !$0.spawns })
                #expect(pairs.filter { !$0.vanishes }.count == nIn, "\(a)→\(b)")
            }
        }
    }

    @Test("the plan is deterministic")
    func deterministic() {
        let (_, from) = raw(.composing, at: 2.2)
        let (_, to) = raw(.shaping, at: 2.2)
        #expect(plan(from, to).pairs == plan(from, to).pairs)
    }

    @Test("dots travel short distances: pairing beats a naive index pairing")
    func pairingIsLocal() {
        // Compare the mean distance a dot travels under the plan against pairing dot i
        // with dot i (generation order), which ignores where dots actually are.
        var better = 0
        var total = 0
        for (a, b) in allPairs {
            let (_, from) = raw(a, at: 0.9)
            let (_, to) = raw(b, at: 0.9)
            let pairs = plan(from, to).pairs
            func meanTravel(_ p: [(Int, Int)]) -> Double {
                p.map { hypot(from.dots[$0.0].x - to.dots[$0.1].x, from.dots[$0.0].y - to.dots[$0.1].y) }
                    .reduce(0, +) / Double(p.count)
            }
            let planned = meanTravel(pairs.map { ($0.from, $0.to) })
            let n = max(from.dots.count, to.dots.count)
            let naive = meanTravel((0..<n).map { (min($0, from.dots.count - 1), min($0, to.dots.count - 1)) })
            total += 1
            if planned < naive { better += 1 }
        }
        #expect(better == total, "spatial pairing should win for every state pair (\(better)/\(total))")
    }
}

@Suite("Blending")
struct BlendTests {
    @Test("progress 0 is exactly the outgoing frame and 1 exactly the incoming one")
    func endsAreExact() {
        for (a, b) in allPairs {
            for size in [OrbSize.px64, .px20] {
                let (_, from) = raw(a, size: size, at: 1.9)
                let (_, to) = raw(b, size: size, at: 1.9)
                let p = plan(from, to, size: Double(size.points))

                let start = finalizeFrame(blend(from: from, to: to, plan: p, progress: 0))
                #expect(multiset(start.dots) == multiset(finalizeFrame(from).dots), "\(a)→\(b) @0")
                #expect(start.lines.map { [$0.x1, $0.y1, $0.x2, $0.y2, $0.a] }
                    == finalizeFrame(from).lines.map { [$0.x1, $0.y1, $0.x2, $0.y2, $0.a] }, "\(a)→\(b) lines @0")

                let end = finalizeFrame(blend(from: from, to: to, plan: p, progress: 1))
                #expect(multiset(end.dots) == multiset(finalizeFrame(to).dots), "\(a)→\(b) @1")
                #expect(end.lines.map { [$0.x1, $0.y1, $0.x2, $0.y2, $0.a] }
                    == finalizeFrame(to).lines.map { [$0.x1, $0.y1, $0.x2, $0.y2, $0.a] }, "\(a)→\(b) lines @1")
            }
        }
    }

    @Test("every intermediate frame is finite, on-canvas and drawable")
    func intermediateFramesAreSane() {
        for (a, b) in allPairs {
            let (_, from) = raw(a, at: 0.4)
            let (_, to) = raw(b, at: 0.4)
            let p = plan(from, to)
            for step in 0...20 {
                let frame = finalizeFrame(blend(from: from, to: to, plan: p, progress: Double(step) / 20))
                #expect(!frame.dots.isEmpty || step == 0 || step == 20, "\(a)→\(b) @\(step)")
                for dot in frame.dots {
                    #expect(dot.x.isFinite && dot.y.isFinite && dot.z.isFinite && dot.r.isFinite && dot.white.isFinite)
                    #expect(dot.r > 0 && dot.a >= 0.02 && dot.a < 1.05)
                    #expect(dot.x > -8 && dot.x < 72 && dot.y > -8 && dot.y < 72, "\(a)→\(b) @\(step)")
                }
            }
        }
    }

    @Test("motion is smooth: no dot ever jumps")
    func noJumps() {
        // smoothstep's steepest slope is 1.5, so a 0.01 step may move a dot by at most
        // 1.5 × 0.01 = 1.5 % of the distance between its two endpoints.
        for (a, b) in allPairs {
            let (_, from) = raw(a, at: 2.6)
            let (_, to) = raw(b, at: 2.6)
            let p = plan(from, to)
            var previous = blend(from: from, to: to, plan: p, progress: 0)
            for step in 1...100 {
                let current = blend(from: from, to: to, plan: p, progress: Double(step) / 100)
                for (i, pair) in p.pairs.enumerated() {
                    let travel = hypot(
                        from.dots[pair.from].x - to.dots[pair.to].x, from.dots[pair.from].y - to.dots[pair.to].y)
                    let moved = hypot(current.dots[i].x - previous.dots[i].x, current.dots[i].y - previous.dots[i].y)
                    #expect(moved <= 0.0151 * travel + 1e-9, "\(a)→\(b) dot \(i) step \(step)")
                }
                previous = current
            }
        }
    }

    @Test("morphing a state into itself changes nothing")
    func selfMorphIsIdentity() {
        // Exact at the ends (tested above); in between `a·u + a·s` can differ from `a` by
        // a rounding ulp, so compare within a tolerance, dot by dot in plan order.
        for state in OrbState.allCases {
            let (_, frame) = raw(state, at: 1.1)
            let p = plan(frame, frame)
            for progress in [0.0, 0.3, 0.5, 0.9, 1.0] {
                let out = blend(from: frame, to: frame, plan: p, progress: progress)
                #expect(out.dots.count == frame.dots.count)
                for (dot, pair) in zip(out.dots, p.pairs) {
                    let original = frame.dots[pair.from]
                    let error = zip(row(dot), row(original)).map { abs($0 - $1) }.max() ?? 0
                    #expect(error < 1e-9, "\(state) @\(progress)")
                }
            }
        }
    }

    @Test("with nothing to pair, a transition degrades to a cross-fade")
    func emptySideCrossFades() {
        let (_, frame) = raw(.searching, at: 0.5)
        let empty = RawFrame(dots: [])
        let p = plan(frame, empty)
        #expect(p.pairs.isEmpty)
        let half = blend(from: frame, to: empty, plan: p, progress: 0.5)  // easedProgress(0.5) = 0.5
        #expect(half.dots.count == frame.dots.count)
        for (dot, original) in zip(half.dots, frame.dots) { #expect(abs(dot.a - original.a * 0.5) < 1e-12) }
    }

    @Test("easing is 0 at 0, 1 at 1, monotone, and clamps")
    func easing() {
        #expect(easedProgress(0) == 0 && easedProgress(1) == 1 && easedProgress(0.5) == 0.5)
        #expect(easedProgress(-3) == 0 && easedProgress(7) == 1)
        var last = 0.0
        for i in 0...100 {
            let e = easedProgress(Double(i) / 100)
            #expect(e >= last)
            last = e
        }
    }
}

@Suite("Running transitions")
struct ActiveTransitionTests {
    private func make(
        from: OrbState = .working, to: OrbState = .composing, size: OrbSize = .px64,
        start: Double = 1.0, duration: Double = 0.9, speed: Double = 1
    ) -> ActiveTransition {
        ActiveTransition(
            from: .state(Resolved(state: from, size: size)), to: Resolved(state: to, size: size),
            size: Double(size.points), startingAt: start, speed: speed, duration: duration)
    }

    @Test("progress runs 0 → 1 over the duration, and clamps outside it")
    func progress() {
        let t = make(start: 10, duration: 2)
        #expect(t.progress(at: 5) == 0 && t.progress(at: 10) == 0)
        #expect(abs(t.progress(at: 11) - 0.5) < 1e-12)
        #expect(t.progress(at: 12) == 1 && t.progress(at: 99) == 1)
        #expect(make(duration: 0).progress(at: 0) == 1)  // a zero-length transition is already over
    }

    @Test("it begins on the outgoing state and finishes on exactly the target's own frame")
    func beginsAndEnds() {
        for (a, b) in allPairs {
            let t = make(from: a, to: b, start: 3, duration: 1)
            let from = Resolved(state: a, size: .px64)
            let to = Resolved(state: b, size: .px64)

            let first = t.frame(at: 3, speed: 1)
            let outgoing = from.mode.frame(size: 64, time: 3 * from.speed, options: from.opts)
            #expect(multiset(first.dots) == multiset(outgoing.dots), "\(a)→\(b) start")

            let last = t.frame(at: 4, speed: 1)
            let incoming = to.mode.frame(size: 64, time: 4 * to.speed, options: to.opts)
            #expect(last.dots.map(row) == incoming.dots.map(row), "\(a)→\(b) end")  // identical, in order
        }
    }

    @Test("both states keep animating during the blend")
    func statesKeepMoving() {
        let t = make(from: .working, to: .searching, start: 0, duration: 4)
        let a = t.frame(at: 1.0, speed: 1).dots.map(row)
        let b = t.frame(at: 1.1, speed: 1).dots.map(row)
        #expect(a != b)
    }

    @Test("interrupting a morph starts the next one exactly where the picture is — no pop")
    func retargetIsContinuous() {
        let first = make(from: .working, to: .searching, start: 2, duration: 1)
        let now = 2.4
        #expect(first.progress(at: now) > 0 && first.progress(at: now) < 1)

        let frozen = first.rawFrame(at: now, speed: 1)
        let second = ActiveTransition(
            from: .snapshot(frozen), to: Resolved(state: .shaping, size: .px64),
            size: 64, startingAt: now, speed: 1, duration: 1)

        // the instant the second morph begins, the picture is what the first one showed
        #expect(
            multiset(second.frame(at: now, speed: 1).dots) == multiset(finalizeFrame(frozen).dots))
        // and it then travels on to the new target
        let end = second.frame(at: now + 1, speed: 1)
        let shaping = Resolved(state: .shaping, size: .px64)
        #expect(end.dots.map(row) == shaping.mode.frame(size: 64, time: (now + 1) * shaping.speed, options: shaping.opts).dots.map(row))
    }

    @Test("the user speed multiplier reaches both ends of the blend")
    func speedApplies() {
        let slow = make(start: 0, duration: 1, speed: 0.5)
        let fast = make(start: 0, duration: 1, speed: 2)
        #expect(slow.frame(at: 2, speed: 0.5).dots.map(row) != fast.frame(at: 2, speed: 2).dots.map(row))
        // at completion the frame is the target's ordinary frame at THAT speed
        let to = Resolved(state: .composing, size: .px64)
        #expect(
            fast.frame(at: 2, speed: 2).dots.map(row)
                == to.mode.frame(size: 64, time: 2 * to.speed * 2, options: to.opts).dots.map(row))
    }
}
