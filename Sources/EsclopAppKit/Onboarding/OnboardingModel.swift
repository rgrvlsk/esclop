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
            case .welcome: return "Welcome"
            case .automatic: return "Automatic"
            case .permissions: return "Permissions"
            case .agents: return "Agents"
            case .done: return "Done"
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
    }

    public var isFinished: Bool { defaults.bool(forKey: Self.finishedKey) }
    public var shouldShowAtLaunch: Bool { !isFinished }

    public var isFirst: Bool { step == Step.allCases.first }
    public var isLast: Bool { step == Step.allCases.last }

    public func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { finish(); return }
        forward = true
        step = following
    }

    public func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
    }

    public func go(to target: Step) {
        forward = target.rawValue >= step.rawValue
        step = target
    }

    /// Skip and Done both end it for good; the menu can still bring it back.
    public func finish() {
        defaults.set(true, forKey: Self.finishedKey)
        onFinish()
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

    /// Whether macOS lets L'Esclop read copied images without asking (macOS 15.4 and later
    /// can ask before every programmatic read of the clipboard).
    public var clipboardAccess: Access {
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

    /// Open at login, through the system's login items.
    public var opensAtLogin: Bool {
        get {
            access(keyPath: \.opensAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.opensAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = "macOS did not add L'Esclop to the login items: \(error.localizedDescription). Add it in System Settings → General → Login Items."
                }
            }
        }
    }

    public var loginError: String?

    /// System Settings at Privacy & Security, where Paste from Other Apps lives.
    public static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
}
