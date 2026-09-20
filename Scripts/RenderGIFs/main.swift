//
// main.swift
//  ThinkingOrb
//
// Created by persuara on 9/21/26
//
//  Renders the animated GIFs shown in the README — one per state, with the two
//  tuned sizes (64 pt and 20 pt) side by side.
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
/// Length of one loop, in seconds of real time (before the preset's own speed-up).
let loopSeconds = 4.0
/// The first part of the loop cross-fades in from the moment just AFTER the loop
/// ends. These animations are not periodic (several unrelated frequencies run at
/// once), so a raw loop would visibly jump; this hides the seam.
let dissolveSeconds = 0.5
/// GitHub's dark-theme page background, so the tile melts into it. GIFs have no
/// partial transparency, so a solid tile is the clean choice on light pages too.
let background = Color(red: 13 / 255, green: 17 / 255, blue: 23 / 255)

/// Layout in points; rendered at 2x. Big orb on the left, small one in the remainder.
let tileSize = CGSize(width: 96, height: 64)
let renderScale = 2.0

// MARK: - Frame rendering

/// One tile at `elapsed` seconds: both sizes of `state`, at the given opacity.
private func drawOrbs(_ state: OrbState, elapsed: Double, opacity: Double, in context: GraphicsContext) {
    var context = context
    context.opacity = opacity

    let large = Resolved(state: state, size: .px64)
    context.paint(
        large.mode.frame(size: 64, time: elapsed * large.speed, options: large.opts), dark: true)

    let small = Resolved(state: state, size: .px20)
    var corner = context
    corner.translateBy(x: 64 + (tileSize.width - 64 - 20) / 2, y: (tileSize.height - 20) / 2)
    corner.paint(
        small.mode.frame(size: 20, time: elapsed * small.speed, options: small.opts), dark: true)
}

@MainActor
private func renderFrame(_ state: OrbState, index: Int, frameCount: Int) -> CGImage? {
    let elapsed = Double(index) / framesPerSecond
    let dissolveFrames = Int(dissolveSeconds * framesPerSecond)

    let content = Canvas { context, _ in
        if index < dissolveFrames {
            // Start of the loop: fade the continuation of the END (t + loop) into the start.
            let weight = Double(index) / Double(dissolveFrames)
            drawOrbs(state, elapsed: elapsed + loopSeconds, opacity: 1 - weight, in: context)
            drawOrbs(state, elapsed: elapsed, opacity: weight, in: context)
        } else {
            drawOrbs(state, elapsed: elapsed, opacity: 1, in: context)
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
private func writeGIF(for state: OrbState, to url: URL) throws {
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
        guard let image = renderFrame(state, index: index, frameCount: frameCount) else {
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

// MARK: - Main

@MainActor
private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        print("usage: render-gifs <output-directory> [state …]")
        exit(2)
    }
    let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let requested = arguments.dropFirst(2).compactMap { OrbState(rawValue: $0) }
    for state in requested.isEmpty ? OrbState.allCases : requested {
        let url = outputDirectory.appendingPathComponent("\(state.rawValue).gif")
        try writeGIF(for: state, to: url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "%-11@ %6.0f KB  %@", state.rawValue as NSString, Double(bytes) / 1024, url.lastPathComponent))
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
