// SPDX-License-Identifier: GPL-3.0-or-later
//
// Switches with a title and a line under it. SwiftUI hands such a toggle to accessibility as its
// last text, so VoiceOver read the explanation ("Files that do not match are left alone.")
// instead of the name ("Only some files"). Every such switch names itself here: the title is
// the label, the line under it the hint.

import SwiftUI

struct TitledToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text(subtitle)
        }
        .switchLabel(title: title, hint: subtitle)
    }
}

extension View {
    /// A switch's accessibility name and hint, for a toggle whose label is more than its title.
    func switchLabel(title: String, hint: String?) -> some View {
        accessibilityLabel(title).accessibilityHint(hint ?? "")
    }
}
