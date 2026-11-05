// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Shared.swift
//  Clop
//
//  Created by Alin Panaitiu on 24.09.2023.
//
// Derived from Clop (github.com/FuzzyIdeas/Clop, commit 4be5106), GPL-3.0, Copyright Alin Panaitiu.
// Modified 2026-11-03 for L'Esclop: kept the tuned curves that turn one compression factor
// (0...100, higher = smaller) into each encoder's quality scale; dropped the tier enum, the x264
// and x265 paths (L'Esclop's ffmpeg has neither) and everything outside the curves; the image
// curves now feed esclop-engine parameters instead of pngquant/jpegoptim/cwebp arguments.

import Foundation

/// A compression factor translated to the scales of the encoders esclop drives.
struct Curves: Sendable {
    let factor: Int

    init(_ factor: Int) {
        self.factor = clamp(factor, 0, 100)
    }

    // MARK: Images

    /// Whether this counts as aggressive (drives labels).
    var isAggressive: Bool { factor >= 50 }

    /// JPEG quality ceiling. 30 -> 85; above 70 the curve steepens from 54 down to 18 at 100.
    var jpegQuality: Int {
        factor <= 70
            ? clamp(Int((85.0 - Double(factor - 30) * (55.0 / 70.0)).rounded()), 25, 95)
            : clamp(Int((54.0 - Double(factor - 70) * (36.0 / 30.0)).rounded()), 18, 95)
    }

    /// Upper bound of the PNG quantisation quality range. 30 -> 100, ramping to 25 at 100.
    var pngQualityMax: Int {
        clamp(Int((100.0 - Double(factor - 30) * (75.0 / 70.0)).rounded()), 25, 100)
    }

    /// Quantiser speed, 1 (slowest, best) to 10: spend more effort the harder we compress.
    var pngSpeed: Int {
        switch factor {
        case ..<40: return 4
        case 40 ..< 60: return 3
        case 60 ..< 85: return 2
        default: return 1
        }
    }

    /// gifsicle arguments. 30 -> -O2 --lossy=30; 64 -> -O3 --lossy=80 --colors=N. Above 70 the
    /// lossy value ramps exponentially to about 2000 at 100.
    var gifsicleArgs: [String] {
        let level = factor >= 50 ? 3 : (factor >= 20 ? 2 : 1)
        let lossy = factor <= 70
            ? clamp(Int((30.0 + Double(factor - 30) * (50.0 / 34.0)).rounded()), 0, 200)
            : Int((89.0 * pow(2000.0 / 89.0, Double(factor - 70) / 30.0)).rounded())
        var args = ["-O\(level)", "--lossy=\(lossy)"]
        if factor >= 50 {
            let colors = clamp(Int((256.0 - Double(factor - 50) * (192.0 / 50.0)).rounded()), 32, 256)
            args.append("--colors=\(colors)")
        }
        return args
    }

    /// WebP, AVIF and HEIC quality (0-100). 30 -> 60; above 70 it steepens from 40 to 15 at 100.
    var conversionQuality: Int {
        factor <= 70
            ? clamp(Int((75.0 - Double(factor) * 0.5).rounded()), 20, 90)
            : clamp(Int((40.0 - Double(factor - 70) * (25.0 / 30.0)).rounded()), 15, 90)
    }

    /// ImageIO JPEG quality, used where a gain map has to survive. ImageIO's scale runs lower
    /// than libjpeg's: 0.51 gives the size and PSNR of quality 85.
    var imageIOJPEGQuality: Double {
        max(0.1, min(0.9, Double(jpegQuality) * 0.006))
    }

    /// ImageIO HEIC quality matching `conversionQuality`; ImageIO's HEIC tops out near 0.8.
    var imageIOHEICQuality: Double {
        max(0.1, min(1, Double(conversionQuality) / 75))
    }

    /// ImageIO AVIF quality matching `conversionQuality`.
    var imageIOAVIFQuality: Double {
        max(0.1, min(1, 0.15 + Double(conversionQuality) / 100))
    }

    // MARK: Video

    /// VideoToolbox H.264 `-q:v` (higher = better). 50 -> 46; above 70 (39) it steepens to 18.
    var videoToolboxH264Quality: Int {
        factor <= 70
            ? clamp(Int((70.0 - Double(max(5, factor) - 5) / 95.0 * 45.0).rounded()), 25, 75)
            : clamp(39 - Int((Double(factor - 70) * (21.0 / 30.0)).rounded()), 18, 75)
    }

    /// VideoToolbox HEVC `-q:v` (higher = better). 5 -> 65; above 70 (38) it steepens to 18.
    var videoToolboxHEVCQuality: Int {
        factor <= 70
            ? clamp(Int((65.0 - Double(max(5, factor) - 5) / 95.0 * 40.0).rounded()), 20, 70)
            : clamp(38 - Int((Double(factor - 70) * (20.0 / 30.0)).rounded()), 18, 70)
    }

    /// SVT-AV1 CRF. 5 -> 22; 50 is about 35; above 70 (41) it steepens to 55.
    var av1CRF: Int {
        factor <= 70
            ? clamp(22 + Int((Double(max(5, factor) - 5) / 95.0 * 28.0).rounded()), 20, 55)
            : clamp(41 + Int((Double(factor - 70) * (14.0 / 30.0)).rounded()), 20, 55)
    }

    /// SVT-AV1 preset: slower (better) when compressing harder.
    var av1Preset: Int { factor >= 60 ? 6 : 8 }

    /// libvpx-vp9 CRF. 5 -> 18; 50 is about 31; above 70 (36) it steepens to 50.
    var vp9CRF: Int {
        factor <= 70
            ? clamp(18 + Int((Double(max(5, factor) - 5) / 95.0 * 27.0).rounded()), 15, 50)
            : clamp(36 + Int((Double(factor - 70) * (14.0 / 30.0)).rounded()), 15, 50)
    }
}

func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    max(low, min(high, value))
}
