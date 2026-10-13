//
// NegativeTimeTests.swift
//  ThinkingOrb
//
//  Regression: every state must draw at a negative time without trapping.
//
//  The first frame an orb draws can land a few milliseconds BEFORE the shared
//  clock's origin, because `OrbClock.origin` is created lazily by that same
//  first read, after the timeline has already stamped its frame date. The
//  modes that turn time into an array index — shaping (`frameMorph`) and
//  solving (`SolveCycle`) — trapped on that negative time.
//

import Foundation
import Testing

@testable import ThinkingOrbKit

@Suite("Negative time")
struct NegativeTimeTests {

    @Test("every state, both tuned sizes, draws at negative times", arguments: OrbState.allCases)
    func everyStateSurvivesNegativeTime(state: OrbState) {
        for size in [OrbSize.px20, OrbSize.px64] {
            let resolved = Resolved(state: state, size: size)
            for t in [-0.001, -0.016, -1.0, -7.3, -1_000.5] {
                let frame = resolved.mode.frame(size: Double(size.points), time: t, options: resolved.opts)
                #expect(!frame.dots.isEmpty, "\(state) at \(size.points)pt, t = \(t)")
            }
        }
    }

    @Test("the clock never reports time before its origin")
    func clockIsNeverNegative() {
        let early = Date(timeIntervalSinceNow: -0.05)
        #expect(OrbClock.seconds(at: early) >= 0)
    }
}
