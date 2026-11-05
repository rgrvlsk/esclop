// SPDX-License-Identifier: GPL-3.0-or-later
//
// (The Clop source file this derives from, Clop/PDF.swift, has no header comment of its own.)
//
// Derived from Clop (github.com/FuzzyIdeas/Clop, commit 4be5106), GPL-3.0, Copyright Alin Panaitiu.
// Modified 2026-11-03 for L'Esclop: kept the tuned pdfwrite argument set, the DPI stops and the
// per-document DPI choice; rewrote the image scan as a plain function returning DPIs, made
// `-dSAFER` explicit and first, and dropped the parallel-page path, the progress UI and the
// settings plumbing.

import CoreGraphics
import Foundation

enum Ghostscript {
    /// 300 means no downsampling; below it Ghostscript downsamples images.
    static let noDownsampleDPI = 300
    static let minDPI = 48
    static let maxDPI = 300
    /// Stored setting value meaning "pick per document".
    static let adaptiveDPI = 0
    /// Snap points, high to low.
    static let dpiStops = [300, 250, 200, 150, 100, 72, 48]

    static func lossyArgs(downsample: Bool) -> [String] {
        [
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dAutoFilterMonoImages=true",
            "-dColorImageFilter=/DCTEncode",
            "-dDownsampleColorImages=\(downsample)",
            "-dDownsampleGrayImages=\(downsample)",
            "-dDownsampleMonoImages=\(downsample)",
            "-dGrayImageFilter=/DCTEncode",
            "-dPassThroughJPEGImages=false",
            "-dPassThroughJPXImages=false",
            "-dShowAcroForm=false",
        ]
    }

    static func losslessArgs(downsample: Bool) -> [String] {
        [
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dAutoFilterMonoImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dDownsampleColorImages=\(downsample)",
            "-dDownsampleGrayImages=\(downsample)",
            "-dDownsampleMonoImages=\(downsample)",
            "-dGrayImageFilter=/DCTEncode",
            "-dPassThroughJPEGImages=\(!downsample)",
            "-dPassThroughJPXImages=\(!downsample)",
            "-dShowAcroForm=true",
        ]
    }

    static func resolutionArgs(dpi: Int) -> [String] {
        [
            "-dColorImageDownsampleThreshold=1.0",
            "-dColorImageDownsampleType=/Bicubic",
            "-dColorImageResolution=\(dpi)",
            "-dGrayImageDownsampleThreshold=1.0",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dGrayImageResolution=\(dpi)",
            "-dMonoImageDownsampleThreshold=1.0",
            "-dMonoImageDownsampleType=/Bicubic",
            // 1-bit images compress poorly below 300 dpi.
            "-dMonoImageResolution=\(max(dpi, 300))",
        ]
    }

    static let baseArgs = [
        "-dSAFER",
        "-dALLOWPSTRANSPARENCY",
        "-dAutoRotatePages=/None",
        "-dBATCH",
        "-dCannotEmbedFontPolicy=/Warning",
        // /RGB (DeviceRGB), not /sRGB: the ICC conversion drops isolated transparency groups.
        "-dColorConversionStrategy=/RGB",
        "-dCompatibilityLevel=1.6",
        "-dCompressFonts=true",
        "-dCompressPages=true",
        "-dCompressStreams=true",
        "-dConvertCMYKImagesToRGB=true",
        "-dConvertImagesToIndexed=false",
        "-dCreateJobTicket=false",
        "-dDetectDuplicateImages=true",
        "-dDoThumbnails=false",
        "-dEmbedAllFonts=true",
        "-dEncodeColorImages=true",
        "-dEncodeGrayImages=true",
        "-dEncodeMonoImages=true",
        "-dFastWebView=false",
        "-dGrayDetection=true",
        "-dHaveTransparency=true",
        "-dLZWEncodePages=true",
        "-dMaxBitmap=0",
        "-dMonoImageFilter=/CCITTFaxEncode",
        "-dNOPAUSE",
        "-dNOPROMPT",
        "-dOptimize=true",
        "-dParseDSCComments=false",
        "-dParseDSCCommentsForDocInfo=false",
        "-dPDFNOCIDFALLBACK",
        "-dPDFSETTINGS=/screen",
        "-dPreserveAnnots=true",
        "-dPreserveCopyPage=false",
        "-dPreserveDeviceN=true",
        "-dPreserveEPSInfo=false",
        "-dPreserveHalftoneInfo=false",
        "-dPreserveOPIComments=false",
        "-dPreserveOverprintSettings=true",
        "-dPreserveSeparation=true",
        "-dPrinted=false",
        "-dProcessColorModel=/DeviceRGB",
        "-dSubsetFonts=true",
        // /Preserve, not /Apply: /Apply mis-applies a transfer function on an /Alpha soft mask
        // and can erase masked images (QR codes in exported designs).
        "-dTransferFunctionInfo=/Preserve",
        "-dUCRandBGInfo=/Remove",
    ]

    static let preArgs = [
        "-c",
        "<< /ColorImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /ColorACSImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /GrayImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /GrayACSImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /AlwaysEmbed [ ] >> setdistillerparams << /NeverEmbed [/Courier /Courier-Bold /Courier-Oblique /Courier-BoldOblique /Helvetica /Helvetica-Bold /Helvetica-Oblique /Helvetica-BoldOblique /Times-Roman /Times-Bold /Times-Italic /Times-BoldItalic /Symbol /ZapfDingbats /Arial] >> setdistillerparams",
        "-f",
        "-c",
        "/originalpdfmark { //pdfmark } bind def /pdfmark { { { counttomark pop } stopped { /pdfmark errordict /unmatchedmark get exec stop } if dup type /nametype ne { /pdfmark errordict /typecheck get exec stop } if dup /DOCINFO eq { (Skipping DOCINFO pdfmark\\n) print cleartomark exit } if originalpdfmark exit } loop } def",
        "-f",
    ]

    /// Clears Producer and dates, which also drops the rest of the document info.
    static let postArgs = [
        "-c", "/pdfmark { originalpdfmark } bind def", "-f",
        "-c", "[ /Producer () /ModDate () /CreationDate () /DOCINFO pdfmark", "-f",
    ]

    static var fontPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Library/Fonts", "/Library/Fonts/", "/System/Library/Fonts/", "/Library/Fonts/Microsoft/"]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .joined(separator: ":")
    }

    /// Full argument list. `lossy` recompresses images; `dpi` below 300 downsamples them.
    static func arguments(input: String, output: String, lossy: Bool, dpi: Int) -> [String] {
        let dpi = min(max(dpi, minDPI), maxDPI)
        let downsample = dpi < noDownsampleDPI
        let optimisation = lossy ? lossyArgs(downsample: downsample) : losslessArgs(downsample: downsample)
        // At the lowest stops, also recompress images harder with chroma subsampling.
        var qFactor: [String] = []
        if lossy, dpi <= 100 {
            let q = dpi <= 48 ? 1.3 : (dpi <= 72 ? 1.0 : 0.76)
            let dict = "<< /QFactor \(q) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >>"
            qFactor = ["-c", "<< /ColorImageDict \(dict) /GrayImageDict \(dict) >> setdistillerparams", "-f"]
        }
        // -dColorConversionStrategy has to follow -dPDFSETTINGS=/screen, which re-forces sRGB.
        let out = ["-dColorConversionStrategy=/RGB", "-sDEVICE=pdfwrite", "-sFONTPATH=\(fontPath)", "-o", output]
        return baseArgs + resolutionArgs(dpi: dpi) + optimisation + out + qFactor + preArgs + [input] + postArgs
    }

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
