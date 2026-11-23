#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Draws the DMG window background: assets/dmg/background.png (660 × 400) and background@2x.png.
// Scripts/make-dmg.sh places the app's icon at (165, 170) and Applications at (495, 170), so the
// arrow runs between them. Run from the repository root:
//
//   swift Scripts/dmg-background.swift [OUTDIR]
//
// Finder does not swap a DMG background for dark mode, so the ground is a light neutral.
import AppKit

let size = CGSize(width: 660, height: 400)
let iconY: CGFloat = 170        // icon centres, from the top, as Finder positions them
let leftX: CGFloat = 165, rightX: CGFloat = 495

func color(_ hex: UInt32) -> NSColor {
  NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let ground = color(0xF4F4F2)
let accent = color(0x1E7F6A)    // DESIGN.md accent (light)
let ink = color(0x1B1F1E), secondary = color(0x5E6462)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
  let style = NSMutableParagraphStyle()
  style.alignment = .center
  let attributed = NSAttributedString(string: string, attributes: [
    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
    .paragraphStyle: style,
  ])
  attributed.draw(in: CGRect(x: 0, y: top, width: CGFloat(660), height: size * 1.5))
}

func draw() {
  ground.setFill()
  CGRect(origin: .zero, size: size).fill()

  // A thin arrow from the app to Applications, clear of both 128 pt icons.
  let arrow = NSBezierPath()
  let start = leftX + 96, end = rightX - 96
  arrow.move(to: CGPoint(x: start, y: iconY))
  arrow.line(to: CGPoint(x: end, y: iconY))
  arrow.move(to: CGPoint(x: end - 9, y: iconY - 9))
  arrow.line(to: CGPoint(x: end, y: iconY))
  arrow.line(to: CGPoint(x: end - 9, y: iconY + 9))
  arrow.lineWidth = 2
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  accent.setStroke()
  arrow.stroke()

  text("Drag L'Esclop to Applications", size: 15, weight: .semibold, color: ink, top: 284)
  text("Arrossega L'Esclop a Aplicacions", size: 12, weight: .regular, color: secondary, top: 307)
  // ponytail: only true while releases are not notarised. Once the release job has the
  // notarisation secrets, delete this line and regenerate the PNGs.
  text("If macOS blocks it: System Settings › Privacy & Security › Open Anyway",
       size: 11, weight: .regular, color: secondary, top: 364)
}

func render(scale: Int, to url: URL) throws {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size  // draw in points; the context scales them to pixels
  let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
  cg.translateBy(x: 0, y: size.height)  // top-left origin, as Finder positions icons
  cg.scaleBy(x: 1, y: -1)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  try rep.converting(to: .sRGB, renderingIntent: .default)!
    .representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/dmg")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
print("dmg-background: wrote background.png and background@2x.png in \(out.path)")
