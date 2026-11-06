// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders a vector icon (SVG or PDF) into a macOS .iconset folder at every size iconutil wants,
// drawing the vector at each size rather than scaling one bitmap.
//
//   swift Scripts/make-icon.swift assets/icon.svg OUT.iconset && iconutil -c icns OUT.iconset

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let source = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift ICON.svg OUT.iconset\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
