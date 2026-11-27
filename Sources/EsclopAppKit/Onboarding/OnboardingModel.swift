// SPDX-License-Identifier: GPL-3.0-or-later
//
// The first-run window's state: which of its three steps is showing, whether it has been
// finished (or skipped), the person's first result while it is open, and the clipboard access
// and login item it shows. It opens by itself once, on the first launch, and again from the
// menu whenever the person wants.

import AppKit
import EsclopCore
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        case copy, result, ready

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .copy: return Strings.text("Copy or drop an image")
            case .result: return Strings.text("Same image. Lighter file.")
            case .ready: return Strings.text("Ready when you are")
            }
        }
    }

    public private(set) var step: Step = .copy
    /// When the tour last opened: a result after it is the person's own, shown on the second step.
    public private(set) var openedAt = Date()
    /// The newest results first (the app's recent results); none in tests and renders.
    @ObservationIgnored public var results: @MainActor () -> [OptimisationResult] = { [] }

    /// The first image the person optimised while the tour was open, if it made the file smaller.
    public var ownResult: OptimisationResult? {
        results().last { $0.finishedAt >= openedAt && $0.kind == .image && $0.bytesAfter < $0.bytesBefore }
    }
    /// The direction of the last move, so the transition slides the right way.
    public private(set) var forward = true
    /// The furthest step shown: every step up to it stays a button back or forward to it.
    public private(set) var furthest: Step = .copy

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
        if following.rawValue > furthest.rawValue { furthest = following }
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
    }

    public func go(to target: Step) {
        forward = target.rawValue >= step.rawValue
        step = target
        if target.rawValue > furthest.rawValue { furthest = target }
    }

    /// Starts watching the folders (AppServices, on the first run): once the tour ends, or the
    /// person leaves its window for another, so macOS's Desktop question never covers a step.
    /// Runs once.
    @ObservationIgnored public var onPermissions: (() -> Void)?

    /// The tour's window gave the keyboard to another: a tour left open must not keep the folders
    /// from being watched.
    public func windowLeft() {
        startWatching()
    }

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
        step = .copy
        furthest = .copy
        openedAt = Date()
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
    @ObservationIgnored var setLoginItem: @MainActor (Bool) throws -> Void = { on in
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    public func refreshAccess() {
        clipboardAccess = readClipboardAccess()
        loginStatus = readLoginStatus()
        // The person set it in System Settings as asked: the refusal no longer holds.
        if let wanted = loginWanted, opensAtLogin == wanted { loginError = nil }
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
            loginWanted = newValue
            do {
                try setLoginItem(newValue)
                loginError = nil
            } catch {
                loginError = newValue
                    ? Strings.format("macOS did not add L’Esclop to the login items: %@. Add it in System Settings › General › Login Items & Extensions.", error.localizedDescription)
                    : Strings.format("macOS did not remove L’Esclop from the login items: %@. Remove it in System Settings › General › Login Items & Extensions.", error.localizedDescription)
            }
            loginStatus = readLoginStatus()
        }
    }

    /// On, but macOS waits for the person to allow it in System Settings › General › Login Items & Extensions.
    public var loginNeedsApproval: Bool { loginStatus == .requiresApproval }

    public var loginError: String?
    /// What the person last asked of Open at login: which way a refusal went.
    public private(set) var loginWanted: Bool?

    /// System Settings at Privacy & Security › Paste from Other Apps (Privacy & Security on a macOS
    /// without that list).
    public static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
}
