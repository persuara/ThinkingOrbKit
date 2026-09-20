//
// EngineTests.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
//
//  Unit tests for the engine's building blocks. Many of these assert the worked
//  examples written into the doc comments, so the documentation cannot drift
//  away from the behaviour.
//

import Foundation
import SwiftUI
import Testing
import simd

@testable import ThinkingOrbKit

/// Deterministic pseudo-random numbers (SplitMix64), so failures are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

@Suite("Depth sort and frame assembly")
struct FrameAssemblyTests {
    /// `finalizeFrame` must equal a reference STABLE sort by z (ties keep generation
    /// order) for every size — including both sides of the small-array shortcut.
    @Test("depth sort is stable for every size and tie pattern")
    func stableSort() {
        var rng = SeededGenerator(state: 42)
        let sizes = Array(0...70) + [127, 128, 129, 255, 256, 257, 566, 1000]
        for n in sizes {
            for zLevels in [1, 2, 3, 7, 50, 100_000] {  // 1 level = every dot tied
                for _ in 0..<6 {
                    // The original index is stored in `x`, so stability is checkable exactly.
                    let dots = (0..<n).map { i in
                        Dot(x: Double(i), y: 0, z: Double(Int.random(in: 0..<zLevels, using: &rng)), r: 1, white: 0)
                    }
                    let got = finalizeFrame(dots: dots).dots.map { Int($0.x) }
                    let expected = dots.indices.sorted { (dots[$0].z, $0) < (dots[$1].z, $1) }
                    #expect(got == expected, "n=\(n) zLevels=\(zLevels)")
                }
            }
        }
    }

    @Test("dots below alpha 0.02 are culled and radii clamped to the floor")
    func cullAndClamp() {
        let dots = [
            Dot(x: 0, y: 0, z: 1, r: 0.01, white: 0, a: 0.01),  // culled
            Dot(x: 1, y: 0, z: 0, r: 0.01, white: 0, a: 1),  // raised to rMin
            Dot(x: 2, y: 0, z: -1, r: 5, white: 0, a: 0.02),  // kept: exactly at the threshold
        ]
        let frame = finalizeFrame(dots: dots, rMin: 0.3)
        #expect(frame.dots.map { Int($0.x) } == [2, 1])  // far → near
        #expect(frame.dots.map(\.r) == [5, 0.3])
    }
}

@Suite("Math primitives (doc-comment examples)")
struct PrimitiveTests {
    @Test("hashD is deterministic and matches the documented values")
    func hash() {
        #expect(close(hashD(0, 1.7), 0.9343791858918848))
        #expect(close(hashD(1, 1.7), 0.9061869287324953))
        #expect(hashD(0, 0) == 0)
        for a in 0..<50 { #expect((0..<1).contains(hashD(Double(a), 3.3))) }
    }

    @Test("Fibonacci lattice, n = 4")
    func fibonacci() {
        let expected: [(Double, Double, Double)] = [
            (0.661, 0.750, 0.000), (-0.714, 0.250, 0.654), (0.085, -0.250, -0.965), (0.402, -0.750, 0.525),
        ]
        for (i, e) in expected.enumerated() {
            let p = fibDir(i, of: 4)
            #expect(close(p.x, e.0, 1e-3) && close(p.y, e.1, 1e-3) && close(p.z, e.2, 1e-3), "i=\(i)")
            #expect(close(length(p), 1))  // on the unit sphere
        }
    }

    @Test("angleDelta takes the short way round")
    func angles() {
        #expect(close(angleDelta(0.1, 2 * .pi - 0.1), 0.2))
        #expect(close(angleDelta(3.0, -3.0), 6 - 2 * .pi))
    }

    @Test("Projector: yaw, tilt and screen mapping")
    func projector() {
        let centre = SIMD2<Double>(32, 32)
        func project(_ p: SIMD3<Double>, yaw: Double, tilt: Double) -> SIMD3<Double> {
            Projector(yaw: yaw, tilt: tilt, center: centre, scale: 24)(p)
        }
        #expect(project([1, 0, 0], yaw: 0, tilt: 0) == [56, 32, 0])  // right edge
        #expect(project([0, 0, 1], yaw: 0, tilt: 0) == [32, 32, 1])  // straight at the viewer
        let swung = project([1, 0, 0], yaw: .pi / 2, tilt: 0)  // yaw swings it to the back
        #expect(close(swung.x, 32) && close(swung.y, 32) && close(swung.z, -1))
        let pole = project([0, 1, 0], yaw: 0, tilt: 0.4)  // tipped toward the viewer
        #expect(close(pole.y, 32 - 24 * cos(0.4)) && close(pole.z, sin(0.4)))
    }

    @Test("radiusScale is sub-linear, so small orbs keep legible dots")
    func radiusScaling() {
        #expect(close(radiusScale(size: 300, exponent: 0.6), 1))
        #expect(close(radiusScale(size: 64, exponent: 0.6), 0.3958, 1e-4))
        #expect(close(radiusScale(size: 20, exponent: 0.6), 0.1969, 1e-4))
    }

    @Test("ink alpha is clamped to 0…1, as CSS rgba() does on the web")
    @available(macOS 14, iOS 17, *)
    func inkAlphaClamped() {
        let env = EnvironmentValues()
        #expect(inkColor(white: 0, alpha: 1.0148, dark: false).resolve(in: env).opacity == 1)
        #expect(inkColor(white: 0, alpha: -0.2, dark: false).resolve(in: env).opacity == 0)
        #expect(inkColor(white: 0, alpha: 0.4, dark: false).resolve(in: env).opacity == 0.4)
    }

    @Test("smooth value noise stays in range and hits the corner hash at integers")
    func noise() {
        for i in 0..<200 {
            let v = vnoise(Double(i) * 0.37, Double(i) * 0.61)
            #expect((0...1).contains(v))
        }
        #expect(close(vnoise(3, 5), hashD(3, 5)))
    }
}

@Suite("Preset scaling (doc-comment examples)")
struct ScalingTests {
    @Test("globe at 64: √-paired lattice scaling")
    func globeCounts() {
        let base = ModeKey.globe.baseProfile
        let scaled = scaleCounts(base, by: 0.42)
        #expect(scaled[.latRings] == 11)  // 17 × 0.648 = 11.02
        #expect(scaled[.lonDensity] == 29)  // 44 × 0.648 = 28.52
    }

    @Test("an explicit 0 layer is never resurrected")
    func zeroStaysZero() {
        #expect(ModeKey.ring.baseProfile[.ghostN] == 0)
        #expect(scaleCounts(ModeKey.ring.baseProfile, by: 0.25)[.ghostN] == 0)
    }

    @Test("radius scaling multiplies every radius key and records the factor")
    func radii() throws {
        let scaled = scaleRadii(ModeKey.globe.baseProfile, by: 1.15)
        #expect(close(try #require(scaled[.rBase]), 0.69))
        #expect(close(try #require(scaled[.rDepth]), 1.955))
        #expect(scaled[.rSizeMul] == 1.15)
    }

    @Test("every state maps to a mode and every preset resolves")
    func allPresetsResolve() {
        for state in OrbState.allCases {
            for size in [OrbSize.px20, .px64, 8, 40, 300] {
                let resolved = Resolved(state: state, size: size)
                #expect(resolved.mode == state.mode)
                #expect(resolved.speed > 0)
                #expect(!resolved.opts.values.isEmpty)
            }
        }
    }
}
