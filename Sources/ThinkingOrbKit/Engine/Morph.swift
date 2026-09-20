//
// Morph.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/morph.ts
//
//  Morph: a dotted outline cycling circle → triangle → square → circle —
//  the "shaping" state. Each shape is a continuous closed path
//  parameterised by arc length (top-centre start, clockwise). Every
//  frame the engine blends the two neighbouring paths, then lays the
//  dots EVENLY along the blended outline — spacing stays uniform at
//  every instant of the morph, holds and transitions alike.
//
//  The original was tuned in inkform through a blur + threshold "goo"
//  filter; here (as on the web port) we draw plain circles. The dot GEOMETRY
//  is identical either way. Don't "correct" for the softer edge by shrinking
//  the radius: it makes the mark genuinely smaller than the tuning.
//
//  ── THE IDEA, IN FOUR STEPS ──────────────────────────────────────────────
//   1. Each shape is a function  path(f) → (x, y)  for f ∈ [0, 1): the point
//      a fraction f of the way round its perimeter, starting at TOP-CENTRE
//      and going clockwise on screen. Units are fractions of the frame size,
//      origin at the centre (so x = 0.24 is 24 % of the frame to the right).
//   2. To morph shape A into shape B by amount m ∈ [0, 1], blend the SAME f on
//      both:   P(f) = (1 − m)·A(f) + m·B(f).  Because both start at the top
//      and run clockwise, "the point 30 % round" on one maps to "the point 30 %
//      round" on the other — corners glide into arcs instead of crossing over.
//   3. That blend is uneven (see `frameMorph`), so it is measured and the dots
//      are re-spaced at EQUAL DISTANCES along the blended outline.
//   4. Draw plain circles. There is no z (all 0) and no depth shading — this
//      mode is flat, so nothing here uses the Projector.
//

import Foundation
import simd

/// Smoothstep  s(x) = x²(3 − 2x): eases 0 → 1 with zero slope at both ends, so
/// a morph starts and stops gently.   s(0)=0  s(¼)=0.156  s(½)=0.5  s(¾)=0.844  s(1)=1
private func smoothE(_ x: Double) -> Double {
    x * x * (3 - 2 * x)
}

/// A closed polygon walked by normalised ARC LENGTH `f` ∈ [0, 1].
///
/// point(f): the target distance is f·total (total = perimeter). Walk the
/// edges, subtracting each edge's length, until the target falls inside one;
/// then linearly interpolate along that edge.
///
/// Example — triangle (0,−0.26) → (0.24,0.16) → (−0.24,0.16):
///   edge lengths 0.4837, 0.4800, 0.4837 → perimeter 1.4475
///   point(0.5): target = 0.7237. Edge 0 is 0.4837 long → left over 0.2400 on
///   edge 1 (length 0.48) → halfway along → (0.24 + (−0.24 − 0.24)·0.5, 0.16)
///   = (0, 0.16), the middle of the flat bottom edge.
private struct PolyPath: Sendable {
    let verts: [SIMD2<Double>]
    let lengths: [Double]
    let total: Double

    init(_ verts: [SIMD2<Double>]) {
        var lengths: [Double] = []
        var total = 0.0
        for i in verts.indices {
            let a = verts[i]
            let b = verts[(i + 1) % verts.count]
            let l = distance(a, b)
            lengths.append(l)
            total += l
        }
        self.verts = verts
        self.lengths = lengths
        self.total = total
    }

    func point(_ f: Double) -> SIMD2<Double> {
        var target = f * total
        var i = 0
        while target > lengths[i] && i < verts.count - 1 {
            target -= lengths[i]
            i += 1
        }
        let a = verts[i]
        let b = verts[(i + 1) % verts.count]
        let ff = lengths[i] != 0 ? min(1, target / lengths[i]) : 0
        return a + (b - a) * ff
    }
}

/// The three outlines (all measured in fractions of the frame):
///
///   circle    radius 0.24; a = −π/2 + f·2π, point (0.24·cos a, 0.24·sin a).
///             −π/2 is straight up on screen (screen y grows downward), and
///             a increasing runs clockwise: f = 0 → (0, −0.24) top,
///             f = ¼ → (0.24, 0) right, f = ½ → (0, 0.24) bottom.
///             Perimeter 2π·0.24 = 1.508.
///   triangle  apex (0, −0.26), base corners (±0.24, 0.16). Perimeter 1.447.
///   square    half-width 0.2 → perimeter 1.6. It is walked as FIVE vertices,
///             starting at top-centre (0, −0.2) — an extra vertex so that f = 0
///             begins at the top like the other two (a plain 4-corner square
///             would start at a corner). Edges: 0.2, 0.4, 0.4, 0.4, 0.2, so
///             f = 0.125 is exactly the top-right corner (0.2, −0.2).
private enum MorphShape {
    case circle, triangle, square

    static let triangleRing = PolyPath([
        SIMD2(0.0, -0.26),
        SIMD2(0.24, 0.16),
        SIMD2(-0.24, 0.16),
    ])
    // 5-vertex walk so the path STARTS at top-centre like the other shapes
    static let squareRing = PolyPath([
        SIMD2(0, -0.2),
        SIMD2(0.2, -0.2),
        SIMD2(0.2, 0.2),
        SIMD2(-0.2, 0.2),
        SIMD2(-0.2, -0.2),
    ])

    func point(_ f: Double) -> SIMD2<Double> {
        switch self {
        case .circle:
            let a = -Double.pi / 2 + f * 2 * Double.pi
            return SIMD2(cos(a), sin(a)) * 0.24
        case .triangle:
            return Self.triangleRing.point(f)
        case .square:
            return Self.squareRing.point(f)
        }
    }
}

private let morphCycle: [MorphShape] = [.circle, .triangle, .square]

/// How many dots for outline density `d` (= `iconD`, already scaled by the
/// preset's `count`): n = max(6, round(34·d)). The floor of 6 keeps a sparse
/// outline from collapsing.   d = 0.702 → 24 dots (size 64)   d = 0.53 → 18 (size 20)
// low floor keeps sparse outlines possible while never degenerating
private func morphN(_ d: Double) -> Int {
    Int(max(6, (34 * d).rounded()))
}

// TIMING. Each shape is HELD for 1.4 time units, then MORPHED into the next
// over 0.9, so one segment lasts 2.3 and the full circle → triangle → square
// → circle loop takes 3 × 2.3 = 6.9 units.
private let hold = 1.4
private let morphDur = 0.9
private let seg = hold + morphDur

/// ── MORPH ("shaping") ─────────────────────────────────────────────────────
///
/// WHICH SHAPES, HOW FAR.  tc = t mod 6.9;  k = ⌊tc/2.3⌋ (current shape:
/// 0 circle, 1 triangle, 2 square);  local = tc − 2.3k (time inside the segment).
///     local ≤ 1.4  →  m = 0                        holding shape k
///     local > 1.4  →  m = smoothstep((local − 1.4)/0.9)   easing k → k+1 (mod 3)
///   t = 3.00: tc = 3.00, k = 1, local = 0.70 → m = 0     a still triangle
///   t = 3.95: tc = 3.95, k = 1, local = 1.65 → m = s(0.278) = 0.189
///             the triangle is 19 % of the way to a square.
///
/// BLEND. Sample M = 160 points at f = i/160 on both shapes and mix them:
///     pts[i] = ( A(f) + (B(f) − A(f))·m ) · spread          (`spread` = 1.45 in
///                                                             the shipped presets)
///
/// RE-SPACE. Two things go wrong if you just draw those 160 samples:
///   • the blend CUTS CORNERS, so the perimeter changes — mid-way (m = 0.5)
///     circle → triangle measures 1.409, shorter than both 1.508 and 1.447;
///   • samples equal in f are NOT equal in distance: at that same moment the
///     gaps between neighbouring samples range 0.0070 … 0.0092 (up to 1.3×).
///   So the code measures the blended outline — segment lengths L[i], total
///   perimeter — and places the n dots at equal arc-length spacing:
///         target_k = (k/n)·total         k = 0 … n−1
///   It advances through the segments (`acc` = length already consumed) until
///   target_k lies in segment `seg`, then linearly interpolates inside it:
///         f = (target_k − acc) / L[seg]
///   Result: a constant gap between dots at EVERY instant, including mid-morph
///   — hence "spacing stays uniform".
///
/// SIZE. Dot radius depends only on `rDot`, a FRACTION of the frame:
///         re = rDot · 1.35 · spread              radius = max(0.35, re·size) pt
///   size 64: rDot = 0.008295 → re = 0.01624 → radius 1.04pt
///   size 20: rDot = 0.021231 → re = 0.04156 → radius 0.83pt
///   (rDot is bigger at 20 because the preset's `size` multiplier is 1.011
///   there versus 0.395 at 64.)  The outline itself: the circle's radius is
///   0.24·spread = 0.348 of the frame → 22.3pt at size 64, so 24 dots are
///   about 5.8pt apart, versus a 1.04pt dot radius.
///
/// BREATHE. A gentle uniform pulse  1 + 0.02·sin(3.1·local)  (±2 %) scales the
/// whole outline about the centre.
///
/// FINAL POSITION:  screen = centre + (x·pulse)·size, all dots z = 0,
/// white = 0.1 (near-black ink), alpha 1. Since every z is equal, the stable
/// sort in `finalizeFrame` keeps the dots in the order they were generated.
func frameMorph(size: Double, time t: Double, options o: ModeOpts) -> OrbFrame {
    let K = morphCycle.count
    let tc = t.truncatingRemainder(dividingBy: seg * Double(K))
    let k = Int(floor(tc / seg))
    let local = tc - Double(k) * seg
    let m = local > hold ? smoothE((local - hold) / morphDur) : 0
    let sprd = o[.spread] ?? 1

    // blend the two shape PATHS at m, then measure the blended outline
    let pA = morphCycle[k]
    let pB = morphCycle[(k + 1) % K]
    let M = 160
    var pts: [SIMD2<Double>] = []
    pts.reserveCapacity(M)
    for i in 0..<M {
        let f = Double(i) / Double(M)
        let a = pA.point(f)
        let b = pB.point(f)
        pts.append((a + (b - a) * m) * sprd)
    }
    var L: [Double] = []
    L.reserveCapacity(M)
    var total = 0.0
    for i in 0..<M {
        let l = distance(pts[i], pts[(i + 1) % M])
        L.append(l)
        total += l
    }

    // dot radius depends ONLY on rDot (the size knob); the count sets the
    // gaps. Formed shapes breathe a little (uniform pulse).
    let n = morphN(o[.iconD] ?? 1)
    let re = (o[.rDot] ?? 0.021) * 1.35 * sprd
    let pulse = 1 + 0.02 * sin(local * 3.1)

    var dots: [Dot] = []
    dots.reserveCapacity(n)
    let c2 = size / 2
    var segIdx = 0
    var acc = 0.0
    for k2 in 0..<n {
        // equal arc-length spacing: the k-th dot sits k/n of the way round
        let target = (Double(k2) / Double(n)) * total
        while acc + L[segIdx] < target && segIdx < M - 1 {
            acc += L[segIdx]
            segIdx += 1
        }
        let a = pts[segIdx]
        let b = pts[(segIdx + 1) % M]
        let f = L[segIdx] != 0 ? min(1, (target - acc) / L[segIdx]) : 0
        let p = (a + (b - a) * f) * pulse
        dots.append(
            Dot(
                x: c2 + p.x * size,
                y: c2 + p.y * size,
                z: 0,
                r: max(0.35, re * size),
                white: 0.1
            ))
    }
    return finalizeFrame(dots: dots, rMin: o[.rMin])
}
