// SPDX-License-Identifier: GPL-3.0-or-later
//
// The card's one memorable moment (DESIGN.md): the original size as a full-width bar that
// contracts to the new proportion while the byte figure counts down.

import EsclopIPC
import SwiftUI

struct DeflateBar: View {
    /// 1 is the original size.
    var end: Double
    /// Work done while optimising, drawn in the accent over the full bar.
    var progress: Double?
    var tint: Color
    var filled: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if filled {
                    Capsule().fill(tint).frame(width: max(6, width * end))
                } else {
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: max(6, width * end))
                    if let progress {
                        Capsule().fill(tint).frame(width: max(6, width * progress))
                            .animation(.linear(duration: 0.2), value: progress)
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// A byte count that interpolates while it animates, so the figure counts down with the bar.
struct CountingBytes: View, Animatable {
    var bytes: Double

    nonisolated var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }

    var body: some View {
        Text(ByteSize.format(Int(bytes.rounded())))
    }
}
