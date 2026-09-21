//
// main.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
//
//  Renders the animated GIFs shown in the README — one per state, with the two
//  tuned sizes (64 pt and 20 pt) side by side, plus `morph.gif`, which cycles
//  through several states, each morphing seamlessly into the next, and `tint.png`,
//  a still of the optional tint colour on light and dark backgrounds.
//
//  Frames are computed OFFLINE and deterministically: each one is the engine's
//  own geometry for an exact timestamp, drawn through the same
//  `GraphicsContext.paint` path the SwiftUI view uses, so the GIFs are the real
//  thing rather than a screen recording. Encoding uses ImageIO; nothing needs
//  installing.
//
//  Build and run with `Scripts/render-gifs.sh` (this file is compiled together
//  with the package sources, which is why it can use their internal API).
//
//  Reproducibility: the GEOMETRY is exact (the test suite pins it), but the
//  system rasteriser's anti-aliasing is not bit-stable — regenerating gives GIFs
//  that look identical but differ in a few hundred edge pixels by a few gray
//  levels (measured: at most 9/255), so the files will not be byte-identical.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

/// Frames per second. GIF delays are whole centiseconds, so 25 fps (4 cs) is exact.
let framesPerSecond = 25.0
/// Length of one loop of a single-state GIF, in seconds of real time.
let stateLoopSeconds = 4.0
/// The first part of every loop cross-fades in from the moment just AFTER the loop
/// ends. These animations are not periodic (several unrelated frequencies run at
/// once), so a raw loop would visibly jump; this hides the seam.
let dissolveSeconds = 0.5
/// GitHub's dark-theme page background, so the tile melts into it. GIFs have no
/// partial transparency, so a solid tile is the clean choice on light pages too.
let background = Color(red: 13 / 255, green: 17 / 255, blue: 23 / 255)

/// Layout in points; rendered at 2x. Big orb on the left, small one in the remainder.
let tileSize = CGSize(width: 96, height: 64)
let renderScale = 2.0

/// The states `morph.gif` cycles through, and how long each is held before it
/// morphs into the next, and how long that morph takes.
let showcaseStates: [OrbState] = [.working, .searching, .connecting, .composing, .shaping, .breathing]
let morphHoldSeconds = 0.6
let morphSeconds = 0.9

// MARK: - What a tile shows over time

/// Both sizes of one orb at one instant.
struct Tile {
    var large: OrbFrame
    var small: OrbFrame
}

/// A tile as a function of elapsed seconds.
typealias TileProvider = (Double) -> Tile

/// One state, steady.
func steady(_ state: OrbState) -> TileProvider {
    let large = Resolved(state: state, size: .px64)
    let small = Resolved(state: state, size: .px20)
    return { elapsed in
        Tile(
            large: large.mode.frame(size: 64, time: elapsed * large.speed, options: large.opts),
            small: small.mode.frame(size: 20, time: elapsed * small.speed, options: small.opts))
    }
}

/// `states` in a loop, each held for `hold` seconds and then morphed into the next
/// over `morph` seconds. Periodic in WHICH state is showing; the animations
/// themselves keep running, which is why the GIF still needs its seam dissolve.
func morphing(_ states: [OrbState], hold: Double, morph: Double) -> (provider: TileProvider, loopSeconds: Double) {
    let segment = hold + morph

    /// The transition out of `state[index]`, whose pairing is fixed at the moment it starts.
    func transition(_ segmentIndex: Int, size: OrbSize) -> ActiveTransition {
        let from = states[segmentIndex % states.count]
        let to = states[(segmentIndex + 1) % states.count]
        return ActiveTransition(
            from: .state(Resolved(state: from, size: size)), to: Resolved(state: to, size: size),
            size: Double(size.points), startingAt: Double(segmentIndex) * segment + hold, speed: 1, duration: morph)
    }

    let provider: TileProvider = { elapsed in
        let index = Int(elapsed / segment)
        let local = elapsed - Double(index) * segment
        let state = states[index % states.count]
        if local < hold { return steady(state)(elapsed) }
        // (a transition is cheap to build: ~0.1 ms)
        return Tile(
            large: transition(index, size: .px64).frame(at: elapsed, speed: 1),
            small: transition(index, size: .px20).frame(at: elapsed, speed: 1))
    }
    return (provider, segment * Double(states.count))
}

// MARK: - Frame rendering

/// One tile, at the given opacity.
private func draw(_ tile: Tile, opacity: Double, in context: GraphicsContext) {
    var context = context
    context.opacity = opacity
    context.paint(tile.large, dark: true)

    var corner = context
    corner.translateBy(x: 64 + (tileSize.width - 64 - 20) / 2, y: (tileSize.height - 20) / 2)
    corner.paint(tile.small, dark: true)
}

@MainActor
private func renderFrame(_ tiles: @escaping TileProvider, index: Int, loopSeconds: Double) -> CGImage? {
    let elapsed = Double(index) / framesPerSecond
    let dissolveFrames = Int(dissolveSeconds * framesPerSecond)

    let content = Canvas { context, _ in
        if index < dissolveFrames {
            // Start of the loop: fade the continuation of the END (t + loop) into the start.
            let weight = Double(index) / Double(dissolveFrames)
            draw(tiles(elapsed + loopSeconds), opacity: 1 - weight, in: context)
            draw(tiles(elapsed), opacity: weight, in: context)
        } else {
            draw(tiles(elapsed), opacity: 1, in: context)
        }
    }
    .frame(width: tileSize.width, height: tileSize.height)
    .background(background)

    let renderer = ImageRenderer(content: content)
    renderer.scale = renderScale
    return renderer.cgImage
}

// MARK: - GIF encoding

@MainActor
private func writeGIF(_ tiles: @escaping TileProvider, loopSeconds: Double, to url: URL) throws {
    let frameCount = Int(loopSeconds * framesPerSecond)
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
    else { throw CocoaError(.fileWriteUnknown) }

    // loop count 0 = forever
    CGImageDestinationSetProperties(
        destination,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

    let frameProperties =
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond]] as CFDictionary
    for index in 0..<frameCount {
        guard let image = renderFrame(tiles, index: index, loopSeconds: loopSeconds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, frameProperties)
    }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

    // ImageIO stamps the file "GIF87a", but animation, frame delays and the loop
    // count are GIF89a extensions. Browsers tolerate the mismatch; make the file
    // honest anyway.
    var data = try Data(contentsOf: url)
    if data.prefix(6) == Data("GIF87a".utf8) {
        data.replaceSubrange(0..<6, with: Data("GIF89a".utf8))
        try data.write(to: url)
    }
}

// MARK: - Tint preview (a still)

/// `composing` (the boldest state) drawn in the default gray ink and in four tints,
/// on a white and on a dark background. Each row's first cell is the default ink
/// for that background, so the tints can be judged against it.
@MainActor
private func writeTintSheet(to url: URL) throws {
    let tints: [Color?] = [nil, .blue, .orange, Color(red: 0.2, green: 0.8, blue: 0.4), .pink]
    let rows: [(background: Color, dark: Bool)] = [(.white, false), (background, true)]
    let resolved = Resolved(state: .composing, size: .px64)
    let frame = resolved.mode.frame(size: 64, time: 1.4, options: resolved.opts)
    let cell: CGFloat = 76

    let grid = VStack(spacing: 0) {
        ForEach(0..<rows.count, id: \.self) { row in
            HStack(spacing: 0) {
                ForEach(0..<tints.count, id: \.self) { column in
                    Canvas { context, _ in
                        context.paint(frame, dark: rows[row].dark, tint: tints[column])
                    }
                    .frame(width: 64, height: 64)
                    .frame(width: cell, height: cell)
                    .background(rows[row].background)
                }
            }
        }
    }
    let renderer = ImageRenderer(content: grid)
    renderer.scale = renderScale
    guard
        let image = renderer.cgImage,
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// MARK: - Main

@MainActor
private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        print("usage: render-gifs <output-directory> [state … | morph | tint]")
        exit(2)
    }
    let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    func report(_ name: String, _ url: URL) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "%-11@ %6.0f KB  %@", name as NSString, Double(bytes) / 1024, url.lastPathComponent))
    }

    let requested = Array(arguments.dropFirst(2))
    let everything = requested.isEmpty
    for state in OrbState.allCases where everything || requested.contains(state.rawValue) {
        let url = outputDirectory.appendingPathComponent("\(state.rawValue).gif")
        try writeGIF(steady(state), loopSeconds: stateLoopSeconds, to: url)
        report(state.rawValue, url)
    }
    if everything || requested.contains("morph") {
        let url = outputDirectory.appendingPathComponent("morph.gif")
        let cycle = morphing(showcaseStates, hold: morphHoldSeconds, morph: morphSeconds)
        try writeGIF(cycle.provider, loopSeconds: cycle.loopSeconds, to: url)
        report("morph", url)
    }
    if everything || requested.contains("tint") {
        let url = outputDirectory.appendingPathComponent("tint.png")
        try writeTintSheet(to: url)
        report("tint", url)
    }
}

// Top-level code of a command-line tool runs on the main thread, which is what
// ImageRenderer requires.
MainActor.assumeIsolated {
    do {
        try run()
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
