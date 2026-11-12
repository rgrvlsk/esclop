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
    static let saving = Color(nsColor: Palette.dynamic(light: 0x176B59, dark: 0x63D6B8))
    /// Aggressive compression, where it is the current mode.
    static let warm = Color(nsColor: Palette.dynamic(light: 0x8F5510, dark: 0xE0A040))
    static let error = Palette.error

    /// The competing direction (the owner's option 3): a surface and colours of the app's own.
    /// The structure is the same; only the skin changes, so the two can be judged side by side.
    nonisolated(unsafe) static var own = false
    /// The wood of the icon, as the second colour of the own-brand direction.
    static let wood = Color(nsColor: Palette.dynamic(light: 0x8A5A33, dark: 0xD0A077))
    /// Controls, selection and the drop target: the system accent, or the green in the own-brand direction.
    /// A test process is never the active app, so the system accent draws grey: the default blue stands in for it.
    static var control: Color { own ? saving : Color(nsColor: .systemBlue) }
    /// A lit drop tile: one fill for both appearances, so white text on it is always above 4.5:1.
    static var lit: Color { own ? Color(nsColor: Palette.color(0x176B59)) : Color(nsColor: Palette.color(0x0A60D8)) }
    static let litWarm = Color(nsColor: Palette.color(0x8F5510))
    /// Secondary text on the own-brand surface: the system's fails on boxwood.
    static let ownSecondary = Color(nsColor: Palette.dynamic(light: 0x625C56, dark: 0xB9AFA5))
    /// What is left of the original in a split bar.
    static var kept: Color { own ? Color(nsColor: Palette.dynamic(light: 0xD8BF9F, dark: 0x6E5746)) : Color.primary.opacity(0.32) }

    // Concentric radii: outer = inner + padding.
    /// "−75 %" with the narrow space the figure needs at large sizes.
    static func percent(_ value: Int) -> String { "−\(value)\u{202F}%" }

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
    static let panelPadding: CGFloat = 12
    /// Anything inside a panel or popover: 22 − 12.
    static let innerRadius: CGFloat = 10
    static let tileRadius: CGFloat = 18
    static let hit: CGFloat = 28
    static let gap: CGFloat = 8

    /// The one large figure of a surface.
    static func figure(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension View {
    /// A floating surface: system Liquid Glass (or the own-brand surface), with the one elevation
    /// every floating object shares. `tint` colours the glass itself for a state.
    func protoGlass(_ radius: CGFloat, tint: Color? = nil) -> some View {
        modifier(ProtoSurface(radius: radius, tint: tint))
    }
}

struct ProtoSurface: ViewModifier {
    let radius: CGFloat
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        surface(content, shape)
            // Elevation: one shadow and one inner rim, so the edge never depends on the wallpaper.
            .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? 0.14 : 0.35), lineWidth: 0.5).allowsHitTesting(false))
            // An outer hairline, for a light surface on a white ground.
            .overlay(shape.inset(by: -0.5).strokeBorder(Color.black.opacity(scheme == .dark ? 0.3 : 0.1), lineWidth: 0.5).allowsHitTesting(false))
            .background {
                shape.fill(.black)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.2), radius: 12, y: 8)
                    .mask { Rectangle().padding(-60).overlay(shape.blendMode(.destinationOut)).compositingGroup() }
            }
    }

    @ViewBuilder private func surface(_ content: Content, _ shape: RoundedRectangle) -> some View {
        if let tint {
            // A lit tile: the colour itself, opaque, so the state survives any wallpaper.
            content.background(shape.fill(tint))
        } else if Proto.own {
            // Wood does not transmit: the surface is opaque, with its own secondary ink.
            let fill = scheme == .dark ? Palette.color(0x2B2521) : Palette.color(0xF6F0E8)
            content.foregroundStyle(Color.primary, Proto.ownSecondary).background(shape.fill(Color(nsColor: fill)))
        } else if #available(macOS 26, *) {
            // Glass with a backing in the appearance's own tone: the ground under the ink is
            // bounded whatever the desktop is.
            content
                .background(shape.fill((scheme == .dark ? Color(white: 0.13) : Color(white: 0.97)).opacity(0.8)))
                .glassEffect(.regular, in: shape)
        } else {
            content.glassSurface(shape)
        }
    }
}

/// The clog: the template glyph, or the carved wooden one in the own-brand direction.
struct ProtoClog: View {
    var width: CGFloat

    static let wooden: NSImage? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../assets/icon-wood.png").standardizedFileURL
        return NSImage(contentsOf: url)
    }()

    /// On a lit tile, or where the menu bar glyph itself is meant, both directions draw the template.
    var template = false

    var body: some View {
        if Proto.own, !template, let wooden = Self.wooden {
            Image(nsImage: wooden).resizable().aspectRatio(contentMode: .fit).frame(width: width * 1.25)
        } else if let glyph = MenuBarLabel.customGlyph {
            Image(nsImage: glyph).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: width)
        }
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
        .background(Circle().fill(Color.primary.opacity(0.14)))
        .help(name)
        .accessibilityLabel(name)
    }
}

/// Keys as key caps: "⌃" "⇧" "C".
struct ProtoKeys: View {
    let keys: [String]
    /// A pinned ink, where the surface must not choose one.
    var ink: Color?
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .foregroundStyle(ink.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

/// The bar that matches the claim: what is left in ink, what was saved in green.
struct ProtoSplitBar: View {
    /// Fraction of the original that remains, 0...1.
    var kept: Double
    let height: CGFloat = 6
    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let keptWidth = max(height, (proxy.size.width - gap) * kept)
            HStack(spacing: gap) {
                Capsule().fill(Proto.kept).frame(width: keptWidth)
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
    /// A plain ground (pure white, pure black) to prove the edge.
    var flat: Color?

    var body: some View {
        let colors = scheme == .dark
            ? [Palette.color(0x1B2B45), Palette.color(0x3A1F4A), Palette.color(0x0E1420)]
            : [Palette.color(0x9CC3E6), Palette.color(0xE9C6B0), Palette.color(0x7FA3C9)]
        ZStack(alignment: .topLeading) {
            if let flat { flat } else {
                LinearGradient(colors: colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
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
        alignment: Alignment = .center, flat: Color? = nil
    ) async throws {
        let stage = ZStack(alignment: alignment) {
            ProtoDesktop(busy: busy, flat: flat)
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
        let host = NSHostingView(rootView: view.tint(Proto.own ? Proto.saving : nil).environment(\.colorScheme, scheme))
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
        try data.write(to: folder.appendingPathComponent("proto-\(Proto.own ? "own-" : "")\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }
}
