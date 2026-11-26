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
    /// The example picture until the person copies one: the app's icon. Renders pass the one in
    /// `assets/`, since a test process has none.
    let example: CGImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onboarding: OnboardingModel, settings: SettingsViewModel, example: NSImage? = NSApp.applicationIconImage, openSettings: @escaping () -> Void) {
        self.onboarding = onboarding
        self.settings = settings
        self.openSettings = openSettings
        self.example = example?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public var body: some View {
        VStack(spacing: 0) {
            StepNumbers(step: onboarding.step)
                .padding(.top, Spacing.xl)
            ZStack {
                page(onboarding.step)
                    .id(onboarding.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 600, height: 480)
        .designTint()
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
        case .result: ResultPage(result: onboarding.ownResult, retentionDays: retentionDays, example: example)
        case .ready:
            ReadyPage(onboarding: onboarding, retentionDays: retentionDays) {
                settings.open(SettingsRoute(pane: SettingsPane.named("agents")))
                onboarding.finish()
                openSettings()
            }
        }
    }

    private var retentionDays: Int {
        settings.value(EsclopSettings.backupRetentionDays.key)?.intValue ?? EsclopSettings.backupRetentionDays.defaultValue
    }

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            if !onboarding.isLast {
                Button(Strings.text("Skip")) { onboarding.finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(Strings.text("Close the tour. It stays in the menu: Welcome to L’Esclop."))
            }
            if !onboarding.isFirst {
                Button(Strings.text("Back")) { withAnimation(animation) { onboarding.back() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if onboarding.isLast {
                Button(Strings.text("Get Started")) { onboarding.finish() }
                    .keyboardShortcut(.defaultAction)
                    .primaryButton()
                    .controlSize(.large)
            } else {
                Button(Strings.text("Continue")) { withAnimation(animation) { onboarding.next() } }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.l)
    }
}

/// Where the person is: the three steps as numbered circles on a line, the current one charcoal.
struct StepNumbers: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingModel.Step.allCases) { each in
                if each != OnboardingModel.Step.allCases.first {
                    Rectangle().fill(Ink.secondary.opacity(0.35)).frame(width: 36, height: 1)
                }
                Text("\(each.rawValue + 1)")
                    .font(Typeface.title)
                    .monospacedDigit()
                    .foregroundStyle(each == step ? AnyShapeStyle(Ink.onCharcoal) : AnyShapeStyle(Ink.text))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(each == step ? AnyShapeStyle(Ink.charcoal) : AnyShapeStyle(Surface.tile)))
                    .overlay(Circle().strokeBorder(Ink.secondary.opacity(each == step ? 0 : 0.3), lineWidth: 0.5))
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityElement()
        .accessibilityLabel(Strings.format("Step %d of %d: %@", step.rawValue + 1, OnboardingModel.Step.allCases.count, step.title))
    }
}

/// A step's one heading, in New York, and its sentence.
struct StepHeading: View {
    let title: String
    let summary: String?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Text(title)
                .font(Typeface.heading)
                .accessibilityAddTraits(.isHeader)
            if let summary {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, Spacing.l)
    }
}

// MARK: - Pages

/// 1. Copy or drop an image: a picture going to the clog in the menu bar, and macOS's clipboard
/// question when it is still to come.
struct CopyPage: View {
    let onboarding: OnboardingModel
    let example: CGImage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(
                title: OnboardingModel.Step.copy.title,
                summary: Strings.text("L’Esclop wakes up when you copy a screenshot or drop a file on the clog.")
            )
            HStack(spacing: Spacing.l) {
                PictureTile(image: example)
                    .frame(width: 150, height: 108)
                    .rotationEffect(.degrees(-4))
                Image(systemName: "arrow.turn.right.down")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Ink.saving)
                MenuBarStrip(icons: ["wifi", "battery.100"])
            }
            .padding(.top, Spacing.xl)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.text("A picture goes to the clog in the menu bar."))
            Spacer(minLength: Spacing.m)
            if onboarding.clipboardAccess == .asks || onboarding.clipboardAccess == .denied {
                HStack(spacing: Spacing.m) {
                    AccessBadge(access: onboarding.clipboardAccess)
                    Text(onboarding.clipboardAccess == .denied
                        ? Strings.text("macOS does not let L’Esclop read what you copy. Allow it in Privacy & Security.")
                        : Strings.text("macOS may ask before L’Esclop reads what you copy."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Strings.text("Privacy Settings…")) { openURL(OnboardingModel.privacySettings) }
                }
                .font(.callout)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.s)
            }
        }
    }
}

/// 2. The same image, lighter: the person's own result when one arrived while the tour was open,
/// otherwise an example that says it is one. The picture is the same size twice: compression
/// never shows as the image getting smaller (owner, 2026-11-13).
struct ResultPage: View {
    let result: OptimisationResult?
    let retentionDays: Int
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
            Figure(percentSaved: Int((saved * 100).rounded()), size: .panel)
                .padding(.top, Spacing.s)
            SavingGauge(saved: saved, shape: .arc, lineWidth: 4)
                .frame(width: 220, height: 34)
                .accessibilityHidden(true)
            HStack(spacing: Spacing.xl) {
                sized(Figures.bytes(before), ink: Ink.original, spoken: Strings.text("Before"))
                sized(Figures.bytes(after), ink: Ink.secondary, spoken: Strings.text("After"))
            }
            .padding(.top, Spacing.xs)
            Text(caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, Spacing.m)
            Spacer(minLength: 0)
        }
        .task(id: result?.id) {
            // An undone result, or one whose file is gone, leaves the example's stand-in.
            picture = nil
            guard let url = result?.output, FileManager.default.fileExists(atPath: url.path) else { return }
            picture = await Thumbnails.load(url, side: 240)
        }
    }

    private func sized(_ size: String, ink: some ShapeStyle, spoken: String) -> some View {
        VStack(spacing: Spacing.s) {
            PictureTile(image: result == nil ? example : picture)
                .frame(width: 180, height: 120)
                .accessibilityHidden(true)
            Text(size)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spoken), \(size)")
    }

    private var caption: String {
        let kept = retentionDays <= 0
            ? Strings.text("Nothing you can see changes. The original is always kept.")
            : Strings.format("Nothing you can see changes. The original is kept for %@.", SettingPresentation.retention(days: retentionDays))
        return result == nil ? kept + " " + Strings.text("This is an example: copy a screenshot to see your own.") : kept
    }
}

/// 3. Ready when you are: the clog in the menu bar, a result with what it offers, where results
/// go and what macOS asks next, Open at login and a way to connect an agent.
struct ReadyPage: View {
    let onboarding: OnboardingModel
    let retentionDays: Int
    let connectAgent: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(title: OnboardingModel.Step.ready.title, summary: nil)
            VStack(spacing: Spacing.m) {
                MenuBarStrip(icons: ["wifi", "battery.100", "magnifyingglass"])
                HStack(spacing: Spacing.m) {
                    SavingGauge(saved: 0.75, shape: .ring, lineWidth: 4)
                        .frame(width: 30, height: 30)
                    Figure(percentSaved: 75, size: .card)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(Capsule().fill(Surface.tile))
                HStack(spacing: Spacing.xl) {
                    action("square.on.square", Strings.text("Copy"))
                    action("folder", Strings.text("Show in Finder"))
                    action("arrow.uturn.backward", Strings.text("Undo"))
                }
            }
            .padding(.top, Spacing.m)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.text("A result under the clog, with Copy, Show in Finder and Undo."))
            Text(summary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, Spacing.m)
            HStack(spacing: Spacing.l) {
                Toggle(Strings.text("Open at login"), isOn: Binding(get: { onboarding.opensAtLogin }, set: { onboarding.opensAtLogin = $0 }))
                    .toggleStyle(.switch)
                    .tint(Ink.charcoal)
                    .switchLabel(title: Strings.text("Open at login"), hint: Strings.text("Keep L’Esclop in the menu bar after a restart, so copies are optimised from the start."))
                Button(Strings.text("Connect an AI Agent…"), action: connectAgent)
                    .textButton()
            }
            .padding(.top, Spacing.m)
            if let error = onboarding.loginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Ink.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            } else if onboarding.loginNeedsApproval {
                Button(Strings.text("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                    .textButton()
                    .help(Strings.text("macOS waits for you to allow L’Esclop in Login Items & Extensions."))
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        let kept = retentionDays <= 0
            ? Strings.text("Results appear in the corner and fade away. Originals are always kept.")
            : Strings.format("Results appear in the corner and fade away. Originals are kept for %@.", SettingPresentation.retention(days: retentionDays))
        return kept + " " + Strings.text("macOS will then ask to let L’Esclop see your Desktop, where screenshots land.")
    }

    private func action(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Ink.charcoalText)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Surface.tile))
                .overlay(Circle().strokeBorder(Ink.secondary.opacity(0.3), lineWidth: 0.5))
            Text(name).sectionLabel()
        }
    }
}

extension View {
    /// A text button: charcoal semibold, flat, never the system's link blue.
    func textButton() -> some View {
        buttonStyle(.plain).font(.body.weight(.semibold)).foregroundStyle(Ink.charcoalText)
    }
}

/// A picture on a tile: the given image, or a stand-in photo symbol.
struct PictureTile: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Surface.tile)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
                    // The tile sets the size; the picture fills it and is cut, never grows it.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile - 4, style: .continuous))
                    .padding(4)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Ink.secondary.opacity(0.25), lineWidth: 0.5))
    }
}

/// A piece of the menu bar with the clog first, as it looks up there.
struct MenuBarStrip: View {
    let icons: [String]

    var body: some View {
        HStack(spacing: Spacing.l) {
            Group {
                if let glyph = MenuBarLabel.customGlyph {
                    Image(nsImage: glyph).renderingMode(.template)
                } else {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Radius.key, style: .continuous).fill(NeutralFill.button))
            ForEach(icons, id: \.self) { Image(systemName: $0) }
        }
        .font(.system(size: 15))
        .foregroundStyle(Ink.text)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Capsule().fill(Surface.tile))
        .overlay(Capsule().strokeBorder(Ink.secondary.opacity(0.25), lineWidth: 0.5))
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

struct AccessBadge: View {
    let access: OnboardingModel.Access

    var body: some View {
        switch access {
        case .allowed:
            Label(Strings.text("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(Ink.charcoalText)
        case .asks:
            Label(Strings.text("Asks each time"), systemImage: "questionmark.circle").foregroundStyle(Ink.warm)
        case .denied:
            Label(Strings.text("Denied"), systemImage: "xmark.circle.fill").foregroundStyle(Ink.error)
        case .unknown:
            EmptyView()
        }
    }
}
