// SPDX-License-Identifier: GPL-3.0-or-later
//
// How long a job should take, before it starts and while it runs. The activity capsule only
// appears for jobs expected to take longer than two seconds (DESIGN.md), and shows the time left.

import AVFoundation
import EsclopCore
import Foundation

public enum JobEstimate {
    /// Rough throughput per kind in bytes per second, plus a fixed start-up cost, at the normal
    /// settings; aggressive takes about twice as long. For video the bytes are only a first guess:
    /// `videoSeconds` replaces it with one from the frames as soon as the file's metadata loads.
    static func rate(for kind: MediaKind) -> (bytesPerSecond: Double, startup: TimeInterval) {
        switch kind {
        case .image: return (25_000_000, 0.4)
        case .pdf: return (6_000_000, 0.5)
        case .video: return (8_000_000, 0.5)
        case .audio: return (8_000_000, 0.5)
        }
    }

    /// Pixels per second the bundled video pipeline gets through. Measured on an Apple silicon Mac:
    /// 1920×1080 at 30 fps for 12 s took under a second, 2880×1800 at 60 fps for 40 s took 24 s.
    static let videoPixelsPerSecond = 600_000_000.0

    /// Seconds for a video from its frames: size × frame rate × duration.
    public static func videoSeconds(width: Double, height: Double, fps: Double, duration: TimeInterval, aggressive: Bool) -> TimeInterval {
        let seconds = 0.5 + abs(width * height) * max(1, fps) * max(0, duration) / videoPixelsPerSecond
        return aggressive ? seconds * 2 : seconds
    }

    /// Reads a video's size, frame rate and duration, then estimates as above. nil if unreadable.
    public static func videoSeconds(of url: URL, aggressive: Bool) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, fps) = try? await track.load(.naturalSize, .nominalFrameRate),
              let duration = try? await asset.load(.duration)
        else { return nil }
        return videoSeconds(width: size.width, height: size.height, fps: Double(fps), duration: duration.seconds, aggressive: aggressive)
    }

    public static func expectedSeconds(kind: MediaKind?, bytes: Int, aggressive: Bool) -> TimeInterval {
        guard let kind else { return 0 }
        let rate = rate(for: kind)
        let seconds = rate.startup + Double(bytes) / rate.bytesPerSecond
        return aggressive ? seconds * 2 : seconds
    }

    /// Seconds left: from the progress once the engine reports enough of it, else from the estimate.
    public static func secondsLeft(elapsed: TimeInterval, fraction: Double, expected: TimeInterval) -> TimeInterval {
        if fraction >= 0.05, fraction < 1 {
            return max(1, elapsed / fraction - elapsed)
        }
        return max(1, expected - elapsed)
    }
}
