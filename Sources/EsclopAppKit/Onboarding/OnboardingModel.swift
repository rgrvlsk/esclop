// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first-run window's state: which step is showing, whether onboarding has been finished
// (or skipped), and the permissions the app depends on. It opens by itself once, on the first
// launch, and again from the menu whenever the person wants.

import AppKit
import EsclopCore
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        case welcome, automatic, permissions, agents, done

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .welcome: return Strings.text("Welcome")
            case .automatic: return Strings.text("Automatic")
            case .permissions: return Strings.text("Permissions")
            case .agents: return Strings.text("Agents")
            case .done: return Strings.text("Done")
            }
        }
    }

    public private(set) var step: Step = .welcome
    /// The direction of the last move, so the transition slides the right way.
    public private(set) var forward = true

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var onFinish: () -> Void = {}

    /// Set once the person finishes or skips; the window then only opens from the menu.
    public static let finishedKey = "finishedOnboarding"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        refreshAccess()
        // Back from System Settings, the badge and the switch show what the person chose there.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
    }

    // ponytail: never removed; the app keeps one model for its lifetime, and the block holds it weakly.
    @ObservationIgnored private var activation: (any NSObjectProtocol)?

    public var isFinished: Bool { defaults.bool(forKey: Self.finishedKey) }
    public var shouldShowAtLaunch: Bool { !isFinished }

    public var isFirst: Bool { step == Step.allCases.first }
    public var isLast: Bool { step == Step.allCases.last }

    public func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { finish(); return }
        forward = true
        step = following
        if step.rawValue >= Step.permissions.rawValue { startWatching() }
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
    }

    public func go(to target: Step) {
        forward = target.rawValue >= step.rawValue
        step = target
        if step.rawValue >= Step.permissions.rawValue { startWatching() }
    }

    /// Starts watching the folders (AppServices, on the first run): only once the Permissions page
    /// explains why macOS asks about the Desktop, or the tour ends, so the question never covers
    /// the Welcome page. Runs once.
    @ObservationIgnored public var onPermissions: (() -> Void)?

    private func startWatching() {
        let start = onPermissions
        onPermissions = nil
        start?()
    }

    /// Skip and Done both end it for good; the menu can still bring it back.
    public func finish() {
        windowClosed()
        onFinish()
    }

    /// Closing the window (its close button, ⌘W) ends it too, or it would open at every launch.
    public func windowClosed() {
        defaults.set(true, forKey: Self.finishedKey)
        startWatching()
    }

    /// Back to the first step, for opening it again from the menu.
    public func restart() {
        forward = true
        step = .welcome
    }

    // MARK: Permissions

    public enum Access: Equatable, Sendable {
        case allowed
        case asks
        case denied
        /// Not reported by this macOS.
        case unknown
    }

    /// Whether macOS lets L’Esclop read copied images without asking, as of the last time the app
    /// came to the front.
    public private(set) var clipboardAccess: Access = .unknown
    /// The login item's state, as of the last time the app came to the front.
    public private(set) var loginStatus: SMAppService.Status = .notRegistered

    @ObservationIgnored var readClipboardAccess: @MainActor () -> Access = OnboardingModel.systemClipboardAccess
    @ObservationIgnored var readLoginStatus: @MainActor () -> SMAppService.Status = { SMAppService.mainApp.status }

    public func refreshAccess() {
        clipboardAccess = readClipboardAccess()
        loginStatus = readLoginStatus()
        // Again only once its page read it: reading the Desktop is what makes macOS ask.
        if step == .permissions, desktopAccess != .unknown { checkDesktop() }
    }

    /// Whether L’Esclop may read the Desktop, as Settings' folder rows see it; unknown until the
    /// Permissions page shows.
    public private(set) var desktopAccess: Access = .unknown
    @ObservationIgnored var readDesktopAccess: @MainActor () -> Access = {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return .unknown }
        switch FolderStatus.check(desktop) {
        case .watching: return .allowed
        case .unreadable: return .denied
        case .missing, .notWatching: return .unknown
        }
    }

    public func checkDesktop() {
        desktopAccess = readDesktopAccess()
    }

    /// macOS 15.4 and later can ask before every programmatic read of the clipboard.
    static func systemClipboardAccess() -> Access {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            case .ask, .default: return .asks
            @unknown default: return .unknown
            }
        }
        #endif
        return .unknown
    }

    /// Open at login, through the system's login items. Registered but waiting for the person's
    /// approval in Login Items counts as on: turning it off there is their call, not ours.
    public var opensAtLogin: Bool {
        get { loginStatus == .enabled || loginStatus == .requiresApproval }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = Strings.format("macOS did not add L’Esclop to the login items: %@. Add it in System Settings › General › Login Items & Extensions.", error.localizedDescription)
            }
            loginStatus = readLoginStatus()
        }
    }

    /// On, but macOS waits for the person to allow it in System Settings › General › Login Items & Extensions.
    public var loginNeedsApproval: Bool { loginStatus == .requiresApproval }

    public var loginError: String?

    /// System Settings at Privacy & Security › Paste from Other Apps (Privacy & Security on a macOS
    /// without that list).
    public static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
}
