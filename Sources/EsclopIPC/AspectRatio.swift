// SPDX-License-Identifier: GPL-3.0-or-later
//
// Aspect ratios people type: `16:9`, `4x5`, `0.75`, or a paper size or device name for PDF crops.

import EsclopCore
import Foundation

public enum AspectRatio {
    /// Portrait sizes (width, height). Paper in millimetres or inches, devices in pixels.
    public static let presets: [(name: String, width: Double, height: Double)] = [
        ("A3", 297, 420), ("A4", 210, 297), ("A5", 148, 210), ("B5", 176, 250),
        ("Letter", 8.5, 11), ("Legal", 8.5, 14), ("Tabloid", 11, 17),
        ("iPad", 1640, 2360), ("iPad mini", 1488, 2266), ("iPad Air 13", 2048, 2732), ("iPad Pro 13", 2064, 2752),
        ("iPhone", 1179, 2556), ("Kindle Paperwhite", 1236, 1648), ("Kindle Scribe", 1860, 2480),
        ("Kobo Libra", 1264, 1680), ("reMarkable 2", 1404, 1872),
    ]

    public static var presetNames: [String] { presets.map(\.name) }

    /// Width divided by height.
    public static func parse(_ text: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let preset = presets.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return preset.width / preset.height
        }
        for separator in [":", "x", "X", "/", "×"] where trimmed.contains(separator) {
            let parts = trimmed.split(separator: Character(separator)).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let w = parts[0], let h = parts[1], w > 0, h > 0 { return w / h }
        }
        if let value = Double(trimmed), value > 0 { return value }
        throw EsclopError.invalidArgument("Expected a ratio like 16:9, 3x4 or 0.75, or one of \(presetNames.joined(separator: ", ")); got \(text)")
    }

    /// `1920x1080` → width and height; `16:9` → aspect ratio; `1600` → long edge.
    public static func cropSize(_ text: String, longEdge: Bool = false, smart: Bool = false) throws -> CropSize {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            _ = try parse(trimmed)
            return CropSize(aspectRatio: trimmed, smart: smart)
        }
        for separator in ["x", "X", "×"] where trimmed.contains(separator) {
            let parts = trimmed.split(separator: Character(separator), omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { break }
            let width = parts[0].isEmpty ? nil : Int(parts[0])
            let height = parts[1].isEmpty ? nil : Int(parts[1])
            if (parts[0].isEmpty || width != nil), (parts[1].isEmpty || height != nil), width != nil || height != nil {
                return CropSize(width: width, height: height, smart: smart)
            }
        }
        if let single = Int(trimmed), single > 0 {
            return longEdge ? CropSize(longEdge: single, smart: smart) : CropSize(width: single, smart: smart)
        }
        throw EsclopError.invalidArgument("Expected WxH (1920x1080, 1600x for width only), a ratio (16:9) or one number; got \(text)")
    }
}
