//
// Web.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/web.ts
//
//  Web: a constellation wires itself — the "connecting" state. Nodes drift
//  on the sphere under slow value noise; any pair closer than `thr` grows an
//  edge, and bright packets run along randomly re-picked node pairs.
//

import Foundation
import simd

/// ── WEB ("connecting") ────────────────────────────────────────────────────
/// A constellation of `nodeN` points on the sphere, joined by lines wherever
/// two of them are close, with bright "signal" dots travelling between nodes.
/// Unlike the lattice modes this one emits LINES as well as dots.
///
/// At size 64: 41 nodes + 7 signals = 48 dots, and (at t = 0.6) 81 edges.
///
/// STEP 1 — NODES. Start from the even Fibonacci lattice (`fibDir(i, nodeN)`),
/// then let each node wander:
///
///     p_i(t) = normalize( fibDir_i + 0.3·(2·vnoise(·) − 1) per axis )
///
///   • `vnoise` ∈ [0, 1] so (n − 0.5)·2 ∈ [−1, 1]; × 0.3 → each axis is nudged by
///     at most ±0.3 — a big shove relative to a unit vector, so neighbours
///     genuinely rearrange, but not so big that the constellation dissolves.
///   • Each axis samples a DIFFERENT noise stream. The first argument is
///     `i·k + c` with (k, c) = (0.31, 9), (0.53, 27), (0.77, 55) — different
///     node-index frequencies and offsets, so x, y, z move independently.
///     The second argument is time: t·0.24, t·0.21, t·0.27 — slow drift, a
///     few time units to change noticeably.
///   • normalize() (divide by the length) drops the nudged point back onto
///     the unit sphere, so nodes always sit on the surface.
///
/// STEP 2 — EDGES. For every pair i < j (nodeN·(nodeN−1)/2 = 820 pairs at
/// 41 nodes) measure the straight-line (chord) distance between the unit
/// vectors and connect them when dist < thr:
///
///     dist = √(Δx² + Δy² + Δz²)  =  2·sin(θ/2)    (θ = angle between them)
///
///   thr = 0.72  ⇒  θ = 2·asin(0.36) ≈ 42.2°. For scale, with 41 nodes the
///   average spacing on the sphere is about √(4π/41) ≈ 0.55, so each node
///   reaches a handful of neighbours.
///
///     alpha = (1 − dist/thr) · (0.3 + 0.55·depth)
///     width = max(0.6, lineW·rs)      white = 0.42
///
///   The first factor fades an edge LINEARLY to nothing as the pair drifts
///   towards `thr` (so edges grow and dissolve smoothly rather than popping):
///         dist:   0.10   0.36   0.60   0.72
///         fade:   0.861  0.500  0.167  0.000
///   The second factor uses depth = ((z₁ + z₂)/2 + 1)/2 — the mean depth of
///   the two ends — so edges on the near hemisphere are stronger.
///
/// STEP 3 — NODE DOTS.
///     pulse  = 1 + 0.25·sin(1.4·t + 2.7·i)          each node twinkles ×0.75…×1.25
///     radius = (nodeR + nodeRDepth·depth)·pulse·rs
///     white  = 0.55 − 0.45·depth
///   The 2.7·i term gives every node its own phase, so they don't pulse in step.
///
/// STEP 4 — SIGNALS ("packets"). Packet s lives on the clock
///     u = 0.55·t + 7.31·s
///   • seg = ⌊u⌋ is the current LEG number, f = frac(u) ∈ [0, 1) how far along
///     the leg it is. One leg lasts 1/0.55 ≈ 1.82 time units.
///   • The 7.31·s offset staggers the packets so they don't start together.
///   • Whenever `seg` ticks over, a NEW random pair is chosen from `hashD`:
///         a = ⌊hashD(seg, 3.1·s + 1.7) · nodeN⌋      b = ⌊hashD(seg, 5.7·s + 4.2) · nodeN⌋
///     (same seg → same pair, so during a leg it is stable). If a == b the packet
///     rests for that leg (nothing is drawn).
///   • Position: lerp the two node vectors by f, then re-normalise onto the
///     sphere ("nlerp"). Halfway between (1,0,0) and (0,1,0):
///         (0.5, 0.5, 0) / 0.7071 = (0.707, 0.707, 0)   ← on the sphere, not
///         inside it. It follows the surface, but is not a constant-speed
///         great-circle arc; for near-opposite nodes the chord passes close to
///         the centre and the packet visibly accelerates (the `max(1e-6, …)`
///         only guards a division by zero).
///   • The pair need NOT be connected by an edge — packets can hop anywhere.
///   • Look: radius (1.5·nodeR + nodeRDepth·depth)·rs (1.5× a node),
///     white = 0.05 (near black on light), alpha = 0.5 + 0.5·depth.
///
/// CAMERA: yaw 0.12·t, tilt 0.32. The projector scale is R = 0.8·(size/2)·spread
/// so node vectors stay unit length and every distance above is in unit-sphere
/// units, independent of size.
func frameWeb(size: Double, time t: Double, options o: ModeOpts) -> OrbFrame {
    let R = (size / 2) * 0.8 * (o[.spread] ?? 1)
    // note the projector carries the radius as its scale, so node vectors stay
    // unit-length and distances below are in unit-sphere space
    let pt = Projector(yaw: t * 0.12, tilt: 0.32, center: SIMD2(repeating: size / 2), scale: R)
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)

    let nodeN = Int(o[.nodeN] ?? 30)
    let thr = o[.thr] ?? 0.72
    let nodeR = o[.nodeR] ?? 1.4
    let nodeRDepth = o[.nodeRDepth] ?? 1.8
    let lineW = o[.lineW] ?? 0.8

    // nodes: fib lattice + slow noise wander, renormalised to the surface
    var nodes: [SIMD3<Double>] = []
    nodes.reserveCapacity(nodeN)
    for i in 0..<nodeN {
        let fi = Double(i)
        let d = fibDir(i, of: nodeN)
        let wandered = SIMD3(
            d.x + 0.3 * (vnoise(fi * 0.31 + 9, t * 0.24) - 0.5) * 2,
            d.y + 0.3 * (vnoise(fi * 0.53 + 27, t * 0.21) - 0.5) * 2,
            d.z + 0.3 * (vnoise(fi * 0.77 + 55, t * 0.27) - 0.5) * 2
        )
        nodes.append(normalize(wandered))
    }

    var lines: [Line] = []
    var dots: [Dot] = []

    // edges between close neighbours, alpha by proximity + depth
    for i in 0..<nodeN {
        for j in (i + 1)..<nodeN {
            let dist = distance(nodes[i], nodes[j])
            if dist >= thr { continue }
            let p1 = pt(nodes[i])
            let p2 = pt(nodes[j])
            let depth = ((p1.z + p2.z) / 2 + 1) / 2
            lines.append(
                Line(
                    x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y,
                    white: 0.42,
                    a: (1 - dist / thr) * (0.3 + 0.55 * depth),
                    w: max(0.6, lineW * rs)
                ))
        }
    }

    for i in 0..<nodeN {
        let p = pt(nodes[i])
        let depth = (p.z + 1) / 2
        let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
        dots.append(
            Dot(
                x: p.x, y: p.y, z: p.z,
                r: (nodeR + nodeRDepth * depth) * pulse * rs,
                white: 0.55 - 0.45 * depth
            ))
    }

    // signals: bright packets running between paired nodes
    let signals = Int(o[.signals] ?? 5)
    for s in 0..<signals {
        let fs = Double(s)
        let seg = floor(t * 0.55 + fs * 7.31)
        let a = Int(floor(hashD(seg, fs * 3.1 + 1.7) * Double(nodeN)))
        let b = Int(floor(hashD(seg, fs * 5.7 + 4.2) * Double(nodeN)))
        if a == b { continue }
        let f = frac(t * 0.55 + fs * 7.31)
        // lerp the two node vectors, then re-normalise onto the sphere ("nlerp")
        let along = mix(nodes[a], nodes[b], t: f)
        let l = max(1e-6, length(along))
        let p = pt(along / l)
        let depth = (p.z + 1) / 2
        dots.append(
            Dot(
                x: p.x, y: p.y, z: p.z,
                r: (nodeR * 1.5 + nodeRDepth * depth) * rs,
                white: 0.05,
                a: 0.5 + 0.5 * depth
            ))
    }

    return finalizeFrame(dots: dots, lines: lines, rMin: o[.rMin])
}
