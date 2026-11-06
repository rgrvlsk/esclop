// SPDX-License-Identifier: GPL-3.0-or-later
//
// The detail's deflate bar (DESIGN.md): the original size as a full-width bar that contracts to
// the new proportion when the detail opens.

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
