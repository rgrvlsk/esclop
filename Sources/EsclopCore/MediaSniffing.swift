// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a file's first bytes say it is. Used where the extension alone is not trusted: an agent's
// upload and a pipeline's upload step go through only when the bytes show the kind the
// extension names, so a key or a text file renamed to `.png` stays on the Mac.

import Darwin
import Foundation

extension MediaKind {
    /// How much of a file `sniff` reads, at most.
    public static let sniffLimit = 4096

    /// The kinds a file's first `sniffLimit` bytes show, after following symbolic links. Empty when
    /// no signature matches, the file is empty or cannot be read, or it is not a regular file (a
    /// pipe or a device is never opened for reading). A container that holds sound as well as
    /// picture (MP4, Matroska, Ogg, ASF, RealMedia) gives both `.video` and `.audio`.
    public static func sniff(_ url: URL) -> Set<MediaKind> {
        let fd = open(url.resolvingSymlinksInPath().path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        var head = [UInt8](repeating: 0, count: sniffLimit)
        var count = 0
        while count < sniffLimit {
            let read = head.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + count, sniffLimit - count) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { break }
            count += read
        }
        return sniff(head: Data(head.prefix(count)))
    }

    /// The kinds `head`, a file's first bytes, shows. Only the first `sniffLimit` bytes count.
    public static func sniff(head: Data) -> Set<MediaKind> {
        let h = Head(Array(head.prefix(sniffLimit)))
        guard !h.bytes.isEmpty else { return [] }
        if h.bytes.prefix(1024).firstRange(of: Array("%PDF-".utf8)) != nil { return [.pdf] }
        if let kinds = isoMedia(h) { return kinds }
        for (kinds, matches) in signatures where matches(h) { return kinds }
        if isSVG(h) { return [.image] }
        return []
    }

    // MARK: - Signatures

    /// ISO base media (MP4, MOV, 3GP, M4A, HEIF, AVIF, CR3): an `ftyp` box, or a QuickTime file
    /// that starts with another top-level atom. The major brand tells images and audio apart.
    private static func isoMedia(_ h: Head) -> Set<MediaKind>? {
        // The box's size comes first: an `ftyp` box is small, and the size of a first atom
        // other than `ftyp` is binary, never four letters of text.
        if h.has("ftyp", at: 4), h.has([0, 0]), let brand = h.ascii(8, 4) {
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1", "avif", "avis", "avci", "avcs", "crx "].contains(brand) { return [.image] }
            if ["jp2 ", "jpx ", "jpm ", "jxl "].contains(brand) { return [.image] }
            if ["M4A ", "M4B ", "M4P ", "aax "].contains(brand) { return [.audio] }
            return [.video, .audio]
        }
        if let atom = h.ascii(4, 4), ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(atom), !h.bytes.prefix(4).allSatisfy({ (0x20 ... 0x7E).contains($0) }) {
            return [.video, .audio]
        }
        return nil
    }

    private static let audioVisual: Set<MediaKind> = [.video, .audio]

    private static let signatures: [(Set<MediaKind>, (Head) -> Bool)] = [
        // Images
        ([.image], { $0.has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }), // PNG
        ([.image], { $0.has([0xFF, 0xD8, 0xFF]) }), // JPEG, MPO
        ([.image], { $0.has("GIF87a") || $0.has("GIF89a") }),
        ([.image], { $0.has("RIFF") && $0.has("WEBP", at: 8) }),
        // TIFF and BigTIFF, and the camera raw formats built on them (DNG, CR2, NEF, ARW…);
        // Olympus and Panasonic raw with their own magic numbers.
        ([.image], { $0.has("II*\0") || $0.has("MM\0*") || $0.has("II+\0") || $0.has("MM\0+") }),
        ([.image], { $0.has("IIRO") || $0.has("IIRS") || $0.has("MMOR") || $0.has("IIU\0") }),
        ([.image], { $0.has("FUJIFILMCCD-RAW") || $0.has("\0MRM") || ($0.has("II\u{1A}\0\0\0") && $0.has("HEAPCCDR", at: 6)) }),
        // BMP: "BM" and a known DIB header size, so a text file starting "BM" is not one.
        ([.image], { $0.has("BM") && [12, 40, 52, 56, 64, 108, 124].contains($0.uint32LE(at: 14) ?? 0) }),
        ([.image], { $0.has([0xFF, 0x0A]) || $0.has([0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) }), // JPEG XL
        ([.image], { $0.has([0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) || $0.has([0xFF, 0x4F, 0xFF, 0x51]) }), // JPEG 2000
        ([.image], { $0.has([0, 0, 1, 0]) && ($0.uint16LE(at: 4) ?? 0) > 0 && $0.byte(at: 9) == 0 }), // ICO
        ([.image], { $0.has("icns") && $0.byte(at: 4) == 0 }),
        ([.image], { $0.has("8BPS") && ($0.has([0, 1], at: 4) || $0.has([0, 2], at: 4)) }), // PSD, PSB
        ([.image], { $0.has([0x76, 0x2F, 0x31, 0x01]) }), // OpenEXR
        ([.image], { $0.has("#?RADIANCE") || $0.has("#?RGBE") }),
        // PBM, PGM, PPM: "P1" to "P7", white space, then a number or a comment.
        ([.image], { h in
            guard h.byte(at: 0) == 0x50, (0x31 ... 0x37).contains(h.byte(at: 1) ?? 0), [0x09, 0x0A, 0x0D, 0x20].contains(h.byte(at: 2) ?? 0) else { return false }
            let next = h.bytes.dropFirst(3).first { ![0x09, 0x0A, 0x0D, 0x20].contains($0) }
            return next.map { (0x30 ... 0x39).contains($0) || $0 == 0x23 } ?? false
        }),
        ([.image], { $0.has("PF\n") || $0.has("Pf\n") }), // PFM
        ([.image], { $0.has("DDS ") && $0.has([0x7C, 0, 0, 0], at: 4) }),
        ([.image], { $0.has([0xAB, 0x4B, 0x54, 0x58, 0x20]) }), // KTX, KTX2
        ([.image], { $0.has([0x13, 0xAB, 0xA1, 0x5C]) }), // ASTC
        ([.image], { $0.has("PVR\u{03}") || $0.has([0x03, 0x52, 0x56, 0x50]) || $0.has([0x34, 0, 0, 0]) && $0.has("PVR!", at: 44) }),
        ([.image], { $0.has([0x01, 0xDA]) }), // SGI
        ([.image], { $0.has("DICM", at: 128) }),
        ([.image], { $0.has([0xE0, 0xA5], at: 4) }), // Aseprite
        ([.image], { $0.has([1, 0, 0, 0]) && $0.has(" EMF", at: 40) }),
        ([.image], { $0.has([0xD7, 0xCD, 0xC6, 0x9A]) || $0.has([1, 0, 9, 0, 0, 3]) || $0.has([2, 0, 9, 0, 0, 3]) }), // WMF
        // Audio
        ([.audio], { $0.has("RIFF") && ($0.has("WAVE", at: 8) || $0.has("RMID", at: 8) || $0.has("sfbk", at: 8) || $0.has("DLS ", at: 8)) }),
        ([.audio], { ($0.has("RF64") || $0.has("BW64")) && $0.has("WAVE", at: 8) }),
        ([.audio], { $0.has([0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11]) }), // Wave64
        ([.audio], { $0.has("FORM") && ($0.has("AIFF", at: 8) || $0.has("AIFC", at: 8)) }),
        ([.audio], { $0.has("FRM8") || $0.has("DSD ") && $0.has([0x1C, 0, 0, 0], at: 4) }), // DSD
        ([.audio], { $0.has("caff") && $0.has([0, 1], at: 4) || $0.has("fLaC") || $0.has("#!AMR") || $0.has(".snd") }),
        ([.audio], { $0.has("ID3") && (2 ... 4).contains($0.byte(at: 3) ?? 0) && ($0.byte(at: 4) ?? 0xFF) < 0xFF }),
        ([.audio], { $0.has("MAC ") && (3800 ... 5000).contains($0.uint16LE(at: 4) ?? 0) }), // Monkey's Audio
        ([.audio], { $0.has("MThd") && $0.has([0, 0, 0, 6], at: 4) }), // MIDI
        ([.audio], { $0.has("wvpk") || $0.has("Extended Module: ") || $0.has(".ra\u{FD}") }),
        ([.audio], { $0.has([0x0B, 0x77]) }), // AC-3, E-AC-3
        // An MPEG audio frame (MP1, MP2, MP3) or an ADTS AAC frame: the sync bits, a valid
        // layer, and a bitrate and sample rate that are not reserved.
        ([.audio], { h in
            guard let b1 = h.byte(at: 1), let b2 = h.byte(at: 2), h.byte(at: 0) == 0xFF, b1 & 0xE0 == 0xE0 else { return false }
            if b1 & 0xF6 == 0xF0 { return (b2 >> 2) & 0x0F < 13 } // ADTS: layer 0, a known sample rate
            // MPEG audio: a layer, a version that is not reserved, a bitrate and a sample rate.
            return (b1 >> 1) & 0x03 != 0 && (b1 >> 3) & 0x03 != 1 && b2 >> 4 != 0x0F && (b2 >> 2) & 0x03 != 3
        }),
        // Video, or sound and picture
        ([.video], { $0.has("RIFF") && ($0.has("AVI ", at: 8) || $0.has("AVIX", at: 8)) }),
        (audioVisual, { $0.has([0x1A, 0x45, 0xDF, 0xA3]) }), // Matroska, WebM
        (audioVisual, { $0.has("OggS") }),
        (audioVisual, { $0.has([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) }), // ASF: WMV, WMA
        (audioVisual, { $0.has(".RMF") }), // RealMedia
        ([.video], { $0.has([0, 0, 1, 0xBA]) || $0.has([0, 0, 1, 0xB3]) }), // MPEG program stream, MPEG video
        ([.video], { $0.packets(from: 0, every: 188) }), // MPEG-TS
        ([.video], { $0.packets(from: 4, every: 192) }), // M2TS
        ([.video], { $0.has("FLV\u{01}") || $0.has("DKIF") || $0.has("NuppelVideo") || $0.has("MythTVVideo") }),
        ([.video], { $0.has([0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01]) }), // MXF
        ([.video], { $0.has([0x11, 0xAF], at: 4) || $0.has([0x12, 0xAF], at: 4) }), // FLI, FLC
        ([.video], { $0.has([0xB7, 0xD8, 0x00, 0x20, 0x37, 0x49, 0xDA, 0x11]) }), // WTV
        ([.video], { $0.has([0x1F, 0x07, 0x00, 0x3F]) || $0.has([0x1F, 0x07, 0x00, 0xBF]) }), // DV
    ]

    /// SVG: after a byte-order mark and white space the text starts with `<?xml` or `<svg`, and
    /// `<svg` appears within the bytes read.
    private static func isSVG(_ h: Head) -> Bool {
        var bytes = h.bytes[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        bytes = bytes.drop { [0x09, 0x0A, 0x0D, 0x20].contains($0) }
        guard bytes.starts(with: Array("<?xml".utf8)) || bytes.starts(with: Array("<svg".utf8)) else { return false }
        return bytes.firstRange(of: Array("<svg".utf8)) != nil
    }
}

private struct Head {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func byte(at offset: Int) -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

    func has(_ signature: [UInt8], at offset: Int = 0) -> Bool {
        offset + signature.count <= bytes.count && bytes[offset ..< offset + signature.count].elementsEqual(signature)
    }

    func has(_ signature: String, at offset: Int = 0) -> Bool {
        has(signature.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }, at: offset)
    }

    func ascii(_ offset: Int, _ length: Int) -> String? {
        guard offset + length <= bytes.count else { return nil }
        return String(bytes: bytes[offset ..< offset + length], encoding: .isoLatin1)
    }

    /// At least two transport packets read, each starting with the sync byte 0x47.
    func packets(from start: Int, every size: Int) -> Bool {
        let starts = Array(stride(from: start, to: bytes.count, by: size))
        return starts.count >= 2 && starts.allSatisfy { bytes[$0] == 0x47 }
    }

    func uint16LE(at offset: Int) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        return (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
