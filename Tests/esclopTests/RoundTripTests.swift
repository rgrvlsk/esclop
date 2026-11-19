// SPDX-License-Identifier: GPL-3.0-or-later
//
// optimise -> recent -> restore through the real binary, with ESCLOP_SUPPORT_DIR set: the backup
// lands in that folder, not in the person's Application Support. A HEIC goes through ImageIO,
// so no bundled tool is needed.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct CLIRoundTrip {
    @Test func optimiseRecentRestore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("esclop-roundtrip-\(UUID().uuidString)", isDirectory: true)
        let support = folder.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.heic")
        try Self.heic(photo)
        let original = try Data(contentsOf: photo)

        func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = try esclopBinary()
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["ESCLOP_NO_APP": "1", "ESCLOP_SUPPORT_DIR": support.path]) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let optimised = try run(["optimise", "--no-color", "-n", photo.path])
        #expect(optimised.status == 0, "\(optimised.output)")
        #expect(try Data(contentsOf: photo) != original)

        let recent = try run(["recent", "--json", "--limit", "5"])
        #expect(recent.status == 0, "\(recent.output)")
        struct Row: Decodable { var source: String; var backup: String? }
        let rows = try JSONDecoder().decode([Row].self, from: Data(recent.output.utf8))
        let backup = try #require(rows.first?.backup)
        #expect(rows.first?.source.hasSuffix("/photo.heic") == true)
        #expect(URL(fileURLWithPath: backup).resolvingSymlinksInPath().path.hasPrefix(support.resolvingSymlinksInPath().path + "/"))

        let restored = try run(["restore", "--no-color", photo.path])
        #expect(restored.status == 0, "\(restored.output)")
        #expect(try Data(contentsOf: photo) == original)
    }

    static func heic(_ url: URL) throws {
        let width = 480, height = 360
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw TestFailure("context") }
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let noise = CGFloat((x * 7919 + y * 104_729) % 97) / 97
                context.setFillColor(red: CGFloat(x) / CGFloat(width), green: noise, blue: CGFloat(y) / CGFloat(height), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw TestFailure("heic destination") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure("heic write") }
    }
}
