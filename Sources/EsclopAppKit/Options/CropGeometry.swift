// SPDX-License-Identifier: GPL-3.0-or-later
//
// The crop editor's arithmetic, in image pixels with the origin at the top left: aspect presets
// that centre the largest rectangle of that shape, a free crop dragged by its corners and edges,
// moving the whole rectangle, and an output size in pixels. Typing a size of another shape locks
// the crop to that shape and scales to it, the way Clop's crop field takes "1920x1080". Paper and
// device shapes come from the list `esclop pdf crop --paper-size` and `--for-device` take.

import CoreGraphics
import EsclopCore
import EsclopIPC
import Foundation

public enum CropAspect: Hashable, Sendable, Identifiable {
    case free
    case ratio(Int, Int)
    /// A paper size or device by its name in `AspectRatio.presets`, portrait as the CLI takes it
    /// unless turned to landscape.
    case preset(String, landscape: Bool = false)

    /// Each shape with its portrait twin, as 16:9 has 9:16.
    public static let presets: [CropAspect] = [.free, .ratio(1, 1), .ratio(4, 3), .ratio(3, 4), .ratio(3, 2), .ratio(2, 3), .ratio(16, 9), .ratio(9, 16)]

    public var id: String { title }

    public var title: String {
        switch self {
        case .free: return Strings.text("Free")
        case let .ratio(w, h): return "\(w):\(h)"
        case let .preset(name, _): return name
        }
    }

    /// The same shape turned a quarter.
    public var rotated: CropAspect {
        switch self {
        case .free: return .free
        case let .ratio(w, h): return .ratio(h, w)
        case let .preset(name, landscape): return .preset(name, landscape: !landscape)
        }
    }

    /// Whether turning it changes anything: not free, not square.
    public var rotates: Bool { value.map { abs($0 - 1) > 0.001 } ?? false }

    var value: Double? {
        switch self {
        case .free: return nil
        case let .ratio(w, h): return w > 0 && h > 0 ? Double(w) / Double(h) : nil
        case let .preset(name, landscape):
            return AspectRatio.presets.first { $0.name == name }.map { landscape ? $0.height / $0.width : $0.width / $0.height }
        }
    }
}

/// Where a shape's frame lands in the picture: the middle, or what Vision finds salient (the
/// engine's smart crop, as in the CLI, Shortcuts and pipelines).
public enum CropFraming: Sendable {
    case centre, smart
}

public struct CropGeometry: Equatable, Sendable {
    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    public let imageWidth: Int
    public let imageHeight: Int
    public private(set) var rect: CGRect
    public private(set) var aspect: CropAspect = .free
    /// The output size when it differs from the rectangle (the picture is scaled to it).
    public private(set) var output: (width: Int, height: Int)?
    /// The size as typed (or chosen from the saved ones), kept until the frame changes shape or
    /// size: Crop saves it. It can be larger than `output`, which never enlarges.
    public private(set) var typed: (width: Int, height: Int)?
    /// Smallest side of the rectangle, in pixels.
    static let minimum: CGFloat = 16

    public init(imageWidth: Int, imageHeight: Int) {
        self.imageWidth = max(1, imageWidth)
        self.imageHeight = max(1, imageHeight)
        rect = CGRect(x: 0, y: 0, width: self.imageWidth, height: self.imageHeight)
    }

    public static func == (lhs: CropGeometry, rhs: CropGeometry) -> Bool {
        lhs.imageWidth == rhs.imageWidth && lhs.imageHeight == rhs.imageHeight && lhs.rect == rhs.rect && lhs.aspect == rhs.aspect
            && lhs.output?.width == rhs.output?.width && lhs.output?.height == rhs.output?.height && lhs.typed?.width == rhs.typed?.width && lhs.typed?.height == rhs.typed?.height
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight) }

    /// The largest rectangle of the aspect, kept inside the image and centred on `focus` (a point
    /// of the picture from 0 to 1, origin at the top left), else on the current rectangle.
    public mutating func setAspect(_ aspect: CropAspect, focus: CGPoint? = nil) {
        self.aspect = aspect
        output = nil
        typed = nil
        guard let ratio = aspect.value else { return }
        var width = CGFloat(imageWidth)
        var height = width / ratio
        if height > CGFloat(imageHeight) {
            height = CGFloat(imageHeight)
            width = height * ratio
        }
        let centre = focus.map { CGPoint(x: $0.x * CGFloat(imageWidth), y: $0.y * CGFloat(imageHeight)) } ?? CGPoint(x: rect.midX, y: rect.midY)
        rect = Self.rounded(centred(CGSize(width: width, height: height), on: centre))
    }

    /// Drags one handle by `delta` pixels, keeping the aspect when one is set.
    public mutating func drag(_ handle: Handle, by delta: CGSize) {
        var r = rect
        let left = [.topLeft, .left, .bottomLeft].contains(handle)
        let right = [.topRight, .right, .bottomRight].contains(handle)
        let top = [.topLeft, .top, .topRight].contains(handle)
        let bottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        if left { r.origin.x = min(max(0, r.minX + delta.width), rect.maxX - Self.minimum); r.size.width = rect.maxX - r.minX }
        if right { r.size.width = min(max(Self.minimum, rect.width + delta.width), CGFloat(imageWidth) - r.minX) }
        if top { r.origin.y = min(max(0, r.minY + delta.height), rect.maxY - Self.minimum); r.size.height = rect.maxY - r.minY }
        if bottom { r.size.height = min(max(Self.minimum, rect.height + delta.height), CGFloat(imageHeight) - r.minY) }
        if let ratio = aspect.value {
            // The side the person pulled leads; the other follows, anchored on the opposite edge.
            let horizontal = left || right
            let vertical = top || bottom
            var width = r.width, height = r.height
            if horizontal && (!vertical || abs(delta.width) >= abs(delta.height)) { height = width / ratio } else { width = height * ratio }
            let maxWidth = left ? rect.maxX : CGFloat(imageWidth) - r.minX
            let maxHeight = top ? rect.maxY : CGFloat(imageHeight) - r.minY
            let scale = min(1, maxWidth / width, maxHeight / height)
            width *= scale
            height *= scale
            r = CGRect(
                x: left ? rect.maxX - width : (horizontal ? r.minX : r.midX - width / 2),
                y: top ? rect.maxY - height : (vertical ? r.minY : r.midY - height / 2),
                width: width, height: height
            )
            r = clamped(r)
        }
        rect = Self.rounded(r)
        output = nil
        typed = nil
    }

    /// Moves the whole rectangle, staying inside the image.
    public mutating func move(by delta: CGSize) {
        rect = Self.rounded(clamped(rect.offsetBy(dx: delta.width, dy: delta.height)))
    }

    /// The output size typed in pixels. Another shape locks the crop to it; the picture is then
    /// scaled down (never up) to that size.
    public mutating func setOutput(width: Int, height: Int, focus: CGPoint? = nil) {
        guard width > 0, height > 0 else { return }
        let ratio = Double(width) / Double(height)
        if abs(ratio - Double(rect.width / rect.height)) > 0.005 {
            let divisor = gcd(width, height)
            setAspect(.ratio(width / divisor, height / divisor), focus: focus)
        }
        output = Int(rect.width) == width && Int(rect.height) == height ? nil : (min(width, Int(rect.width)), min(height, Int(rect.height)))
        typed = (width, height)
    }

    public var outputWidth: Int { output?.width ?? Int(rect.width) }
    public var outputHeight: Int { output?.height ?? Int(rect.height) }

    /// What the engine gets; nil when nothing would change.
    public var cropSize: CropSize? {
        guard rect != bounds || output != nil else { return nil }
        let region = CropRect(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
        return CropSize(width: output?.width, height: output?.height, rect: region)
    }

    private func centred(_ size: CGSize, on centre: CGPoint) -> CGRect {
        clamped(CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height))
    }

    private func clamped(_ r: CGRect) -> CGRect {
        let width = min(r.width, CGFloat(imageWidth)), height = min(r.height, CGFloat(imageHeight))
        let x = min(max(0, r.minX), CGFloat(imageWidth) - width)
        let y = min(max(0, r.minY), CGFloat(imageHeight) - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Whole pixels, rounding each edge to the nearest one (never growing past the picture).
    static func rounded(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(1, a) : gcd(b, a % b) }
}
