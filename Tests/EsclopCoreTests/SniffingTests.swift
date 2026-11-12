// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EsclopCore

/// Real files of each kind, written by the system's own encoders.
enum RealMedia {
    static func image(_ type: UTType, to url: URL) -> Bool {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func pdf(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        context.endPDFPage()
        context.closePDF()
    }

    static func audio(to url: URL, settings: [String: Any]) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0 ..< 4410 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.06) * 0.3 }
        try file.write(from: buffer)
    }

    static func video(to url: URL, type: AVFileType) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 3 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(writer.error.map { "\($0)" } ?? "")")
    }
}

@Suite struct SniffingTests {
    @Test func realFilesShowTheirKind() async throws {
        let folder = try scratchFolder()
        var written: [(URL, MediaKind)] = []
        for (name, type) in [("a.png", UTType.png), ("a.jpg", .jpeg), ("a.gif", .gif), ("a.tiff", .tiff), ("a.bmp", .bmp), ("a.heic", .heic), ("a.ico", .ico)] {
            let url = folder.appendingPathComponent(name)
            // HEIC encoding is missing on some virtual machines; the others are always there.
            if RealMedia.image(type, to: url) { written.append((url, .image)) } else { #expect(name == "a.heic", "\(name) was not written") }
        }
        let svg = folder.appendingPathComponent("a.svg")
        try "\u{FEFF}\n<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>\n".write(to: svg, atomically: true, encoding: .utf8)
        written.append((svg, .image))
        let pdf = folder.appendingPathComponent("a.pdf")
        RealMedia.pdf(to: pdf)
        written.append((pdf, .pdf))
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        for name in ["a.wav", "a.aiff", "a.caf"] {
            var settings = pcm
            settings[AVLinearPCMIsBigEndianKey] = name == "a.aiff"
            try RealMedia.audio(to: folder.appendingPathComponent(name), settings: settings)
            written.append((folder.appendingPathComponent(name), .audio))
        }
        try RealMedia.audio(to: folder.appendingPathComponent("a.m4a"), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        written.append((folder.appendingPathComponent("a.m4a"), .audio))
        try await RealMedia.video(to: folder.appendingPathComponent("a.mp4"), type: .mp4)
        try await RealMedia.video(to: folder.appendingPathComponent("a.mov"), type: .mov)
        written += [(folder.appendingPathComponent("a.mp4"), .video), (folder.appendingPathComponent("a.mov"), .video)]

        for (url, kind) in written {
            #expect(MediaKind.of(url) == kind, "\(url.lastPathComponent) is named as \(kind)")
            #expect(MediaKind.sniff(url).contains(kind), "\(url.lastPathComponent) shows \(kind): \(MediaKind.sniff(url))")
        }
        // A PNG named .jpg is still an image.
        let misnamed = folder.appendingPathComponent("really-a-png.jpg")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("a.png"), to: misnamed)
        #expect(MediaKind.sniff(misnamed) == [.image])
    }

    /// Headers of formats the system cannot write, as the format's specification starts them.
    @Test func signaturesOfOtherFormats() {
        func head(_ bytes: [UInt8], pad: Int = 64) -> Data { Data(bytes + [UInt8](repeating: 0, count: pad)) }
        let ascii = { (text: String) in Array(text.utf8) }
        let cases: [(String, Data, Set<MediaKind>)] = [
            ("webp", head(ascii("RIFF") + [0x20, 0, 0, 0] + ascii("WEBPVP8 ")), [.image]),
            ("jxl", head([0xFF, 0x0A, 0xFA]), [.image]),
            ("avif", head([0, 0, 0, 0x1C] + ascii("ftypavif")), [.image]),
            ("cr3", head([0, 0, 0, 0x18] + ascii("ftypcrx ")), [.image]),
            ("psd", head(ascii("8BPS") + [0, 1]), [.image]),
            ("pgm", Data("P5\n16 16\n255\n".utf8), [.image]),
            ("dng", head(ascii("II*\0") + [8, 0, 0, 0]), [.image]),
            ("webm", head([0x1A, 0x45, 0xDF, 0xA3, 0x9F]), [.video, .audio]),
            ("ogg", head(ascii("OggS") + [0, 2]), [.video, .audio]),
            ("avi", head(ascii("RIFF") + [0x20, 0, 0, 0] + ascii("AVI LIST")), [.video]),
            ("ts", Data((0 ..< 3).flatMap { _ in [0x47, 0x40, 0x00, 0x10] + [UInt8](repeating: 0xFF, count: 184) }), [.video]),
            ("mpg", head([0, 0, 1, 0xBA, 0x44]), [.video]),
            ("flac", head(ascii("fLaC") + [0, 0, 0, 0x22]), [.audio]),
            ("mp3 with ID3", head(ascii("ID3") + [4, 0, 0]), [.audio]),
            ("mp3 frame", head([0xFF, 0xFB, 0x90, 0x64]), [.audio]),
            ("aac", head([0xFF, 0xF1, 0x50, 0x80]), [.audio]),
            ("mid", head(ascii("MThd") + [0, 0, 0, 6, 0, 1]), [.audio]),
        ]
        for (name, data, kinds) in cases {
            #expect(MediaKind.sniff(head: data) == kinds, "\(name): \(MediaKind.sniff(head: data))")
        }
    }

    @Test func renamedTextAndKeysShowNoKind() throws {
        let folder = try scratchFolder()
        // The shape of a private key file, with made-up content; put together so that secret
        // scanners do not take this test for a key.
        let armour = ["OPENSSH", "PRIVATE", "KEY"].joined(separator: " ")
        let key = "-----BEGIN \(armour)-----\n" + String(repeating: "made-up-not-a-key", count: 4) + "\n-----END \(armour)-----\n"
        let texts = ["notes": "Meeting notes\nBM and P1 are not headers.\n", "key": key, "public": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample comment\n", "json": "{\"token\": \"abc\"}\n", "gtext": "Get free stuff\n", "html": "<html><body><p>not an svg</p></body></html>\n"]
        for (stem, text) in texts {
            for ext in ["png", "jpg", "mp4", "mov", "pdf", "mp3", "svg", "ts"] {
                let url = folder.appendingPathComponent("\(stem).\(ext)")
                try text.write(to: url, atomically: true, encoding: .utf8)
                #expect(MediaKind.sniff(url).isEmpty, "\(url.lastPathComponent) shows \(MediaKind.sniff(url))")
            }
        }
        let empty = folder.appendingPathComponent("empty.png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(MediaKind.sniff(empty).isEmpty)
        // A link named like a photo shows what it points at.
        let link = folder.appendingPathComponent("photo.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("key.png"))
        #expect(MediaKind.sniff(link).isEmpty)
        // A pipe is never opened for reading, so nothing waits on a writer.
        let fifo = folder.appendingPathComponent("pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(MediaKind.sniff(fifo).isEmpty)
        #expect(MediaKind.sniff(folder).isEmpty, "a folder")
        #expect(MediaKind.sniff(folder.appendingPathComponent("missing.png")).isEmpty)
    }

    /// Only the first 4 KB are read: an `<svg` tag past them, or a PDF header past 1 KB, is not seen.
    @Test func readingStopsAt4KB() throws {
        let folder = try scratchFolder()
        func svg(padding: Int) throws -> URL {
            let url = folder.appendingPathComponent("p\(padding).svg")
            try ("<?xml version=\"1.0\"?>" + String(repeating: " ", count: padding) + "<svg xmlns=\"http://www.w3.org/2000/svg\"/>").write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        #expect(MediaKind.sniff(try svg(padding: 4000)) == [.image])
        #expect(MediaKind.sniff(try svg(padding: 4100)).isEmpty)
        #expect(MediaKind.sniff(head: Data((String(repeating: " ", count: 900) + "%PDF-1.7").utf8)) == [.pdf])
        #expect(MediaKind.sniff(head: Data((String(repeating: " ", count: 1100) + "%PDF-1.7").utf8)).isEmpty)
        #expect(MediaKind.sniffLimit == 4096)
    }
}
