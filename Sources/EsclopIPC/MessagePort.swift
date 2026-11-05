// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin wrappers over CFMessagePort. Local ports deliver on a private serial dispatch queue, so
// neither side needs a run loop and messages arrive in the order they were sent.

import CoreFoundation
import EsclopCore
import Foundation

/// A named port this process listens on.
public final class LocalMessagePort: @unchecked Sendable {
    public let name: String
    fileprivate let onMessage: @Sendable (Data) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var port: CFMessagePort?

    /// Names this process listens on. CoreFoundation hands back the existing port for a name
    /// already taken in the same process, so a second owner is refused here.
    private static let queueKey = DispatchSpecificKey<String>()
    private static let ownedLock = NSLock()
    private static var owned = Set<String>()

    /// Throws `.other` when this or another process already owns the name.
    public init(name: String, onMessage: @escaping @Sendable (Data) -> Void) throws {
        self.name = name
        self.onMessage = onMessage
        self.queue = DispatchQueue(label: "esclop.port.\(name)")
        queue.setSpecific(key: Self.queueKey, value: name)

        Self.ownedLock.lock()
        let fresh = Self.owned.insert(name).inserted
        Self.ownedLock.unlock()
        guard fresh else { throw EsclopError.other("The message port \(name) is already in use in this process") }

        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        var shouldFree: DarwinBoolean = false
        guard let created = CFMessagePortCreateLocal(nil, name as CFString, localPortCallback, &context, &shouldFree) else {
            Self.release(name)
            throw EsclopError.other("The message port \(name) is already in use by another process")
        }
        CFMessagePortSetDispatchQueue(created, queue)
        port = created
    }

    public var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return port.map(CFMessagePortIsValid) ?? false
    }

    public func invalidate() {
        lock.lock()
        let current = port
        port = nil
        lock.unlock()
        guard let current else { return }
        // Invalidate without unscheduling first: unscheduling leaves the name registered, and
        // clients would keep seeing a live port nobody reads.
        CFMessagePortInvalidate(current)
        // Let a callback already running finish before this object can go away (the port holds an
        // unretained pointer to it). Skipped when invalidating from that callback itself.
        if DispatchQueue.getSpecific(key: Self.queueKey) != name { queue.sync {} }
        Self.release(name)
    }

    private static func release(_ name: String) {
        ownedLock.lock()
        owned.remove(name)
        ownedLock.unlock()
    }

    deinit { invalidate() }
}

private func localPortCallback(
    _: CFMessagePort?, _: Int32, _ data: CFData?, _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CFData>? {
    guard let info else { return nil }
    let receiver = Unmanaged<LocalMessagePort>.fromOpaque(info).takeUnretainedValue()
    receiver.onMessage(data.map { $0 as Data } ?? Data())
    return nil
}

/// Sending to a port another process (or this one) listens on.
public enum RemoteMessagePort {
    public static func isListening(_ name: String) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        return CFMessagePortIsValid(remote)
    }

    /// One-way send. Throws `.appNotRunning` when nobody listens on `name`.
    ///
    /// Remote ports are cached per name by CoreFoundation and shared inside the process, so they
    /// are never invalidated here: that would break a concurrent sender holding the same object.
    public static func send(_ data: Data, to name: String, timeout: TimeInterval = 5) throws {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString), CFMessagePortIsValid(remote) else {
            throw EsclopError.appNotRunning
        }
        let status = CFMessagePortSendRequest(remote, IPCProtocol.messageID, data as CFData, timeout, 0, nil, nil)
        switch status {
        case kCFMessagePortSuccess: return
        case kCFMessagePortIsInvalid: throw EsclopError.appNotRunning
        case kCFMessagePortSendTimeout: throw EsclopError.other("The L'Esclop app did not take the message within \(Int(timeout)) s")
        default: throw EsclopError.other("Sending to \(name) failed (CFMessagePort status \(status))")
        }
    }
}
