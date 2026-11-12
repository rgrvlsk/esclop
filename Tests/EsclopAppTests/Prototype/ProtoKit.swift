// SPDX-License-Identifier: GPL-3.0-or-later
//
// Design overhaul prototype (docs/design/proposal.md): tokens, sample pictures, the desktop the
// floating surfaces are judged over, and the window capture. Prototype views live in the test
// target only: they draw the proposal with real SwiftUI and AppKit, and ship nothing.

import AppKit
@testable import EsclopAppKit
import SwiftUI
import Testing

/// The proposal's tokens. One green, and it has one job: the saving.
enum Proto {
    /// The saving figure and the saved part of a bar. Nothing else.
    static let saving = Palette.accent
    /// Aggressive compression, where it is the current mode.
    static let warm = Palette.warm
    static let error = Palette.error

    // Concentric radii: outer = inner + padding.
    static let cardWidth: CGFloat = 208
    static let cardPadding: CGFloat = 4
    static let cardRadius: CGFloat = 14
    static let pictureRadius: CGFloat = 10
    static let footerHeight: CGFloat = 34
    static let detailWidth: CGFloat = 320
    static let detailPadding: CGFloat = 8
    static let detailRadius: CGFloat = 22
    static let detailPictureRadius: CGFloat = 14
    static let panelRadius: CGFloat = 22
    static let tileRadius: CGFloat = 18
    static let hit: CGFloat = 28
    static let gap: CGFloat = 8

    /// The one large figure of a surface.
    static func figure(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension View {
    /// System Liquid Glass in a shape (the app's own modifier: glass on macOS 26, HUD material before).
    func protoGlass(_ radius: CGFloat, interactive: Bool = false) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: interactive)
    }
}

/// A round glass button with a symbol, 28 pt.
struct ProtoIconButton: View {
    let symbol: String
    let name: String
    var body: some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Proto.hit, height: Proto.hit)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.primary.opacity(0.08)))
        .help(name)
        .accessibilityLabel(name)
    }
}

/// Keys as key caps: "⌃" "⇧" "C".
struct ProtoKeys: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// The bar that matches the claim: what is left in ink, what was saved in green.
struct ProtoSplitBar: View {
    /// Fraction of the original that remains, 0...1.
    var kept: Double
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let keptWidth = max(height, (proxy.size.width - gap) * kept)
            HStack(spacing: gap) {
                Capsule().fill(Color.primary.opacity(0.32)).frame(width: keptWidth)
                Capsule().fill(Proto.saving)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Sample pictures

@MainActor
enum ProtoSamples {
    static let screenshot = RenderTests.screenshot

    /// A photograph stand-in: dusk over water.
    static let photo: NSImage = picture(NSSize(width: 400, height: 300)) { rect in
        NSGradient(colors: [Palette.color(0xF2A65A), Palette.color(0xD9627A), Palette.color(0x3B3F78)])?.draw(in: rect, angle: 90)
        Palette.color(0xFFE2A8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 250, y: 120, width: 56, height: 56)).fill()
        Palette.color(0x1F2450).setFill()
        let hills = NSBezierPath()
        hills.move(to: NSPoint(x: 0, y: 300))
        hills.line(to: NSPoint(x: 0, y: 210))
        hills.curve(to: NSPoint(x: 400, y: 200), controlPoint1: NSPoint(x: 120, y: 150), controlPoint2: NSPoint(x: 260, y: 250))
        hills.line(to: NSPoint(x: 400, y: 300))
        hills.fill()
    }

    /// A page of a PDF.
    static let page: NSImage = picture(NSSize(width: 300, height: 400)) { rect in
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.15, alpha: 1).setFill()
        NSRect(x: 34, y: 40, width: 150, height: 14).fill()
        NSColor(white: 0.7, alpha: 1).setFill()
        for row in 0 ..< 14 { NSRect(x: 34, y: 78 + row * 20, width: row % 4 == 3 ? 150 : 232, height: 6).fill() }
    }

    /// A poster: flat colour and type shapes.
    static let poster: NSImage = picture(NSSize(width: 400, height: 400)) { rect in
        Palette.color(0x2B59C3).setFill()
        rect.fill()
        Palette.color(0xF6C445).setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 70, width: 190, height: 190)).fill()
        NSColor.white.setFill()
        NSRect(x: 60, y: 300, width: 240, height: 22).fill()
        NSRect(x: 60, y: 336, width: 150, height: 12).fill()
    }

    /// A chart on a dark ground.
    static let chart: NSImage = picture(NSSize(width: 400, height: 260)) { rect in
        Palette.color(0x16181D).setFill()
        rect.fill()
        for (index, height) in [60, 110, 85, 150, 130, 190, 170].enumerated() {
            Palette.color(index == 5 ? 0xFF7A59 : 0x5B6472).setFill()
            NSRect(x: 40 + index * 48, y: 230 - height, width: 30, height: height).fill()
        }
    }

    static let pictures: [NSImage] = [screenshot, photo, page, poster, chart, screenshot]

    static func picture(_ size: NSSize, draw: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            draw(rect)
            return true
        }
    }
}

/// The desktop behind the floating surfaces: a wallpaper with an edge of a window on it, so glass
/// has something to refract. `busy` puts strong colour and text right under the surface.
struct ProtoDesktop: View {
    @Environment(\.colorScheme) private var scheme
    var busy = false

    var body: some View {
        let colors = scheme == .dark
            ? [Palette.color(0x1B2B45), Palette.color(0x3A1F4A), Palette.color(0x0E1420)]
            : [Palette.color(0x9CC3E6), Palette.color(0xE9C6B0), Palette.color(0x7FA3C9)]
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            if busy {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0 ..< 40, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0 ..< 9, id: \.self) { column in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill([Color.red, .yellow, .white, .black, .green, .purple][(row + column) % 6].opacity(0.85))
                                    .frame(width: CGFloat(30 + (row * 7 + column * 13) % 60), height: 10)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Capture

@MainActor
enum ProtoRender {
    static var folder: URL { RenderTests.folder }

    /// A floating surface over the desktop, in a borderless window the size of the stage.
    static func floating(
        _ view: some View, size: CGSize, name: String, scheme: ColorScheme, busy: Bool = false,
        alignment: Alignment = .center
    ) async throws {
        let stage = ZStack(alignment: alignment) {
            ProtoDesktop(busy: busy)
            view.padding(24)
        }
        .frame(width: size.width, height: size.height)
        try await capture(stage, size: size, name: name, scheme: scheme, style: [.borderless])
    }

    /// A window with its title bar.
    static func window(_ view: some View, size: CGSize, name: String, scheme: ColorScheme, title: String = "") async throws {
        try await capture(view, size: size, name: name, scheme: scheme, style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], title: title)
    }

    private static func capture(
        _ view: some View, size: CGSize, name: String, scheme: ColorScheme, style: NSWindow.StyleMask, title: String = ""
    ) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.title = title
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            window.close()
        }
        // A runner without a window server session gives no image: the layout still ran.
        guard let image = WindowSnapshots.image(of: window) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("proto-\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }
}
