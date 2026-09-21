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
///
/// Change `state` and the orb morphs seamlessly into the new one; see
/// ``OrbTransition``.
///
/// Pass `tint` to draw in a colour instead of gray:
///
///     ThinkingOrb(state: .searching, tint: .blue)
///
/// Depth is still shown by strength — near dots are the full tint, far dots fade
/// toward the background — so it reads on light, dark and coloured backgrounds
/// alike, and `theme` no longer matters.
public struct ThinkingOrb: View {
    private let state: OrbState
    private let size: OrbSize
    private let theme: OrbTheme
    private let tint: Color?
    private let speed: Double
    private let paused: Bool
    private let transition: OrbTransition

    /// The state whose animation is on screen, or that a morph is heading for.
    ///
    /// It follows `state` one update late, on purpose: the update in which `state`
    /// changes still draws the OLD orb, and `onChange` then starts the morph. Drawing
    /// the new state straight away would flash it for a frame before the morph began.
    @State private var displayed: OrbState
    /// The morph in progress, if any.
    @State private var inFlight: ActiveTransition?

    /// - Parameters:
    ///   - state: Which animation to show.
    ///   - size: `.px64` or `.px20` (the two hand-tuned designs), or any custom
    ///     size such as `40`. See ``OrbSize`` for how other sizes are derived.
    ///   - theme: `.auto` follows the ambient color scheme; `.dark` / `.light`
    ///     pin the palette. Ignored when `tint` is set.
    ///   - tint: The ink colour. `nil` (the default) keeps the gray ink that
    ///     follows `theme`. With a colour, dots are drawn in it, near ones strong
    ///     and far ones faint, on any background — see the type's documentation.
    ///   - speed: Animation speed multiplier on top of the preset's baked speed.
    ///   - paused: Freeze the animation on the current frame.
    ///   - transition: How to change when `state` changes: morph seamlessly (the
    ///     default) or switch instantly.
    public init(
        state: OrbState = .working,
        size: OrbSize = .px64,
        theme: OrbTheme = .auto,
        tint: Color? = nil,
        speed: Double = 1,
        paused: Bool = false,
        transition: OrbTransition = .morph()
    ) {
        self.state = state
        self.size = size
        self.theme = theme
        self.tint = tint
        self.speed = speed
        self.paused = paused
        self.transition = transition
        _displayed = State(initialValue: state)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let dark = theme.isDark(in: colorScheme)

        Group {
            if reduceMotion {
                // reduced motion → one static, deterministic frame of the CURRENT state
                let resolved = Resolved(state: state, size: size)
                orbCanvas(resolved.mode.frame(size: Double(size.points), time: 0.6, options: resolved.opts), dark: dark)
            } else {
                let resolved = Resolved(state: displayed, size: size)
                let morph = inFlight
                TimelineView(.animation(paused: paused)) { timeline in
                    let elapsed = OrbClock.seconds(at: timeline.date)
                    // t = seconds · presetSpeed · userSpeed — the single number every
                    // mode animates from. At 60 fps t advances by
                    // (1/60)·presetSpeed·speed per frame; e.g. searching@64 gives
                    // 0.0336 per frame, since its preset speed is 2.015.
                    let frame =
                        morph?.frame(at: elapsed, speed: speed)
                        ?? resolved.mode.frame(
                            size: Double(size.points), time: elapsed * resolved.speed * speed, options: resolved.opts)
                    orbCanvas(frame, dark: dark)
                }
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
        .onChange(of: state) { newState in
            changeState(to: newState)
        }
        // a different size means different presets: the morph's dot pairing no longer applies
        .onChange(of: size) { _ in
            inFlight = nil
        }
        // Reduce Motion turning on mid-morph: settle on the current state
        .onChange(of: reduceMotion) { _ in
            inFlight = nil
            displayed = state
        }
    }

    private func orbCanvas(_ frame: OrbFrame, dark: Bool) -> some View {
        let tint = tint
        return Canvas { context, _ in
            context.paint(frame, dark: dark, tint: tint)
        }
    }

    /// `state` just changed: start a morph, or switch instantly.
    private func changeState(to newState: OrbState) {
        guard newState != displayed else { return }

        guard case .morph(let duration) = transition, duration > 0, !reduceMotion, !paused else {
            inFlight = nil
            displayed = newState
            return
        }

        let now = OrbClock.seconds(at: Date())
        let source: ActiveTransition.Source
        if let running = inFlight, running.progress(at: now) < 1 {
            // interrupted mid-morph: start from exactly the picture on screen
            source = .snapshot(running.rawFrame(at: now, speed: speed))
        } else {
            source = .state(Resolved(state: displayed, size: size))
        }
        inFlight = ActiveTransition(
            from: source,
            to: Resolved(state: newState, size: size),
            size: Double(size.points),
            startingAt: now,
            speed: speed,
            duration: duration
        )
        displayed = newState
    }
}
