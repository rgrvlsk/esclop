// SPDX-License-Identifier: GPL-3.0-or-later
//
// A result card: thumbnail left, text right, the deflating bar, actions on hover below. 300 pt
// wide, left aligned, HUD material. The saving is the one large figure.

import EsclopCore
import EsclopIPC
import SwiftUI

public struct ResultCardView: View {
    let card: ResultCard
    let perform: (CardPresentation.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// False until the deflate plays: the bar sits at full width and the figure at the original size.
    @State private var deflated = false

    public init(card: ResultCard, perform: @escaping (CardPresentation.Action) -> Void) {
        self.card = card
        self.perform = perform
        _deflated = State(initialValue: card.hasPlayedArrival || (card.result == nil && !card.isWorking))
    }

    public var body: some View {
        let info = card.presentation
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if case .notice = card.phase {} else { thumbnail }
                VStack(alignment: .leading, spacing: 2) {
                    if !info.fileName.isEmpty {
                        Text(info.fileName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    headline(info)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let end = info.barEnd {
                // Reduced motion: the full bar and the deflated one crossfade instead of moving.
                ZStack {
                    DeflateBar(
                        end: deflated ? end : 1, progress: info.progress,
                        tint: card.isWorking ? (card.aggressive ? Palette.warm : Palette.accent) : color(info.tone),
                        filled: card.result != nil
                    )
                    .id(reduceMotion ? AnyHashable(deflated) : AnyHashable(0))
                    .transition(.opacity)
                }
            }
            if showsActions(info) {
                actions(info)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(width: Metrics.cardWidth, alignment: .leading)
        .panelSurface()
        .contentShape(RoundedRectangle(cornerRadius: Metrics.panelRadius))
        .onHover { hovering in
            withAnimation(Motion.hover) { card.isHovered = hovering }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(.escape) { perform(.dismiss); return .handled }
        .onKeyPress(.return) { run(.reveal, in: info) }
        .onKeyPress(characters: ["z", "c"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            return run(press.characters == "z" ? .restore : .copy, in: info)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityActions {
            ForEach(info.actions, id: \.self) { action in
                Button(action.accessibilityName) { perform(action) }
            }
        }
        .onAppear(perform: arrive)
        .onChange(of: card.result?.id) { arrive() }
    }

    // MARK: Parts

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        Group {
            if let image = card.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
        }
        .frame(width: Metrics.thumbnail, height: Metrics.thumbnail)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func headline(_ info: CardPresentation) -> some View {
        if info.headlineIsFigure {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.headline)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(color(info.tone))
                    .opacity(deflated ? 1 : 0)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text(ByteSize.format(info.bytesBefore)).foregroundStyle(.secondary)
                    Text("→").foregroundStyle(.tertiary)
                    if reduceMotion {
                        ZStack {
                            Text(ByteSize.format(deflated ? info.bytesAfter : info.bytesBefore))
                                .id(deflated)
                                .transition(.opacity)
                        }
                    } else {
                        CountingBytes(bytes: Double(deflated ? info.bytesAfter : info.bytesBefore))
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.headline)
                    .font(.callout)
                    .foregroundStyle(info.tone == .error ? Color.red : (info.tone == .warm ? Palette.warm : .secondary))
                Text(info.detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(info.tone == .error ? 4 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func actions(_ info: CardPresentation) -> some View {
        HStack(spacing: 6) {
            ForEach(info.actions.filter { $0 != .dismiss }, id: \.self) { action in
                Button(action.title) { perform(action) }
                    .help(action.accessibilityName)
            }
            Spacer(minLength: 0)
            Button {
                perform(.dismiss)
            } label: {
                Image(systemName: CardPresentation.Action.dismiss.symbol)
            }
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Behaviour

    private func showsActions(_ info: CardPresentation) -> Bool {
        card.isHovered || focused || info.tone == .error
    }

    private func run(_ action: CardPresentation.Action, in info: CardPresentation) -> KeyPress.Result {
        guard info.actions.contains(action) else { return .ignored }
        perform(action)
        return .handled
    }

    /// Plays the deflate once, when a result arrives. Reduced motion crossfades instead.
    private func arrive() {
        guard card.result != nil else {
            deflated = card.hasPlayedArrival || !card.isWorking
            return
        }
        if card.hasPlayedArrival {
            deflated = true
            return
        }
        card.hasPlayedArrival = true
        withAnimation(reduceMotion ? Motion.crossfade : Motion.deflate) { deflated = true }
    }

    private var symbol: String {
        switch card.result?.kind ?? MediaKind.of(card.source) {
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        default: return "photo"
        }
    }

    private func color(_ tone: CardPresentation.Tone) -> Color {
        switch tone {
        case .saving: return Palette.accent
        case .warm: return Palette.warm
        case .neutral: return .secondary
        case .error: return .red
        }
    }
}
