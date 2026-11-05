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

    public var title: String { harder ? "Drop to optimise harder" : "Drop to optimise" }

    public var detail: String {
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        return harder ? "\(files) with the aggressive settings" : "\(files). Hold ⌘ for harder"
    }
}
