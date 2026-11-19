// SPDX-License-Identifier: GPL-3.0-or-later
//
// Output settings the engine reads: "Converted … go" once the result's format is known, and
// "Downscale Retina screenshots".

import EsclopCore
@testable import EsclopOptimisers
import Foundation
import ImageIO
import Testing

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
        #expect(converted.output == world.file("photo-optimised.jpeg"))
        #expect(FileManager.default.fileExists(atPath: png.path))
        #expect(converted.backup == nil)

        // Same format: "Optimised … go" (in place) still applies.
        let optimised = try await world.engine.optimise(png, request: request, progress: { _ in })
        #expect(optimised.output == png)

        let explicit = try await world.engine.convert(png, to: .jpeg, request: world.request(png), progress: { _ in })
        #expect(explicit.output == world.file("photo.jpeg"))
        #expect(!FileManager.default.fileExists(atPath: png.path))
    }

    @Test func retinaScreenshotsAreHalvedWhenAsked() async throws {
        let world = try await TestWorld()
        defer { Task { await world.finish() } }
        let shot = world.file("shot.png")
        try Fixture.write(
            try Fixture.gradient(width: 320, height: 240, deep: true, alpha: false), to: shot, type: .png,
            properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
        )
        let automatic = world.request(shot, origin: .clipboard, location: .temporary)

        let off = try await world.engine.optimise(shot, request: automatic, progress: { _ in })
        #expect(Inspect.size(off.output)! == (320, 240))

        try EsclopSettings.downscaleRetinaImages.set(true, in: world.settings)
        let on = try await world.engine.optimise(shot, request: automatic, progress: { _ in })
        #expect(Inspect.size(on.output)! == (160, 120))
        // Only automatic optimisation: the person asked the CLI for this exact file.
        let cli = try await world.engine.optimise(shot, request: world.request(shot, location: .temporary), progress: { _ in })
        #expect(Inspect.size(cli.output)! == (320, 240))
    }
}
