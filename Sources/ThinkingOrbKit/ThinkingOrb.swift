//
// ThinkingOrb.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/ThinkingOrb.tsx
//
//  The ThinkingOrb view.
//
//  One shared clock keeps every orb in phase. `TimelineView(.animation)`
//  supplies the frames and pauses itself while the view is off-screen, which
//  replaces the web's IntersectionObserver / visibilitychange plumbing.
//  Reduce Motion users get a static representative frame that still follows
//  the live color scheme.
//
//      ThinkingOrb(state: .searching, size: .px64)
//      ThinkingOrb(state: .working, size: .px20, theme: .dark, speed: 1.5)
//

import SwiftUI

/// The web uses `performance.now()`: milliseconds since page load, shared by
/// every canvas. This is the same idea — seconds since first use, shared by
/// every orb, so instances started at different times stay in phase.
enum OrbClock {
    private static let origin = Date()

    static func seconds(at date: Date) -> Double {
        date.timeIntervalSince(origin)
    }
}

/// A dotted, depth-shaded 3D "thinking" indicator.
///
///     ThinkingOrb(state: .searching)                      // 64 pt
///     ThinkingOrb(state: .working, size: .px20)           // inline with text
///     ThinkingOrb(state: .shaping, theme: .dark, speed: 1.5)
///
/// It draws itself with a SwiftUI `Canvas` inside a `TimelineView`, so it needs
/// no assets and pauses on its own while off-screen. With Reduce Motion on it
/// shows one still frame.
public struct ThinkingOrb: View {
    private let state: OrbState
    private let size: OrbSize
    private let theme: OrbTheme
    private let speed: Double
    private let paused: Bool

    /// - Parameters:
    ///   - state: Which animation to show.
    ///   - size: `.px64` or `.px20` (the two hand-tuned designs), or any custom
    ///     size such as `40`. See ``OrbSize`` for how other sizes are derived.
    ///   - theme: `.auto` follows the ambient color scheme; `.dark` / `.light`
    ///     pin the palette.
    ///   - speed: Animation speed multiplier on top of the preset's baked speed.
    ///   - paused: Freeze the animation on the current frame.
    public init(
        state: OrbState = .working,
        size: OrbSize = .px64,
        theme: OrbTheme = .auto,
        speed: Double = 1,
        paused: Bool = false
    ) {
        self.state = state
        self.size = size
        self.theme = theme
        self.speed = speed
        self.paused = paused
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let resolved = Resolved(state: state, size: size)
        let dark = theme.isDark(in: colorScheme)

        Group {
            if reduceMotion {
                // reduced motion → one static, deterministic frame
                orbCanvas(resolved, t: 0.6, dark: dark)
            } else {
                TimelineView(.animation(paused: paused)) { timeline in
                    // t = seconds · presetSpeed · userSpeed — the single number every
                    // mode animates from. At 60 fps t advances by
                    // (1/60)·presetSpeed·speed per frame; e.g. searching@64 gives
                    // 0.0336 per frame, since its preset speed is 2.015.
                    let t = OrbClock.seconds(at: timeline.date) * resolved.speed * speed
                    orbCanvas(resolved, t: t, dark: dark)
                }
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    private func orbCanvas(_ resolved: Resolved, t: Double, dark: Bool) -> some View {
        let side = Double(size.points)
        return Canvas { context, _ in
            context.paint(resolved.mode.frame(size: side, time: t, options: resolved.opts), dark: dark)
        }
    }
}
