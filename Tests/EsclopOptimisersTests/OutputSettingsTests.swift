// SPDX-License-Identifier: GPL-3.0-or-later
//
// Output settings the engine reads: "Converted … go" once the result's format is known, and
// "Downscale Retina screenshots".

import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct OutputSettingsTests {
    /// A location from the settings sends a conversion where "Converted images go" says (next to
    /// the original), so the in-place default no longer removes the source. An explicit in-place
    /// request still converts in place.
    @Test func conversionsFollowConvertedBehaviour() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        try Fixture.png(png)
        try EsclopSettings.convertedImageBehaviour.set(.sameFolder, in: world.settings)

        var request = world.request(png)
        request.locationFromSettings = true
        let converted = try await world.engine.convert(png, to: .jpeg, request: request, progress: { _ in })
        // The default template leaves a conversion its plain name, with the usual .jpg.
        #expect(converted.output == world.file("photo.jpg"))
        #expect(FileManager.default.fileExists(atPath: png.path))
        #expect(converted.backup == nil)

        // Same format: "Optimised … go" (in place) still applies.
        let optimised = try await world.engine.optimise(png, request: request, progress: { _ in })
        #expect(optimised.output == png)

        try FileManager.default.removeItem(at: converted.output)
        let explicit = try await world.engine.convert(png, to: .jpeg, request: world.request(png), progress: { _ in })
        #expect(explicit.output == world.file("photo.jpg"))
        #expect(!FileManager.default.fileExists(atPath: png.path))
    }

    /// An agent's call with no place follows "Converted … go" too, but an in-place setting does not
    /// let it overwrite originals: without that permission it keeps its default, next to the file.
    @Test func agentConversionsFollowConvertedBehaviourWithinTheirPermission() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let png = world.file("photo.png")
        try Fixture.png(png)
        try EsclopSettings.convertedImageBehaviour.set(.temporary, in: world.settings)
        var request = world.request(png, origin: .mcp, location: .sameFolder)
        request.locationFromSettings = true

        let temporary = try await world.engine.convert(png, to: .jpeg, request: request, progress: { _ in })
        #expect(temporary.output.deletingLastPathComponent() != png.deletingLastPathComponent())

        try EsclopSettings.convertedImageBehaviour.set(.inPlace, in: world.settings)
        let beside = try await world.engine.convert(png, to: .jpeg, request: request, progress: { _ in })
        #expect(beside.output == world.file("photo.jpg"))
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test func retinaScreenshotsAreHalvedWhenAsked() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        // The density and the EXIF comment macOS puts on a screenshot, saved or copied.
        let retina: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"],
        ]
        let shot = world.file("shot.png")
        try Fixture.write(
            try Fixture.gradient(width: 320, height: 240, deep: true, alpha: false), to: shot, type: .png, properties: retina
        )
        let automatic = world.request(shot, origin: .clipboard, location: .temporary)

        let off = try await world.engine.optimise(shot, request: automatic, progress: { _ in })
        #expect(Inspect.size(off.output)! == (320, 240))

        try EsclopSettings.downscaleRetinaImages.set(true, in: world.settings)
        let on = try await world.engine.optimise(shot, request: automatic, progress: { _ in })
        #expect(Inspect.size(on.output)! == (160, 120))
        #expect(ImageInfo.probe(on.output)?.dpi == 72)
        // HEIC's density cannot be rewritten after the encode, so it is written at 72 dpi.
        let heic = world.file("shot.heic")
        try Fixture.write(
            try Fixture.gradient(width: 320, height: 240, deep: false, alpha: false), to: heic, type: .heic, properties: retina
        )
        let halvedHEIC = try await world.engine.optimise(heic, request: world.request(heic, origin: .clipboard, location: .temporary), progress: { _ in })
        #expect(Inspect.size(halvedHEIC.output)! == (160, 120))
        #expect(ImageInfo.probe(halvedHEIC.output)?.dpi == 72)
        // A 144 dpi picture that is not a screenshot (a watermarked photo, an export) keeps its pixels.
        let photo = world.file("photo.png")
        try Fixture.write(
            try Fixture.gradient(width: 320, height: 240, deep: true, alpha: false), to: photo, type: .png,
            properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
        )
        let kept = try await world.engine.optimise(photo, request: world.request(photo, origin: .clipboard, location: .temporary), progress: { _ in })
        #expect(Inspect.size(kept.output)! == (320, 240))
        // 150 dpi is a scan, not a 2x screenshot.
        let scan = world.file("scan.png")
        try Fixture.write(
            try Fixture.gradient(width: 320, height: 240, deep: true, alpha: false), to: scan, type: .png,
            properties: retina.merging([kCGImagePropertyDPIWidth: 150, kCGImagePropertyDPIHeight: 150]) { $1 }
        )
        let scanned = try await world.engine.optimise(scan, request: world.request(scan, origin: .clipboard, location: .temporary), progress: { _ in })
        #expect(Inspect.size(scanned.output)! == (320, 240))
        // Only automatic optimisation: the person asked the CLI for this exact file.
        let cli = try await world.engine.optimise(shot, request: world.request(shot, location: .temporary), progress: { _ in })
        #expect(Inspect.size(cli.output)! == (320, 240))
    }

    /// The halved screenshot is marked 1x without re-encoding: PNG `pHYs`, JPEG resolution.
    @Test func oneXRewritesTheDensityOnly() throws {
        let folder = try Harness.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try Fixture.gradient(width: 64, height: 48, deep: false, alpha: false)
        for (name, type) in [("a.png", UTType.png), ("a.jpg", UTType.jpeg)] {
            let url = folder.appendingPathComponent(name)
            try Fixture.write(image, to: url, type: type, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
            #expect(ImageInfo.probe(url)?.dpi == 144)
            let before = try Data(contentsOf: url).count
            ImageIOCodec.setDensity(url, dpi: 72)
            #expect(ImageInfo.probe(url)?.dpi == 72, "\(name)")
            #expect(Inspect.size(url)! == (64, 48))
            #expect(abs(try Data(contentsOf: url).count - before) < 4096, "\(name) was not re-encoded")
        }
    }
}
