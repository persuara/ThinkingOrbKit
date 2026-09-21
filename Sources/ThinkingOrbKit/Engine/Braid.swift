//
// Braid.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/braid.ts
//
//  Braid: three strands plait around the sphere — the "weaving" state.
//  Each strand runs pole to pole on a helix, and a radial breathing term
//  makes them trade places, reading as the over/under of a plait.
//

import Foundation
import simd

/// ── BRAID ("weaving") ─────────────────────────────────────────────────────
/// Three strands of dots spiral from pole to pole around a faint ghost sphere
/// (a `fibDir` cloud that gives the eye something to read the strands against).
///
/// At size 64: ghost 75 + 3 strands × 26 dots = 153 dots.
///
/// THE HELIX. Every strand dot has a height u ∈ (−0.96, 0.96) on the unit
/// sphere (−1 = south pole, +1 = north pole; 0.96 stops short of the poles so
/// the strands don't all pinch into one point).
///
///     ring radius   surf = √(1 − u²)          (circle of latitude at height u)
///     azimuth       a    = u·π·turns + phase   (angle round the vertical axis)
///     position      ( cos a · surf,  u,  sin a · surf ) · R · weave
///
///   • As u runs −1 → +1, `a` advances by 2π·turns, so the strand winds round
///     the axis `turns` full times (turns = 3 → three revolutions): a helix.
///   • The 3 strands get phase = s·2π/3 = 0°, 120°, 240°: same helix, rotated
///     by a third of a turn each — a triple-strand rope.
///   • Example, strand 0 (phase 0), u = 0.5: surf = √0.75 = 0.866 and
///     a = 0.5·π·3 = 4.712 rad = 270° = 0.75 of a revolution.
///
/// THE SLIDE. u = (frac(i/strandN + 0.045·t)·2 − 1)·0.96.
///   frac(...) ∈ [0, 1); ×2 − 1 maps it to [−1, 1); ×0.96 gives (−0.96, 0.96).
///   The i/strandN part spreads the dots evenly along the strand; adding
///   0.045·t slides ALL of them along together, so the whole braid seems to
///   flow. A dot needs 1/0.045 ≈ 22 time units to travel from one end to the
///   other, then frac() wraps it back to the start.
///
/// END FADE. endFade = min(1, (1 − |u|)/0.1): full opacity while |u| ≤ 0.9,
/// then a linear ramp down to 0.4 at |u| = 0.96 (u = 0.96 → 0.04/0.1 = 0.4),
/// so dots dim as they approach the poles.
///
/// THE PLAIT (over/under). The radius is modulated by
///     weave = 1 + 0.075·sin(2a + 0.8·t)                  (radius ±7.5 %)
///   — written in the code as  u·π·turns·2 + phase·2 + 0.8t,  which is exactly
///   2·(u·π·turns + phase) + 0.8t = 2a + 0.8t.
///   For the same u the three strands sit at azimuths a, a + 120°, a + 240°, so
///   their weave phases (2a) differ by 240° and 480° (≡ 120°): at any moment
///   the three are at three DIFFERENT radii. As the whole braid spins (yaw
///   0.4·t) and the swell travels (0.8·t), which strand is nearest keeps
///   changing; combined with depth shading that reads as strands passing over
///   and under each other.
///
/// DEPTH / LOOK:  depth = (zr/R + 1)/2
///     radius = (rBase + rDepth·depth)·rs
///     white  = 0.55 − 0.45·depth           (0.10 near … 0.55 far)
///     alpha  = endFade·(0.45 + 0.55·depth)
///   Ghost dots: radius 0.8·rs, white 0.78, alpha 0.1 + 0.22·depth.
/// CAMERA: yaw = 0.4·t (a fairly quick spin), tilt 0.3.
func frameBraid(size: Double, time t: Double, options o: ModeOpts) -> RawFrame {
    let R = (size / 2) * 0.76
    let pt = Projector(yaw: t * 0.4, tilt: 0.3, center: SIMD2(repeating: size / 2), scale: 1)
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)

    var dots: [Dot] = []
    let ghostN = Int(o[.ghostN] ?? 150)
    for i in 0..<ghostN {
        let p = pt(fibDir(i, of: ghostN) * R)
        let depth = (p.z / R + 1) / 2
        dots.append(Dot(x: p.x, y: p.y, z: p.z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
    }

    let strandN = Int(o[.strandN] ?? 52)
    let turns = o[.turns] ?? 3
    let rBase = o[.rBase] ?? 1.2
    let rDepth = o[.rDepth] ?? 1.8
    for s in 0..<3 {
        let phase = (Double(s) / 3) * 2 * Double.pi
        for i in 0..<strandN {
            // u walks pole to pole; the frac() drift slides the whole strand along
            let u = (frac(Double(i) / Double(strandN) + t * 0.045) * 2 - 1) * 0.96
            let surf = max(0, 1 - u * u).squareRoot()
            let endFade = min(1, (1 - abs(u)) / 0.1)
            let a = u * Double.pi * turns + phase
            // radial breathing: strands trade places — the over/under of a plait
            let weave = 1 + 0.075 * sin(u * Double.pi * turns * 2 + phase * 2 + t * 0.8)
            let rr = surf * R * weave
            let p = pt(SIMD3(cos(a) * rr, u * R * weave, sin(a) * rr))
            let depth = (p.z / R + 1) / 2
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: (rBase + rDepth * depth) * rs,
                    white: 0.55 - 0.45 * depth,
                    a: endFade * (0.45 + 0.55 * depth)
                ))
        }
    }
    return RawFrame(dots: dots, rMin: o[.rMin])
}
