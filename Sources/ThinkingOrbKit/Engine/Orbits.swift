//
// Orbits.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/orbits.ts
//
//  Orbits: particles on tilted orbits — the "working" state. No nucleus
//  (the tuned preset runs coreless): just ghost paths and the particles
//  doing the work.
//

import Foundation
import simd

/// ── ORBITS ("working") ────────────────────────────────────────────────────
/// A cloud of `orbitN` circles, each in its own randomly tilted plane through
/// the centre, like the electron shells of an atom. Each circle is drawn twice:
///   • a GHOST PATH — `ghostN` faint dots evenly spaced round the circle
///   • PARTICLES  — `particles` bright dots that actually RUN round it
/// The whole bundle turns slowly as one (yaw t·0.12, tilt 0.3).
///
/// Dot count = orbitN × (ghostN + particles). At size 64: 12 × (40 + 3) = 516.
///
/// STEP 1 — a random plane per orbit, from three hashes (fixed forever, since
/// `hashD` is deterministic):   h1 = hashD(orb, 1.7)  h2 = hashD(orb, 5.2)
///                              h3 = hashD(orb, 8.9)
///
///   radius   ro  = R·(0.45 + 0.52·h1)         between 45 % and 97 % of R
///   normal   n   from spherical angles:
///              θ  = 2π·h1                     (azimuth, 0…2π)
///              φ  = acos(2·h2 − 1)            (polar angle, 0…π)
///              n  = (sinφ·cosθ,  cosφ,  sinφ·sinθ)
///
///   WHY acos(2h−1) and not simply π·h? Because of Archimedes again (see
///   `fibDir`): if cosφ is uniform on [−1, 1] the normals are uniform over the
///   SPHERE. Picking φ uniformly instead would crowd normals near the poles.
///
///   in-plane axes (a right-handed orthonormal basis u, v, n):
///              u = normalize(ẑ × n) = (−n_y, n_x, 0)/‖…‖   (horizontal)
///              v = n × u
///   Any point of the orbit circle is then   P(a) = ro·( u·cos a + v·sin a ),
///   which is perpendicular to n for every angle a — i.e. it stays in the plane.
///   (`max(1e-6, …)` guards the one degenerate case n ∥ ẑ, where ẑ × n = 0.)
///
///   WORKED EXAMPLE, orbit 0 at size 64 (R = 32·0.82 = 26.24):
///       h1 = 0.9344   h2 = 0.7469   h3 = 0.3174
///       ro = 26.24·(0.45 + 0.52·0.9344) = 24.56
///       θ  = 5.871 rad    φ = acos(0.4938) = 1.054 rad
///       n  = ( 0.797,  0.494, −0.348)     |n| = 1
///       u  = (−0.527,  0.850,  0.000)     u·n = 0   ✓ perpendicular
///       v  = ( 0.296,  0.184,  0.937)     |v| = 1, u·v = 0   ✓ orthonormal
///
/// STEP 2 — motion. Particle m of an orbit sits at angle
///       a = t·speed + (m / particles)·2π + 6·h2
///   • speed = (0.25 + 0.55·h3) rad per time unit, negative if h3 ≤ 0.5, so
///     about half the orbits run backwards (orbit 0: h3 = 0.317 → −0.425).
///   • (m/particles)·2π spaces the particles evenly: 3 of them → 0°, 120°, 240°.
///   • 6·h2 gives each orbit its own random starting phase.
///   Ghost dots use a = (k/ghostN)·2π and do NOT depend on t — they are the
///   track, the particles are the trains.
///
/// STEP 3 — depth shading, normalised PER ORBIT. The projected z of a point on
/// a circle of radius ro lies in [−ro, ro], so depth = (z/ro + 1)/2 ∈ [0, 1]
/// regardless of how big the orbit is (0 = far side, 1 = near side).
///   ghost:    r = ghostR·rs                       alpha = ghostA·(0.4 + 0.6·depth)
///   particle: r = (partR + partRDepth·depth)·rs   white = 0.3 − 0.22·depth
///   (`rs` = radiusScale, see Core.swift.) Near particles are bigger AND darker
///   (white 0.08); far ones smaller and lighter (0.30) — the depth cue.
func frameOrbits(size: Double, time t: Double, options o: ModeOpts) -> RawFrame {
    let R = (size / 2) * 0.82
    // whole cluster: slow yaw (0.12 rad per unit t) and a fixed 0.3 rad tilt
    let pt = Projector(yaw: t * 0.12, tilt: 0.3, center: SIMD2(repeating: size / 2), scale: 1)
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)

    var dots: [Dot] = []
    let orbitN = Int(o[.orbitN] ?? 12)
    let ghostN = Int(o[.ghostN] ?? 40)
    let particles = Int(o[.particles] ?? 3)
    let ghostR = o[.ghostR] ?? 0.9
    let ghostA = o[.ghostA] ?? 0.5
    let partR = o[.partR] ?? 1.2
    let partRDepth = o[.partRDepth] ?? 1.6

    // orbits: each a tilted circle — a ghost path + running particles
    for orb in 0..<orbitN {
        let h1 = hashD(Double(orb), 1.7)
        let h2 = hashD(Double(orb), 5.2)
        let h3 = hashD(Double(orb), 8.9)
        let ro = R * (0.45 + 0.52 * h1)
        let th = h1 * 2 * Double.pi
        let phi = acos(2 * h2 - 1)
        // orbit plane basis (u, v ⟂ normal n)
        let n = SIMD3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
        var u = SIMD3(-n.y, n.x, 0)
        u /= max(1e-6, length(u))
        let v = cross(n, u)
        let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

        // ghost path
        for k in 0..<ghostN {
            let a = (Double(k) / Double(ghostN)) * 2 * Double.pi
            // P(a) = ro·(u·cos a + v·sin a), then spin/tilt/flatten
            let p = pt((u * cos(a) + v * sin(a)) * ro)
            let depth = (p.z / ro + 1) / 2
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: ghostR * rs,
                    white: 0.72,
                    a: ghostA * (0.4 + 0.6 * depth)
                ))
        }
        // the particles doing the work
        for m in 0..<particles {
            let a = t * speed + (Double(m) / Double(particles)) * 2 * Double.pi + h2 * 6
            let p = pt((u * cos(a) + v * sin(a)) * ro)
            let depth = (p.z / ro + 1) / 2
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: (partR + partRDepth * depth) * rs,
                    white: 0.3 - 0.22 * depth
                ))
        }
    }
    return RawFrame(dots: dots, rMin: o[.rMin])
}
