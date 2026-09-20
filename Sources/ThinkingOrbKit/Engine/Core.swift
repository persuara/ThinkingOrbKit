//
// Core.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/core.ts
//
//  Shared primitives for the dotted 3D thought-orbs (inkform / PlotterLab's
//  HalftoneSphere lineage): honestly 3D — rotated, depth-shaded, z-sorted.
//  Depth is carried by dot size and ink weight alone. Plain fills only:
//  no blur, no filters.
//
//  Everything here is pure math with no shared state, so a frame can be
//  computed on any thread and compared numerically against the TypeScript
//  engine (see the golden-vector tests).
//
//  ── HOW A FRAME IS MADE (the whole pipeline in five lines) ───────────────
//    1. A mode generates points on/near a UNIT sphere (radius 1, y up).
//    2. `Projector` spins + tilts them, then flattens to screen (x, y) and
//       keeps the rotated z as "depth" (+z = towards the viewer).
//    3. depth ∈ [0, 1] is mapped to dot RADIUS, INK and ALPHA — near dots are
//       bigger and darker, far dots smaller and lighter. That is the ONLY
//       3D cue; there is no lighting, no perspective.
//    4. `finalizeFrame` culls invisible dots, clamps radii, sorts far → near.
//    5. `GraphicsContext.paint(_:dark:)` fills one flat circle per dot, in that order.
//

import Foundation
import SwiftUI
import simd

/// One dot, in final screen space (points), ready to be filled.
///
///  - `x`, `y`  screen position, origin top-left, y grows DOWNWARD.
///  - `z`       rotated depth in unit-sphere units; +z = nearer the viewer.
///              Used only for sorting — the painter never reads it.
///  - `r`       circle radius in points.
///  - `white`   "ink value" on PAPER: 0 = black ink, 1 = white. On dark themes
///              the painter mirrors it (1 − white) so near dots read bright.
///  - `a`       alpha 0…1 (1 = opaque). Dots below 0.02 are culled.
struct Dot: Sendable {
    var x: Double
    var y: Double
    var z: Double
    var r: Double
    /// Ink value: 0 = darkest ink on paper. Mirrored on dark themes.
    var white: Double
    var a: Double = 1
}

/// A stroked edge between two projected points (the `connecting` web).
struct Line: Sendable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    /// Ink value, same convention as `Dot.white`.
    var white: Double
    var a: Double = 1
    var w: Double
}

/// One rendered instant: a complete, final set of draw instructions.
/// `dots` is already z-sorted into draw order and radius-clamped; `lines`
/// are drawn first. Nothing here needs further interpretation.
struct OrbFrame: Sendable {
    var dots: [Dot]
    var lines: [Line]
}

// MARK: - Scalar helpers

/// Fractional part, always in [0, 1): `frac(x) = x − ⌊x⌋`.
/// Unlike `x.truncatingRemainder(1)` it wraps NEGATIVE numbers upward:
///   frac( 2.75) = 0.75
///   frac(-0.25) = 0.75   (not −0.25)
/// That makes it a clean "sawtooth clock": frac(t) climbs 0 → 1, snaps to 0.
func frac(_ x: Double) -> Double {
    x - floor(x)
}

/// Deterministic pseudo-random number in [0, 1) — the classic "GLSL sin hash".
///
///   hashD(a, b) = frac( sin(a·12.9898 + b·78.233) · 43758.5453 )
///
/// WHY IT WORKS: the two constants mix (a, b) into one angle; sin() squashes
/// it into [−1, 1]; multiplying by ~43758 blows a tiny change in the angle up
/// into a huge change in the product, and `frac` keeps only the low digits,
/// which look random. Same input → same output, forever (no RNG state), which
/// is what makes every frame reproducible and comparable against TypeScript.
///
/// It is NOT high-quality randomness: neighbouring inputs can land close
/// together, and it degenerates at (0, 0):
///   hashD(0, 0)   = 0.0000    (sin 0 = 0)
///   hashD(0, 1.7) = 0.9344
///   hashD(1, 1.7) = 0.9062    ← close to the previous one; fine for "looks
///                               varied", not for statistics.
func hashD(_ a: Double, _ b: Double) -> Double {
    let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
    return h - floor(h)
}

/// Smooth 2-D "value noise" in [0, 1] — a random height at every integer
/// grid corner, blended smoothly in between.
///
///   1. Find the cell: (xi, yi) = ⌊(x, y)⌋ and the position inside it,
///      (fx, fy) ∈ [0, 1).
///   2. Ease the position with smoothstep  s(f) = f²(3 − 2f)  so the noise has
///      zero slope at every corner (no visible grid creases):
///         s(0) = 0,  s(0.25) = 0.156,  s(0.5) = 0.5,  s(0.75) = 0.844,  s(1) = 1
///   3. Take the 4 corner values a (xi,yi)  b (xi+1,yi)  c (xi,yi+1)  d (xi+1,yi+1)
///      from `hashD` and bilinearly blend them:
///         a + (b−a)·fx + (c−a)·fy + (a−b−c+d)·fx·fy
///      (that last term is what makes it a true bilinear patch, not just two
///      separate 1-D lerps).
///
/// Properties: exactly equals the corner hash at integer inputs, always stays
/// within the min/max of the four corners, and is continuous everywhere.
/// At (fx, fy) = (0.5, 0.5) the smoothstep gives 0.5, so the result is the
/// plain average (a+b+c+d)/4.
func vnoise(_ x: Double, _ y: Double) -> Double {
    let xi = floor(x)
    let yi = floor(y)
    var fx = x - xi
    var fy = y - yi
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    let a = hashD(xi, yi)
    let b = hashD(xi + 1, yi)
    let c = hashD(xi, yi + 1)
    let d = hashD(xi + 1, yi + 1)
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
}

/// Stable, evenly spread directions on a unit sphere — the FIBONACCI LATTICE.
/// Returns the i-th of n points as a unit vector `SIMD3(x, y, z)`, y up.
///
///   y_i   = 1 − 2(i + 0.5)/n            ← evenly spaced heights
///   ρ_i   = √(1 − y_i²)                 ← radius of the latitude circle at y_i
///   θ_i   = i · φ,  φ = π(3 − √5) ≈ 2.39996 rad ≈ 137.508°   (the GOLDEN ANGLE)
///   point = (ρ_i·cos θ_i,  y_i,  ρ_i·sin θ_i)
///
/// WHY it is even: Archimedes' hat-box theorem — the surface area of a sphere
/// between two parallel planes depends only on their distance apart, so
/// evenly spaced y means every point owns an equal-area band. The +0.5 puts each
/// point at the middle of its band (so nothing sits exactly on a pole). The
/// golden angle is the "most irrational" rotation, so successive points never
/// line up in columns — you get sunflower-seed packing instead of stripes.
///
/// Example, n = 4:
///    i │  y      ρ      θ (rad)   →  (x, y, z)
///    0 │  0.750  0.661  0.000        ( 0.661,  0.750,  0.000)
///    1 │  0.250  0.968  2.400        (−0.714,  0.250,  0.654)
///    2 │ −0.250  0.968  4.800        ( 0.085, −0.250, −0.965)
///    3 │ −0.750  0.661  7.200        ( 0.402, −0.750,  0.525)
func fibDir(_ i: Int, of n: Int) -> SIMD3<Double> {
    let golden = Double.pi * (3 - 5.0.squareRoot())
    let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
    let rad = (1 - y * y).squareRoot()
    let a = Double(i) * golden
    return SIMD3(rad * cos(a), y, rad * sin(a))
}

/// Shortest signed angular distance from b to a, wrapped to (−π, π].
///
/// Plain `a − b` is wrong near the 0 / 2π seam: angles 0.1 and 2π − 0.1 are
/// only 0.2 rad apart on a circle, but subtract to −6.08. The trick is that
/// sin/cos are periodic, so atan2(sin d, cos d) folds any d back into (−π, π]:
///   angleDelta(0.1, 2π − 0.1) = 0.2          (not −6.08)
///   angleDelta(3.0, −3.0)     = 6 − 2π = −0.283   (the short way round)
func angleDelta(_ a: Double, _ b: Double) -> Double {
    atan2(sin(a - b), cos(a - b))
}

// MARK: - Projection

/// Shared spin + tilt + orthographic projection. Takes a 3-D point and returns
/// `SIMD3(screen x, screen y, depth)`. Call it like a function: `pt(point)`.
///
/// Two rotations, then drop the depth axis (orthographic = no perspective,
/// parallel rays, so size never changes with distance — only our depth→radius
/// mapping does that):
///
///   YAW  about the vertical (y) axis by ψ — the "spin":
///        x₁ =  x·cosψ + z·sinψ
///        z₁ = −x·sinψ + z·cosψ
///   TILT about the horizontal (x) axis by τ — the camera looks slightly
///        down on the sphere:
///        y₁ = y·cosτ − z₁·sinτ
///        z₂ = y·sinτ + z₁·cosτ
///   SCREEN:  X = center.x + x₁·scale     Y = center.y − y₁·scale   (minus: screen y is DOWN)
///            depth = z₂                  (+ = towards the viewer)
///   The result packs them as SIMD3(X, Y, depth), so `.x`/`.y` are screen
///   coordinates and `.z` is the depth — the same `z` a `Dot` carries.
///
/// `scale` is either 1 (when the caller already multiplied the point by a
/// radius R) or R itself (when points are unit vectors).
///
/// Examples (centre 32,32; scale 24):
///   pt(SIMD3(1,0,0)), ψ=0,   τ=0   → X=56, Y=32, depth  0    right edge of the sphere
///   pt(SIMD3(0,0,1)), ψ=0,   τ=0   → X=32, Y=32, depth +1    straight at the viewer
///   pt(SIMD3(1,0,0)), ψ=π/2, τ=0   → X=32, Y=32, depth −1    yaw swung it to the BACK
///   pt(SIMD3(0,1,0)), ψ=0,   τ=0.4 → X=32, Y=9.89, depth +0.389
///        the north pole, tipped toward us: height 24·cos0.4 = 22.1 (so Y =
///        32 − 22.1) and depth = sin0.4 = 0.389.
struct Projector: Sendable {
    private let st: Double
    private let ct: Double
    private let sy: Double
    private let cyw: Double
    private let center: SIMD2<Double>
    private let scale: Double

    /// Precomputes sin/cos of yaw and tilt once per frame (not once per dot).
    init(yaw: Double, tilt: Double, center: SIMD2<Double>, scale: Double) {
        self.st = sin(tilt)
        self.ct = cos(tilt)
        self.sy = sin(yaw)
        self.cyw = cos(yaw)
        self.center = center
        self.scale = scale
    }

    func callAsFunction(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let x1 = p.x * cyw + p.z * sy
        let z1 = -p.x * sy + p.z * cyw
        let y1 = p.y * ct - z1 * st
        let z2 = p.y * st + z1 * ct
        return SIMD3(center.x + x1 * scale, center.y - y1 * scale, z2)
    }
}

// MARK: - Frame assembly

/// Turn raw mode output into a finished frame: drop invisible marks, clamp
/// radii to the mode's floor, and z-sort far→near into draw order.
///
/// This runs in the GEOMETRY step, not the painter, so a frame is a complete
/// set of draw instructions: the array order is the order to draw in.
///
///  • CULL   alpha < 0.02 is invisible (< 1/50 of full ink) — don't pay to draw it.
///  • CLAMP  r = max(rMin, r). Far dots on small orbs can compute to e.g.
///           0.6 × 0.396 = 0.24 pt; with rMin = 0.3 they are lifted to 0.3 so
///           they stay a visible speck instead of vanishing.
///  • SORT   ascending z ("painter's algorithm"): far dots first, near dots last
///           so near dots overdraw far ones — this is what sells the depth.
///           The sort must be STABLE (equal z keeps generation order); see
///           `sortedByDepth`.
func finalizeFrame(dots: [Dot], lines: [Line] = [], rMin: Double? = nil) -> OrbFrame {
    let floorR = rMin ?? 0.3
    var visible: [Dot] = []
    visible.reserveCapacity(dots.count)
    for var d in dots {
        if d.a < 0.02 { continue }
        d.r = max(floorR, d.r)
        visible.append(d)
    }
    return OrbFrame(
        dots: sortedByDepth(visible),
        lines: lines.filter { $0.a >= 0.02 }
    )
}

/// Stable sort by ascending `z` (far → near). Equal depths keep their original
/// order — several modes (morph, and the face-on ring) emit many dots at an
/// identical z, and the TypeScript relies on `Array.sort` being stable.
///
/// A plain bottom-up merge sort on the concrete `[Dot]` type, rather than
/// `sorted(by:)`: it is stable by construction (no undocumented guarantee, no
/// index tie-break) and, being non-generic with no closure, it stays fast in
/// unoptimised Debug builds where generic sorting dominates the frame.
private func sortedByDepth(_ dots: [Dot]) -> [Dot] {
    let n = dots.count
    if n < 2 { return dots }
    var a = dots
    // Small frames (shaping, connecting) are cheaper to insertion-sort in place
    // than to set up a merge: strict `>` never moves equal depths past each
    // other, so it is stable too.
    if n <= 32 {
        a.withUnsafeMutableBufferPointer { p in
            for i in 1..<n {
                let x = p[i]
                var j = i - 1
                while j >= 0 && p[j].z > x.z {
                    p[j + 1] = p[j]
                    j -= 1
                }
                p[j + 1] = x
            }
        }
        return a
    }
    var b = dots
    // Raw buffers: no per-access bounds / uniqueness checks, which is what makes
    // element-by-element loops slow in a Debug build.
    a.withUnsafeMutableBufferPointer { aBuf in
        b.withUnsafeMutableBufferPointer { bBuf in
            var src = aBuf
            var dst = bBuf
            var width = 1
            while width < n {
                var lo = 0
                while lo < n {
                    let mid = min(lo + width, n)
                    let hi = min(lo + 2 * width, n)
                    var l = lo
                    var r = mid
                    var k = lo
                    while l < mid && r < hi {
                        // take from the right run only if it is strictly nearer: ties go left
                        if src[r].z < src[l].z {
                            dst[k] = src[r]
                            r += 1
                        } else {
                            dst[k] = src[l]
                            l += 1
                        }
                        k += 1
                    }
                    while l < mid {
                        dst[k] = src[l]
                        l += 1
                        k += 1
                    }
                    while r < hi {
                        dst[k] = src[r]
                        r += 1
                        k += 1
                    }
                    lo += 2 * width
                }
                swap(&src, &dst)
                width *= 2
            }
            // after the final swap `src` points at the sorted data; make sure it is in `a`
            if src.baseAddress != aBuf.baseAddress {
                for i in 0..<n { aBuf[i] = src[i] }
            }
        }
    }
    return a
}

/// Dot radii were tuned for a 300pt frame; sub-linear scaling keeps small
/// spinners legible. Lower pow = radii shrink less with size.
///
///   scale = (size / 300) ^ pow          (pow is usually `rsPow` = 0.6)
///
///   size  │ linear (pow 1) │ pow 0.6
///    300  │ 1.000          │ 1.000
///     64  │ 0.213          │ 0.396
///     20  │ 0.067          │ 0.197
///
/// A 20pt orb drawn with LINEAR scaling would have dots 0.067× the tuned size
/// (sub-pixel mush); at pow 0.6 they are 0.197× — about 3× bigger, still
/// readable. So a base radius of 1.7 becomes 1.7 × 0.396 = 0.67pt at size 64.
func radiusScale(size: Double, exponent pow: Double) -> Double {
    Foundation.pow(size / 300, pow)
}

// MARK: - Painting (SwiftUI Canvas binding)

/// Matte grayscale ink. On dark substrates the ink value is mirrored
/// (1 − white) so near dots read bright — the same depth language on an
/// inverted substrate.
///
///   w  = clamp(white, 0, 1)
///   g  = round( (dark ? 1 − w : w) · 255 )      one gray level, R = G = B = g
///   color = sRGB(g/255, g/255, g/255) with opacity = clamp(alpha, 0, 1)
///
/// Example, white = 0.3 (a fairly dark dot):
///   light theme → g = round(0.30·255) = round(76.5) = 77   dark grey ink
///   dark theme  → g = round(0.70·255) = round(178.5) = 179 light grey ink
/// Note both land exactly on a .5 tie. `.rounded()` rounds ties away from zero,
/// which for these non-negative values is the same as JavaScript's
/// `Math.round` (ties toward +∞), so the result matches the web exactly.
func inkColor(white: Double, alpha: Double, dark: Bool) -> Color {
    let w = min(1, max(0, white))
    let g = ((dark ? 1 - w : w) * 255).rounded()
    // The engine can emit alpha slightly above 1 (weaving reaches 1.0148: the radial
    // weave pushes a dot past the sphere, so its depth exceeds 1). On the web CSS
    // `rgba()` clamps that silently; SwiftUI's behaviour above 1 is undocumented,
    // so clamp explicitly.
    return Color(.sRGB, white: g / 255, opacity: min(1, max(0, alpha)))
}

/// Painting belongs to the drawing surface, so it is a `GraphicsContext`
/// method — inside `Canvas { context, _ in … }` a frame is drawn with
/// `context.paint(frame, dark: dark)`.
extension GraphicsContext {
    /// Fill pass: dots in the order given (already z-sorted by `finalizeFrame`).
    /// A dot is the circle inscribed in the square [x−r, x+r] × [y−r, y+r].
    func paintDots(_ dots: [Dot], dark: Bool) {
        for d in dots {
            let rect = CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)
            fill(Path(ellipseIn: rect), with: .color(inkColor(white: d.white, alpha: d.a, dark: dark)))
        }
    }

    /// Stroke pass for edge-based modes. Runs before the dots so nodes sit on top.
    func paintLines(_ lines: [Line], dark: Bool) {
        for l in lines {
            var path = Path()
            path.move(to: CGPoint(x: l.x1, y: l.y1))
            path.addLine(to: CGPoint(x: l.x2, y: l.y2))
            stroke(path, with: .color(inkColor(white: l.white, alpha: l.a, dark: dark)), lineWidth: l.w)
        }
    }

    /// Paint a finished frame. Lines first, so nodes sit on top of their edges.
    func paint(_ frame: OrbFrame, dark: Bool) {
        if !frame.lines.isEmpty { paintLines(frame.lines, dark: dark) }
        paintDots(frame.dots, dark: dark)
    }
}
