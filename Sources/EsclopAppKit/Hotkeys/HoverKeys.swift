// SPDX-License-Identifier: GPL-3.0-or-later
//
// The card keys while the pointer rests on a card: Carbon hotkeys, held only while it rests
// there, so the keys reach the card with no click, no permission and the app in front keeping
// its window (DESIGN.md › Keys). Clop holds its hover keys the same way; a key monitor would
// need Accessibility and could not keep the key from the app in front.

import AppKit
import Carbon.HIToolbox

@MainActor
final class HoverKeys {
    static let shared = HoverKeys()
    /// How long the pointer rests before the keys are the card's, so a pass on the way
    /// elsewhere takes none (Clop waits as long).
    static let rest: Duration = .milliseconds(200)
    /// "Escl": tells these hotkeys from KeyboardShortcuts' own on the same dispatcher.
    nonisolated static let signature: OSType = 0x4573_636C

    /// The card holding the keys.
    private(set) var owner: UUID?
    private var held: [(ref: EventHotKeyRef, key: Character)] = []
    private var press: ((Character) -> Void)?
    private var handlerInstalled = false

    /// The keys `owner` holds now.
    var keys: [Character] { held.map(\.key) }

    /// `owner` takes `keys` until it gives them back; another card's keys go first. A key that
    /// another app already holds, or that the keyboard layout has no plain key for, is skipped.
    func hold(_ keys: [Character], for owner: UUID, press: @escaping (Character) -> Void) {
        release()
        installHandler()
        let codes = Self.keyCodes()
        for key in keys {
            guard let code = codes[key] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(held.count))
            if RegisterEventHotKey(code, 0, id, GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                held.append((ref, key))
            }
        }
        self.owner = owner
        self.press = press
    }

    /// Gives the keys back, if `owner` still holds them.
    func release(from owner: UUID) {
        if self.owner == owner { release() }
    }

    private func release() {
        for entry in held { UnregisterEventHotKey(entry.ref) }
        held = []
        owner = nil
        press = nil
    }

    fileprivate func fire(_ id: UInt32) {
        guard held.indices.contains(Int(id)) else { return }
        press?(held[Int(id)].key)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerInstalled = InstallEventHandler(GetEventDispatcherTarget(), hoverKeyPressed, 1, &spec, nil, nil) == noErr
    }

    /// The plain key that types each character in the current layout (on AZERTY the digits need
    /// Shift, so they are not held there). Space and Backspace are the same key everywhere.
    static func keyCodes() -> [Character: UInt32] {
        var codes: [Character: UInt32] = [" ": UInt32(kVK_Space), CardKeys.delete: UInt32(kVK_Delete)]
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return codes }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars
                )
                guard status == noErr, length == 1, let character = String(utf16CodeUnits: chars, count: 1).first,
                      CardKeys.all.contains(character), codes[character] == nil
                else { continue }
                codes[character] = UInt32(code)
            }
        }
        return codes
    }
}

/// Carbon calls it on the main thread for every hotkey on the dispatcher; it takes only its own.
private func hoverKeyPressed(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr, id.signature == HoverKeys.signature else { return OSStatus(eventNotHandledErr) }
    MainActor.assumeIsolated { HoverKeys.shared.fire(id.id) }
    return noErr
}
