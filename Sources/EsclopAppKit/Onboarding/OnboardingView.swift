// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first-run window (`pr8-first-run`): three steps. Copy or drop an image; the same image,
// lighter; where the results appear. Every step but the last can be skipped; the menu opens it
// again. What it no longer walks through lives in Settings: the automatic switches (Automatic),
// the Desktop's access (each folder's row) and the agents (Agents).

import AppKit
import EsclopCore
import EsclopIPC
import ServiceManagement
import SwiftUI

public struct OnboardingView: View {
    let onboarding: OnboardingModel
    let settings: SettingsViewModel
    let openSettings: () -> Void
    /// The example picture until the person copies one: a photograph of the bay of Jóncols, Cap
    /// de Creus (CC0; ARTWORK.md).
    let example: CGImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onboarding: OnboardingModel, settings: SettingsViewModel, example: CGImage? = OnboardingView.examplePhoto, openSettings: @escaping () -> Void) {
        self.onboarding = onboarding
        self.settings = settings
        self.openSettings = openSettings
        self.example = example
    }

    /// The bundled example photograph.
    public static let examplePhoto: CGImage? = {
        guard let url = Bundle.module.url(forResource: "FirstRunExample", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    public var body: some View {
        VStack(spacing: 0) {
            StepNumbers(step: onboarding.step, furthest: onboarding.furthest) { target in
                withAnimation(animation) { onboarding.go(to: target) }
            }
            .padding(.top, Spacing.xs)
            ZStack {
                page(onboarding.step)
                    .id(onboarding.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 600, height: 540)
        .background { FirstRunGround().ignoresSafeArea() }
        .designTint()
        // VoiceOver hears where it is now.
        .onChange(of: onboarding.step) { _, step in
            AccessibilityNotification.Announcement(Strings.format("Step %d of %d: %@", step.rawValue + 1, OnboardingModel.Step.allCases.count, step.title)).post()
        }
        // A refused login item is said aloud as well as shown.
        .onChange(of: onboarding.loginError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        // So is the wait for the person's approval in System Settings.
        .onChange(of: onboarding.loginNeedsApproval) { _, waits in
            if waits { AccessibilityNotification.Announcement(Strings.text("Allow L’Esclop in Login Items & Extensions.")).post() }
        }
    }

    var transition: AnyTransition {
        // Reduce Motion: a crossfade instead of the slide (DESIGN.md › Motion).
        if reduceMotion { return .opacity }
        let edge: Edge = onboarding.forward ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var animation: Animation {
        reduceMotion ? Motion.crossfade : .spring(duration: 0.35, bounce: 0)
    }

    @ViewBuilder private func page(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .copy: CopyPage(onboarding: onboarding, example: example)
        case .result: ResultPage(result: onboarding.ownResult, example: example)
        case .ready:
            ReadyPage(onboarding: onboarding, retentionDays: retentionDays)
        }
    }

    private func connectAgent() {
        settings.open(SettingsRoute(pane: SettingsPane.named("agents")))
        onboarding.finish()
        openSettings()
    }

    private var retentionDays: Int {
        settings.value(EsclopSettings.backupRetentionDays.key)?.intValue ?? EsclopSettings.backupRetentionDays.defaultValue
    }

    /// Continue, or Get Started on the last step with Open at login and Connect an AI Agent…
    /// beside it. Esc skips the tour, as the close button does; ← goes back, → goes on, and the
    /// numbers above go back too.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .center, spacing: Spacing.m) {
                if onboarding.isLast {
                    Toggle(Strings.text("Open at login"), isOn: Binding(get: { onboarding.opensAtLogin }, set: { onboarding.opensAtLogin = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(WarmInk.switchOn)
                        .font(.system(size: 13))
                        .switchLabel(title: Strings.text("Open at login"), hint: Strings.text("Keep L’Esclop in the menu bar after a restart, so copies are optimised from the start."))
                        .fixedSize()
                    Button(Strings.text("Connect an AI Agent…"), action: connectAgent)
                        .textButton()
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize()
                        // Clear of the switch, so the switch reads as Open at login's alone.
                        .padding(.leading, 16)
                }
                Spacer(minLength: 0)
                if onboarding.isLast {
                    Button(Strings.text("Get Started")) { onboarding.finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PillButtonStyle(prominent: true, large: true))
                } else {
                    // Once the person's own image has arrived, Continue says so: it is the way on.
                    Button(Strings.text("Continue")) { withAnimation(animation) { onboarding.next() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PillButtonStyle(prominent: onboarding.isFirst && onboarding.ownResult != nil, large: true))
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.xl)
        .background {
            // Esc skips, like the close button; the tour stays in the menu. ← and → step.
            Group {
                Button(Strings.text("Skip")) { onboarding.finish() }
                    .keyboardShortcut(.cancelAction)
                Button(Strings.text("Back")) { withAnimation(animation) { onboarding.back() } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(onboarding.isFirst)
                Button(Strings.text("Continue")) { withAnimation(animation) { onboarding.next() } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(onboarding.isLast)
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }
}

/// The first run's ground: the cream, lit from the top, as the targets draw it.
struct FirstRunGround: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(nsColor: Palette.dynamic(light: 0xEEE3D2, dark: 0x2A221C))
            RadialGradient(
                colors: [Color(nsColor: Palette.dynamic(light: 0xF6EEE2, dark: 0x3A3029)).opacity(0.9), .clear],
                center: .top, startRadius: 0, endRadius: 560
            )
            LinearGradient(colors: [.clear, Color.black.opacity(dark ? 0.15 : 0.02)], startPoint: .center, endPoint: .bottom)
        }
    }
}

/// Where the person is: the three steps as numbered circles on a line, the current one charcoal.
/// A step already seen is a button back to it.
struct StepNumbers: View {
    let step: OnboardingModel.Step
    var furthest: OnboardingModel.Step = .copy
    let go: (OnboardingModel.Step) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingModel.Step.allCases) { each in
                if each != OnboardingModel.Step.allCases.first {
                    Rectangle().fill(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.3))).frame(width: 40, height: 1)
                }
                let current = each == step
                let label = Strings.format("Step %d of %d: %@", each.rawValue + 1, OnboardingModel.Step.allCases.count, each.title)
                if !current, each.rawValue <= furthest.rawValue {
                    // A step already seen, behind or ahead after going back: a button to it,
                    // raised, with a wash under the pointer.
                    Button { go(each) } label: { circle(each, current: false, ahead: false) }
                        .buttonStyle(SeenStepStyle())
                        .help(each.title)
                        .accessibilityLabel(label)
                } else {
                    circle(each, current: current, ahead: !current)
                        .accessibilityElement()
                        .accessibilityLabel(label)
                        .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
    }

    /// A step's circle: charcoal for the one shown; a step to come says so with its number in
    /// the secondary ink (4.5:1), on the same raised disc.
    private func circle(_ each: OnboardingModel.Step, current: Bool, ahead: Bool) -> some View {
        Text("\(each.rawValue + 1)")
            .font(.system(size: 17, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(current ? AnyShapeStyle(WarmInk.onChosen) : ahead ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Ink.text))
            .frame(width: 44, height: 44)
            .background {
                if current {
                    Circle().fill(WarmInk.chosen).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                } else if ahead {
                    // A step still to come is flat: only a hairline, nothing to press yet; the
                    // label colour under Increase Contrast.
                    Circle().strokeBorder(contrast == .increased ? AnyShapeStyle(Color(nsColor: .labelColor)) : AnyShapeStyle(Ink.secondary.opacity(0.45)), lineWidth: 1)
                } else {
                    // Raised, and in dark with the lit rim the picture tiles have, so it reads
                    // as something to press.
                    Color.clear.warmTile(22, fill: Surface.raised, lit: scheme == .dark)
                }
            }
            .contentShape(Circle())
            .contentShape(.focusEffect, Circle())
    }
}

/// Wraps its text to the fewest lines that fit `maxWidth`, each of about the same length, as a
/// designer breaks a centred sentence.
struct BalancedLines: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        return text.sizeThatFits(ProposedViewSize(width: width(text, proposal: proposal), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    private func width(_ text: LayoutSubview, proposal: ProposedViewSize) -> CGFloat {
        let widest = min(proposal.width ?? maxWidth, maxWidth)
        let oneLine = text.sizeThatFits(.unspecified).width
        let lines = max(1, (oneLine / widest).rounded(.up))
        // A little over the even share, so the last word does not drop to a third line.
        return min(widest, oneLine / lines + 12)
    }
}

/// A step's one heading, in New York, and its sentence.
struct StepHeading: View {
    let title: String
    let summary: String?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Text(title)
                .font(.warmHeading(34))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
            if let summary {
                // Lines of even length in every language, at most 380 pt wide.
                BalancedLines(maxWidth: 380) {
                    Text(summary)
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.l)
    }
}

// MARK: - Pages

/// 1. Copy or drop an image: a picture going to the clog in the menu bar, and macOS's clipboard
/// question when it is still to come.
struct CopyPage: View {
    let onboarding: OnboardingModel
    let example: CGImage?
    /// The person's own picture, once they copied one during the tour.
    @State private var own: CGImage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(
                title: OnboardingModel.Step.copy.title,
                summary: Strings.text("L’Esclop wakes up when you copy a screenshot or drop a file on the clog.")
            )
            Spacer(minLength: Spacing.m)
            HStack(alignment: .center, spacing: 0) {
                PictureTile(image: own ?? example)
                    .frame(width: 262, height: 182)
                    // A picture copied during the tour takes the example's place.
                    .task(id: onboarding.ownResult?.id) {
                        own = nil
                        guard let url = onboarding.ownResult?.output, FileManager.default.fileExists(atPath: url.path) else { return }
                        let image = await Thumbnails.load(url, side: 300)
                        if !Task.isCancelled { own = image }
                    }
                    .rotationEffect(.degrees(-4))
                    .overlay(alignment: .bottomTrailing) {
                        // The pointer as macOS draws it: black with a white edge, on any picture.
                        ZStack {
                            Image(systemName: "cursorarrow").font(.system(size: 33, weight: .black)).foregroundStyle(.white)
                            Image(systemName: "cursorarrow").font(.system(size: 30, weight: .regular)).foregroundStyle(.black)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: -26, y: 10)
                    }
                // The arrow ends just above the clog.
                FlightArrow()
                    .stroke(Ink.progress, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 96, height: 56)
                    // Its tail 4 pt clear of the picture's edge.
                    .offset(x: -1, y: -42)
                MenuBarStrip(icons: ["wifi", "battery.100"])
                    .offset(x: -36, y: 12)
            }
            .padding(.leading, 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.text("A picture goes to the clog in the menu bar."))
            Spacer(minLength: Spacing.m)
            if onboarding.clipboardAccess == .asks || onboarding.clipboardAccess == .denied {
                // The same band as step 3's: an amber sign, the sentence in text ink, one pill.
                let denied = onboarding.clipboardAccess == .denied
                HStack(spacing: Spacing.s) {
                    Image(systemName: denied ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                        .foregroundStyle(Ink.warm)
                        .accessibilityLabel(denied ? Strings.text("Denied") : Strings.text("Asks each time"))
                    Text(denied
                        ? Strings.text("macOS does not let L’Esclop read what you copy. Allow it in Privacy & Security.")
                        : Strings.text("macOS may ask each time L’Esclop reads what you copy. Choose Allow there so it stops asking."))
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.s)
                    Button(Strings.text("Open Privacy Settings")) { openURL(OnboardingModel.privacySettings) }
                        .buttonStyle(PillButtonStyle(compact: true, decision: true))
                        .fixedSize()
                }
                .padding(.leading, Spacing.m)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DecisionBand())
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.l)
            }
        }
    }
}

/// The arrow from the picture to the clog: up, over and down onto it.
struct FlightArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX + 2, y: rect.minY + rect.height * 0.62)
        let end = CGPoint(x: rect.maxX - 6, y: rect.maxY - 2)
        let control = CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY - rect.height * 0.35)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        // The head, along the curve's last direction.
        let angle = atan2(end.y - control.y, end.x - control.x)
        for side in [-1.0, 1.0] {
            let wing = angle + .pi + side * .pi / 5.5
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + 11 * cos(wing), y: end.y + 11 * sin(wing)))
        }
        return path
    }
}

/// 2. The same image, lighter: the person's own result when one arrived while the tour was open,
/// otherwise an example that says it is one. The picture is the same size twice: compression
/// never shows as the image getting smaller (owner, 2026-11-13).
struct ResultPage: View {
    let result: OptimisationResult?
    /// The picture before the person's own: the same on both sides, as theirs would be.
    let example: CGImage?
    @State private var picture: CGImage?

    /// The example's sizes when the person has not optimised anything yet.
    static let example = (before: 2_400_000, after: 612_000)

    var body: some View {
        let before = result?.bytesBefore ?? Self.example.before
        let after = result?.bytesAfter ?? Self.example.after
        let saved = before > 0 ? 1 - Double(after) / Double(before) : 0
        VStack(spacing: 0) {
            StepHeading(title: OnboardingModel.Step.result.title, summary: nil)
            Figure(percentSaved: Int((saved * 100).rounded()), size: .firstRun)
                .padding(.top, Spacing.xs)
            // The arc draws its whole height inside its frame, 12 pt clear of the pictures; its
            // white dot is 11 pt, so it reads on cream.
            SavingGauge(saved: saved, shape: .arc, lineWidth: 5)
                .frame(width: 250, height: SavingGauge.arcHeight(width: 250, lineWidth: 5))
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 40) {
                sized(Figures.bytes(before), ink: Ink.original, spoken: Strings.text("Before"))
                sized(Figures.bytes(after), ink: Ink.secondary, spoken: Strings.text("After"))
            }
            Text(Strings.text("Nothing you can see changes."))
                .font(.system(size: 16))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, Spacing.m)
            // Whose picture this is: an example, or the person's own copy.
            Text(result == nil ? Strings.text("An example. Copy a screenshot to see your own.") : Strings.text("Your own copy, optimised just now."))
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .task(id: result?.id) {
            // An undone result, or one whose file is gone, leaves the example's stand-in.
            picture = nil
            guard let url = result?.output, FileManager.default.fileExists(atPath: url.path) else { return }
            let image = await Thumbnails.load(url, side: 240)
            if !Task.isCancelled { picture = image }
        }
    }

    private func sized(_ size: String, ink: some ShapeStyle, spoken: String) -> some View {
        VStack(spacing: Spacing.s) {
            PictureTile(image: result == nil ? example : picture)
                .frame(width: 204, height: 136)
                .accessibilityHidden(true)
            Text(size)
                .font(.system(size: 19, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spoken), \(size)")
    }
}

/// 3. Ready when you are: the corner of the screen with the clog in the menu bar and a result
/// under it, with what a result offers; where results go and how long originals stay. Open at
/// login and Connect an AI Agent… are in the footer.
struct ReadyPage: View {
    let onboarding: OnboardingModel
    let retentionDays: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(title: OnboardingModel.Step.ready.title, summary: nil)
            // With a band to show, the drawing gives up height; its words keep their size.
            ScreenCornerArt(compact: loginBand != nil)
                .padding(.top, Spacing.s)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Strings.text("A result under the clog, with Copy, Show in Finder and Undo."))
            // The steps' one sentence size, on two lines.
            Text(summary)
                .font(.system(size: 16))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
                // At rest, the same air under the drawing as under the note: 32 and 32.
                .padding(.top, loginBand == nil ? Spacing.xl : Spacing.l)
            Text(Strings.text("Next, macOS may ask to let L’Esclop see your Desktop, where screenshots land."))
                .font(.system(size: 13))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
                // A separate, quieter thought under the sentence.
                .padding(.top, 13)
            // What macOS still needs about the login item: an amber band right above the footer,
            // next to the switch it is about.
            if let band = loginBand {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ink.warm)
                        .accessibilityHidden(true)
                    Text(band)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(onboarding.loginError ?? band)
                    Spacer(minLength: Spacing.s)
                    Button(Strings.text("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(PillButtonStyle(compact: true, decision: true))
                        .fixedSize()
                }
                .padding(.leading, Spacing.m)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .background(DecisionBand())
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.m)
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: loginBand)
    }

    /// A refused login item, or one macOS waits to be allowed.
    private var loginBand: String? {
        if onboarding.loginError != nil {
            return onboarding.loginWanted == false
                ? Strings.text("macOS did not remove L’Esclop from your login items.")
                : Strings.text("macOS did not add L’Esclop to your login items.")
        }
        if onboarding.loginNeedsApproval { return Strings.text("Allow L’Esclop in Login Items & Extensions.") }
        return nil
    }

    private var summary: String {
        retentionDays <= 0
            ? Strings.text("Results show in a corner and fade away; the clog keeps the latest. Originals are always kept.")
            : Strings.format("Results show in a corner and fade away; the clog keeps the latest. Originals are kept for %@.", SettingPresentation.retention(days: retentionDays))
    }
}

/// The top-right corner of a Mac's screen: its bezel turning down at the right, the menu bar
/// with the clog, a result under it, and the three things a result offers.
struct ScreenCornerArt: View {
    /// Shorter by 36 pt, for when a band needs the room: tighter gaps and smaller circles.
    var compact = false
    @Environment(\.colorScheme) private var scheme

    private let width: CGFloat = 520
    private var height: CGFloat { compact ? 200 : 236 }

    var body: some View {
        let dark = scheme == .dark
        let screen = RoundedRectangle(cornerRadius: 44, style: .continuous)
        ZStack(alignment: .top) {
            // The screen: its top edge runs in from the left and turns down at the right; both
            // ends fade into the page.
            screen
                .fill(dark ? Color.white.opacity(0.05) : Color.white.opacity(0.5))
                // The menu bar: a paler band under the bezel, with a hairline under it.
                .overlay(alignment: .top) {
                    // Clipped at the screen's own size, so its corner is the bezel's.
                    VStack(spacing: 0) {
                        Rectangle().fill(dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55)).frame(height: compact ? 36 : 42)
                        Rectangle().fill(Ink.secondary.opacity(0.25)).frame(height: 0.5)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(screen)
                }
                .overlay(
                    screen.strokeBorder(
                        LinearGradient(colors: dark ? [Color(nsColor: Palette.color(0x7A6E65)), Color(nsColor: Palette.color(0x5E544C))] : [Color(nsColor: Palette.color(0x3E3833)), Color(nsColor: Palette.color(0x2A2521))], startPoint: .top, endPoint: .bottom),
                        lineWidth: 10
                    )
                )
                .frame(width: 760, height: 420)
                .offset(x: width - 20 - (width + 760) / 2, y: 6)
                .frame(width: width, height: height, alignment: .top)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)], startPoint: .leading, endPoint: .trailing))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 0.85)], startPoint: .top, endPoint: .bottom))
                .clipped()
            // The result hangs at least 4 pt under the menu bar's line, compact or not.
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    ClogGlyph().font(.system(size: 18))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                    Image(systemName: "magnifyingglass")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.text)
                .padding(.top, compact ? 15 : 24)
                .padding(.bottom, compact ? 13 : 12)
                .offset(x: 50)
                // The result, under the clog: the step's hero.
                HStack(spacing: 14) {
                    SavingGauge(saved: 0.75, shape: .ring, lineWidth: 7)
                        .frame(width: 48, height: 48)
                    Figure(percentSaved: 75, size: .window)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, compact ? 9 : 13)
                .warmTile(24, fill: Surface.raised)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                HStack(spacing: 36) {
                    action("square.on.square", Strings.text("Copy"))
                    action("folder", Strings.text("Show in Finder"))
                    action("arrow.uturn.backward", Strings.text("Undo"))
                }
                .padding(.top, compact ? 8 : 18)
            }
        }
        .frame(width: width, height: height)
    }

    private func action(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 17 : 20))
                .foregroundStyle(Ink.charcoalText)
                .frame(width: compact ? 44 : 56, height: compact ? 44 : 56)
                .background(Color.clear.warmTile(compact ? 22 : 28, fill: Color(nsColor: Palette.dynamic(light: 0xFBF6EE, dark: 0x4A3F36))))
                .contentShape(.focusEffect, Circle())
            Text(name).warmLabel()
        }
    }
}

extension View {
    /// A text button: charcoal semibold, never the system's link blue; a capsule wash under the
    /// pointer, darker when pressed. The wash reaches 8 pt past the words, which keep their place.
    func textButton() -> some View {
        buttonStyle(TextButtonStyle()).font(.body.weight(.semibold)).padding(.horizontal, -8)
    }
}

struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonFace(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct TextButtonFace<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .foregroundStyle(Ink.charcoalText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovering ? 0.06 : 0)))
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
            .onHover { hovering = $0 }
    }
}

/// A picture on a cream tile: the given image, or a stand-in photo symbol.
struct PictureTile: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    // The whole picture, as the person made it; the tile sets the size.
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .padding(5)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .background(Color.clear.warmTile(16, fill: Surface.raised))
    }
}

/// The clog, as the menu bar shows it.
struct ClogGlyph: View {
    var body: some View {
        if let glyph = MenuBarLabel.customGlyph {
            Image(nsImage: glyph).renderingMode(.template)
        } else {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
        }
    }
}

/// A piece of the menu bar with the clog first, as it looks up there.
struct MenuBarStrip: View {
    let icons: [String]

    var body: some View {
        HStack(spacing: 22) {
            ClogGlyph()
                .frame(width: 52, height: 42)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(NeutralFill.button))
            ForEach(icons, id: \.self) { Image(systemName: $0) }
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(Ink.text)
        .padding(.leading, 9)
        .padding(.trailing, 22)
        .padding(.vertical, 9)
        .warmTile(18, fill: Surface.raised)
    }
}

/// Open at login, the one switch that is a system setting, in Settings › General,
/// on the same model, with what macOS still waits for and why it refused.
struct LoginItemRows: View {
    let onboarding: OnboardingModel

    var body: some View {
        TitledToggle(
            title: Strings.text("Open at login"),
            subtitle: Strings.text("Keep L’Esclop in the menu bar after a restart, so copies are optimised from the start."),
            isOn: Binding(get: { onboarding.opensAtLogin }, set: { onboarding.opensAtLogin = $0 })
        )
        .markable(SettingsPaneView.openAtLoginRow)
        if onboarding.loginNeedsApproval {
            LabeledContent {
                Button(Strings.text("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
            } label: {
                // Amber marks the decision; the sentence stays in text ink (amber holds 3:1).
                Label {
                    Text(Strings.text("macOS waits for you to allow L’Esclop in Login Items & Extensions.")).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Ink.warm)
                }
            }
        }
        if let error = onboarding.loginError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Ink.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A band that needs a decision: amber, with the label colour's edge under Increase Contrast.
struct DecisionBand: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape.fill(Surface.warmDecision)
            .overlay { if contrast == .increased { shape.strokeBorder(Color(nsColor: .labelColor), lineWidth: 1) } }
    }
}

/// A step already seen: its raised disc brightens under the pointer and darkens when pressed.
struct SeenStepStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SeenStep(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct SeenStep<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .overlay { if hovering || pressed { Circle().fill(Color.primary.opacity(pressed ? 0.12 : 0.06)).allowsHitTesting(false) } }
            .overlay { if hovering { Circle().strokeBorder(WarmInk.chosen.opacity(0.6), lineWidth: 1.5).allowsHitTesting(false) } }
            .onHover { hovering = $0 }
    }
}
