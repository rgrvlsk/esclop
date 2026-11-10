// SPDX-License-Identifier: GPL-3.0-or-later
//
// Video and audio in the compare window. Video shows both players in the mode's layout (the
// split masks the optimised one right of the divider) under one transport: play both, scrub
// both, step a frame back or forward. Audio plays one side at a time from the same moment.

import AVKit
import SwiftUI

/// A bare AVPlayerView: the window's own transport drives it.
struct ComparePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct CompareVideo: View {
    @Bindable var model: CompareModel
    let players: ComparePlayers

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch model.mode {
            case .split:
                let divider = size.width * model.viewport.split
                ZStack(alignment: .topLeading) {
                    ComparePlayerView(player: players.before)
                    ComparePlayerView(player: players.after)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, size.width - divider)).offset(x: divider) }
                    CompareDivider(x: divider, height: size.height) { x in
                        model.viewport.split = CompareViewport.split(at: x, width: size.width)
                    }
                    HStack {
                        CompareChip(text: Strings.text("Original"))
                        Spacer()
                        CompareChip(text: Strings.text("Optimised"))
                    }
                    .padding(10)
                }
                .coordinateSpace(.named("compareCanvas"))
            case .sideBySide:
                HStack(spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        ComparePlayerView(player: players.before)
                        CompareChip(text: Strings.text("Original")).padding(10)
                    }
                    ZStack(alignment: .topLeading) {
                        ComparePlayerView(player: players.after)
                        CompareChip(text: Strings.text("Optimised")).padding(10)
                    }
                }
            case .flip:
                ZStack(alignment: .topLeading) {
                    ComparePlayerView(player: players.before).opacity(model.showsOriginal ? 1 : 0)
                    ComparePlayerView(player: players.after).opacity(model.showsOriginal ? 0 : 1)
                    CompareChip(text: model.showsOriginal ? Strings.text("Original") : Strings.text("Optimised")).padding(10)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.text("Comparison"))
    }
}

/// Play, frame steps and the shared scrubber for video; for audio, a play button per side.
struct CompareTransport: View {
    let players: ComparePlayers

    var body: some View {
        HStack(spacing: 10) {
            if players.isAudio {
                sideButton(.before, title: Strings.text("Play the original"))
                sideButton(.after, title: Strings.text("Play the optimised file"))
            } else {
                Button(Strings.text("Previous Frame"), systemImage: "backward.frame") { players.step(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button(players.isPlaying ? Strings.text("Pause Both") : Strings.text("Play Both"), systemImage: players.isPlaying ? "pause.fill" : "play.fill") {
                    players.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button(Strings.text("Next Frame"), systemImage: "forward.frame") { players.step(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            Slider(value: Binding(get: { players.time }, set: { players.seek(to: $0) }), in: 0 ... max(players.duration, 0.01))
                .accessibilityLabel(Strings.text("Position in both files"))
                .accessibilityValue(Self.clock(players.time))
            Text("\(Self.clock(players.time)) / \(Self.clock(players.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func sideButton(_ side: ComparePlayers.Side, title: String) -> some View {
        let playing = players.playingSide == side
        return Button {
            if playing { players.pause() } else { players.play(side: side) }
        } label: {
            Label(title, systemImage: playing ? "pause.circle.fill" : "play.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(playing ? Strings.text("Pause") : title)
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
