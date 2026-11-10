// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fidelity judge for the PDF benchmark. Build: swiftc -O judge.swift -o judge
//
//   judge info FILE              JSON: opens, pages, text hash, links, outline items, form
//                                fields, encrypted/locked, and the gs path's per-document DPI
//   judge compare ORIGINAL OUT   JSON: both infos plus SSIM per page at 150 dpi (RGB, 7x7
//                                uniform window, mean of the three channels)

import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

func info(_ url: URL) -> [String: Any] {
    guard let doc = PDFDocument(url: url) else { return ["opens": false] }
    var result: [String: Any] = ["opens": doc.pageCount > 0, "encrypted": doc.isEncrypted, "locked": doc.isLocked, "pages": doc.pageCount]
    if doc.isLocked { return result }
    let text = doc.string ?? ""
    result["text_sha"] = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
    result["text_chars"] = text.count
    var links = 0, fields = 0, annots = 0
    for i in 0 ..< doc.pageCount {
        for a in doc.page(at: i)?.annotations ?? [] {
            annots += 1
            if a.type == "Link" { links += 1 }
            if a.type == "Widget" { fields += 1 }
        }
    }
    func count(_ o: PDFOutline?) -> Int {
        guard let o else { return 0 }
        return (0 ..< o.numberOfChildren).reduce(0) { $0 + 1 + count(o.child(at: $1)) }
    }
    result["links"] = links
    result["fields"] = fields
    result["annotations"] = annots
    result["outline"] = count(doc.outlineRoot)
    result["adaptive_dpi"] = adaptiveDPI(url)
    return result
}

// MARK: the gs path's DPI choice, copied from Sources/EsclopOptimisers/GhostscriptArguments.swift

let dpiStops = [300, 250, 200, 150, 100, 72, 48]

func imageDPIs(_ url: URL) -> [Double] {
    guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return [] }
    final class Collector { var dpis: [Double] = []; var w = 0.0; var h = 0.0 }
    let c = Collector()
    for n in 1 ... document.numberOfPages {
        guard let page = document.page(at: n), let dict = page.dictionary else { continue }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { continue }
        c.w = Double(box.width) / 72; c.h = Double(box.height) / 72
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { continue }
        CGPDFDictionaryApplyBlock(xo, { _, object, info in
            let c = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            var s: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &s), let s, let d = CGPDFStreamGetDictionary(s) else { return true }
            var st: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(d, "Subtype", &st), let st, String(cString: st) == "Image" else { return true }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(d, "Width", &w), CGPDFDictionaryGetInteger(d, "Height", &h) else { return true }
            c.dpis.append((Double(w) / c.w + Double(h) / c.h) / 2)
            return true
        }, Unmanaged.passUnretained(c).toOpaque())
    }
    let v = c.dpis
    guard v.count >= 4 else { return v }
    let s = v.sorted()
    func pct(_ p: Double) -> Double {
        let i = Double(s.count - 1) * p, lo = Int(i.rounded(.down)), hi = Int(i.rounded(.up))
        return s[lo] * (1 - (i - Double(lo))) + s[hi] * (i - Double(lo))
    }
    let fence = pct(0.25) - 1.5 * (pct(0.75) - pct(0.25))
    return v.filter { $0 >= fence }
}

func adaptiveDPI(_ url: URL) -> Int {
    let dpis = imageDPIs(url)
    guard !dpis.isEmpty else { return 300 }
    var counts: [Int: Int] = [:]
    for d in dpis { if let b = dpiStops.first(where: { Double($0) <= d }) { counts[b, default: 0] += 1 } }
    var above = 0
    for s in dpiStops { above += counts[s] ?? 0; if above > 3 { return s } }
    return 300
}

// MARK: rendering and SSIM

struct Raster { var w: Int; var h: Int; var px: [UInt8] }

func render(_ page: CGPDFPage, dpi: Double = 150) -> Raster {
    let box = page.getBoxRect(.cropBox)
    let rot = page.rotationAngle % 180 != 0
    let w = max(1, Int((Double(rot ? box.height : box.width) * dpi / 72).rounded()))
    let h = max(1, Int((Double(rot ? box.width : box.height) * dpi / 72).rounded()))
    var px = [UInt8](repeating: 255, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
    }
    return Raster(w: w, h: h, px: px)
}

func ssim(_ a: Raster, _ b: Raster) -> Double {
    guard a.w == b.w, a.h == b.h else { return 0 }
    let w = a.w, h = a.h, r = 3, c1: Double = 6.5025, c2: Double = 58.5225
    var total = 0.0
    var sx = [Double](repeating: 0, count: (w + 1) * (h + 1))
    var sy = sx, sxx = sx, syy = sx, sxy = sx
    for ch in 0 ..< 3 {
        for y in 0 ..< h {
            var rx = 0.0, ry = 0.0, rxx = 0.0, ryy = 0.0, rxy = 0.0
            for x in 0 ..< w {
                let p = Double(a.px[(y * w + x) * 4 + ch]), q = Double(b.px[(y * w + x) * 4 + ch])
                rx += p; ry += q; rxx += p * p; ryy += q * q; rxy += p * q
                let i = (y + 1) * (w + 1) + x + 1, u = y * (w + 1) + x + 1
                sx[i] = sx[u] + rx; sy[i] = sy[u] + ry; sxx[i] = sxx[u] + rxx; syy[i] = syy[u] + ryy; sxy[i] = sxy[u] + rxy
            }
        }
        var acc = 0.0, n = 0
        for y in r ..< h - r {
            for x in r ..< w - r {
                let y0 = y - r, y1 = y + r + 1, x0 = x - r, x1 = x + r + 1
                func box(_ s: [Double]) -> Double { s[y1 * (w + 1) + x1] - s[y0 * (w + 1) + x1] - s[y1 * (w + 1) + x0] + s[y0 * (w + 1) + x0] }
                let k = Double((2 * r + 1) * (2 * r + 1))
                let mx = box(sx) / k, my = box(sy) / k
                let vx = box(sxx) / k - mx * mx, vy = box(syy) / k - my * my, cxy = box(sxy) / k - mx * my
                acc += ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
                n += 1
            }
        }
        total += n > 0 ? acc / Double(n) : 1
    }
    return total / 3
}

func compare(_ a: URL, _ b: URL) -> [String: Any] {
    var result: [String: Any] = ["original": info(a), "output": info(b)]
    guard let da = CGPDFDocument(a as CFURL), let db = CGPDFDocument(b as CFURL), da.numberOfPages > 0,
          da.numberOfPages == db.numberOfPages, !da.isEncrypted || da.isUnlocked else {
        result["ssim"] = [Double]()
        return result
    }
    let buffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: da.numberOfPages)
    buffer.initialize(repeating: 0)
    DispatchQueue.concurrentPerform(iterations: da.numberOfPages) { i in
        autoreleasepool {
            guard let pa = da.page(at: i + 1), let pb = db.page(at: i + 1) else { return }
            buffer[i] = ssim(render(pa), render(pb))
        }
    }
    let values = Array(buffer)
    buffer.deallocate()
    result["ssim"] = values.map { ($0 * 10000).rounded() / 10000 }
    return result
}

let args = CommandLine.arguments
let out: [String: Any]
switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "info"): out = info(URL(fileURLWithPath: args[2]))
case (4, "compare"): out = compare(URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3]))
default:
    FileHandle.standardError.write("usage: judge info FILE | judge compare ORIGINAL OUTPUT\n".data(using: .utf8)!)
    exit(2)
}
print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
