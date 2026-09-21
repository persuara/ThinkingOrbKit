//
// Transition.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM — nothing: new in this package, not part of the TypeScript library
//
//  Morphing one state into another.
//
//  ── THE IDEA ─────────────────────────────────────────────────────────────
//  Every state is a cloud of dots. To turn state A into state B seamlessly,
//  give each dot of A a partner dot of B and slide every dot from its own
//  position, size and ink to its partner's. Per dot, with s the eased progress:
//
//        value(s) = valueA · (1 − s) + valueB · s        (x, y, z, r, white, alpha)
//
//  Three things have to be solved:
//
//   1. WHICH dot goes where?            → `TransitionPlan`   (below)
//   2. Dot COUNTS differ (24 … 566).    → dots split and merge; see `DotPair`
//   3. What if the user changes state   → a running morph can be frozen into a
//      again mid-morph?                    snapshot and used as the new start.
//
//  The blend happens on RAW frames (see `RawFrame`), where each dot keeps a
//  stable index, and the result goes through the ordinary `finalizeFrame`
//  (cull, clamp, depth-sort), so the painter needs no special case.
//

import Foundation
import simd

// MARK: - Pairing

/// One moving dot of a transition: outgoing dot `from` slides into incoming dot `to`.
///
/// Counts rarely match, so pairs come in three kinds:
///
///     normal     both dots are real: A's dot becomes B's dot.
///     spawns     B has MORE dots. This pair's outgoing dot is only an anchor
///                (another pair already owns it): the incoming dot starts on top
///                of it, fully transparent, and fades IN while moving out.
///     vanishes   A has MORE dots. This pair's incoming dot is only an anchor:
///                the outgoing dot moves onto it and fades OUT.
///
/// So 24 dots becoming 566 is 24 "normal" pairs plus 542 "spawns" that bloom
/// out of them; 566 becoming 24 is the reverse — dots streaming together and
/// dissolving into their neighbours.
struct DotPair: Sendable, Equatable {
    var from: Int
    var to: Int
    var spawns: Bool
    var vanishes: Bool
}

/// The pairing between two raw frames. Built once, when a transition starts.
///
/// HOW dots are matched. The goal is that dots travel SHORT distances, so the
/// morph looks like a flow and not a scramble. The exact optimum (optimal
/// transport) is far too slow, so this uses a cheap, deterministic stand-in:
///
///   1. Order each frame's dots by position on screen — first by which of 16
///      ANGULAR SECTORS around the centre they lie in, then, inside a sector,
///      by distance from the centre (near → far).
///   2. Match the two orderings BY RANK, stretching the shorter list along the
///      longer one: dot k of the longer list pairs with dot ⌊k·small/large⌋ of
///      the shorter.
///
/// Dots in the same direction from the centre therefore meet, and the inner ones
/// stay inner. Example, a 204-dot globe becoming a 24-dot ring: sorted by angle,
/// each ring dot is reached by about 8.5 globe dots from the same direction —
/// they stream inward/outward to it and merge.
///
/// The ordering is a function of positions only, so the plan is deterministic.
struct TransitionPlan: Sendable {
    let pairs: [DotPair]

    /// - Parameter center: the middle of the frame, in the frames' own coordinates.
    init(from outgoing: RawFrame, to incoming: RawFrame, center: SIMD2<Double>) {
        let outCount = outgoing.dots.count
        let inCount = incoming.dots.count
        guard outCount > 0, inCount > 0 else {
            // nothing to pair with: `blend` falls back to a plain cross-fade
            pairs = []
            return
        }

        let outOrder = Self.spatialOrder(outgoing.dots, around: center)
        let inOrder = Self.spatialOrder(incoming.dots, around: center)

        var pairs: [DotPair] = []
        pairs.reserveCapacity(max(outCount, inCount))

        if inCount >= outCount {
            // Walk the LARGER (incoming) list. Its rank k maps onto outgoing rank
            // ⌊k·out/in⌋, which is non-decreasing and reaches every outgoing dot,
            // so the first incoming dot mapped to a source is its real successor
            // and any further ones are spawned from it.
            var previous = -1
            for k in 0..<inCount {
                let source = k * outCount / inCount
                pairs.append(
                    DotPair(from: outOrder[source], to: inOrder[k], spawns: source == previous, vanishes: false))
                previous = source
            }
        } else {
            // Mirror image: the outgoing list is larger; extras vanish into a neighbour.
            var previous = -1
            for k in 0..<outCount {
                let target = k * inCount / outCount
                pairs.append(
                    DotPair(from: outOrder[k], to: inOrder[target], spawns: false, vanishes: target == previous))
                previous = target
            }
        }
        self.pairs = pairs
    }

    /// Indices of `dots` ordered by (angular sector, distance from `center`).
    /// Sorting uses plain loops on concrete types — cheap even in Debug builds.
    private static func spatialOrder(_ dots: [Dot], around center: SIMD2<Double>) -> [Int] {
        let sectors = 16
        var buckets = [[Int]](repeating: [], count: sectors)
        var distance2 = [Double](repeating: 0, count: dots.count)

        for index in dots.indices {
            let dx = dots[index].x - center.x
            let dy = dots[index].y - center.y
            distance2[index] = dx * dx + dy * dy
            // atan2 ∈ (−π, π]  →  sector 0 … 15
            let turn = (atan2(dy, dx) + Double.pi) / (2 * Double.pi)
            buckets[min(sectors - 1, Int(turn * Double(sectors)))].append(index)
        }

        var order: [Int] = []
        order.reserveCapacity(dots.count)
        for var bucket in buckets {
            // insertion sort by distance; strict `>` keeps equal distances in index order
            if bucket.count > 1 {
                for i in 1..<bucket.count {
                    let item = bucket[i]
                    var j = i - 1
                    while j >= 0 && distance2[bucket[j]] > distance2[item] {
                        bucket[j + 1] = bucket[j]
                        j -= 1
                    }
                    bucket[j + 1] = item
                }
            }
            order.append(contentsOf: bucket)
        }
        return order
    }
}

// MARK: - Blending

/// Smoothstep easing `s(p) = p²(3 − 2p)`: eases in and out, so a morph starts and
/// ends gently. s(0) = 0 and s(1) = 1 exactly.
func easedProgress(_ progress: Double) -> Double {
    let p = min(1, max(0, progress))
    return p * p * (3 - 2 * p)
}

/// The frame `progress` (0…1) of the way from `outgoing` to `incoming`.
///
///     dot   = outgoing·(1 − s) + incoming·s        s = easedProgress(progress)
///     alpha = (spawns ? 0 : outgoing.a)·(1 − s) + (vanishes ? 0 : incoming.a)·s
///     lines cross-fade: outgoing lines at alpha·(1 − s), incoming at alpha·s
///
/// Written as `a·(1 − s) + b·s` rather than `a + (b − a)·s` on purpose: it gives
/// EXACTLY `a` at s = 0 and EXACTLY `b` at s = 1 (no rounding residue), so a
/// transition begins and ends on precisely the frames it connects.
///
/// If the plan has no pairs (one side was empty) this degrades to a cross-fade.
func blend(from outgoing: RawFrame, to incoming: RawFrame, plan: TransitionPlan, progress: Double) -> RawFrame {
    let s = easedProgress(progress)
    let u = 1 - s

    var dots: [Dot] = []
    if plan.pairs.isEmpty {
        dots.reserveCapacity(outgoing.dots.count + incoming.dots.count)
        for var dot in outgoing.dots {
            dot.a *= u
            dots.append(dot)
        }
        for var dot in incoming.dots {
            dot.a *= s
            dots.append(dot)
        }
    } else {
        dots.reserveCapacity(plan.pairs.count)
        for pair in plan.pairs {
            // Defensive: a mode's dot count is meant to be constant, but never trap on it.
            guard pair.from < outgoing.dots.count, pair.to < incoming.dots.count else { continue }
            let a = outgoing.dots[pair.from]
            let b = incoming.dots[pair.to]
            dots.append(
                Dot(
                    x: a.x * u + b.x * s,
                    y: a.y * u + b.y * s,
                    z: a.z * u + b.z * s,
                    r: a.r * u + b.r * s,
                    white: a.white * u + b.white * s,
                    a: (pair.spawns ? 0 : a.a) * u + (pair.vanishes ? 0 : b.a) * s
                ))
        }
    }

    var lines: [Line] = []
    lines.reserveCapacity(outgoing.lines.count + incoming.lines.count)
    for var line in outgoing.lines {
        line.a *= u
        lines.append(line)
    }
    for var line in incoming.lines {
        line.a *= s
        lines.append(line)
    }

    return RawFrame(dots: dots, lines: lines, rMin: (outgoing.rMin ?? 0.3) * u + (incoming.rMin ?? 0.3) * s)
}

// MARK: - A running transition

/// A morph in flight: everything needed to draw any moment of it.
///
/// The two states keep ANIMATING while they blend (the outgoing orbit keeps
/// orbiting, the incoming globe keeps spinning); only the pairing is fixed, at
/// the moment the transition starts. It is a pure value — the view stores one
/// and asks it for a frame at each timestamp.
struct ActiveTransition: Sendable {
    /// Where the transition starts from.
    enum Source: Sendable {
        /// A state that keeps animating while it fades out.
        case state(Resolved)
        /// A frozen picture: used when the user changes state AGAIN mid-morph, so
        /// the new morph begins exactly on what is currently on screen (no jump).
        case snapshot(RawFrame)
    }

    let from: Source
    let to: Resolved
    /// Side length in points; both ends are drawn at the same size.
    let size: Double
    /// Clock reading (seconds) when the transition began.
    let start: Double
    /// Length of the transition in seconds.
    let duration: Double
    let plan: TransitionPlan

    /// - Parameters:
    ///   - start: the current clock reading; the pairing is computed from both
    ///     states' geometry at exactly this moment.
    ///   - speed: the view's user speed multiplier (states' own preset speeds
    ///     are applied on top, as when drawing normally).
    init(from: Source, to: Resolved, size: Double, startingAt start: Double, speed: Double, duration: Double) {
        self.from = from
        self.to = to
        self.size = size
        self.start = start
        self.duration = duration
        self.plan = TransitionPlan(
            from: Self.rawFrame(of: from, size: size, elapsed: start, speed: speed),
            to: to.mode.rawFrame(size: size, time: start * to.speed * speed, options: to.opts),
            center: SIMD2(repeating: size / 2)
        )
    }

    /// 0 = just started, 1 = finished (also for a zero or negative duration).
    func progress(at elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, (elapsed - start) / duration))
    }

    /// The blended, still-unfinished frame at `elapsed` — also what gets frozen
    /// into a `.snapshot` when the transition is interrupted.
    func rawFrame(at elapsed: Double, speed: Double) -> RawFrame {
        blend(
            from: Self.rawFrame(of: from, size: size, elapsed: elapsed, speed: speed),
            to: to.mode.rawFrame(size: size, time: elapsed * to.speed * speed, options: to.opts),
            plan: plan,
            progress: progress(at: elapsed)
        )
    }

    /// The finished frame to draw at `elapsed`. Once the transition is over this
    /// is exactly the target state's ordinary frame.
    func frame(at elapsed: Double, speed: Double) -> OrbFrame {
        if progress(at: elapsed) >= 1 {
            return to.mode.frame(size: size, time: elapsed * to.speed * speed, options: to.opts)
        }
        return finalizeFrame(rawFrame(at: elapsed, speed: speed))
    }

    private static func rawFrame(of source: Source, size: Double, elapsed: Double, speed: Double) -> RawFrame {
        switch source {
        case .state(let resolved):
            return resolved.mode.rawFrame(
                size: size, time: elapsed * resolved.speed * speed, options: resolved.opts)
        case .snapshot(let frame):
            return frame
        }
    }
}
