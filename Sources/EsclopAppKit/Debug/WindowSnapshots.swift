// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pictures of the app's own windows on request, for UI checks and pull request screenshots.
// Off unless ESCLOP_SNAPSHOT_DIR names a folder. Then a distributed notification named
// `dev.esclop.snapshot`, whose object is a label, writes every visible window of the app to
// `<folder>/<label>-<n>-<kind>.png` and a `<label>.json` that lists each window's frame.
//
//   open -n --env ESCLOP_SNAPSHOT_DIR=/tmp/shots "dist/L'Esclop.app"
//   osascript -l JavaScript -e '$.NSDistributedNotificationCenter.defaultCenter
//     .postNotificationNameObjectUserInfoDeliverImmediately("dev.esclop.snapshot", "after-copy", $(), true)'
//
// A process may capture its own windows without the screen recording permission, so this works
// in a session where nothing else can take screenshots. Only the app's windows are drawn:
// whatever is behind a glass panel is left out.

import AppKit

@MainActor
public final class WindowSnapshots: NSObject {
    public static let notificationName = Notification.Name("dev.esclop.snapshot")
    public static let environmentKey = "ESCLOP_SNAPSHOT_DIR"

    public struct Entry: Codable, Equatable, Sendable {
        public var file: String
        public var kind: String
        public var title: String
        /// In points, origin at the top left of the main screen.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var level: Int
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var label: String
        public var screenWidth: Double
        public var screenHeight: Double
        public var appearance: String
        public var windows: [Entry]
    }

    public let directory: URL

    /// Nil unless the environment asks for snapshots.
    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[Self.environmentKey], !path.isEmpty else { return nil }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        super.init()
    }

    public func start() {
        // Delivered at once: a menu bar app is never the active app, and the default behaviour
        // holds notifications back until it is.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(requested(_:)), name: Self.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    public func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func requested(_ note: Notification) {
        _ = try? write(label: note.object as? String ?? "")
    }

    /// Letters, digits, `-` and `_`; anything else becomes `-`, so a label is never a path.
    public nonisolated static func safe(_ text: String, fallback: String = "snapshot") -> String {
        let mapped = text.unicodeScalars.map { scalar -> Character in
            let allowed = (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) || scalar == "-" || scalar == "_"
            return allowed ? Character(scalar) : "-"
        }
        let trimmed = String(String(mapped).prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// What a window is, for the file name: its title, or its class without the module.
    public nonisolated static func kind(title: String, className: String) -> String {
        let name = title.isEmpty ? (className.split(separator: ".").last.map(String.init) ?? className) : title
        return safe(name, fallback: "window").lowercased()
    }

    /// Writes every visible window of the app; returns the manifest it wrote.
    @discardableResult
    public func write(label: String, windows: [NSWindow]? = nil) throws -> Manifest {
        let label = Self.safe(label)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first?.frame ?? .zero
        var entries: [Entry] = []
        let visible = (windows ?? NSApp.windows).filter { $0.isVisible && $0.frame.width >= 1 && $0.frame.height >= 1 }
        for (index, window) in visible.enumerated() {
            let kind = Self.kind(title: window.title, className: window.className)
            let file = "\(label)-\(index + 1)-\(kind).png"
            guard let image = Self.image(of: window),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            let frame = window.frame
            entries.append(Entry(
                file: file, kind: kind, title: window.title,
                x: frame.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height,
                level: window.level.rawValue
            ))
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let manifest = Manifest(
            label: label, screenWidth: screen.width, screenHeight: screen.height,
            appearance: dark ? "dark" : "light", windows: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("\(label).json"), options: .atomic)
        return manifest
    }

    /// The window as the window server composites it, glass included.
    /// `CGWindowListCreateImage` is marked unavailable in the macOS 15 SDK for new code but still
    /// ships; ScreenCaptureKit would need the screen recording permission.
    public nonisolated static func image(of window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // A window without a window server counterpart has no number the call can take.
        guard let number = MainActor.assumeIsolated({ UInt32(exactly: window.windowNumber) }), number > 0 else { return nil }
        // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
        return create(.null, 1 << 3, number, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}
