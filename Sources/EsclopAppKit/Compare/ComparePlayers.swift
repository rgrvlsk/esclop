// SPDX-License-Identifier: GPL-3.0-or-later
//
// The two players of a video or audio comparison, kept in step. Video plays both sides together,
// scrubs both and steps both a frame at a time; audio plays one side at a time from the same
// moment (two soundtracks at once cannot be judged), as Clop does.

import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class ComparePlayers {
    enum Side: Sendable { case before, after }

    let before: AVPlayer
    let after: AVPlayer
    let isAudio: Bool
    private(set) var isPlaying = false
    /// For audio, the side that plays.
    private(set) var playingSide: Side?
    /// Seconds into both files.
    private(set) var time: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?

    init(before: URL, after: URL, isAudio: Bool) {
        self.before = AVPlayer(url: before)
        self.after = AVPlayer(url: after)
        self.isAudio = isAudio
        // The original has no sound in a video comparison: one soundtrack is enough to follow.
        self.before.isMuted = !isAudio
        for player in [self.before, self.after] { player.actionAtItemEnd = .pause }
        observe(self.after)
        Task { await loadDuration() }
    }

    func stop() {
        before.pause()
        after.pause()
        if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
        observer = nil
        observedPlayer = nil
        isPlaying = false
        playingSide = nil
    }

    private func loadDuration() async {
        let seconds = (try? await after.currentItem?.asset.load(.duration))?.seconds ?? 0
        duration = seconds.isFinite ? seconds : 0
    }

    private func observe(_ player: AVPlayer) {
        if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
        observedPlayer = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] now in
            MainActor.assumeIsolated { self?.tick(now) }
        }
    }

    private func tick(_ now: CMTime) {
        time = now.seconds.isFinite ? now.seconds : 0
        guard !isAudio, isPlaying else { return }
        // The original follows the optimised one; nudge it when it drifts.
        if abs(before.currentTime().seconds - time) > 0.08 {
            before.seek(to: now, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if let item = after.currentItem, item.duration.isNumeric, now >= item.duration { pause() }
    }

    // MARK: Video

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        if duration > 0, time >= duration - 0.05 { seek(to: 0) }
        if isAudio {
            play(side: playingSide ?? .after)
            return
        }
        before.play()
        after.play()
        isPlaying = true
    }

    func pause() {
        before.pause()
        after.pause()
        isPlaying = false
        playingSide = nil
    }

    /// Both sides to `seconds`, exactly.
    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)
        time = target.seconds
        before.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        after.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// A frame forward (1) or back (-1) on both sides; playback stops first.
    func step(by frames: Int) {
        pause()
        before.currentItem?.step(byCount: frames)
        after.currentItem?.step(byCount: frames)
        time = after.currentTime().seconds
    }

    // MARK: Audio

    /// Plays one side from where the other was; the other stops.
    func play(side: Side) {
        let (playing, other) = side == .before ? (before, after) : (after, before)
        other.pause()
        playing.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playing.play()
        observe(playing)
        playingSide = side
        isPlaying = true
    }
}
