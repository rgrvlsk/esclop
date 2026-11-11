// SPDX-License-Identifier: GPL-3.0-or-later
//
// (The Clop source file this derives from, Clop/PDF.swift, has no header comment of its own.)
//
// Derived from Clop (github.com/FuzzyIdeas/Clop, commit 4be5106), GPL-3.0, Copyright Alin Panaitiu.
// Modified 2026-11-03 for L'Esclop: kept the DPI stops and the per-document DPI choice; rewrote
// the image scan as a plain function returning DPIs and dropped the settings plumbing.
// Modified 2026-11-11: the pdfwrite argument set went with Ghostscript (PDFs now go through
// esclop-engine's `pdf.optimise`); what is left is the resolution policy.

import CoreGraphics
import Foundation

/// The resolution PDF images are kept at: stops, the per-document choice and stepping down.
enum PDFResolution {
    /// 300 means no downsampling; below it images drawn denser are downsampled.
    static let noDownsampleDPI = 300
    static let minDPI = 48
    static let maxDPI = 300
    /// Stored setting value meaning "pick per document".
    static let adaptiveDPI = 0
    /// Snap points, high to low.
    static let dpiStops = [300, 250, 200, 150, 100, 72, 48]

    // MARK: Choosing a resolution

    /// The next stop below `dpi`; stays at the lowest.
    static func stepDown(from dpi: Int) -> Int {
        dpiStops.first { $0 < dpi } ?? dpiStops.last ?? dpi
    }

    /// The stop at or below `dpi`.
    static func snap(_ dpi: Int) -> Int {
        dpiStops.first { $0 <= dpi } ?? minDPI
    }

    /// Effective resolution of every image drawn on each page, assuming it fills the page.
    static func imageDPIs(in url: URL) -> [Double] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return [] }
        final class Collector {
            var dpis: [Double] = []
            var pageWidth = 0.0
            var pageHeight = 0.0
        }
        let collector = Collector()
        for number in 1 ... document.numberOfPages {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0, let pageDict = page.dictionary else { continue }
            collector.pageWidth = Double(box.width) / 72
            collector.pageHeight = Double(box.height) / 72
            var resources: CGPDFDictionaryRef?
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects
            else { continue }
            CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
                guard let info else { return true }
                let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dict = CGPDFStreamGetDictionary(stream)
                else { return true }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Image"
                else { return true }
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(dict, "Width", &width),
                      CGPDFDictionaryGetInteger(dict, "Height", &height)
                else { return true }
                let dpi = (Double(width) / collector.pageWidth + Double(height) / collector.pageHeight) / 2
                collector.dpis.append(dpi)
                return true
            }, Unmanaged.passUnretained(collector).toOpaque())
        }
        return dropLowOutliers(collector.dpis)
    }

    /// Lower Tukey fence: small images placed on part of a page look like low-DPI images.
    static func dropLowOutliers(_ values: [Double]) -> [Double] {
        guard values.count >= 4 else { return values }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let index = Double(sorted.count - 1) * p
            let low = Int(index.rounded(.down))
            let high = Int(index.rounded(.up))
            let fraction = index - Double(low)
            return sorted[low] * (1 - fraction) + sorted[high] * fraction
        }
        let q1 = percentile(0.25)
        let q3 = percentile(0.75)
        let fence = q1 - 1.5 * (q3 - q1)
        return values.filter { $0 >= fence }
    }

    /// Picks the highest stop at or below `cap` that more than three images reach, so a
    /// document of 150 dpi scans is not "downsampled" to 250 for nothing. Returns `cap` when
    /// there are no images to go by.
    static func adaptiveDPI(for url: URL, cap: Int = noDownsampleDPI) -> (dpi: Int, sourceMax: Int?) {
        let dpis = imageDPIs(in: url)
        guard let maximum = dpis.max() else { return (cap, nil) }
        let stops = dpiStops.filter { $0 <= cap }
        var counts: [Int: Int] = [:]
        for dpi in dpis {
            guard let bucket = stops.first(where: { Double($0) <= dpi }) else { continue }
            counts[bucket, default: 0] += 1
        }
        var atOrAbove = 0
        for stop in stops {
            atOrAbove += counts[stop] ?? 0
            if atOrAbove > 3 {
                return (stop, Int(maximum.rounded()))
            }
        }
        return (cap, Int(maximum.rounded()))
    }
}
