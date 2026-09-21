//
// Ribbon.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/ribbon.ts
//
//  Ribbon: an undulating sash of parallel strands rides a great circle —
//  the "composing" state. The tuned preset freezes the 3D tumble (spin 0),
//  leaving the traveling undulation on a fixed band.
//
//  The same painter also drives "breathing" (ring), via the `faceOn` flag:
//  a face-on circle whose radius — not its out-of-plane offset — undulates,
//  so it reads as a ring slowly morphing rather than a sash in orbit.
//

import Foundation
import simd

/// ── RIBBON ("composing") and RING ("breathing") ───────────────────────────
/// One function, two looks, switched by `faceOn`:
///   • ribbon (faceOn = 0): a wavy sash of parallel dotted strands wrapped round
///     a tilted great circle of the sphere, with a faint ghost sphere behind it.
///   • ring   (faceOn = 1): the same band seen exactly face-on, so it reads as
///     a flat circle whose radius ripples — no ghost sphere.
///
/// Dot counts at size 64:  ribbon = 12 lanes × 44 dots + 38 ghost = 566
///                         ring   = 11 lanes × 44 dots +  0 ghost = 484
/// (lanes = round(base lanes · bandMul), e.g. round(3 · 3.9) = 12.)
///
/// STEP 1 — THE BAND PLANE. A great circle is a circle through the centre, so
/// it lives in a plane spanned by two perpendicular unit vectors u and v:
///
///     u = ( cos ya, 0, sin ya )                       ya = 0.24·t·spin
///     v = ( −uz·sin ta,  cos ta,  ux·sin ta )         ta = tilt of the plane
///     n = u × v                                       the plane's normal
///
///   v is perpendicular to u (u·v = −ux·uz·sin ta + uz·ux·sin ta = 0) and has
///   length √(sin²ta·(uz²+ux²) + cos²ta) = 1. Every point of the circle is
///        P(a) = u·cos a + v·sin a          (a = angle round the band)
///   and every P(a) is perpendicular to n, so it never leaves the plane.
///
///   `spin` scales ALL the tumbling; the shipped presets set spin = 0, which
///   freezes ya = 0 (u = (1,0,0)) and, for the ribbon, ta = 0.55, leaving only
///   the travelling wave. Then, with ta = 0.55:
///        u = (1, 0, 0)   v = (0, 0.853, 0.523)   n = (0, −0.523, 0.853)
///
/// STEP 2 — WHY THE RING LOOKS ROUND. The camera tilts by camTilt = 0.3, so
/// (for the un-spun band, ya = 0, which is what spin = 0 gives) the vertical
/// extent of v on screen is cos(ta + camTilt) and its depth is
/// sin(ta + camTilt):
///
///     ribbon: ta = 0.55        → height cos(0.85) = 0.66, depth sin(0.85) = 0.75
///             the great circle is squashed to a 66 %-tall ellipse, its near half
///             clearly in front.
///     ring:   ta = −camTilt    → height cos 0 = 1, depth sin 0 = 0
///             the camera cancels the tilt exactly: u → right, v → up, n → straight
///             at the viewer. The band is a perfect circle facing you.
///
///   Consequence worth knowing: in ring mode every dot has depth ≈ 0, so the
///   z-sort is between (almost) equal numbers — the draw order among them is
///   decided by floating-point noise. That is harmless: equal depth = equal
///   size and ink.
///
/// STEP 3 — LANES. A sash is several parallel strands. Lane w of `lanes`
/// is displaced along n by
///
///     laneOff = (w − (lanes−1)/2)·0.075        centred on 0
///     edge    = |w − (lanes−1)/2| / max(1, (lanes−1)/2)     0 = middle … 1 = outer edge
///
///   and the point is re-normalised, so with |P| = 1 and P ⟂ n:
///        (P + off·n) / √(1 + off²)
///   is a smaller circle parallel to the band, at "latitude" atan(off):
///        5 lanes → offsets −0.15, −0.075, 0, +0.075, +0.15 = −8.5°, −4.3°, 0°, +4.3°, +8.5°
///        12 lanes (shipped ribbon@64) → ±0.4125 = ±22.4°, a ~45°-wide sash.
///   Outer lanes are drawn smaller and paler to soften the sash edge:
///        radius × (1 − 0.25·edge)      white + 0.18·edge
///
///   In RING mode n points at the viewer, so a lane offset moves the dot only
///   in DEPTH and shrinks its screen radius by 1/√(1+off²). Lanes at +off and
///   −off share a screen radius; the +off one is nearer, so it is drawn bigger,
///   darker and more opaque:  off = 0.375 → radius factor 0.936, depth ±0.351.
///
/// STEP 4 — THE UNDULATION. Two travelling waves along the band angle a:
///
///     wob = ( 0.16·sin(3a − 1.7t + 0.22·w)  +  0.07·sin(5a + 1.1t) ) · wobMul
///
///   • Wave 1 has 3 lobes round the circle and moves forward at 1.7/3 =
///     0.567 rad per unit t. Its phase includes 0.22·w, so each lane is offset
///     0.22 rad from its neighbour — the wave leans across the sash.
///   • Wave 2 has 5 lobes and moves BACKWARD at 1.1/5 = 0.22 rad per unit t.
///   • Peak |wob| = 0.16 + 0.07 = 0.23 (× wobMul). This is `wobAmp`.
///
///   How wob is used depends on the mode:
///     ribbon: off = laneOff + wob → the strand is pushed out of the plane
///             (along n); after re-normalisation it slides in latitude — an
///             up-and-down wave on a sphere whose silhouette stays pinned at R.
///     ring:   radial = 1 + wob → the in-plane RADIUS itself swells and pinches,
///             so lobes really do grow outward. (A normal-direction wobble
///             would be cancelled by re-normalising — points would just be
///             pulled back onto the sphere — so ring uses the radius instead.)
///
///   Ring size guard: baseR = R / (1 + 0.85·wobAmp) so the swollen lobes stay
///   inside the frame. Ring@64: wobMul 0.368 → wobAmp = 0.0846 →
///   baseR = 0.933·R = 23.3pt (R = 0.78·32 = 24.96); lobes reach 1.012·R at
///   most and pinch to 0.854·R.
///
/// LOOK:  depth = (zr/R + 1)/2
///     radius = (rBase + rDepth·depth)·(1 − 0.25·edge)·rs
///     white  = 0.52 − 0.44·depth + 0.18·edge
///     alpha  = 0.4 + 0.6·depth
///   Ghost sphere: `fibDir` dots, radius 0.8·rs, white 0.78, alpha 0.1 + 0.22·depth.
func frameRibbon(size: Double, time t: Double, options o: ModeOpts) -> RawFrame {
    let R = (size / 2) * 0.78
    // spin scales the 3D tumble; spin=0 freezes the band's orientation,
    // leaving only the traveling undulation
    let spin = o[.spin] ?? 1
    let camTilt = 0.3
    let pt = Projector(yaw: t * 0.1 * spin, tilt: camTilt, center: SIMD2(repeating: size / 2), scale: 1)
    let rs = radiusScale(size: size, exponent: o[.rsPow] ?? 0.6)
    let faceOn = (o[.faceOn] ?? 0) != 0
    let wobMul = o[.wobMul] ?? 1

    var dots: [Dot] = []
    let ghostN = Int(o[.ghostN] ?? 150)
    for i in 0..<ghostN {
        let p = pt(fibDir(i, of: ghostN) * R)
        let depth = (p.z / R + 1) / 2
        dots.append(Dot(x: p.x, y: p.y, z: p.z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
    }

    // The band plane, precessing (frozen when spin=0). The projection squashes
    // the band's great circle vertically by cos(ta + camTilt); face-on sets
    // ta = -camTilt so that term is 1 and the band reads as a true circle
    // rather than ribbon's tilted ellipse.
    let ya = t * 0.24 * spin
    let ta = faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
    let u = SIMD3(cos(ya), 0, sin(ya))
    let v = SIMD3(-u.z * sin(ta), cos(ta), u.x * sin(ta))
    // plane normal n = u × v
    let n = cross(u, v)

    // Radial lobes swell past R, so pull the base radius in by (most of) the
    // wobble amplitude. The silhouette then stays inside the frame however far
    // the deformation is pushed, while lobes keep getting deeper relative to
    // the mean radius.
    let wobAmp = 0.23 * wobMul
    let baseR = faceOn ? R / (1 + 0.85 * wobAmp) : R

    let baseLanes = o[.lanes] ?? 5
    let segs = Int(o[.segs] ?? 88)
    let lanes = max(1, Int((baseLanes * (o[.bandMul] ?? 1)).rounded()))
    let rBase = o[.rBase] ?? 1.1
    let rDepth = o[.rDepth] ?? 1.7
    let mid = Double(lanes - 1) / 2
    for w in 0..<lanes {
        let fw = Double(w)
        let laneOff = (fw - mid) * 0.075
        let edge = abs(fw - mid) / max(1, mid)
        for k in 0..<segs {
            let a = (Double(k) / Double(segs)) * 2 * Double.pi
            // the undulation: two traveling waves along the band; wobMul
            // scales the deformation — 0 is a clean band
            let wob = (0.16 * sin(a * 3 - t * 1.7 + fw * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * wobMul
            // A normal-direction wobble is cancelled by the re-normalisation below:
            // the point lands back on the sphere, so the silhouette is pinned at R
            // and the deformation can only ever pull dots inward. Face-on instead
            // modulates the in-plane RADIUS, so lobes genuinely swell outward and
            // pinch inward. Ribbon keeps the original out-of-plane sash wobble.
            let radial = faceOn ? 1 + wob : 1
            let off = faceOn ? laneOff : laneOff + wob
            // (P(a) + off·n), then divide by its length to land back on the sphere
            let q = u * cos(a) + v * sin(a) + n * off
            let rr = baseR * radial
            let p = pt(q / length(q) * rr)
            let depth = (p.z / R + 1) / 2
            dots.append(
                Dot(
                    x: p.x, y: p.y, z: p.z,
                    r: (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth
                ))
        }
    }
    return RawFrame(dots: dots, rMin: o[.rMin])
}
