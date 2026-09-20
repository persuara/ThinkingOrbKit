//
// Presets.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/presets.ts
//
//  The shipped tunings: nine states × two tuned sizes (20 and 64 pt), baked from
//  the inkform mini-page tuning session. Any other size is blended from those two.
//  `count`/`size` are multipliers over the base fine profiles; `speed`
//  multiplies the shared clock. Resolving a (state, size) pair is pure and
//  cheap (see `Resolved.init(state:size:)`), so the render loop just reads plain numbers.
//

import Foundation

enum ModeKey: String, CaseIterable, Sendable {
    case orbits
    case globe
    case rubik
    case wave
    case web
    case braid
    case ribbon
    case ring
    case morph
}

extension OrbState {
    /// Which mode animates this state. A `switch`, so adding an `OrbState`
    /// without deciding its mode is a compile error (the TypeScript
    /// `Record<OrbState, ModeKey>` gets the same guarantee from the compiler;
    /// a Swift dictionary would not).
    var mode: ModeKey {
        switch self {
        case .working: .orbits
        case .searching: .globe
        case .solving: .rubik
        case .listening: .wave
        case .connecting: .web
        case .weaving: .braid
        case .composing: .ribbon
        case .breathing: .ring
        case .shaping: .morph
        }
    }
}

struct Preset: Sendable {
    var speed: Double
    var count: Double
    var size: Double
    /// Extra mode opts merged verbatim after scaling.
    var extra: ModeOpts? = nil

    /// Blend two tunings: `t = 0` gives `a` exactly, `t = 1` gives `b` exactly.
    ///
    /// `speed`, `count` and `size` are MULTIPLIERS (always > 0), so they are
    /// blended geometrically — `a^(1−t) · b^t`, a straight line in log space.
    /// That is the right notion of "halfway" for a multiplier: halfway between
    /// ×0.1 and ×0.4 is ×0.2, not ×0.25. The extras (`scanMul`, `bandMul`,
    /// `wobMul`, `spread`, …) are plain settings and blend linearly. Every mode
    /// gives both of its sizes the same set of extras; a key present on one
    /// side only is carried over unchanged.
    static func blended(_ a: Preset, _ b: Preset, t: Double) -> Preset {
        if t <= 0 { return a }
        if t >= 1 { return b }
        func geometric(_ x: Double, _ y: Double) -> Double { pow(x, 1 - t) * pow(y, t) }

        let aExtra = a.extra ?? ModeOpts()
        let bExtra = b.extra ?? ModeOpts()
        var extra = ModeOpts()
        for key in Set(aExtra.values.keys).union(bExtra.values.keys) {
            switch (aExtra[key], bExtra[key]) {
            case let (x?, y?): extra[key] = x + (y - x) * t
            case let (x?, nil): extra[key] = x
            case let (nil, y?): extra[key] = y
            case (nil, nil): break
            }
        }
        return Preset(
            speed: geometric(a.speed, b.speed),
            count: geometric(a.count, b.count),
            size: geometric(a.size, b.size),
            extra: extra.values.isEmpty ? nil : extra
        )
    }
}

/// The two sizes the tunings below were authored for.
private enum TunedSize {
    case px20
    case px64

    var points: Double {
        switch self {
        case .px20: 20
        case .px64: 64
        }
    }
}

extension ModeKey {
    /// The baked tunings — three numbers per (mode, size), plus optional extras:
    ///
    ///   speed   multiplies the clock:  t = elapsedSeconds · speed · userSpeed
    ///           Every rate inside a mode is "radians (or laps) per unit of t",
    ///           so speed decides how fast the orb feels. Examples:
    ///             working@64 (speed 1.885): the cluster yaws 0.12 rad per t
    ///                 → 0.12 · 1.885 = 0.226 rad/s → one full turn in 27.8 s
    ///             searching@64 (speed 2.015): spin 0.5 rad per t
    ///                 → 1.0075 rad/s → one revolution every 6.24 s
    ///           `userSpeed` (the view's `speed:` parameter) multiplies on top, so
    ///           speed: 2 halves both periods.
    ///           The 20pt presets are usually FASTER (connecting: 3.315 @64 vs
    ///           6.63 @20) — a tiny orb needs quicker motion to read as alive.
    ///   count   dot-count multiplier → `scaleCounts` (lattice sides scale by √count)
    ///   size    dot-radius multiplier → `scaleRadii`
    ///   extra   options merged verbatim AFTER scaling, e.g. globe's scan speed
    ///           (`scanMul`) or ribbon's `bandMul` / `wobMul`.
    ///
    /// Both sizes are separate designs: searching@20 is a tiny 6-ring lattice with
    /// big dots (count 0.105, size 1.75), not a shrunken copy of searching@64.
    ///
    /// Written as a `switch` over (mode, tuned size): the compiler checks that all
    /// 18 combinations exist, so there is no "missing preset" case to handle.
    fileprivate func preset(for size: TunedSize) -> Preset {
        switch (self, size) {
        case (.orbits, .px64): Preset(speed: 1.885, count: 1, size: 1)
        case (.orbits, .px20): Preset(speed: 3.9, count: 0.238, size: 2.4)

        case (.globe, .px64): Preset(speed: 2.015, count: 0.42, size: 1.15, extra: [.scanMul: 4.08, .dimBase: 0.45])
        case (.globe, .px20): Preset(speed: 2.665, count: 0.105, size: 1.75, extra: [.scanMul: 4.335, .dimBase: 0.45])

        case (.rubik, .px64): Preset(speed: 1.82, count: 0.35, size: 1.05)
        case (.rubik, .px20): Preset(speed: 1.95, count: 0.088, size: 1.9)

        case (.wave, .px64): Preset(speed: 4.388, count: 0.341, size: 1)
        case (.wave, .px20): Preset(speed: 3.998, count: 0.105, size: 1.6)

        case (.web, .px64): Preset(speed: 3.315, count: 1.35, size: 0.95)
        case (.web, .px20): Preset(speed: 6.63, count: 0.25, size: 1.52)

        case (.braid, .px64): Preset(speed: 1.625, count: 0.5, size: 1)
        case (.braid, .px20): Preset(speed: 2.75, count: 0.1125, size: 1.36)

        case (.ribbon, .px64): Preset(speed: 2.34, count: 0.25, size: 0.85, extra: [.spin: 0, .bandMul: 3.9, .wobMul: 1])
        case (.ribbon, .px20): Preset(speed: 3.12, count: 0.051, size: 1.073, extra: [.spin: 0, .bandMul: 4.94, .wobMul: 1])

        case (.ring, .px64): Preset(speed: 3.24, count: 0.25, size: 0.956, extra: [.spin: 0, .bandMul: 3.627, .wobMul: 0.368])
        case (.ring, .px20): Preset(speed: 3.78, count: 0.028, size: 1.622, extra: [.spin: 0, .bandMul: 3.968, .wobMul: 0.565])

        case (.morph, .px64): Preset(speed: 2.405, count: 0.702, size: 0.395, extra: [.spread: 1.45])
        case (.morph, .px20): Preset(speed: 2.08, count: 0.53, size: 1.011, extra: [.spread: 1.45])
        }
    }
}

extension ModeKey {
    /// The preset for ANY size in points.
    ///
    /// The position between the two tunings is measured in LOG size, because
    /// size acts multiplicatively (the engine's own radius scaling is a power of
    /// size):
    ///
    ///     t = ln(points / 20) / ln(64 / 20)        clamped to 0 … 1
    ///
    ///     points:   ≤ 20    32     40      50     ≥ 64
    ///     t:         0     0.40   0.60    0.79     1
    ///
    /// At exactly 20 and 64 this is the hand-tuned preset, untouched. Below 20
    /// and above 64 `t` is clamped, so the nearest tuning is used as is.
    func preset(forPoints points: Double) -> Preset {
        let small = TunedSize.px20.points
        let large = TunedSize.px64.points
        let t = log(points / small) / log(large / small)
        return Preset.blended(preset(for: .px20), preset(for: .px64), t: min(1, max(0, t)))
    }
}

struct Resolved: Sendable {
    var mode: ModeKey
    var speed: Double
    var opts: ModeOpts

    /// Resolve a (state, size) pair to its mode + fully-scaled draw options.
    ///
    /// `size` need not be one of the two tuned sizes: the preset is looked up by
    /// `ModeKey.preset(forPoints:)`, which blends the 20 pt and 64 pt tunings
    /// (and clamps outside that range). At exactly 20 and 64 it is the
    /// hand-tuned preset, untouched.
    ///
    /// Pipeline:  base profile → scaleCounts(count) → scaleRadii(size) → merge extra
    /// (skipping a step when its multiplier is exactly 1). Worked example,
    /// searching@64  (count 0.42, size 1.15, extra scanMul 4.08 / dimBase 0.45):
    ///     base       latRings 17, lonDensity 44, rBase 0.6,  rDepth 1.7
    ///     ×count     latRings 11, lonDensity 29
    ///     ×size      rBase 0.69,  rDepth 1.955, rSizeMul 1.15
    ///     +extra     scanMul 4.08, dimBase 0.45
    ///
    /// The TypeScript memoises this in a `Map` (`resolvePreset`). Here it is
    /// deliberately NOT cached: it is a pure function of two enums that copies a
    /// ~10-entry dictionary a few times. Measured: ≈ 4.6 µs per call optimised,
    /// ≈ 25 µs in a Debug build — versus ≈ 160 µs for a single frame of the
    /// heaviest mode. It only runs when a view's body is re-evaluated, never per
    /// animation frame, because `TimelineView` reuses the value its closure
    /// captured. A cache would need a lock and shared mutable state to save time
    /// nobody can measure.
    init(state: OrbState, size: OrbSize) {
        let mode = state.mode
        let preset = mode.preset(forPoints: Double(size.points))
        var opts = mode.baseProfile
        if preset.count != 1 { opts = scaleCounts(opts, by: preset.count) }
        if preset.size != 1 { opts = scaleRadii(opts, by: preset.size) }
        if let extra = preset.extra { opts = opts.merging(extra) }
        self.mode = mode
        self.speed = preset.speed
        self.opts = opts
    }
}
