// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fidelity judge for the PDF benchmark. Build: swiftc -O judge.swift -o judge
//
//   judge info FILE              JSON: opens, pages, text hash, links, outline items, form
//                                fields, encrypted/locked, and the gs path's per-document DPI
//   judge compare ORIGINAL OUT   JSON: both infos plus SSIM per page at 150 dpi (RGB, 7x7
//                                uniform window, mean of the three channels)
//   judge compare-many ORIG OUT…  the same against several outputs, rendering the original once
//
// Memory: SSIM needs O(width). Each page's cost (two rasters plus CoreGraphics' full-size image
// decode) counts against JUDGE_RASTER_MB in flight (400 MB by default), so pages run one per
// core only while they are small; a page over JUDGE_PAGE_MB (1200) is not rendered and gets
// SSIM -1 (unjudged).

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

/// Largest page raster, in pixels (JUDGE_MAX_MP megapixels).
let maxPagePixels = (Double(ProcessInfo.processInfo.environment["JUDGE_MAX_MP"] ?? "") ?? 25) * 1e6

/// 150 dpi, or less for pages so large that 150 dpi would pass `maxPagePixels` (posters, maps).
func pageDPI(_ page: CGPDFPage) -> Double {
    let box = page.getBoxRect(.cropBox)
    let px = Double(box.width) * Double(box.height) * 150 * 150 / (72 * 72)
    return px > maxPagePixels ? 150 * (maxPagePixels / px).squareRoot() : 150
}

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

/// SSIM over 7x7 uniform windows, mean of the R, G and B channels. A sliding window keeps only
/// the column sums of the seven rows it covers, so memory is O(width): full-page integral
/// images cost ~1 GB at 25 megapixels. The sums are integers well under 2^53, exact in Double,
/// so the result matches the integral-image version exactly.
func ssim(_ a: Raster, _ b: Raster) -> Double {
    guard a.w == b.w, a.h == b.h else { return 0 }
    let w = a.w, h = a.h, r = 3, side = 2 * r + 1, c1: Double = 6.5025, c2: Double = 58.5225
    guard w > 2 * r, h > 2 * r else { return 1 }
    let k = Double(side * side)
    // Column sums per channel: x, y, xx, yy, xy at [(q * 3 + ch) * w + x].
    var col = [Double](repeating: 0, count: 15 * w)
    var acc = [Double](repeating: 0, count: 3)
    a.px.withUnsafeBufferPointer { pa in
        b.px.withUnsafeBufferPointer { pb in
            col.withUnsafeMutableBufferPointer { col in
                func addRow(_ y: Int, _ sign: Double) {
                    for x in 0 ..< w {
                        let o = (y * w + x) * 4
                        for ch in 0 ..< 3 {
                            let p = Double(pa[o + ch]), q = Double(pb[o + ch])
                            col[(0 + ch) * w + x] += sign * p
                            col[(3 + ch) * w + x] += sign * q
                            col[(6 + ch) * w + x] += sign * p * p
                            col[(9 + ch) * w + x] += sign * q * q
                            col[(12 + ch) * w + x] += sign * p * q
                        }
                    }
                }
                for y in 0 ..< side { addRow(y, 1) }
                for y in r ..< h - r {
                    if y > r {
                        addRow(y - r - 1, -1)
                        addRow(y + r, 1)
                    }
                    for ch in 0 ..< 3 {
                        var s = [0.0, 0.0, 0.0, 0.0, 0.0]
                        for x in 0 ..< side { for q in 0 ..< 5 { s[q] += col[(q * 3 + ch) * w + x] } }
                        var sum = 0.0
                        for x in r ..< w - r {
                            if x > r {
                                for q in 0 ..< 5 { s[q] += col[(q * 3 + ch) * w + x + r] - col[(q * 3 + ch) * w + x - r - 1] }
                            }
                            let mx = s[0] / k, my = s[1] / k
                            let vx = s[2] / k - mx * mx, vy = s[3] / k - my * my, cxy = s[4] / k - mx * my
                            sum += ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
                        }
                        acc[ch] += sum
                    }
                }
            }
        }
    }
    let n = Double((w - 2 * r) * (h - 2 * r))
    return acc.reduce(0) { $0 + $1 / n } / 3
}

/// Pixels where some channel differs by more than 32: SSIM rounded to 4 decimals hides a few
/// lost glyphs on a page, this count does not.
func diffPixels(_ a: Raster, _ b: Raster) -> Int {
    guard a.w == b.w, a.h == b.h else { return a.w * a.h }
    var n = 0
    a.px.withUnsafeBufferPointer { pa in
        b.px.withUnsafeBufferPointer { pb in
            for i in stride(from: 0, to: a.w * a.h * 4, by: 4) {
                if abs(Int(pa[i]) - Int(pb[i])) > 32 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 32 || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 32 { n += 1 }
            }
        }
    }
    return n
}

/// Pixels where the mean signed luminance difference over the 5x5 window around them passes 24
/// levels. Anti-aliasing that rounds an edge differently moves little ink in and out within a
/// few pixels and averages out; a glyph that is missing or changed removes or adds ink over its
/// whole area and does not.
func inkDiffPixels(_ a: Raster, _ b: Raster) -> Int {
    guard a.w == b.w, a.h == b.h else { return a.w * a.h }
    let w = a.w, h = a.h, r = 2
    var n = 0
    a.px.withUnsafeBufferPointer { pa in
        b.px.withUnsafeBufferPointer { pb in
            func luma(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> Int { (Int(p[o]) * 299 + Int(p[o + 1]) * 587 + Int(p[o + 2]) * 114) / 1000 }
            for j in r ..< h - r {
                for i in r ..< w - r {
                    let c = (j * w + i) * 4
                    if pa[c] == pb[c] && pa[c + 1] == pb[c + 1] && pa[c + 2] == pb[c + 2] { continue }
                    var sum = 0
                    for dj in -r ... r { for di in -r ... r { let o = ((j + dj) * w + i + di) * 4; sum += luma(pa, o) - luma(pb, o) } }
                    if abs(sum) > 24 * 25 { n += 1 }
                }
            }
        }
    }
    return n
}

/// Caps the raster bytes in flight across pages: a page waits until its rasters fit, except
/// when nothing else is in flight, so one oversized page still runs alone.
final class Budget {
    let limit: Int
    var used = 0
    let cond = NSCondition()
    init(_ limit: Int) { self.limit = limit }
    func run<T>(_ cost: Int, _ body: () -> T) -> T {
        cond.lock()
        while used > 0 && used + cost > limit { cond.wait() }
        used += cost
        cond.unlock()
        defer { cond.lock(); used -= cost; cond.broadcast(); cond.unlock() }
        return body()
    }
}

/// Raster bytes in flight per judge process. A page holds two RGBA rasters (the original's and
/// one output's) plus CoreGraphics' own buffers while rendering.
let rasterBudget = Budget((Int(ProcessInfo.processInfo.environment["JUDGE_RASTER_MB"] ?? "") ?? 400) << 20)

/// Pixels of the images a page draws through its XObjects (two form levels deep). CoreGraphics
/// decodes each at full size whatever the output resolution, so this, not the raster, sets the
/// memory a render of an image-heavy page needs.
func imagePixels(_ page: CGPDFPage) -> Double {
    final class Sum { var px = 0.0 }
    let sum = Sum()
    func visit(_ res: CGPDFDictionaryRef, _ depth: Int) {
        var xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return }
        var forms: [CGPDFDictionaryRef] = []
        withUnsafeMutablePointer(to: &forms) { fp in
            CGPDFDictionaryApplyBlock(xo, { _, object, info in
                let fp = info!.assumingMemoryBound(to: [CGPDFDictionaryRef].self)
                var s: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &s), let s, let d = CGPDFStreamGetDictionary(s) else { return true }
                var st: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(d, "Subtype", &st), let st else { return true }
                if String(cString: st) == "Image" {
                    var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(d, "Width", &w), CGPDFDictionaryGetInteger(d, "Height", &h) {
                        sum.px += Double(w) * Double(h)
                    }
                } else if String(cString: st) == "Form" {
                    var r: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(d, "Resources", &r), let r { fp.pointee.append(r) }
                }
                return true
            }, fp)
        }
        if depth < 2 { forms.forEach { visit($0, depth + 1) } }
    }
    var res: CGPDFDictionaryRef?
    if let d = page.dictionary, CGPDFDictionaryGetDictionary(d, "Resources", &res), let res { visit(res, 0) }
    return sum.px
}

/// Bytes a page comparison holds: two RGBA rasters, plus ~8 bytes per image pixel for
/// CoreGraphics' decode (a 212-megapixel scan measured 1.6 GB).
func pageCost(_ page: CGPDFPage, dpi: Double) -> Int {
    let box = page.getBoxRect(.cropBox)
    let raster = 2 * 4 * Int(Double(box.width) * dpi / 72 + 1) * Int(Double(box.height) * dpi / 72 + 1)
    return raster + Int(8 * imagePixels(page))
}

/// Pages costing more than this are not rendered; their SSIM is -1 (unjudged).
let pageLimit = (Int(ProcessInfo.processInfo.environment["JUDGE_PAGE_MB"] ?? "") ?? 1200) << 20

/// SSIM of one page pair within the budget, or -1 when the page is over `pageLimit`.
func judgedPage(_ pa: CGPDFPage, _ body: (Double) -> Void) {
    let dpi = pageDPI(pa), cost = pageCost(pa, dpi: dpi)
    if cost > pageLimit { return }
    rasterBudget.run(cost) { body(dpi) }
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
            buffer[i] = -1
            judgedPage(pa) { dpi in buffer[i] = ssim(render(pa, dpi: dpi), render(pb, dpi: dpi)) }
        }
    }
    let values = Array(buffer)
    buffer.deallocate()
    result["ssim"] = values.map { ($0 * 10000).rounded() / 10000 }
    return result
}

/// One rendering of the original against several outputs: [{"output": info, "ssim": [...]}].
func compareMany(_ a: URL, _ outs: [URL]) -> [String: Any] {
    var result: [String: Any] = ["original": info(a)]
    let da = CGPDFDocument(a as CFURL)
    let docs = outs.map { CGPDFDocument($0 as CFURL) }
    let n = da?.numberOfPages ?? 0
    let usable = docs.map { d in d.map { $0.numberOfPages == n && n > 0 && (!$0.isEncrypted || $0.isUnlocked) } ?? false }
    let buffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: max(1, n * outs.count))
    buffer.initialize(repeating: 0)
    let diffs = UnsafeMutableBufferPointer<Int>.allocate(capacity: max(1, n * outs.count))
    diffs.initialize(repeating: -1)
    let shifted = UnsafeMutableBufferPointer<Int>.allocate(capacity: max(1, n * outs.count))
    shifted.initialize(repeating: -1)
    if let da, n > 0, !da.isEncrypted || da.isUnlocked {
        DispatchQueue.concurrentPerform(iterations: n) { i in
            autoreleasepool {
                guard let pa = da.page(at: i + 1) else { return }
                for k in 0 ..< docs.count { buffer[k * n + i] = -1 }
                judgedPage(pa) { dpi in
                    let ra = render(pa, dpi: dpi)
                    for (k, d) in docs.enumerated() where usable[k] {
                        autoreleasepool {
                            if let pb = d?.page(at: i + 1) {
                                let rb = render(pb, dpi: dpi)
                                buffer[k * n + i] = ssim(ra, rb)
                                diffs[k * n + i] = diffPixels(ra, rb)
                                shifted[k * n + i] = diffs[k * n + i] == 0 ? 0 : inkDiffPixels(ra, rb)
                            }
                        }
                    }
                }
            }
        }
    }
    result["outputs"] = outs.enumerated().map { k, url -> [String: Any] in
        let values = usable[k] ? Array(buffer[k * n ..< (k + 1) * n]).map { ($0 * 10000).rounded() / 10000 } : []
        let d = usable[k] ? Array(diffs[k * n ..< (k + 1) * n]) : []
        let sh = usable[k] ? Array(shifted[k * n ..< (k + 1) * n]) : []
        return ["output": info(url), "ssim": values, "diffpx": d, "diffpx_ink": sh]
    }
    buffer.deallocate()
    diffs.deallocate()
    shifted.deallocate()
    return result
}

/// Exits with code 75 once resident memory passes JUDGE_SELF_MB (1300): some files (decompression
/// bombs) make PDFKit or CoreGraphics allocate faster than an outside watchdog can poll.
let selfLimit = UInt64((Int(ProcessInfo.processInfo.environment["JUDGE_SELF_MB"] ?? "") ?? 1300) << 20)
let guardThread = Thread {
    while true {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if kr == KERN_SUCCESS && info.resident_size > selfLimit {
            FileHandle.standardError.write("judge: over \(selfLimit >> 20) MB resident, giving up\n".data(using: .utf8)!)
            exit(75)
        }
        usleep(10_000)
    }
}
guardThread.start()

let args = CommandLine.arguments
let out: [String: Any]
switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "info"): out = info(URL(fileURLWithPath: args[2]))
case (4, "compare"): out = compare(URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3]))
case (3, "pagecost"):
    let d = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL)
    out = ["image_mp": (1 ... max(1, d?.numberOfPages ?? 0)).map { i in d?.page(at: i).map { imagePixels($0) / 1e6 } ?? 0 }]
case (_, "compare-many") where args.count >= 4:
    out = compareMany(URL(fileURLWithPath: args[2]), args[3...].map { URL(fileURLWithPath: $0) })
default:
    FileHandle.standardError.write("usage: judge info FILE | judge compare ORIGINAL OUTPUT | judge compare-many ORIGINAL OUTPUT...\n".data(using: .utf8)!)
    exit(2)
}
print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
