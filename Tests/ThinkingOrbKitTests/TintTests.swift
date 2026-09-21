//
// TintTests.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
//
//  The optional tint colour. The gray ink of an orb is really "black on light /
//  white on dark" at a depth-driven strength, and a tint replaces that fixed ink
//  colour. These pin that reading down with numbers.
//

import CoreGraphics
import SwiftUI
import Testing

@testable import ThinkingOrbKit

/// A colour as (red, green, blue, opacity) in gamma-encoded sRGB.
@available(macOS 14, iOS 17, *)
private func srgb(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = color.resolve(in: EnvironmentValues()).cgColor
    let c = cg.converted(to: space, intent: .defaultIntent, options: nil)!.components!
    return (Double(c[0]), Double(c[1]), Double(c[2]), Double(c[3]))
}

/// One colour composited over a solid gray backdrop (in sRGB, as the screen does).
@available(macOS 14, iOS 17, *)
private func over(_ color: Color, backdrop: Double) -> Double {
    let c = srgb(color)
    // gray inks only: red == green == blue
    return c.r * c.a + backdrop * (1 - c.a)
}

@Suite("Tinted ink")
struct TintTests {
    private let whites = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
    private let alphas = [0.02, 0.3, 0.7, 1.0]

    @Test("a tint keeps its own colour and sets the opacity to alpha × (1 − white)")
    @available(macOS 14, iOS 17, *)
    func opacityIsStrength() {
        let tint = Color(.sRGB, red: 0.2, green: 0.5, blue: 0.9, opacity: 1)
        for w in whites {
            for a in alphas {
                let ink = srgb(inkColor(white: w, alpha: a, dark: false, tint: tint))
                #expect(abs(ink.r - 0.2) < 1e-3 && abs(ink.g - 0.5) < 1e-3 && abs(ink.b - 0.9) < 1e-3, "hue w=\(w)")
                #expect(abs(ink.a - a * (1 - w)) < 1e-3, "opacity w=\(w) a=\(a)")
            }
        }
    }

    @Test("tint = .black over white is the default light theme; tint = .white over black is the default dark theme")
    @available(macOS 14, iOS 17, *)
    func reproducesTheDefaults() {
        for w in whites {
            for a in alphas {
                let lightDefault = over(inkColor(white: w, alpha: a, dark: false), backdrop: 1)
                let lightTint = over(inkColor(white: w, alpha: a, dark: false, tint: .black), backdrop: 1)
                // the default rounds its gray to 8 bits; the tint does not
                #expect(abs(lightDefault - lightTint) <= 0.5 / 255 + 1e-3, "light w=\(w) a=\(a)")

                let darkDefault = over(inkColor(white: w, alpha: a, dark: true), backdrop: 0)
                let darkTint = over(inkColor(white: w, alpha: a, dark: true, tint: .white), backdrop: 0)
                #expect(abs(darkDefault - darkTint) <= 0.5 / 255 + 1e-3, "dark w=\(w) a=\(a)")
            }
        }
    }

    @Test("with a tint, the theme has no effect")
    @available(macOS 14, iOS 17, *)
    func themeIsIgnored() {
        for w in whites {
            let light = srgb(inkColor(white: w, alpha: 0.8, dark: false, tint: .orange))
            let dark = srgb(inkColor(white: w, alpha: 0.8, dark: true, tint: .orange))
            #expect(light == dark, "w=\(w)")
        }
    }

    @Test("near dots are stronger than far dots, and alpha above 1 is clamped")
    @available(macOS 14, iOS 17, *)
    func strengthAndClamping() {
        let near = srgb(inkColor(white: 0.1, alpha: 1, dark: false, tint: .blue)).a
        let far = srgb(inkColor(white: 0.7, alpha: 1, dark: false, tint: .blue)).a
        #expect(near > far)
        // weaving reaches alpha 1.0148 — never more opaque than fully strong
        #expect(srgb(inkColor(white: 0.1, alpha: 1.0148, dark: false, tint: .blue)).a <= 0.9 + 1e-3)
        #expect(srgb(inkColor(white: 0.1, alpha: -1, dark: false, tint: .blue)).a == 0)
    }

    @Test("a tint that is itself translucent stays translucent")
    @available(macOS 14, iOS 17, *)
    func tintOpacityMultiplies() {
        let half = Color.blue.opacity(0.5)
        let ink = srgb(inkColor(white: 0.2, alpha: 1, dark: false, tint: half))
        #expect(abs(ink.a - 0.5 * 0.8) < 1e-3)
    }

    @Test("no tint leaves the default gray ink exactly as it was")
    @available(macOS 14, iOS 17, *)
    func nilTintIsUnchanged() {
        for w in whites {
            for dark in [false, true] {
                let implicit = srgb(inkColor(white: w, alpha: 0.6, dark: dark))
                let explicit = srgb(inkColor(white: w, alpha: 0.6, dark: dark, tint: nil))
                #expect(implicit == explicit)
                #expect(implicit.r == implicit.g && implicit.g == implicit.b)  // still pure gray
            }
        }
    }
}
