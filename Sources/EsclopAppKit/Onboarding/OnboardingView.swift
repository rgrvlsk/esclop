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
        .tint(Palette.accent)
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
        case .done: DonePage()
        }
    }

    private var footer: some View {
        HStack {
            if !onboarding.isLast {
                Button("Skip") { onboarding.finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close the tour. It stays in the menu: Welcome to L'Esclop.")
            }
            Spacer()
            StepDots(step: onboarding.step)
            Spacer()
            if !onboarding.isFirst {
                Button("Back") { withAnimation(animation) { onboarding.back() } }
            }
            if onboarding.isLast {
                Button("Open Settings") {
                    onboarding.finish()
                    openSettings()
                }
                Button("Done") { onboarding.finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(onboarding.isFirst ? "Get Started" : "Continue") { withAnimation(animation) { onboarding.next() } }
                    .keyboardShortcut(.defaultAction)
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
                    .fill(each == step ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary))
                    .frame(width: each == step ? 18 : 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingModel.Step.allCases.count): \(step.title)")
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
            Text("L'Esclop")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 12)
            Text("Makes the images, videos, PDFs and audio you copy and drop smaller, right where they are.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 16) {
                Point(symbol: "doc.on.clipboard", title: "Copy a screenshot", text: "It is optimised at once and put back on the clipboard, smaller.")
                Point(symbol: "square.and.arrow.down.on.square", title: "Drag files", text: "A drop zone appears in the corner; drop on it to optimise.")
                Point(symbol: "arrow.uturn.backward", title: "Change your mind", text: "Originals are kept, so every result can be undone.")
                Point(symbol: "sparkles", title: "Ask an agent", text: "Claude, Codex, Cursor and others can optimise, convert and crop for you.")
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
                    .foregroundStyle(Palette.accent)
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

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(
                title: "What happens on its own",
                summary: "L'Esclop optimises what you copy as soon as you copy it. Originals are kept for \(SettingPresentation.display(settings.value(EsclopSettings.backupRetentionDays.key), for: settings.descriptor(EsclopSettings.backupRetentionDays.key)!)) and can be restored from the menu."
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
                title: "What macOS will ask",
                summary: "Everything runs on this Mac: no account, no network, nothing leaves it. L'Esclop needs no Accessibility, Screen Recording or Full Disk Access."
            )
            Form {
                Section {
                    LabeledContent {
                        HStack {
                            AccessBadge(access: onboarding.clipboardAccess)
                            Button("Privacy Settings…") { openURL(OnboardingModel.privacySettings) }
                        }
                    } label: {
                        SettingLabel(
                            title: "Read the clipboard",
                            summary: "To find images you copy. macOS may ask before L'Esclop reads it; choose Always Allow under Privacy & Security → Paste from Other Apps so it does not ask every time."
                        )
                    }
                    LabeledContent {
                        Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    } label: {
                        SettingLabel(
                            title: "Files in Desktop, Documents and Downloads",
                            summary: "macOS asks the first time L'Esclop replaces a file in one of these folders. Allow it so optimised files can go back where they were."
                        )
                    }
                    Toggle(isOn: Binding(get: { onboarding.opensAtLogin }, set: { onboarding.opensAtLogin = $0 })) {
                        SettingLabel(title: "Open at login", summary: "Keep L'Esclop in the menu bar after a restart, so copies are optimised from the start.")
                    }
                    if let error = onboarding.loginError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }
}

struct AccessBadge: View {
    let access: OnboardingModel.Access

    var body: some View {
        switch access {
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.accent)
        case .asks:
            Label("Asks each time", systemImage: "questionmark.circle").foregroundStyle(Palette.warm)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill").foregroundStyle(.red)
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
                title: "Connect an AI agent",
                summary: "Agents use L'Esclop through its MCP server to optimise, convert and crop files when you ask them. You can do this later in Settings → Agents and MCP."
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
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("L'Esclop is in the menu bar")
                .font(.title.weight(.semibold))
                .padding(.top, 14)
            Group {
                if let glyph = MenuBarLabel.customGlyph {
                    Text("Look for \(Image(nsImage: glyph)) at the top of the screen. It has recent results, originals to restore and Settings.")
                } else {
                    Text("Look for the clog at the top of the screen. It has recent results, originals to restore and Settings.")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .frame(maxWidth: 520)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(Hotkeys.all, id: \.name.rawValue) { hotkey in
                    GridRow {
                        Text(KeyboardShortcuts.getShortcut(for: hotkey.name)?.description ?? "None")
                            .font(.title3.weight(.medium))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(hotkey.title)
                    }
                }
            }
            .padding(.top, 28)
            Text("Change the shortcuts in Settings → General.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            Spacer(minLength: 24)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
}
