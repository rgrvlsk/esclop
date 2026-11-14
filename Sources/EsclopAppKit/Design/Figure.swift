// SPDX-License-Identifier: GPL-3.0-or-later
//
// The saving as a piece of typography (docs/design/proposal.md › Spark 1): SF Pro Compressed,
// bold, tall and narrow, in `Ink.saving`. Its unit ("%", "MB") is 55 % of its size, semibold,
// raised to the cap line. Only a saving is ever set this way, and at most one per surface.

import Foundation
import SwiftUI

public struct Figure: View {
    /// The four sizes.
    public enum Size: CGFloat, CaseIterable, Sendable {
        /// The card, inside its 50 pt ring (`CardFooter.ring`).
        case card = 17
        /// The menu panel, the options popover.
        case panel = 32
        /// The detail, inside its 62 pt ring; batch and All Results until they have their own.
        case detail = 20
        /// The first run.
        case firstRun = 72
    }

    /// The number with its sign, "−75".
    public let number: String
    /// "%", "MB"; empty for none.
    public let unit: String
    /// The whole figure as the locale writes it, "−75%" or "−75 %": what VoiceOver reads.
    public let spoken: String
    public let size: CGFloat
    /// `saving`, or the secondary ink for a result that grew.
    public var color: AnyShapeStyle

    public init(number: String, unit: String, spoken: String, size: CGFloat, color: some ShapeStyle = Ink.saving) {
        self.number = number
        self.unit = unit
        self.spoken = spoken
        self.size = size
        self.color = AnyShapeStyle(color)
    }

    /// A percentage saved: "−75 %".
    public init(percentSaved: Int, size: Size, locale: Locale = .current, color: some ShapeStyle = Ink.saving) {
        let parts = Self.percentParts(percentSaved, locale: locale)
        self.init(number: parts.number, unit: parts.unit, spoken: parts.text, size: size.rawValue, color: color)
    }

    /// Bytes saved: "−38 MB".
    public init(bytesSaved: Int64, size: Size, color: some ShapeStyle = Ink.saving) {
        let parts = Self.byteParts(bytesSaved)
        self.init(number: parts.number, unit: parts.unit, spoken: parts.text, size: size.rawValue, color: color)
    }

    public static func font(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.compressed)
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.045) {
            Text(number).font(Self.font(size))
            if !unit.isEmpty {
                Text(unit).font(Self.font(size * 0.55, weight: .semibold)).baselineOffset(size * 0.3)
            }
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: - Text

    /// The minus sign, not a hyphen.
    public static let minus = "\u{2212}"

    public struct Parts: Equatable, Sendable {
        public var number: String
        public var unit: String
        /// As the locale writes the whole: en "−75%", ca "−75 %" (a narrow no-break space).
        public var text: String
    }

    /// A saving of `percent` (0...100) as the locale writes a percentage: whether a space goes
    /// before the sign comes from the locale; where it does, it is a narrow no-break space.
    public static func percentParts(_ percent: Int, locale: Locale = .current) -> Parts {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = (percent > 0 ? minus : "") + (formatter.string(from: NSNumber(value: abs(percent))) ?? "\(abs(percent))")
        return Parts(number: number, unit: "%", text: number + (spacedPercent(locale) ? "\u{202F}" : "") + "%")
    }

    /// A saving of `bytes` through `ByteCountFormatter` (the system's language), split into
    /// number and unit.
    public static func byteParts(_ bytes: Int64) -> Parts {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.formattingContext = .standalone
        let sign = bytes > 0 ? minus : ""
        let whole = formatter.string(fromByteCount: abs(bytes))
        // "38 MB", "38,2 MB": the unit is the last word.
        guard let space = whole.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }) else {
            return Parts(number: sign + whole, unit: "", text: sign + whole)
        }
        return Parts(number: sign + whole[..<space], unit: String(whole[whole.index(after: space)...]), text: sign + whole)
    }

    /// Whether the locale puts a space between a number and "%".
    static func spacedPercent(_ locale: Locale) -> Bool {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        let text = formatter.string(from: 0.75) ?? "75%"
        guard let sign = text.firstIndex(of: "%"), sign > text.startIndex else { return false }
        return text[text.index(before: sign)].isWhitespace
    }
}
