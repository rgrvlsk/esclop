// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first-run window: welcome, what L'Esclop does on its own (the same rows as Settings),
// what macOS will ask and why, connecting an agent (the Agents pane's section), and where to
// find it afterwards. Every step can be skipped; the menu opens it again.

import AppKit
import EsclopCore
import EsclopIPC
import EsclopMCP
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

public struct OnboardingView: View {
    let onboarding: OnboardingModel
    let settings: SettingsViewModel
    let agents: AgentsModel?
    let actions: SettingsActions
    let openSettings: () -> Void
    /// The app's icon; renders pass the one in `assets/`, since a test process has none.
    let icon: NSImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        onboarding: OnboardingModel, settings: SettingsViewModel, agents: AgentsModel?, actions: SettingsActions,
        icon: NSImage? = NSApp.applicationIconImage, openSettings: @escaping () -> Void
    ) {
        self.onboarding = onboarding
        self.icon = icon
        self.settings = settings
        self.agents = agents
        self.actions = actions
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(onboarding.step)
                    .id(onboarding.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
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
        case .welcome: WelcomePage(icon: icon)
        case .automatic: AutomaticPage(settings: settings, actions: actions)
        case .permissions: PermissionsPage(onboarding: onboarding, actions: actions)
        case .agents: AgentsPage(agents: agents, settings: settings, actions: actions)
        case .done:
            DonePage { name in
                settings.open(SettingsRoute(pane: .general, row: Hotkeys.rowID(name)))
                openSettings()
            }
        }
    }

    private var footer: some View {
        HStack {
            if !onboarding.isLast {
                Button(Strings.text("Skip")) { onboarding.finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(Strings.text("Close the tour. It stays in the menu: Welcome to L’Esclop."))
            }
            Spacer()
            StepDots(step: onboarding.step)
            Spacer()
            if !onboarding.isFirst {
                Button(Strings.text("Back")) { withAnimation(animation) { onboarding.back() } }
            }
            if onboarding.isLast {
                Button(Strings.text("Open Settings")) {
                    onboarding.finish()
                    openSettings()
                }
                Button(Strings.text("Done")) { onboarding.finish() }
                    .keyboardShortcut(.defaultAction)
                    .primaryButton()
            } else {
                Button(onboarding.isFirst ? Strings.text("Get Started") : Strings.text("Continue")) { withAnimation(animation) { onboarding.next() } }
                    .keyboardShortcut(.defaultAction)
                    .primaryButton()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Where the person is: one dot per step, the current one filled with the accent.
struct StepDots: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingModel.Step.allCases) { each in
                Capsule()
                    .fill(each == step ? AnyShapeStyle(Ink.charcoal) : AnyShapeStyle(.quaternary))
                    .frame(width: each == step ? 18 : 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityElement()
        .accessibilityLabel(Strings.format("Step %d of %d: %@", step.rawValue + 1, OnboardingModel.Step.allCases.count, step.title))
    }
}

/// The heading every step but the first carries.
struct PageHeading: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 36)
    }
}

// MARK: - Pages

struct WelcomePage: View {
    let icon: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
            }
            Text(Strings.text("L’Esclop"))
                .font(.largeTitle.weight(.bold))
                .padding(.top, 12)
            Text(Strings.text("Makes the images, videos, PDFs and audio you copy and drop smaller, right where they are."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // Catalan runs to three lines; without this the stack cut it to one.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 16) {
                Point(symbol: "doc.on.clipboard", title: Strings.text("Copy a screenshot"), text: Strings.text("It is optimised at once and put back on the clipboard, smaller."))
                Point(symbol: "square.and.arrow.down.on.square", title: Strings.text("Drag files"), text: Strings.text("A drop zone appears in the corner; drop on it to optimise."))
                Point(symbol: "arrow.uturn.backward", title: Strings.text("Change your mind"), text: Strings.text("Originals are kept, so every result can be undone."))
                Point(symbol: "sparkles", title: Strings.text("Ask an agent"), text: Strings.text("Claude, Codex, Cursor and others can optimise, convert and crop for you."))
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.top, 28)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
    }

    struct Point: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(Ink.charcoalText)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The settings that decide what happens without asking, as the same rows Settings shows.
struct AutomaticPage: View {
    let settings: SettingsViewModel
    let actions: SettingsActions

    static let keys = [
        EsclopSettings.enableClipboardOptimiser.key, EsclopSettings.optimiseVideoClipboard.key,
        EsclopSettings.optimisePDFClipboard.key, EsclopSettings.optimiseAudioClipboard.key,
        EsclopSettings.enableDragAndDrop.key, EsclopSettings.optimisedImageBehaviour.key,
    ]

    /// 0 keeps originals for ever: "kept for 0 days" read as the opposite.
    static func summary(retentionDays days: Int) -> String {
        days <= 0
            ? Strings.text("L’Esclop optimises what you copy as soon as you copy it. Originals are always kept and can be restored from the menu.")
            : Strings.format("L’Esclop optimises what you copy as soon as you copy it. Originals are kept for %@ and can be restored from the menu.", SettingPresentation.retention(days: days))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(
                title: Strings.text("What happens on its own"),
                summary: Self.summary(retentionDays: settings.value(EsclopSettings.backupRetentionDays.key)?.intValue ?? EsclopSettings.backupRetentionDays.defaultValue)
            )
            Form {
                Section {
                    ForEach(Self.keys.compactMap(settings.descriptor), id: \.key) { descriptor in
                        SettingRow(descriptor: descriptor, model: settings, actions: actions)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }
}

/// What macOS will ask for, why, and the one switch that is a system setting (open at login).
struct PermissionsPage: View {
    let onboarding: OnboardingModel
    let actions: SettingsActions
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(
                title: Strings.text("What macOS will ask"),
                summary: Strings.text("Files are optimised on this Mac, with no account. They leave it only when you upload them or set up automatic uploads. L’Esclop needs no Accessibility, Screen Recording or Full Disk Access.")
            )
            Form {
                Section {
                    LabeledContent {
                        HStack {
                            AccessBadge(access: onboarding.clipboardAccess)
                            Button(Strings.text("Privacy Settings…")) { openURL(OnboardingModel.privacySettings) }
                        }
                    } label: {
                        SettingLabel(
                            title: Strings.text("Read the clipboard"),
                            summary: Strings.text("To find images you copy. macOS may ask before L’Esclop reads it; choose Allow under Privacy & Security › Paste from Other Apps so it does not ask every time.")
                        )
                    }
                    // The Desktop as Settings sees it: asking here is what brings macOS's
                    // question, while this page explains it.
                    LabeledContent {
                        HStack {
                            AccessBadge(access: onboarding.desktopAccess)
                            if onboarding.desktopAccess == .denied {
                                Button(Strings.text("Privacy Settings…")) { FolderRow.openPrivacySettings() }
                            }
                        }
                    } label: {
                        SettingLabel(
                            title: Strings.text("Files in Desktop, Documents and Downloads"),
                            summary: Strings.text("macOS will ask to let L’Esclop see your Desktop: that is where screenshots land, and L’Esclop watches it for new ones. It asks again the first time L’Esclop replaces a file in Documents or Downloads. If you say no, the Desktop is left alone; Settings › Images shows how to allow it later.")
                        )
                    }
                    LoginItemRows(onboarding: onboarding)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .onAppear { onboarding.checkDesktop() }
    }
}

/// Open at login, the one switch that is a system setting: in the tour and in Settings › General,
/// on the same model, with what macOS still waits for and why it refused.
struct LoginItemRows: View {
    let onboarding: OnboardingModel
    /// Settings' row id, which a deep link or a search result scrolls to and marks.
    var rowID: String?
    var highlighted = false

    var body: some View {
        TitledToggle(
            title: Strings.text("Open at login"),
            subtitle: Strings.text("Keep L’Esclop in the menu bar after a restart, so copies are optimised from the start."),
            isOn: Binding(get: { onboarding.opensAtLogin }, set: { onboarding.opensAtLogin = $0 })
        )
        .id(rowID)
        .highlighted(highlighted)
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

/// The Agents pane's list, so an agent can be connected without leaving the tour.
struct AgentsPage: View {
    let agents: AgentsModel?
    let settings: SettingsViewModel
    let actions: SettingsActions

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(
                title: Strings.text("Connect an AI agent"),
                summary: Strings.text("Agents use L’Esclop through its MCP server to optimise, convert and crop files when you ask them. You can do this later in Settings › Agents and MCP.")
            )
            if let agents {
                Form {
                    AgentsConnectSection(agents: agents, model: settings, actions: actions)
                }
                .formStyle(.grouped)
            } else {
                Spacer()
            }
        }
    }
}

struct DonePage: View {
    /// Opens a hotkey's row in Settings.
    var setShortcut: (KeyboardShortcuts.Name) -> Void = { _ in }
    /// Read again when the window comes back from Settings, where a key may have been set.
    @State private var shortcutsRead = 0

    /// "Look for <icon> at the top of the screen…": the sentence comes from the catalog with %@
    /// where the icon goes, so each language puts it where it reads naturally.
    static func lookFor(_ icon: Image) -> Text {
        let parts = Strings.text("Look for %@ at the top of the screen. It has recent results, originals to restore and Settings.").components(separatedBy: "%@")
        guard parts.count == 2 else { return Text(parts.joined()) }
        return Text(parts[0]) + Text(icon) + Text(parts[1])
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Ink.charcoalText)
                .accessibilityHidden(true)
            Text(Strings.text("L’Esclop is in the menu bar"))
                .font(.title.weight(.semibold))
                .padding(.top, 14)
            Group {
                if let glyph = MenuBarLabel.customGlyph {
                    // A template, so it takes the text colour: as is, it was dark on the dark ground.
                    Self.lookFor(Image(nsImage: glyph).renderingMode(.template))
                } else {
                    Text(Strings.text("Look for the clog at the top of the screen. It has recent results, originals to restore and Settings."))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: 520)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                    GridRow {
                        Group {
                            let _ = shortcutsRead
                            if let shortcut = KeyboardShortcuts.getShortcut(for: hotkey.name) {
                                Text(shortcut.description)
                                    .font(.title3.weight(.medium))
                                    .monospacedDigit()
                            } else {
                                // "Go to the newest result" has no key until one is set: this
                                // opens its row in Settings, so the keyboard alone finds it.
                                Button(Strings.text("Set…")) { setShortcut(hotkey.name) }
                            }
                        }
                        .gridColumnAlignment(.trailing)
                        Text(hotkey.title)
                    }
                }
            }
            .padding(.top, 28)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in shortcutsRead += 1 }
            Text(Strings.text("Change the shortcuts in Settings › General."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            // The card keys (DESIGN.md › Keys), the three most used. They are fixed, so they sit
            // apart from the shortcuts Settings changes.
            Grid(alignment: .leading, horizontalSpacing: 18) {
                GridRow {
                    Text(Strings.text("Space, ⌘Z, ⌘C"))
                        .font(.title3.weight(.medium))
                        .gridColumnAlignment(.trailing)
                    Text(Strings.text("On the result under the pointer: Quick Look, Undo, Copy"))
                }
            }
            .padding(.top, 22)
            Spacer(minLength: 24)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
}
