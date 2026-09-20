//
// Theme.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
// PORTED FROM src/theme.ts
//
//  Theme resolution. The web needs a MutationObserver
//  and matchMedia listeners to stay live; in SwiftUI the environment already
//  is that live source, so resolution collapses to a pure function.
//

import SwiftUI

extension OrbTheme {
    /// Resolve the effective dark/light substrate: an explicit theme wins,
    /// `auto` follows the ambient color scheme.
    func isDark(in colorScheme: ColorScheme) -> Bool {
        switch self {
        case .dark: true
        case .light: false
        case .auto: colorScheme == .dark
        }
    }
}
