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
// A burst, for judging motion: user info `frames` (1–240) and `interval` (8–2000 ms) captures
// that many frames, one every `interval` ms from the request, as `<label>-f<NNN>-<n>-<kind>.png`,
// and `<label>.json` lists each frame's time and windows.
//
//   osascript -l JavaScript -e '$.NSDistributedNotificationCenter.defaultCenter
//     .postNotificationNameObjectUserInfoDeliverImmediately("dev.esclop.snapshot", "arrival",
//     $({frames: 30, interval: 33}), true)'
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
        /// A single snapshot's windows; for a burst, the first frame's.
        public var windows: [Entry]
        /// A burst's frames, in order; nil for a single snapshot.
        public var frames: [Frame]? = nil
    }

    public struct Frame: Codable, Equatable, Sendable {
        public var index: Int
        /// When the frame was taken, from the request.
        public var milliseconds: Double
        public var windows: [Entry]
    }

    /// How many frames, how far apart.
    public struct Burst: Equatable, Sendable {
        public static let maxFrames = 240
        public static let intervals = 8 ... 2000

        public var frames: Int
        public var interval: Int

        public init(frames: Int, interval: Int) {
            self.frames = min(max(frames, 1), Self.maxFrames)
            self.interval = min(max(interval, Self.intervals.lowerBound), Self.intervals.upperBound)
        }

        /// From a request's user info, `frames` and `interval` (milliseconds), as numbers or
        /// text. Nil, a single snapshot, without `frames` or with fewer than two.
        public static func from(_ info: [AnyHashable: Any]?) -> Burst? {
            func number(_ key: String) -> Int? {
                switch info?[key] {
                case let value as NSNumber: value.intValue
                case let value as String: Int(value.trimmingCharacters(in: .whitespaces))
                default: nil
                }
            }
            guard let frames = number("frames"), frames > 1 else { return nil }
            return Burst(frames: frames, interval: number("interval") ?? 33)
        }
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
        let label = note.object as? String ?? ""
        if let burst = Burst.from(note.userInfo) {
            Task { _ = try? await write(label: label, burst: burst) }
        } else {
            _ = try? write(label: label)
        }
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

    /// Writes `burst.frames` frames of every visible window, one every `burst.interval` ms. Frames
    /// are captured on time and encoded off the main actor, so writing never delays the next one.
    @discardableResult
    public func write(label: String, burst: Burst, windows: (() -> [NSWindow])? = nil) async throws -> Manifest {
        let label = Self.safe(label)
        let directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first?.frame ?? .zero
        let clock = ContinuousClock()
        let start = clock.now
        var frames: [Frame] = []
        var encodes: [Task<Void, Never>] = []
        for index in 0 ..< burst.frames {
            try? await Task.sleep(until: start + .milliseconds(index * burst.interval), clock: clock)
            let elapsed = start.duration(to: clock.now)
            let visible = (windows?() ?? NSApp.windows).filter { $0.isVisible && $0.frame.width >= 1 && $0.frame.height >= 1 }
            var entries: [Entry] = []
            for (number, window) in visible.enumerated() {
                guard let image = Self.image(of: window) else { continue }
                let kind = Self.kind(title: window.title, className: window.className)
                let file = String(format: "%@-f%03d-%d-%@.png", label, index + 1, number + 1, kind)
                let frame = window.frame
                entries.append(Entry(
                    file: file, kind: kind, title: window.title,
                    x: frame.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height,
                    level: window.level.rawValue
                ))
                let url = directory.appendingPathComponent(file)
                encodes.append(Task.detached(priority: .utility) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
                })
            }
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            frames.append(Frame(index: index + 1, milliseconds: (milliseconds * 10).rounded() / 10, windows: entries))
        }
        for encode in encodes { await encode.value }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let manifest = Manifest(
            label: label, screenWidth: screen.width, screenHeight: screen.height,
            appearance: dark ? "dark" : "light", windows: frames.first?.windows ?? [], frames: frames
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
