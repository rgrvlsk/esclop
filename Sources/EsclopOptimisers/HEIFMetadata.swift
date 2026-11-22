// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Removes the personal metadata of a HEIF file (HEIC, AVIF) without touching its pictures. The
/// Exif and XMP items listed in the `meta` box are overwritten where they lie: the Exif with an
/// empty block that keeps only the orientation and density, the XMP with an empty packet. No box
/// moves and no offset changes, so the coded images, their properties (colour profile, gain map,
/// depth) and the file size stay as they were.
// ponytail: blanks the items in place instead of dropping them. Dropping them would shift every
// offset after the `meta` box (`iloc`, and a `moov`'s chunk offsets) to save a few hundred bytes.
enum HEIFMetadata {
    /// `file` with its Exif and XMP items blanked; the same bytes when it has none. nil for a
    /// structure this does not read: the caller then re-encodes.
    /// - Parameters:
    ///   - orientation: the Exif orientation to keep (1-8), if the source had one.
    ///   - dpi: the density to keep, if the source had one.
    static func blanked(_ file: Data, orientation: Int?, dpi: Double?) -> Data? {
        var bytes = [UInt8](file)
        guard let top = boxes(bytes, from: 0, to: bytes.count) else { return nil }
        let metas = top.filter { $0.type == "meta" }
        guard metas.count == 1, let children = boxes(bytes, from: metas[0].body + 4, to: metas[0].end) else { return nil }
        func box(_ type: String) -> [Box] { children.filter { $0.type == type } }
        guard box("iinf").count == 1, box("iloc").count == 1, box("iref").count <= 1, box("idat").count <= 1,
              let items = items(bytes, box("iinf")[0]),
              let locations = locations(bytes, box("iloc")[0], idat: box("idat").first, size: bytes.count)
        else { return nil }
        var references: [Reference] = []
        if let iref = box("iref").first {
            guard let found = Self.references(bytes, iref) else { return nil }
            references = found
        }

        // An XMP that only describes an auxiliary image (a gain map's or a depth map's) is how
        // that image is read, not who took it.
        let auxiliary = Set(references.filter { $0.type == "auxl" }.map(\.from))
        let targets = items.filter { id, item in
            if item.type == "Exif" { return true }
            guard item.isXMP else { return false }
            let described = references.filter { $0.type == "cdsc" && $0.from == id }.flatMap(\.to)
            return described.isEmpty || !described.allSatisfy(auxiliary.contains)
        }
        for (id, item) in targets.sorted(by: { $0.key < $1.key }) {
            guard item.encoding.isEmpty, let extents = locations[id]?.extents, !extents.isEmpty else { return nil }
            // Bytes another item also uses are not this item's to blank.
            for (other, location) in locations where other != id {
                for a in extents {
                    for b in location.extents where a.start < b.start + b.length && b.start < a.start + a.length { return nil }
                }
            }
            let room = extents.reduce(0) { $0 + $1.length }
            let blank: [UInt8]
            if item.type == "Exif" {
                guard let block = [exif(orientation: orientation, dpi: dpi), exif(orientation: nil, dpi: nil)].first(where: { $0.count <= room })
                else { return nil }
                blank = block + [UInt8](repeating: 0, count: room - block.count)
            } else {
                let packet = Array(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8)
                guard packet.count <= room else { return nil }
                blank = packet + [UInt8](repeating: 0x20, count: room - packet.count)
            }
            var written = 0
            for extent in extents {
                bytes.replaceSubrange(extent.start ..< extent.start + extent.length, with: blank[written ..< written + extent.length])
                written += extent.length
            }
        }
        return Data(bytes)
    }

    // MARK: Boxes

    struct Box {
        var type: String
        /// Where the box's content starts, after its size and type.
        var body: Int
        var end: Int
    }

    /// The boxes between `from` and `to`; nil when one runs past `to`.
    static func boxes(_ bytes: [UInt8], from: Int, to: Int) -> [Box]? {
        var found: [Box] = []
        var reader = Reader(bytes: bytes, at: from, end: to)
        while reader.at < to {
            let start = reader.at
            guard var size = reader.uint(4), let type = reader.fourCC() else { return nil }
            if size == 1 {
                guard let large = reader.uint(8) else { return nil }
                size = large
            } else if size == 0 {
                size = to - start
            }
            guard size >= reader.at - start, size <= to - start else { return nil }
            found.append(Box(type: type, body: reader.at, end: start + size))
            reader.at = start + size
        }
        return found
    }

    struct Item {
        var type: String
        var contentType = ""
        var encoding = ""
        var isXMP: Bool {
            type == "mime" && contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/rdf+xml"
        }
    }

    /// `iinf`: each item's type, and a `mime` item's content type and encoding.
    static func items(_ bytes: [UInt8], _ iinf: Box) -> [Int: Item]? {
        var reader = Reader(bytes: bytes, at: iinf.body, end: iinf.end)
        guard let version = reader.uint(1), reader.uint(3) != nil, let count = reader.uint(version == 0 ? 2 : 4),
              let entries = boxes(bytes, from: reader.at, to: iinf.end), entries.count == count
        else { return nil }
        var items: [Int: Item] = [:]
        for entry in entries {
            var reader = Reader(bytes: bytes, at: entry.body, end: entry.end)
            // Versions 0 and 1 name no item type; HEIF files use 2 and 3.
            guard entry.type == "infe", let version = reader.uint(1), version >= 2, reader.uint(3) != nil,
                  let id = reader.uint(version == 2 ? 2 : 4), reader.uint(2) != nil, let type = reader.fourCC(),
                  reader.string() != nil, items[id] == nil
            else { return nil }
            var item = Item(type: type)
            if type == "mime" {
                guard let contentType = reader.string() else { return nil }
                item.contentType = contentType
                // Optional, and some writers leave out its terminating zero.
                item.encoding = String(decoding: bytes[reader.at ..< entry.end].prefix { $0 != 0 }, as: UTF8.self)
            }
            items[id] = item
        }
        return items
    }

    struct Location {
        /// Absolute byte ranges in the file, in the item's order.
        var extents: [(start: Int, length: Int)]
    }

    /// `iloc`: where each item's bytes are, in the file or in `idat`. An item whose bytes are in
    /// another file or another item has no extents.
    static func locations(_ bytes: [UInt8], _ iloc: Box, idat: Box?, size: Int) -> [Int: Location]? {
        var reader = Reader(bytes: bytes, at: iloc.body, end: iloc.end)
        guard let version = reader.uint(1), version <= 2, reader.uint(3) != nil, let sizes = reader.uint(1), let more = reader.uint(1)
        else { return nil }
        let (offsetSize, lengthSize, baseSize, indexSize) = (sizes >> 4, sizes & 15, more >> 4, version > 0 ? more & 15 : 0)
        guard [offsetSize, lengthSize, baseSize, indexSize].allSatisfy([0, 4, 8].contains), let count = reader.uint(version < 2 ? 2 : 4)
        else { return nil }
        var locations: [Int: Location] = [:]
        for _ in 0 ..< count {
            guard let id = reader.uint(version < 2 ? 2 : 4), locations[id] == nil, let method = version > 0 ? reader.uint(2).map({ $0 & 15 }) : 0,
                  let reference = reader.uint(2), let base = reader.uint(baseSize), let extentCount = reader.uint(2)
            else { return nil }
            var extents: [(start: Int, length: Int)] = []
            for _ in 0 ..< extentCount {
                guard reader.uint(indexSize) != nil, let offset = reader.uint(offsetSize), let length = reader.uint(lengthSize) else { return nil }
                extents.append((offset, length))
            }
            let origin: (start: Int, end: Int)
            switch (method, reference) {
            case (0, 0): origin = (0, size)
            case (1, 0):
                guard let idat else { return nil }
                origin = (idat.body, idat.end)
            default:
                locations[id] = Location(extents: [])
                continue
            }
            var absolute: [(start: Int, length: Int)] = []
            for extent in extents {
                guard base <= origin.end, extent.start <= origin.end else { return nil }
                let start = origin.start + base + extent.start
                // Length 0: to the end of the file or of `idat`.
                let length = extent.length == 0 ? origin.end - start : extent.length
                guard start <= origin.end, length >= 0, length <= origin.end - start else { return nil }
                absolute.append((start, length))
            }
            locations[id] = Location(extents: absolute)
        }
        return locations
    }

    struct Reference {
        var type: String
        var from: Int
        var to: [Int]
    }

    /// `iref`: which items each item points at, by reference type (`cdsc`, `auxl`...).
    static func references(_ bytes: [UInt8], _ iref: Box) -> [Reference]? {
        var reader = Reader(bytes: bytes, at: iref.body, end: iref.end)
        guard let version = reader.uint(1), reader.uint(3) != nil, let entries = boxes(bytes, from: reader.at, to: iref.end) else { return nil }
        let idSize = version == 0 ? 2 : 4
        var references: [Reference] = []
        for entry in entries {
            var reader = Reader(bytes: bytes, at: entry.body, end: entry.end)
            guard let from = reader.uint(idSize), let count = reader.uint(2) else { return nil }
            var to: [Int] = []
            for _ in 0 ..< count {
                guard let id = reader.uint(idSize) else { return nil }
                to.append(id)
            }
            references.append(Reference(type: entry.type, from: from, to: to))
        }
        return references
    }

    // MARK: Exif

    /// A HEIF Exif item: the offset of the TIFF header (0), then a big-endian TIFF block whose
    /// only directory holds the orientation and the density.
    static func exif(orientation: Int?, dpi: Double?) -> [UInt8] {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: Int) -> [UInt8] { u16(value >> 16 & 0xFFFF) + u16(value & 0xFFFF) }
        let orientation = orientation.flatMap { (1 ... 8).contains($0) ? $0 : nil }
        let dpi = dpi.flatMap { (1 ... 65535).contains($0) ? Int(($0 * 100).rounded()) : nil }
        let count = (orientation == nil ? 0 : 1) + (dpi == nil ? 0 : 3)
        // After the header (8), the entry count (2), the entries and the next-directory offset (4).
        let values = 8 + 2 + count * 12 + 4
        var entries: [UInt8] = []
        var extra: [UInt8] = []
        func short(_ tag: Int, _ value: Int) { entries += u16(tag) + u16(3) + u32(1) + u16(value) + u16(0) }
        func rational(_ tag: Int, _ hundredths: Int) {
            entries += u16(tag) + u16(5) + u32(1) + u32(values + extra.count)
            extra += u32(hundredths) + u32(100)
        }
        if let orientation { short(0x0112, orientation) }
        if let dpi {
            rational(0x011A, dpi)
            rational(0x011B, dpi)
            short(0x0128, 2) // inches
        }
        return u32(0) + Array("MM".utf8) + u16(42) + u32(8) + u16(count) + entries + u32(0) + extra
    }

    // MARK: Reading

    struct Reader {
        let bytes: [UInt8]
        var at: Int
        let end: Int

        /// A big-endian unsigned integer of `size` bytes (0 reads 0).
        mutating func uint(_ size: Int) -> Int? {
            guard size >= 0, size <= 8, at <= end - size else { return nil }
            var value: UInt64 = 0
            for index in at ..< at + size { value = value << 8 | UInt64(bytes[index]) }
            guard value <= UInt64(Int.max) else { return nil }
            at += size
            return Int(value)
        }

        mutating func fourCC() -> String? {
            guard at <= end - 4 else { return nil }
            defer { at += 4 }
            return String(decoding: bytes[at ..< at + 4], as: UTF8.self)
        }

        /// A null-terminated UTF-8 string.
        mutating func string() -> String? {
            guard at < end, let zero = bytes[at ..< end].firstIndex(of: 0) else { return nil }
            defer { at = zero + 1 }
            return String(decoding: bytes[at ..< zero], as: UTF8.self)
        }
    }
}
