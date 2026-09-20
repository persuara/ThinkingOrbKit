//
// Types.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/types.ts
//
//  Public vocabulary of the orb.
//

import Foundation

/// The nine shipped states — each a hand-tuned animation:
/// - `working`    — particles on tilted orbits
/// - `searching`  — a scan meridian sweeps a dotted globe
/// - `solving`    — bands scramble in quarter turns, then click back
/// - `listening`  — a waveform rolls through latitude rings
/// - `connecting` — a constellation wires itself, packets running the edges
/// - `weaving`    — three strands plait around the sphere
/// - `composing`  — an undulating multi-band sash
/// - `breathing`  — a face-on ring slowly morphing
/// - `shaping`    — a dotted outline morphs circle → triangle → square
public enum OrbState: String, CaseIterable, Identifiable, Sendable {
    case working
    case searching
    case solving
    case listening
    case connecting
    case weaving
    case composing
    case breathing
    case shaping

    public var id: String { rawValue }

    /// Accessibility label (`breathing` reads as "Thinking…", as on the web).
    public var label: String {
        switch self {
        case .working: "Working…"
        case .searching: "Searching…"
        case .solving: "Solving…"
        case .listening: "Listening…"
        case .connecting: "Connecting…"
        case .weaving: "Weaving…"
        case .composing: "Composing…"
        case .breathing: "Thinking…"
        case .shaping: "Shaping…"
        }
    }
}

/// The rendered size of an orb, in points (orbs are square).
///
///     ThinkingOrb(state: .working, size: .px64)   // tuned: chat-avatar scale
///     ThinkingOrb(state: .working, size: .px20)   // tuned: inline-text scale
///     ThinkingOrb(state: .working, size: 40)      // any size, by literal…
///     ThinkingOrb(state: .working, size: OrbSize(40))   // …or explicitly
///
/// Exactly two sizes are hand-tuned — 64 and 20. Each carries its own dot count,
/// dot size and speed: they are separate designs, not a scale factor. Any other
/// size is derived from them:
///
/// - **Between 20 and 64 pt** the two tunings are blended, so a 40 pt orb sits
///   smoothly between the 20 pt and 64 pt looks.
/// - **Outside that range** the nearest tuning is used unchanged, drawn at the
///   size you asked for. The engine scales dot radii sub-linearly with size, so
///   small orbs stay legible, but these sizes were not hand-tuned: very large
///   orbs look sparser than the 64 pt design, and very small ones coarser.
public struct OrbSize: Hashable, Sendable {
    /// Side length in points. Always finite and at least 1.
    public let points: CGFloat

    /// A custom size. Values below 1 pt (and non-finite values) are raised to 1.
    public init(_ points: CGFloat) {
        self.points = points.isFinite ? max(1, points) : 1
    }

    /// The tuned chat-avatar size (64 pt).
    public static let px64 = OrbSize(64)
    /// The tuned inline-text size (20 pt).
    public static let px20 = OrbSize(20)
}

/// `ThinkingOrb(state: .working, size: 40)`
extension OrbSize: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self.init(CGFloat(value)) }
}

/// `ThinkingOrb(state: .working, size: 36.5)`
extension OrbSize: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self.init(CGFloat(value)) }
}

/// Theme mode.
///
/// - `auto` (default) follows the SwiftUI `colorScheme` environment.
/// - `dark` / `light` pin the palette regardless of context.
///
/// Dark renders light ink on the transparent canvas (for dark backgrounds);
/// light renders dark ink (for light backgrounds).
public enum OrbTheme: Sendable {
    case auto
    case dark
    case light
}
