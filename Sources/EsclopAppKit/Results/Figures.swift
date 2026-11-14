// SPDX-License-Identifier: GPL-3.0-or-later
//
// The figures on the floating result, written the way DESIGN.md shows them: "612 kB · −75 %",
// "2.4 MB → 612 kB". Decimal (SI) units like Finder, one decimal below 10, the locale's decimal
// separator, a true minus and a no-break space before the percent sign.

import EsclopCore
import Foundation

public enum Figures {
    static let space = "\u{00A0}"

    public static func bytes(_ count: Int, locale: Locale = Strings.locale) -> String {
        let value = Double(max(0, count))
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("kB", 1e3)]
        for (unit, size) in units where value >= size * 0.9995 {
            return number(value / size, locale: locale) + space + unit
        }
        return "\(Int(value))" + space + "B"
    }

    /// "−75 %", "−0.4 %", "+12 %": the change from `before` to `after`.
    public static func percent(before: Int, after: Int, locale: Locale = Strings.locale) -> String {
        guard before > 0 else { return "0" + space + "%" }
        let value = abs(Double(before - after)) / Double(before) * 100
        return (after <= before ? "−" : "+") + number(value, locale: locale) + space + "%"
    }

    /// True when the change would read "−0 %": too small to call a saving.
    public static func isNoSaving(before: Int, after: Int) -> Bool {
        guard before > 0 else { return true }
        return after <= before && Double(before - after) / Double(before) * 100 < 0.05
    }

    /// "2.4 MB → 612 kB"
    public static func change(before: Int, after: Int, locale: Locale = Strings.locale) -> String {
        bytes(before, locale: locale) + " → " + bytes(after, locale: locale)
    }

    /// "0:37", "1:02:05"
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "12 s left", "3 min left"
    public static func timeLeft(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded(.up))
        return value < 60
            ? Strings.format("%d s left", value).replacingOccurrences(of: " s", with: space + "s")
            : Strings.format("%d min left", Int((Double(value) / 60).rounded(.up))).replacingOccurrences(of: " min", with: space + "min")
    }

    /// "−16 LUFS"
    public static func lufs(_ value: Double, locale: Locale = Strings.locale) -> String {
        (value < 0 ? "−" : "") + number(abs(value), locale: locale) + space + "LUFS"
    }

    /// One decimal below 10, whole numbers above: 2.4, 612, 37.
    static func number(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        let rounded = (value * 10).rounded() / 10
        formatter.maximumFractionDigits = rounded < 10 && rounded != rounded.rounded() ? 1 : 0
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        return formatter.string(from: NSNumber(value: formatter.maximumFractionDigits == 0 ? value.rounded() : rounded)) ?? "\(value)"
    }
}
