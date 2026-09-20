//
// Lattice.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/lattice.ts
//
//  The sphere-lattice modes: globe (searching), rubik (solving) and
//  wave (listening). All draw a lat/long dot field with mode-specific
//  motion, then hand off to the shared z-sorted frame builder.
//
//  ── THE LAT/LONG LATTICE (shared by all three) ───────────────────────────
//  A point on the unit sphere at latitude φ (−π/2 south pole … +π/2 north
//  pole) and longitude λ (0 … 2π round the vertical axis) is
//
//        (x, y, z) = ( cosφ·cosλ,  sinφ,  cosφ·sinλ )        y is UP
//
//  Rows are evenly spaced in latitude:  φ_i = −π/2 + (i / rows)·π, for
//  i = 0…rows — that is rows + 1 rows, both poles included.
//
//  Row i holds  lonCount = max(1, round(|cosφ_i| · lonDensity))  dots, spaced
//  evenly in longitude. WHY |cosφ|: the circumference of a latitude circle is
//  2π·cosφ, so giving it lonDensity·cosφ dots keeps the SPACING along every
//  row the same as at the equator (2π/lonDensity). Without it the dots would
//  bunch up into dense knots at the poles.
//
//  Example, rows = 11, lonDensity = 29 (globe at size 64):
//        i │ latitude │ |cosφ| │ dots
//        0 │ −90.0°   │ 0.000  │  1   (pole, see below)
//        1 │ −73.6°   │ 0.282  │  8
//        3 │ −40.9°   │ 0.756  │ 22
//        5 │  −8.2°   │ 0.990  │ 29
//        6 │  +8.2°   │ 0.990  │ 29
//       11 │ +90.0°   │ 0.000  │  1   (pole)
//     total over all 12 rows = 204 dots (matches the reference output).
//     Pole rows: cos(−π/2) is 6e-17, not exactly 0, and 6e-17·29 rounds to 0,
//     so max(1, 0) lifts it to a single dot at each pole.
//
//  DEPTH. After the Projector, z ∈ [−1, 1] for a unit sphere, so
//        depth = (z + 1) / 2     0 = far side, 1 = near side.
//

import Foundation
import simd

// MARK: - The shared solver heartbeat (rubik)
// Rapid eased moves scramble, then replay in reverse (palindrome) so
// everything clicks back to solved, rests, repeats.

/// One slab twist: rotate every lattice point whose coordinate on `axis` lies
/// in [lo, hi) by `ang` (always ±90°) about that axis.
private struct Move {
    var axis: Int  // 0 = x, 1 = y, 2 = z
    var lo: Double
    var hi: Double
    var ang: Double
}

/// The timeline of the solver. Returns, for the instant `time`, how far each
/// move has progressed (`amount[i]` ∈ [0, 1]: 0 = untouched, 1 = a full
/// quarter turn) and which move is currently animating (`active`, −1 = none).
///
/// TIMELINE with count = 14 moves, slotDur = 0.42, rest = 1.2:
///
///   slot:   0  1  2 … 13 │ 14 15 … 26 27 │ rest
///   move:   0  1  2 … 13 │ 13 12 … 1  0  │ (all solved)
///           └ scramble ┘   └ unscramble ┘
///   time:   0 ───── 5.88 ────────── 11.76 ─ 12.96 (= cycle length, then repeats)
///
///     cycle = 2·count·slotDur + rest = 2·14·0.42 + 1.2 = 12.96
///
///  • Scramble slot j:   moves 0…j−1 are finished (amount 1), move j is
///    animating (amount = ep), later moves untouched (0).
///  • Unscramble slot s ≥ count: it undoes move u = 2·count − 1 − s. So slot 14
///    undoes move 13, slot 15 undoes 12, … slot 27 undoes move 0. Moves BELOW u
///    stay at 1; move u runs 1 → 0 (amount = 1 − ep).
///  • WHY reverse order: twists don't commute (turn x then y ≠ y then x), so
///    to return to the start you must undo the LAST move FIRST — a palindrome:
///    m0 m1 … m13 │ m13⁻¹ … m1⁻¹ m0⁻¹.
///
/// EASING inside a slot. With p = fraction of the slot elapsed (0…1):
///     cl = min(1, p / 0.7)          the move finishes in the first 70 % …
///     ep = 1 − (1 − cl)³            … with a cubic ease-OUT ("machine ease")
///   p:    0     0.25   0.5    0.7    1.0
///   ep:   0     0.734  0.977  1.0    1.0
///   It lurches to speed then settles; the last 30 % of the slot is a still
///   "click" before the next move starts.
///
///   Example t = 0.63: slot = ⌊0.63/0.42⌋ = 1, p = (0.63 − 0.42)/0.42 = 0.5,
///   cl = 0.714, ep = 0.977 → amount = [1, 0.977, 0, 0, …], active = 1.
private struct SolveCycle {
    var amount: [Double]
    var active: Int

    init(time: Double, count: Int, slotDuration slotDur: Double, rest: Double) {
        let cyc = 2 * Double(count) * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDur {
            let slot = Int(floor(tc / slotDur))
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)  // machine ease-out
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        self.amount = amount
        self.active = active
    }
}

/// Apply every in-progress twist to one lattice point, IN ORDER (move 0 first).
///
/// For move i with amount k the angle is a = ang·k, so a is 0…±90°. A point is
/// affected only if its coordinate on the move's axis is inside the slab
/// [lo, hi) — a slice of the sphere perpendicular to that axis, like a layer
/// of a Rubik's cube. Rotating about axis A leaves A's coordinate unchanged:
///
///   axis x:  y' = y·cos a − z·sin a      z' = y·sin a + z·cos a
///   axis y:  x' = x·cos a + z·sin a      z' = −x·sin a + z·cos a
///   axis z:  x' = x·cos a − y·sin a      y' = x·sin a + y·cos a
///
/// Example, axis y, full quarter turn (a = π/2), the point (1, 0, 0):
///   x' = 1·0 + 0·1 = 0,   z' = −1·1 + 0·0 = −1     →  (0, 0, −1)
/// (a point on the right edge is swung round to the back.)
///
/// Notes:
///  • Rotations preserve length, so points stay ON the sphere; only their
///    arrangement is scrambled.
///  • Later moves test their slab against the ALREADY-ROTATED coordinates,
///    which is what actually scrambles things (and why order matters).
///  • `hi` is exclusive, so a coordinate of exactly +1.0 (a pole) belongs to
///    no slab and never moves.
///  • `inActive` reports whether the point sits in the band being turned right
///    now, so the caller can highlight it.
/// The outcome of `SolveCycle.apply`: where the point ended up, and whether it
/// sits in the band being turned right now.
private struct Twist {
    var point: SIMD3<Double>
    var inActive: Bool
}

extension SolveCycle {
    func apply(_ moves: [Move], to point: SIMD3<Double>) -> Twist {
        var (x, y, z) = (point.x, point.y, point.z)
        var inActive = false
        for i in moves.indices {
            if amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : mv.axis == 1 ? y : z
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == active { inActive = true }
            let a = mv.ang * amount[i]
            let ca = cos(a)
            let sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return Twist(point: SIMD3(x, y, z), inActive: inActive)
    }
}

/// The scramble, generated deterministically from `hashD` (so it is identical
/// every cycle and every launch). For move i:
///   axis = ⌊hashD(i, 2.3)·3⌋        → 0, 1 or 2   (x, y, z)
///   lo   = −1 + 0.5·⌊hashD(i, 5.9)·4⌋ → −1, −0.5, 0 or 0.5
///   slab = [lo, lo + 0.5)           → one of 4 equal slices of [−1, 1]
///   dir  = hashD(i, 7.7) < 0.5 ? +1 : −1     ang = dir·π/2
/// The first moves come out as:
///   move 0: x-axis, slab [ 0.5, 1.0), −90°
///   move 1: z-axis, slab [−0.5, 0.0), +90°
///   move 2: z-axis, slab [−1.0,−0.5), −90°
///   move 3: z-axis, slab [−0.5, 0.0), +90°
extension Move {
    static func scramble(count: Int) -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(count)
        for i in 0..<count {
            let fi = Double(i)
            let axis = min(2, Int(floor(hashD(fi, 2.3) * 3)))
            let lo = -1.0 + 0.5 * Double(min(3, Int(floor(hashD(fi, 5.9) * 4))))
            let dir: Double = hashD(fi, 7.7) < 0.5 ? 1 : -1
            moves.append(Move(axis: axis, lo: lo, hi: lo + 0.5, ang: (dir * Double.pi) / 2))
        }
        return moves
    }
}

// MARK: - Globe: lat/long field, a scan meridian sweeps — searching

/// ── GLOBE ("searching") ───────────────────────────────────────────────────
/// The plain lat/long lattice (see the header), spinning steadily, with a
/// meridian of enlarged dots — the "scan" — sweeping round it like a radar.
///
/// CAMERA: yaw = t·spin (spin = 0.5 rad per unit t), tilt = 0.4 + 0.06·sin(0.35t)
/// — a gentle nod between 0.34 and 0.46 rad. `radius` = 0.82·(size/2) is the
/// projector's scale, so lattice points stay unit vectors.
///
/// DOT LOOK (all driven by depth = (z+1)/2):
///     radius = (rBase + rDepth·depth + rBoost·boost)·rs
///     white  = inkFar − inkSpan·depth        (0.62 far … 0.08 near)
///     alpha  = dimBase + (1 − dimBase)·min(1, boost)
///
/// THE SCAN. For each dot with longitude λ:
///     d     = angleDelta(λ + t·spin, scan)          how far (in angle) from the scan line
///     boost = exp(−d²/0.18) · max(0, z)
///   • exp(−d²/0.18) is a Gaussian bell, σ = √0.09 = 0.3 rad ≈ 17°:
///         d (rad):  0     0.15   0.3    0.6    0.9    1.2
///         bell:     1.000 0.882  0.607  0.135  0.011  0.000
///     so the ripple is a soft band about 40° wide at half height, not a hard line.
///   • max(0, z) zeroes the boost on the BACK hemisphere, so the scan only
///     shows on the side facing you.
///   • the boost is added to the RADIUS ("a size ripple, not a shine"), so
///     dots swell as the line passes and shrink back.
///   • `scan = t·(spin + (1.7 − spin)·scanMul)`. In the sphere's own longitude
///     the bell is centred on λ* = scan − t·spin = t·(1.7 − spin)·scanMul.
///     With scanMul = 4.08 (size 64) that is 1.2·4.08 = 4.90 rad per unit t —
///     `scanMul` scales how fast the line sweeps relative to the spin.
///   • dimBase = 0.45: un-scanned dots are drawn at 45 % alpha, and alpha rises
///     to 1 where boost ≥ 1, so the meridian pops out of a dimmed globe.
func frameGlobe(size: Double, time t: Double, options o: ModeOpts) -> OrbFrame {
    let spin = 0.5
    let radius = (size / 2) * 0.82
    let tilt = 0.4 + 0.06 * sin(t * 0.35)
    let pt = Projector(yaw: t * spin, tilt: tilt, center: SIMD2(repeating: size / 2), scale: radius)
    // scan sweeps relative to the spin; scanMul scales that relative rate
    let scan = t * (spin + (1.7 - spin) * (o[.scanMul] ?? 1))
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)
    let dimBase = o[.dimBase] ?? 1

    var dots: [Dot] = []
    let latRings = Int(o[.latRings] ?? 17)
    let lonDensity = o[.lonDensity] ?? 44
    let rBase = o[.rBase] ?? 0.6
    let rDepth = o[.rDepth] ?? 1.7
    let rBoost = o[.rBoost] ?? 1
    let inkFar = o[.inkFar] ?? 0.62
    let inkSpan = o[.inkSpan] ?? 0.54
    for li in 0...latRings {
        let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * Double.pi
        let cosLat = cos(lat)
        let sinLat = sin(lat)
        let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
        for lj in 0..<lonCount {
            let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
            let p = pt(SIMD3(cosLat * cos(lon), sinLat, cosLat * sin(lon)))
            let depth = (p.z + 1) / 2
            // the scan: a moving meridian read as a size ripple, not a shine
            let d = angleDelta(lon + t * spin, scan)
            let boost = exp(-(d * d) / 0.18) * max(0, p.z)
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: (rBase + rDepth * depth + rBoost * boost) * rs,
                    white: inkFar - inkSpan * depth,
                    // dimBase < 1 fades un-scanned dots so the meridian reads clearly
                    a: dimBase + (1 - dimBase) * min(1, boost)
                ))
        }
    }
    return finalizeFrame(dots: dots, rMin: o[.rMin])
}

// MARK: - Rubik: bands twist in quarter turns, scramble → solve — solving

/// ── RUBIK ("solving") ─────────────────────────────────────────────────────
/// The same lat/long lattice, but before the camera sees it, a queue of slab
/// twists (see `SolveCycle`, `SolveCycle.apply`, `Move.scramble` above) is applied to
/// every point: the sphere is sliced into 4 layers along an axis and one layer
/// at a time is turned a quarter, like a Rubik's cube. It scrambles through 14
/// moves, then plays them backwards until solved, pauses, and loops
/// (12.96 time units per cycle).
///
/// Per dot:   (x, y, z) = SolveCycle.apply(lattice point)  →  projector  →  depth
///     radius = (rBase + rDepth·depth + (inActive ? rActive : 0))·rs
///     white  = inkFar − inkSpan·depth − (inActive ? 0.14 : 0)
/// so the band that is turning right now gets a bit bigger and 0.14 darker —
/// "the hand" doing the turning.
///
/// CAMERA: yaw = 0.55·t, tilt = 0.35 + 0.1·sin(0.9t) (nods between 0.25–0.45).
/// The projector scale is `R` = 0.82·(size/2), points are unit vectors.
func frameRubik(size: Double, time t: Double, options o: ModeOpts) -> OrbFrame {
    let R = (size / 2) * 0.82
    let pt = Projector(
        yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9), center: SIMD2(repeating: size / 2), scale: R)
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)
    let moveCount = Int(o[.moveCount] ?? 14)
    let moves = Move.scramble(count: moveCount)
    let sc = SolveCycle(time: t, count: moveCount, slotDuration: 0.42, rest: 1.2)

    var dots: [Dot] = []
    let latRings = Int(o[.latRings] ?? 15)
    let lonDensity = o[.lonDensity] ?? 40
    let rBase = o[.rBase] ?? 0.6
    let rDepth = o[.rDepth] ?? 1.7
    let rActive = o[.rActive] ?? 0.3
    let inkFar = o[.inkFar] ?? 0.62
    let inkSpan = o[.inkSpan] ?? 0.54
    for li in 0...latRings {
        let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * Double.pi
        let cosLat = cos(lat)
        let sinLat = sin(lat)
        let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
        for lj in 0..<lonCount {
            let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
            let twist = sc.apply(moves, to: SIMD3(cosLat * cos(lon), sinLat, cosLat * sin(lon)))
            let p = pt(twist.point)
            let depth = (p.z + 1) / 2
            // the band being turned inks a touch darker — the "hand"
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: (rBase + rDepth * depth + (twist.inActive ? rActive : 0)) * rs,
                    white: inkFar - inkSpan * depth - (twist.inActive ? 0.14 : 0)
                ))
        }
    }
    return finalizeFrame(dots: dots, rMin: o[.rMin])
}

// MARK: - Wave: a waveform rolls through the rings — listening

/// ── WAVE ("listening") ────────────────────────────────────────────────────
/// The lat/long lattice again, but each latitude ROW is scaled in and out as
/// a whole, so a ripple runs from pole to pole and the silhouette bulges and
/// pinches like an audio waveform wrapped round a ball.
///
/// For row ri (0 = south pole … `rings` = north pole) the "displacement" is
/// the sum of TWO travelling sine waves:
///
///     w(ri, t) = 0.62·sin(2.10·t − 0.52·ri) + 0.38·sin(1.27·t + 0.83·ri)
///
///   • The weights 0.62 + 0.38 = 1, so w always stays in [−1, 1].
///   • A wave sin(ω·t ∓ k·ri) has constant phase along ri = ±(ω/k)·t, i.e. it
///     TRAVELS. Wave A moves toward higher rows at 2.10/0.52 = 4.04 rows per
///     time unit, wave B moves the OTHER way at 1.27/0.83 = 1.53 rows per unit.
///     Counter-propagating waves with unrelated speeds never line up twice,
///     so the pattern is "organic, never quite repeating".
///   • Their spatial periods are 2π/0.52 = 12.1 rows and 2π/0.83 = 7.6 rows.
///
///     rr = R·(0.88 + 0.105·w)      so rr/R ∈ [0.775, 0.985]
///
///   The row's ENTIRE position — horizontal AND vertical — is multiplied by rr,
///   i.e. (cosφ·cosλ·rr, sinφ·rr, cosφ·sinλ·rr): a pure radial pump.
///
///   Example, size 64 (R = 32·0.874 = 27.97), t = 0.6:
///       row  0:  w = +0.853  → rr/R = 0.970   (near a crest, nearly full size)
///       row  5:  w = −0.976  → rr/R = 0.778   (a trough, pinched in 22 %)
///       row 10:  w = +0.579  → rr/R = 0.941
///
/// The crest also styles the dots:  crest = max(0, w)
///     radius = (rBase + rDepth·depth)·(1 + 0.4·crest)·rs     up to 40 % bigger
///     white  = 0.66 − 0.56·depth − 0.1·crest                  a bit darker
///
/// WHY R = 0.874·(size/2): the mean radius is 0.88·R, so the wave sphere reads
/// ~15 % smaller than the other modes; the constant is 0.76 × 1.15 to make up
/// for it. Depth uses the NOMINAL R, so it lands in ≈ [0.01, 0.99].
/// CAMERA: slow yaw 0.18·t, fixed tilt 0.38.
func frameWave(size: Double, time t: Double, options o: ModeOpts) -> OrbFrame {
    // 0.76 base × 1.15 — the undulation pulls the sphere inward, so wave read
    // ~15% smaller than the other lattice modes; scaled up to match them
    let R = (size / 2) * 0.874
    let pt = Projector(yaw: t * 0.18, tilt: 0.38, center: SIMD2(repeating: size / 2), scale: 1)
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)

    var dots: [Dot] = []
    let rings = Int(o[.rings] ?? 15)
    let lonDensity = o[.lonDensity] ?? 40
    let rBase = o[.rBase] ?? 0.6
    let rDepth = o[.rDepth] ?? 1.7
    for ri in 0...rings {
        let fri = Double(ri)
        let lat = -Double.pi / 2 + (fri / Double(rings)) * Double.pi
        let cosLat = cos(lat)
        let sinLat = sin(lat)
        // two waves, different tempi — organic, never quite repeating
        let w = 0.62 * sin(t * 2.1 - fri * 0.52) + 0.38 * sin(t * 1.27 + fri * 0.83)
        let rr = R * (0.88 + 0.105 * w)
        let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
        for lj in 0..<lonCount {
            let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
            let p = pt(SIMD3(cosLat * cos(lon), sinLat, cosLat * sin(lon)) * rr)
            let depth = (p.z / R + 1) / 2
            let crest = max(0, w)
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: (rBase + rDepth * depth) * (1 + 0.4 * crest) * rs,
                    white: 0.66 - 0.56 * depth - 0.1 * crest
                ))
        }
    }
    return finalizeFrame(dots: dots, rMin: o[.rMin])
}
