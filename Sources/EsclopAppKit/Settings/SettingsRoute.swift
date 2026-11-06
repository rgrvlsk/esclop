// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deep links into the Settings window, shaped like Clop's settings links:
//   esclop://settings                       the window, on the last pane
//   esclop://settings/images                a pane, by id or title
//   esclop://settings/imageCompression      a setting: its pane, scrolled to and highlighted
//   esclop://settings/images/imageCompression
//   esclop://settings/images?highlight=imageCompression

import Foundation

public struct SettingsRoute: Equatable, Sendable {
    public var pane: SettingsPane?
    /// The row to scroll to and highlight: a registry key or a row id such as `hotkey.optimiseClipboard`.
    public var row: String?

    public init(pane: SettingsPane? = nil, row: String? = nil) {
        self.pane = pane
        self.row = row
    }

    public static let scheme = "esclop"
    public static let host = "settings"

    /// Parses a link. `paneOf` finds the pane of a row id, so a link that names only the row
    /// opens the right pane, and a stale pane in the link does not win over the row's real one.
    /// Nil when the URL is not a settings link.
    public init?(url: URL, paneOf: (String) -> SettingsPane?) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let named = parts.first.flatMap(SettingsPane.named)
        let pathRow = parts.count > 1 ? parts[1] : (named == nil ? parts.first : nil)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "highlight" || $0.name == "key" }?.value
        let row = (pathRow ?? query).flatMap { $0.isEmpty ? nil : $0 }
        self.row = row
        pane = row.flatMap(paneOf) ?? named
    }

    /// The link to one setting: `esclop://settings/<pane>/<key>`. The pane is spelled out so the
    /// link reads as where it goes; opening it looks the pane up from the key anyway.
    public static func link(pane: SettingsPane, row: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(pane.rawValue)/\(row)"
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func link(pane: SettingsPane) -> URL {
        URL(string: "\(scheme)://\(host)/\(pane.rawValue)")!
    }
}
