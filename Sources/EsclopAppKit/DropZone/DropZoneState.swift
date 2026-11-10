// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// What the drop zone shows while a drag is under way.
@MainActor @Observable
public final class DropZoneState {
    /// Files of a kind L'Esclop optimises in the drag.
    public var fileCount: Int
    /// The drag is over the zone.
    public var hovering: Bool
    /// Command is held: drop to optimise harder.
    public var harder: Bool

    public init(fileCount: Int = 0, hovering: Bool = false, harder: Bool = false) {
        self.fileCount = fileCount
        self.hovering = hovering
        self.harder = harder
    }

    public var title: String { harder ? Strings.text("Drop to optimise harder") : Strings.text("Drop to optimise") }

    public var detail: String {
        switch (fileCount == 1, harder) {
        case (true, true): return Strings.text("1 file with the aggressive settings")
        case (true, false): return Strings.text("1 file. Hold ⌘ for harder")
        case (false, true): return Strings.format("%d files with the aggressive settings", fileCount)
        case (false, false): return Strings.format("%d files. Hold ⌘ for harder", fileCount)
        }
    }

}
