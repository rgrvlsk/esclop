// SPDX-License-Identifier: GPL-3.0-or-later
//
// Contrast of every colour the options popover draws, on its surface over a white and over a
// black desktop, light and dark (UI check, N1): at least 4.5:1 for text, 3:1 for icons. Set
// ESCLOP_CONTRAST_TABLE to a file path to write the table the PR shows.

@testable import EsclopAppKit
import Foundation
import Testing

@Suite struct PopoverInkTests {
    static let desktops: [(String, RGBA)] = [("white", .white), ("black", .black)]

    @Test func everyForegroundMeetsItsTarget() throws {
        var rows = ["| Colour | Light, white desktop | Light, black desktop | Dark, white desktop | Dark, black desktop | Target |", "|---|---|---|---|---|---|"]
        var pairs: [(PopoverInk.Token, Bool)] = PopoverInk.foregrounds.map { ($0, false) }
        pairs.append((PopoverInk.accent, true))
        for (token, selected) in pairs {
            let target = token.isIcon ? 3.0 : 4.5
            var cells: [String] = []
            for dark in [false, true] {
                for (_, desktop) in Self.desktops {
                    let ratio = PopoverInk.contrast(token, dark: dark, desktop: desktop, selected: selected)
                    #expect(ratio >= target, "\(token.name)\(selected ? " on the selected fill" : "") \(dark ? "dark" : "light"): \(ratio)")
                    cells.append(String(format: "%.1f:1", ratio))
                }
            }
            rows.append("| \(token.name)\(selected ? " (selected tile)" : "") | \(cells.joined(separator: " | ")) | \(token.isIcon ? "3:1" : "4.5:1") |")
        }
        // Before: the system's secondary and tertiary label colours on the surface the UI check
        // measured in dark mode (#5f6163 at 0.89).
        let measured = RGBA(0x5F6163, alpha: 0.89)
        for (name, ink) in [("Before: secondary label", RGBA(0xFFFFFF, alpha: 0.55)), ("Before: tertiary label", RGBA(0xFFFFFF, alpha: 0.25))] {
            let cells = Self.desktops.map { _, desktop -> String in
                let ground = measured.over(desktop)
                return String(format: "%.1f:1", RGBA.contrast(ink.over(ground), ground))
            }
            rows.append("| \(name) | – | – | \(cells.joined(separator: " | ")) | |")
        }
        if let path = ProcessInfo.processInfo.environment["ESCLOP_CONTRAST_TABLE"] {
            try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The popover's views draw with these inks only: no system style that takes its contrast
    /// from the desktop behind the glass.
    @Test func thePopoverUsesOnlyItsOwnInks() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EsclopAppKit/Options")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 5)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in [".foregroundStyle(.secondary)", ".foregroundStyle(.tertiary)", ".buttonStyle(.link)", "?? .primary"] {
                #expect(!text.contains(banned), "\(file.lastPathComponent) uses \(banned)")
            }
        }
    }

    @Test func theArithmeticMatchesWCAG() {
        #expect(abs(RGBA.contrast(.white, .black) - 21) < 0.01)
        #expect(abs(RGBA.contrast(RGBA(0x777777), .white) - 4.48) < 0.01)
        #expect(RGBA(0x000000, alpha: 0.5).over(.white) == RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1))
    }
}
