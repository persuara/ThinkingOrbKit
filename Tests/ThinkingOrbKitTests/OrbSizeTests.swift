//
// OrbSizeTests.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
//
//  The public `OrbSize` type and how a preset is derived for an arbitrary size.
//

import CoreGraphics
import Foundation
import Testing

@testable import ThinkingOrbKit

@Suite("OrbSize")
struct OrbSizeTests {
    @Test("the tuned constants are just 64 and 20 points")
    func tunedConstants() {
        #expect(OrbSize.px64.points == 64)
        #expect(OrbSize.px20.points == 20)
        #expect(OrbSize.px64 == OrbSize(64))
    }

    @Test("integer and float literals make a custom size")
    func literals() {
        let integer: OrbSize = 40
        let fractional: OrbSize = 36.5
        #expect(integer.points == 40)
        #expect(fractional.points == 36.5)
        #expect(integer == OrbSize(40))
    }

    @Test("nonsense sizes are raised to 1pt instead of crashing or producing NaN geometry")
    func sanitising() {
        for bad: CGFloat in [0, -5, -.infinity, .infinity, .nan, 0.2] {
            #expect(OrbSize(bad).points == 1, "OrbSize(\(bad))")
        }
        #expect(OrbSize(1).points == 1)
        #expect(OrbSize(1000).points == 1000)
    }
}

@Suite("Presets for arbitrary sizes")
struct CustomSizePresetTests {
    /// Sizes at, between and far beyond the two tuned ones.
    static let sizes: [Double] = [1, 4, 8, 12, 16, 20, 24, 33, 40, 50, 64, 90, 128, 300, 1000]

    @Test("at exactly 20 and 64 the hand-tuned presets come back untouched")
    func anchorsAreExact() {
        // (Resolved at the tuned sizes is also pinned to the TypeScript reference by
        // the golden tests; this checks the blend function's endpoints directly.)
        for mode in ModeKey.allCases {
            let small = mode.preset(forPoints: 20)
            let large = mode.preset(forPoints: 64)
            #expect(Preset.blended(small, large, t: 0).count == small.count)
            #expect(Preset.blended(small, large, t: 1).count == large.count)
            #expect(Preset.blended(small, large, t: 0).extra?.values == small.extra?.values)
            #expect(Preset.blended(small, large, t: 1).extra?.values == large.extra?.values)
        }
    }

    @Test("outside 20…64 the nearest tuning is used unchanged", arguments: ModeKey.allCases)
    func clampedOutsideRange(mode: ModeKey) {
        let small = mode.preset(forPoints: 20)
        let large = mode.preset(forPoints: 64)
        for points in [1.0, 8, 19.99] {
            let p = mode.preset(forPoints: points)
            #expect(p.speed == small.speed && p.count == small.count && p.size == small.size)
        }
        for points in [64.01, 100, 300, 5000] {
            let p = mode.preset(forPoints: points)
            #expect(p.speed == large.speed && p.count == large.count && p.size == large.size)
        }
    }

    @Test("halfway in log-size is the geometric mean of the multipliers", arguments: ModeKey.allCases)
    func geometricMidpoint(mode: ModeKey) {
        let small = mode.preset(forPoints: 20)
        let large = mode.preset(forPoints: 64)
        let midpoint = 20 * (64.0 / 20).squareRoot()  // t = 0.5 exactly
        let p = mode.preset(forPoints: midpoint)
        #expect(abs(p.count - (small.count * large.count).squareRoot()) < 1e-12)
        #expect(abs(p.size - (small.size * large.size).squareRoot()) < 1e-12)
        #expect(abs(p.speed - (small.speed * large.speed).squareRoot()) < 1e-12)
        // extras blend linearly
        for (key, value) in small.extra?.values ?? [:] {
            let other = large.extra?[key] ?? value
            #expect(abs((p.extra?[key] ?? .nan) - (value + other) / 2) < 1e-12, "extra \(key)")
        }
    }

    @Test("blended multipliers stay between the two tunings, and vary smoothly", arguments: ModeKey.allCases)
    func betweenAndMonotone(mode: ModeKey) {
        let small = mode.preset(forPoints: 20)
        let large = mode.preset(forPoints: 64)
        var previous = mode.preset(forPoints: 20)
        for points in stride(from: 21.0, through: 64.0, by: 1) {
            let p = mode.preset(forPoints: points)
            for (value, a, b) in [(p.count, small.count, large.count), (p.size, small.size, large.size),
                                  (p.speed, small.speed, large.speed)] {
                #expect(value >= min(a, b) - 1e-12 && value <= max(a, b) + 1e-12)
            }
            // no jumps: each 1pt step changes a multiplier by less than 10 %
            #expect(abs(p.count / previous.count - 1) < 0.10)
            #expect(abs(p.size / previous.size - 1) < 0.10)
            previous = p
        }
    }
}

@Suite("Rendering at any size")
struct CustomSizeRenderingTests {
    @Test("every state yields a finite, non-empty, in-bounds frame at every size",
          arguments: OrbState.allCases)
    func rendersSanely(state: OrbState) {
        for points in CustomSizePresetTests.sizes {
            let resolved = Resolved(state: state, size: OrbSize(CGFloat(points)))
            for t in [0.0, 0.6, 3.3, 17.0] {
                let frame = resolved.mode.frame(size: points, time: t, options: resolved.opts)
                #expect(!frame.dots.isEmpty, "\(state) @\(points) t=\(t)")
                for dot in frame.dots {
                    #expect(dot.x.isFinite && dot.y.isFinite && dot.z.isFinite && dot.r.isFinite)
                    // alpha may exceed 1 slightly (weaving reaches 1.0148 in the TypeScript
                    // reference too); the painter clamps it. Anything far above 1 is a bug.
                    #expect(dot.r > 0 && dot.a >= 0.02 && dot.a < 1.05)
                    // every mode is designed to sit inside its frame
                    #expect(dot.x >= -0.1 * points - dot.r && dot.x <= 1.1 * points + dot.r, "\(state) @\(points) x=\(dot.x)")
                    #expect(dot.y >= -0.1 * points - dot.r && dot.y <= 1.1 * points + dot.r, "\(state) @\(points) y=\(dot.y)")
                }
            }
        }
    }

    @Test("bigger orbs never have fewer dots than smaller ones between the tunings")
    func densityGrowsWithSize() {
        for state in OrbState.allCases {
            func dots(_ points: CGFloat) -> Int {
                let r = Resolved(state: state, size: OrbSize(points))
                return r.mode.frame(size: Double(points), time: 0.6, options: r.opts).dots.count
            }
            #expect(dots(64) >= dots(20), "\(state)")
        }
    }
}
