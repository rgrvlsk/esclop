// SPDX-License-Identifier: GPL-3.0-or-later
//
// The warm windows: Settings, the first run, the pipeline editor and All Results (owner's
// decision, 2026-11-26: "Recuperem en general el color càlid. Tant en clar com en fosc."). Each
// sits on a warm page; its content rests on cream tiles at the one control elevation; what is
// pressable is a white pill; what is chosen is charcoal (in dark, the light cream, so it still
// reads as chosen on walnut). In dark the page is walnut and a tile a step lighter, so it rises.
//
// - Increase Contrast: tiles, pills, fields and dashed outlines get a 1 pt border in the label
//   colour.
// - Reduce Transparency: nothing to remove; every fill is opaque.

import AppKit
import SwiftUI

extension Surface {
    /// The ground of a warm window, under its tiles.
    public static let page = Color(nsColor: pageColor)
    /// A warm window's sidebar: a step darker than its page.
    public static let sidebar = Color(nsColor: Palette.dynamic(light: 0xD3CABE, dark: 0x14100C))
    /// Resting content on a warm page: a warmer cream than the floating surfaces'.
    public static let warmTile = Color(nsColor: Palette.dynamic(light: 0xF7EFE3, dark: 0x2F2620))
    /// Sunk into a warm tile: an icon's circle, a field.
    static let sunken = Color(nsColor: Palette.dynamic(light: 0xEADCC8, dark: 0x1E1813))
    /// A sign's disc on a tile: peach sand in light, a walnut well below the tile in dark.
    static let disc = Color(nsColor: Palette.dynamic(light: 0xF0DFC8, dark: 0x26201B))
    /// Raised off a cream ground (the first run's): lighter than the ground in both appearances.
    static let raised = Color(nsColor: Palette.dynamic(light: 0xFBF6EE, dark: 0x3B312A))
    /// Needs a decision, on a warm page: an even peach amber.
    static let warmDecision = Color(nsColor: Palette.dynamic(light: 0xF9DDAF, dark: 0x553C18))
    /// The page as the window's own background, so its title bar is the page too.
    static let pageColor = Palette.dynamic(light: 0xE8E0D5, dark: 0x221B16)
}

/// What is chosen or on in a warm window: charcoal in light; in dark the light cream, since the
/// dark charcoal reads as disabled on walnut.
enum WarmInk {
    static let chosen = Color(nsColor: Palette.dynamic(light: 0x36322E, dark: 0xEDE3D6))
    static let onChosen = Color(nsColor: Palette.dynamic(light: 0xFFFFFF, dark: 0x2A231E))
    /// A switch that is on: charcoal in light, a light taupe in dark (5:1 on walnut), so on and
    /// off never look alike.
    static let switchOn = Color(nsColor: Palette.dynamic(light: 0x36322E, dark: 0x857B72))
}

extension NSWindow {
    /// A warm window: the page reaches under a transparent title bar, and the title stays for
    /// the Window menu and VoiceOver while the content's heading names it.
    func dressWarm() {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = Surface.pageColor
    }
}

extension Font {
    /// A warm window's one heading: New York, regular.
    static func warmHeading(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

extension View {
    /// Resting content on a warm page: cream, lit from the top, at the control elevation.
    /// `lit` brightens it under the pointer or the keyboard.
    public func warmTile(_ radius: CGFloat = Radius.tile, fill: Color = Surface.warmTile, lit: Bool = false, ring: Bool = false) -> some View {
        modifier(WarmTile(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), fill: fill, lit: lit, ring: ring))
    }

    /// The page under a warm window's content, reaching under the title bar.
    public func warmPage(_ color: Color = Surface.page) -> some View {
        background(color.ignoresSafeArea())
    }

    /// A warm tile's one section label: small caps, tracked, in the text's ink.
    func warmLabel() -> some View {
        font(.system(size: 11, weight: .bold)).textCase(.uppercase).tracking(1.8).foregroundStyle(Ink.text)
    }
}

struct WarmTile<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: Color
    var lit = false
    /// The keyboard is on it: the charcoal ring (cream in dark).
    var ring = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content.background {
            shape.fill(fill)
                .overlay {
                    // Light from above on the cream: the top third a little whiter, as in the
                    // targets. A state's colour (amber) stays even.
                    if fill == Surface.warmTile || fill == Surface.raised {
                        shape.fill(LinearGradient(
                            stops: [.init(color: .white.opacity(dark ? 0.04 : 0.6), location: 0), .init(color: .white.opacity(0), location: 0.5)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    }
                }
                // Under the pointer: the cream stays, a hairline and a deeper shadow lift it; in
                // dark a light rim, so brick red keeps 4.5:1.
                .overlay { if lit, !dark { shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 1) } }
                .overlay { if lit, dark { shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1) } }
                .shadow(color: .black.opacity(lit && !dark ? 0.08 : 0), radius: 10, y: 5)
                .overlay { if ring { shape.inset(by: -1).strokeBorder(WarmInk.chosen.opacity(0.85), lineWidth: 2) } }
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color(nsColor: .labelColor), lineWidth: 1)
                    } else {
                        shape.strokeBorder(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.75), lineWidth: 0.5)
                    }
                }
                .shadow(color: .black.opacity(dark ? 0.45 : 0.07), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 8, y: 3)
                .allowsHitTesting(false)
        }
    }
}

/// A symbol in a sunken sand circle: a tile's or a step's sign.
struct IconBadge: View {
    let symbol: String
    var size: CGFloat = 36
    var ink: Color = Ink.charcoalText

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .regular))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(Surface.disc)
                    // A well in both appearances: a light lip under it in light, none in dark.
                    .overlay { if !dark { Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 0.5) } }
            }
            .accessibilityHidden(true)
    }
}

/// A pressable capsule: white with a charcoal word, or charcoal with a white one for the step
/// that ends something ("Get Started").
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    /// The first run's: one size up.
    var large = false
    /// On an amber band: white in light, cream in dark, so it stays the brightest thing there.
    var decision = false

    func makeBody(configuration: Configuration) -> some View {
        PillFace(label: configuration.label, prominent: prominent, compact: compact, large: large, decision: decision, pressed: configuration.isPressed)
    }
}

private struct PillFace<Label: View>: View {
    let label: Label
    let prominent: Bool
    let compact: Bool
    let large: Bool
    let decision: Bool
    let pressed: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let dark = scheme == .dark
        let chosen = prominent || (decision && dark)
        label
            .font(.system(size: large ? 16 : compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(chosen ? AnyShapeStyle(WarmInk.onChosen) : AnyShapeStyle(Ink.text))
            .lineLimit(1)
            .padding(.horizontal, large ? 26 : compact ? 12 : 16)
            .frame(minHeight: large ? 44 : compact ? 26 : 30)
            .background {
                Capsule()
                    // In dark, a walnut a few steps up, not a grey: the pill keeps the page's warmth.
                    .fill(chosen ? AnyShapeStyle(WarmInk.chosen) : AnyShapeStyle(dark ? Color(nsColor: Palette.color(hovering ? 0x554A40 : 0x4A4037)) : Color.white))
                    .overlay(Capsule().strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : (dark ? Color.white.opacity(0.18) : Color.black.opacity(0.06)), lineWidth: contrast == .increased ? 1 : 0.75))
                    .shadow(color: .black.opacity(dark ? 0.35 : (hovering ? 0.16 : 0.1)), radius: hovering ? 2.5 : 1.5, y: 1)
            }
            .contentShape(Capsule())
            // With Full Keyboard Access the focus ring follows the capsule.
            .contentShape(.focusEffect, Capsule())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .onHover { hovering = $0 && enabled }
    }
}

/// A dashed outline that adds something: "Add Folder…", "Add a step", "New Pipeline".
struct DashedAddButtonStyle: ButtonStyle {
    var radius: CGFloat = Radius.tile

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
                DashedOutline(radius: radius)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A place still empty: a dashed outline at 3:1 on the page, in the label colour under Increase
/// Contrast.
struct DashedOutline: View {
    var radius: CGFloat = Radius.tile
    var circle = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let ink = contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.85))
        let style = StrokeStyle(lineWidth: 1, dash: circle ? [3, 3] : [4, 3])
        if circle {
            Circle().strokeBorder(ink, style: style)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ink, style: style)
        }
    }
}

/// A row in a warm sidebar: cream and raised when it is the one shown, a wash under the pointer,
/// the charcoal ring once the arrow keys move through the list.
struct SidebarRowStyle: ButtonStyle {
    var selected: Bool
    var focused = false
    /// What Return would open, before it is chosen: a wash, not the chosen tile.
    var marked = false

    func makeBody(configuration: Configuration) -> some View {
        SidebarRowFace(label: configuration.label, selected: selected, focused: focused, marked: marked, pressed: configuration.isPressed)
    }
}

private struct SidebarRowFace<Label: View>: View {
    let label: Label
    let selected: Bool
    let focused: Bool
    let marked: Bool
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        label
            .font(.system(size: 14, weight: selected ? .medium : .regular))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background {
                if selected {
                    Color.clear.warmTile(14, ring: focused)
                } else if pressed || hovering || marked {
                    shape.fill(Color.primary.opacity(pressed ? 0.08 : marked ? 0.07 : 0.05))
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// A row on a tile: the label on the left, its control on the right.
struct PanelRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Spacing.l) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            // The control keeps its own width; the words wrap instead.
            configuration.content
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A capsule choice on a tile: cream and raised, charcoal when chosen.
struct ChoiceChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(WarmInk.onChosen) : AnyShapeStyle(Ink.text))
            .lineLimit(1)
            .padding(.horizontal, 15)
            .frame(minHeight: 32)
            .raised(Capsule(), fill: selected ? WarmInk.chosen : Surface.warmTile)
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// What takes typing on a warm tile: sunk a shade, with a hairline, and the charcoal ring while
/// it has the keyboard (the caller says so: its own focus state commits the value).
struct WarmFieldStyle: @preconcurrency TextFieldStyle {
    var focused = false

    // SwiftUI calls the style on the main actor; the protocol does not say so.
    @MainActor func _body(configuration: TextField<Self._Label>) -> some View {
        WarmField(field: configuration, focused: focused)
    }
}

private struct WarmField<Field: View>: View {
    let field: Field
    let focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        field
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background { WarmFieldGround(radius: 7) }
            .overlay { if focused { shape.inset(by: -2).strokeBorder(WarmInk.chosen.opacity(0.75), lineWidth: 2) } }
    }
}

/// A warm search field: sunk into the page, with the magnifier, a clear button while it has
/// text, and the ring while it has the keyboard. ⌘F goes to it; Esc clears it.
struct WarmSearchField: View {
    @Binding var text: String
    let prompt: String
    /// Down from the field: the caller moves into its results.
    var down: (() -> Void)?

    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            WarmPlaceholder(text: text, prompt: prompt) {
                TextField(prompt, text: $text, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focused)
                    .accessibilityAddTraits(.isSearchField)
                    .onExitCommand { text = "" }
                    .onKeyPress(.downArrow) {
                        guard let down else { return .ignored }
                        down()
                        return .handled
                    }
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.text("Clear"))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background {
            Capsule().fill(Surface.warmTile)
                .overlay(Capsule().strokeBorder(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.75)), lineWidth: contrast == .increased ? 1 : 0.75))
        }
        .overlay { if focused { Capsule().inset(by: -2).strokeBorder(WarmInk.chosen.opacity(0.85), lineWidth: 2) } }
        .background {
            // ⌘F, as in every Mac window with a search.
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

/// A field's prompt in the secondary ink (4.5:1 on the warm fills), which a text field's own
/// prompt does not take on macOS; it hides while the field has text.
struct WarmPlaceholder<Field: View>: View {
    let text: String
    let prompt: String
    @ViewBuilder let field: Field

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                // Where the field draws its text, past the caret, as a native prompt.
                Text(prompt)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            field
        }
    }
}

/// A checkbox that holds its own on cream: a rounded square with an edge at 3:1, charcoal with a
/// white check when on (cream with a dark check in dark); the words after it.
struct WarmCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        WarmCheckbox(configuration: configuration)
    }
}

private struct WarmCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        let on = configuration.isOn
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    shape.fill(on ? AnyShapeStyle(WarmInk.chosen) : AnyShapeStyle(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.8)))
                    if !on {
                        shape.strokeBorder(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.8)), lineWidth: 1)
                    }
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(WarmInk.onChosen)
                    }
                }
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                configuration.label
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? Strings.text("on") : Strings.text("off"))
    }
}

/// A pop-up menu on a warm tile: the chosen value in a white raised pill with one down chevron,
/// the choices in the system menu, the current one checked.
struct PillMenu<Value: Hashable, Content: View>: View {
    let title: String
    let current: String
    @Binding var selection: Value
    @ViewBuilder let choices: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        Menu {
            Picker(title, selection: $selection) { choices }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            Text(current)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background {
            Capsule()
                .fill(dark ? Color.white.opacity(0.13) : Color.white)
                .overlay(Capsule().strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : (dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)), lineWidth: contrast == .increased ? 1 : 0.5))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.1), radius: 1.5, y: 1)
        }
        // With Full Keyboard Access the focus ring follows the capsule, not the words.
        .contentShape(.focusEffect, Capsule())
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

/// "…": a round pill that opens a menu of what else can be done.
struct MoreMenu<Content: View>: View {
    /// Three dots at the weight of the symbols beside them.
    static var dots: NSImage {
        let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)) ?? NSImage()
        image.isTemplate = true
        return image
    }

    var size: CGFloat = 30
    var quiet = false
    @ViewBuilder let items: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        let dark = scheme == .dark
        // The whole circle is the menu's label, so a click anywhere on it opens the menu.
        Menu { items } label: {
            Image(nsImage: Self.dots)
                .foregroundStyle(Ink.text)
                .opacity(quiet && !hovering ? 0.55 : 1)
                .frame(width: size, height: size)
                .background {
                    if !quiet {
                        Circle()
                            .fill(dark ? Color(nsColor: Palette.color(0x4A4037)) : Color.white)
                            .overlay(Circle().strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : (dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)), lineWidth: contrast == .increased ? 1 : 0.5))
                            .shadow(color: .black.opacity(dark ? 0.35 : 0.1), radius: 1.5, y: 1)
                    } else if hovering {
                        Circle().fill(Color.primary.opacity(0.07))
                    }
                }
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .contentShape(.focusEffect, Circle())
        .onHover { hovering = $0 }
        .help(Strings.text("More options"))
        .accessibilityLabel(Strings.text("More options"))
    }
}

/// The trailing inset that leaves room for a scroller that always shows (legacy style) and
/// none for the overlay one, so a pane's gutters stay even.
@MainActor
enum Gutter {
    /// `overflows`: the scroll view's content is taller than it, so a legacy scroller shows.
    static func trailing(_ even: CGFloat, overflows: Bool = true) -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy && overflows ? max(4, even - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) : even
    }
}

extension View {
    /// Says whether a scroll view's content is taller than the scroll view (macOS 15 and later;
    /// before, it assumes so).
    func readsOverflow(_ overflows: Binding<Bool>) -> some View {
        modifier(OverflowReader(overflows: overflows))
    }

    /// Writes this view's height, from its first layout on.
    func readsHeight(_ height: Binding<CGFloat>) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { height.wrappedValue = proxy.size.height }
                .onChange(of: proxy.size.height) { _, now in height.wrappedValue = now }
        })
    }
}

/// Keyboard focus that the person moved, not the window's first focus when it opens: a list
/// draws its ring for the one, never for the other.
struct KeyboardEntry {
    private var opened = Date.distantFuture

    mutating func appeared() { opened = Date() }

    /// Focus arrived well after the window opened.
    var settled: Bool { Date().timeIntervalSince(opened) > 0.6 }
}

private struct OverflowReader: ViewModifier {
    @Binding var overflows: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            // The container includes the bars' insets (a toolbar over the content), so content a
            // little shorter than the container can still scroll.
            content.onScrollGeometryChange(for: Bool.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom > $0.containerSize.height + 1 } action: { _, now in overflows = now }
        } else {
            content
        }
    }
}

/// A field's ground on a tile: sunk a shade, with an edge at 3:1 (the label colour under
/// Increase Contrast).
struct WarmFieldGround: View {
    var radius: CGFloat = 7
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Surface.sunken.opacity(0.7))
            .overlay(shape.strokeBorder(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.8)), lineWidth: contrast == .increased ? 1 : 0.75))
    }
}

/// A field's ring while it has the keyboard.
struct WarmFieldRing: View {
    var radius: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: -2).strokeBorder(WarmInk.chosen.opacity(0.85), lineWidth: 2)
    }
}

/// English text as a typesetter writes it: curly quotes and apostrophes. Catalan copy is already
/// typeset in the strings file.
enum Typeset {
    static func smart(_ text: String) -> String {
        var out = ""
        var open = true
        for character in text {
            switch character {
            case "\"": out.append(open ? "“" : "”"); open.toggle()
            case "'": out.append("’")
            default: out.append(character)
            }
        }
        return out
    }
}

/// Lays its children out in lines, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat
    /// Between lines; `spacing` when nil.
    var lineSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * (lineSpacing ?? spacing)
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Its natural size, never wider than the row: a long name is cut, not run past the edge.
    private static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: max(width, 0), height: nil))
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], width: width)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
