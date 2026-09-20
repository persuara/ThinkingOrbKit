//
// Profiles.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/profiles.ts
//
//  Density profiles + the multiplier machinery that scales them.
//  The base rows are inkform's `fine` profiles; each
//  shipped preset (state × size) applies count / radius multipliers on top,
//  resolved once per (state, size).
//
//  ── THE IDEA ─────────────────────────────────────────────────────────────
//  Every mode is authored ONCE as a dense "fine" profile (the tables at the
//  bottom). A 20pt spinner can't show 500 dots, so each (state, size) preset
//  supplies two multipliers:
//      count  — how many dots to keep        (see `scaleCounts`)
//      size   — how big each dot should be   (see `scaleRadii`)
//  and the base profile is run through both. Worked example, "searching" at
//  size 64 (count 0.42, size 1.15):
//      latRings   17 →  11        lonDensity 44 → 29    (476 dots → 204 = ×0.43 ≈ 0.42)
//      rBase     0.6 → 0.69       rDepth    1.7 → 1.955
//

import Foundation

/// Every tunable a mode can read from its profile.
///
/// The TypeScript original keeps these in a `{ [key: string]: number }` bag,
/// where a typo such as `o.rbase ?? 0.6` silently falls back to the default.
/// As an enum the compiler checks every key, `OptKey.allCases` lists them, and
/// the scaling rules below can be written against real types.
///
/// `rawValue` is the original string, so this still round-trips with the JSON
/// spec (`spec/orbs-spec.json`) and the golden vectors.
enum OptKey: String, CaseIterable, Sendable {
    // ── Lattice modes (globe, rubik, wave) ───────────────────────────────
    /// Number of latitude BANDS (globe, rubik); there are (n + 1) rows since
    /// both poles are included (fence-post).
    case latRings
    /// Same as `latRings`, for wave.
    case rings
    /// Dots on the EQUATOR row. A row at latitude φ gets round(|cos φ|·lonDensity),
    /// so dot spacing along every row is about the same (see Lattice.swift).
    case lonDensity
    /// Rubik: number of slab twists in the scramble.
    case moveCount
    /// Rubik: extra radius for the band that is turning right now.
    case rActive
    /// Globe: extra radius on the scanned meridian.
    case rBoost
    /// Ink `white` for the far side; near dots are `inkFar − inkSpan` (0.62 → 0.08).
    case inkFar
    case inkSpan
    /// Globe: how fast the scan sweeps relative to the spin (added by presets).
    case scanMul
    /// Globe: alpha of un-scanned dots, so the meridian pops (added by presets).
    case dimBase

    // ── Orbits ───────────────────────────────────────────────────────────
    /// Number of tilted orbit circles.
    case orbitN
    /// Faint dots tracing each orbit — for `braid` and `ribbon` it is the size
    /// of the ghost reference sphere instead. 0 means "no ghost layer" (ring).
    case ghostN
    /// Ghost dot radius and base alpha (orbits).
    case ghostR
    case ghostA
    /// Bright travellers per orbit; radius = partR + partRDepth·depth.
    case particles
    case partR
    case partRDepth

    // ── Web ──────────────────────────────────────────────────────────────
    /// Constellation nodes; pairs closer than `thr` (chord distance) get an edge.
    case nodeN
    case thr
    /// Bright packets running along node pairs.
    case signals
    /// Node radius = nodeR + nodeRDepth·depth.
    case nodeR
    case nodeRDepth
    /// Edge stroke width.
    case lineW

    // ── Braid ────────────────────────────────────────────────────────────
    /// Dots per strand (there are 3 strands).
    case strandN
    /// Helix revolutions from pole to pole.
    case turns

    // ── Ribbon / ring ────────────────────────────────────────────────────
    /// Parallel strands in the sash × dots per strand.
    case lanes
    case segs
    /// 1 = render as the face-on ring instead of the tilted ribbon.
    case faceOn
    /// Multiplier on the 3D tumble; 0 freezes it (added by presets).
    case spin
    /// Multiplier on the number of lanes (added by presets).
    case bandMul
    /// Multiplier on the undulation depth; 0 is a clean band (added by presets).
    case wobMul

    // ── Morph ────────────────────────────────────────────────────────────
    /// Dot radius as a FRACTION of the frame.
    case rDot
    /// Outline sampling density (a real-valued multiplier, not a count).
    case iconD
    /// Outline scale (added by presets; also read by web for its radius).
    case spread

    // ── Shared ───────────────────────────────────────────────────────────
    /// Dot radius = rBase + rDepth·depth (depth: 0 far … 1 near).
    case rBase
    case rDepth
    /// Exponent of `radiusScale`, and the smallest radius a dot may have.
    case rsPow
    case rMin
    /// Bookkeeping: the product of every `scaleRadii` multiplier applied.
    case rSizeMul
}

/// The TypeScript `ModeOpts` bag, keyed by `OptKey`. Read with a default, the
/// same way the original does:  `o[.rBase] ?? 0.6`.
struct ModeOpts: Sendable, ExpressibleByDictionaryLiteral {
    var values: [OptKey: Double]

    init(_ values: [OptKey: Double] = [:]) {
        self.values = values
    }

    init(dictionaryLiteral elements: (OptKey, Double)...) {
        self.values = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    subscript(key: OptKey) -> Double? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// `{ ...self, ...other }`
    func merging(_ other: ModeOpts) -> ModeOpts {
        ModeOpts(values.merging(other.values, uniquingKeysWith: { _, new in new }))
    }
}

// 2-D lattices (rings × dots-per-ring) come in pairs — each side takes
// √scale so the TOTAL dot count scales by `scale`; flat lists scale
// linearly. `iconD` sets the morph outline's sampling density.
private let countPairs: [(OptKey, OptKey)] = [
    (.latRings, .lonDensity),
    (.rings, .lonDensity),
    (.lanes, .segs),
]
private let countKeys: [OptKey] = [.orbitN, .ghostN, .nodeN, .strandN, .signals]
private let iconDensityKeys: [OptKey] = [.iconD]

// Every key that sets a dot's rendered radius — scaling all of them keeps
// a dot's near/far falloff intact while shrinking or growing the mark.
private let radiusKeys: [OptKey] = [
    .rBase,
    .rDepth,
    .rActive,
    .rDot,
    .ghostR,
    .partR,
    .partRDepth,
    .nodeR,
    .nodeRDepth,
]

/// Scale how MANY dots a profile produces by `scale` (the preset's `count`).
///
/// THREE RULES, because dot count grows differently per key:
///
///  1. PAIRS (rows × columns). A lattice with R rows and C columns has ≈ R·C
///     dots. To scale the TOTAL by s, scale EACH side by √s, since
///     (R√s)·(C√s) = R·C·s. Each side is rounded and floored at 2.
///        s = 0.42 → √s = 0.648
///        latRings   17 × 0.648 = 11.02 → 11
///        lonDensity 44 × 0.648 = 28.52 → 29
///     Pairs: (latRings, lonDensity)  (rings, lonDensity)  (lanes, segs).
///     `lonDensity` is in two pairs; the `done` set makes sure it is only
///     scaled by the FIRST pair that owns it, never twice.
///
///  2. FLAT LISTS scale linearly (n × s, min 1): orbitN, ghostN, nodeN,
///     strandN, signals.
///        composing @64, s = 0.25:  ghostN 150 × 0.25 = 37.5 → 38  (.rounded(): ties go up)
///        connecting @64, s = 1.35: nodeN 30 × 1.35 = 40.5 → 41, signals 5 → 7
///     EXCEPTION: an explicit 0 stays 0. "breathing" has ghostN = 0 (no ghost
///     sphere); without this rule it would be rescaled to max(1, 0) = 1 and a
///     stray dot would appear.
///
///  3. `iconD` (morph outline density) is a real-valued multiplier, kept as a
///     float and floored at 0.02:   iconD 1 × 0.702 = 0.702.
func scaleCounts(_ opts: ModeOpts, by scale: Double) -> ModeOpts {
    var out = opts
    var done = Set<OptKey>()
    let rt = scale.squareRoot()
    for (a, b) in countPairs {
        if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
            out[a] = max(2, (va * rt).rounded())
            out[b] = max(2, (vb * rt).rounded())
            done.insert(a)
            done.insert(b)
        }
    }
    for k in countKeys {
        // 0 means the mode opted out of that layer entirely (ring has no ghost
        // sphere) — scaling must not resurrect it as a single stray dot
        if let v = out[k], v != 0, !done.contains(k) {
            out[k] = max(1, (v * scale).rounded())
        }
    }
    for k in iconDensityKeys {
        if let v = out[k] { out[k] = max(0.02, v * scale) }
    }
    return out
}

/// Scale how BIG each dot is by `scale` (the preset's `size`).
///
/// Every radius key is multiplied by the same factor, so a dot's near/far
/// falloff `rBase + rDepth·depth` keeps its shape — the whole ramp just gets
/// taller or shorter:
///     size 1.15:  rBase 0.6 → 0.69     rDepth 1.7 → 1.955
///     far dot  (depth 0):  0.6        → 0.69
///     near dot (depth 1):  0.6 + 1.7  → 0.69 + 1.955 = 2.645   (= 2.3 × 1.15)
/// `rSizeMul` records the factor itself for the morph mode, whose radius is
/// derived from dot SPACING rather than any single radius key (they multiply
/// if scaled twice).
func scaleRadii(_ opts: ModeOpts, by scale: Double) -> ModeOpts {
    var out = opts
    for k in radiusKeys {
        if let v = out[k] { out[k] = v * scale }
    }
    // remember the multiplier itself — spacing-derived radii (the morph
    // outline) use it, since they aren't based on any single radius key
    out[.rSizeMul] = (out[.rSizeMul] ?? 1) * scale
    return out
}

extension ModeKey {
    /// Base (fine) profile for this mode, before the preset multipliers.
    /// A `switch`, so every mode is guaranteed to have one (no optional lookup).
    var baseProfile: ModeOpts {
        switch self {
        case .globe:
            return [
                .latRings: 17,
                .lonDensity: 44,
                .rBase: 0.6,
                .rDepth: 1.7,
                .rBoost: 1.0,
                .inkFar: 0.62,
                .inkSpan: 0.54,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .orbits:
            return [
                .orbitN: 12,
                .ghostN: 40,
                .ghostR: 0.9,
                .ghostA: 0.5,
                .particles: 3,
                .partR: 1.2,
                .partRDepth: 1.6,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .rubik:
            return [
                .latRings: 15,
                .lonDensity: 40,
                .moveCount: 14,
                .rBase: 0.6,
                .rDepth: 1.7,
                .rActive: 0.3,
                .inkFar: 0.62,
                .inkSpan: 0.54,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .wave:
            return [
                .rings: 15,
                .lonDensity: 40,
                .rBase: 0.6,
                .rDepth: 1.7,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .web:
            return [
                .nodeN: 30,
                .thr: 0.72,
                .signals: 5,
                .nodeR: 1.4,
                .nodeRDepth: 1.8,
                .lineW: 0.8,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .braid:
            return [
                .strandN: 52,
                .turns: 3.0,
                .ghostN: 150,
                .rBase: 1.2,
                .rDepth: 1.8,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .ribbon:
            return [
                .lanes: 5,
                .segs: 88,
                .ghostN: 150,
                .rBase: 1.1,
                .rDepth: 1.7,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        // ring shares ribbon's painter; faceOn cancels the camera tilt and moves
        // the undulation onto the radius, and there is no ghost sphere behind it
        case .ring:
            return [
                .lanes: 5,
                .segs: 88,
                .ghostN: 0,
                .faceOn: 1,
                .rBase: 1.1,
                .rDepth: 1.7,
                .rsPow: 0.6,
                .rMin: 0.3,
            ]
        case .morph:
            return [
                .rDot: 0.021,
                .iconD: 1,
                .rMin: 0.25,
            ]
        }
    }
}
