//
// Registry.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/engine/registry.ts
//
//  Mode key → geometry builder.
//
//  The TypeScript builds `MODE_FRAMES` and `MODE_DRAWS` as lookup tables
//  (`Record<ModeKey, …>` / `Object.fromEntries`). In Swift the same mapping is
//  a `switch` on the enum: the compiler proves every mode is handled, there is
//  no optional to unwrap, and there is no need for a second "draws" table.
//  Drawing a frame is `GraphicsContext.paint(_:dark:)` (see Core.swift).
//

import Foundation
import SwiftUI

extension ModeKey {
    /// The mode's geometry for one instant, BEFORE culling, clamping and depth
    /// sorting: dots in stable generation order (see `RawFrame`).
    func rawFrame(size: Double, time t: Double, options opts: ModeOpts) -> RawFrame {
        switch self {
        case .orbits: frameOrbits(size: size, time: t, options: opts)
        case .globe: frameGlobe(size: size, time: t, options: opts)
        case .rubik: frameRubik(size: size, time: t, options: opts)
        case .wave: frameWave(size: size, time: t, options: opts)
        case .web: frameWeb(size: size, time: t, options: opts)
        case .braid: frameBraid(size: size, time: t, options: opts)
        case .ribbon: frameRibbon(size: size, time: t, options: opts)
        // ring shares ribbon's geometry — the `faceOn` profile flag switches it
        case .ring: frameRibbon(size: size, time: t, options: opts)
        case .morph: frameMorph(size: size, time: t, options: opts)
        }
    }

    /// Geometry for one instant: pure math over (size, t, opts), no rendering
    /// surface and no theme — `dark` only affects ink at paint time.
    ///
    /// The portable surface: pure geometry, no canvas. A finished frame:
    /// culled, clamped and z-sorted into draw order.
    func frame(size: Double, time t: Double, options opts: ModeOpts) -> OrbFrame {
        finalizeFrame(rawFrame(size: size, time: t, options: opts))
    }
}
