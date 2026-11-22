// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin wrappers over CFMessagePort. Local ports deliver on a private serial dispatch queue, so
// neither side needs a run loop and messages arrive in the order they were sent.

import CoreFoundation
import EsclopCore
import Foundation
import os

/// Every CFMessagePort call in this file that creates, closes or frees a port runs under this
/// lock. Sending does not: a send may wait for its timeout.
///
/// CoreFoundation is not safe across threads here. A lookup of a name this process listens on
/// shares the listener's Mach port object; when the listener closes during such a lookup, the
/// object and its receive right are never freed, so the name stays registered for good and
/// `isListening` says yes after the listener has gone (HC-45: about one close in four under four
/// polling threads). Two threads looking up one name can also free a cached remote port twice,
/// which crashes.
/// ponytail: one lock for every name serialises the launchd lookups; split it by name if they
/// ever queue behind each other.
private let portLifetimes = NSLock()

/// A named port this process listens on.
/// Sendable by hand: `port` is behind `lock`; the rest is immutable.
public final class LocalMessagePort: @unchecked Sendable {
    public let name: String
    fileprivate let onMessage: @Sendable (Data) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Retained by hand so that the last release happens under `portLifetimes`.
    private var port: Unmanaged<CFMessagePort>?

    /// Names this process listens on. CoreFoundation hands back the existing port for a name
    /// already taken in the same process, so a second owner is refused here.
    private static let queueKey = DispatchSpecificKey<String>()
    private static let owned = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Throws `.other` when this or another process already owns the name.
    public init(name: String, onMessage: @escaping @Sendable (Data) -> Void) throws {
        self.name = name
        self.onMessage = onMessage
        self.queue = DispatchQueue(label: "esclop.port.\(name)")
        queue.setSpecific(key: Self.queueKey, value: name)

        let fresh = Self.owned.withLock { $0.insert(name).inserted }
        guard fresh else { throw EsclopError.other("The message port \(name) is already in use in this process") }

        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        var shouldFree: DarwinBoolean = false
        let queue = queue
        let created = portLifetimes.withLock { () -> Unmanaged<CFMessagePort>? in
            guard let port = CFMessagePortCreateLocal(nil, name as CFString, localPortCallback, &context, &shouldFree) else { return nil }
            CFMessagePortSetDispatchQueue(port, queue)
            return Unmanaged.passRetained(port)
        }
        guard let created else {
            Self.release(name)
            throw EsclopError.other("The message port \(name) is already in use by another process")
        }
        port = created
    }

    public func invalidate() {
        lock.lock()
        let current = port
        port = nil
        lock.unlock()
        guard let current else { return }
        // Invalidate without unscheduling first: unscheduling leaves the name registered, and
        // clients would keep seeing a live port nobody reads.
        portLifetimes.withLock { CFMessagePortInvalidate(current.takeUnretainedValue()) }
        // Let a callback already running finish before this object can go away (the port holds an
        // unretained pointer to it). Skipped when invalidating from that callback itself.
        if DispatchQueue.getSpecific(key: Self.queueKey) != name { queue.sync {} }
        // ponytail: frees still outside the lock: CoreFoundation releases the Mach port itself a
        // moment later on a queue of its own; a callback still running (invalidated from inside
        // it, or a message that arrived during invalidate) holds the last reference; an
        // in-process `send` to this name keeps a remote sharing the Mach port until it returns.
        // None was seen to leak (0 stuck in 3000 closes); lock the send too if one ever does.
        portLifetimes.withLock { current.release() }
        Self.release(name)
    }

    private static func release(_ name: String) {
        _ = owned.withLock { $0.remove(name) }
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
        portLifetimes.withLock {
            guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
            return CFMessagePortIsValid(remote)
        }
    }

    /// One-way send. Throws `.appNotRunning` when nobody listens on `name`.
    ///
    /// Remote ports are cached per name by CoreFoundation and shared inside the process, so they
    /// are never invalidated here: that would break a concurrent sender holding the same object.
    public static func send(_ data: Data, to name: String, timeout: TimeInterval = 5) throws {
        let remote = portLifetimes.withLock { () -> Unmanaged<CFMessagePort>? in
            guard let remote = CFMessagePortCreateRemote(nil, name as CFString), CFMessagePortIsValid(remote) else { return nil }
            return Unmanaged.passRetained(remote)
        }
        guard let remote else { throw EsclopError.appNotRunning }
        // Sent outside the lock: a send may wait up to `timeout`.
        defer { portLifetimes.withLock { remote.release() } }
        let status = CFMessagePortSendRequest(remote.takeUnretainedValue(), IPCProtocol.messageID, data as CFData, timeout, 0, nil, nil)
        switch status {
        case kCFMessagePortSuccess: return
        case kCFMessagePortIsInvalid: throw EsclopError.appNotRunning
        case kCFMessagePortSendTimeout: throw EsclopError.other("The L'Esclop app did not take the message within \(Int(timeout)) s")
        default: throw EsclopError.other("Sending to \(name) failed (CFMessagePort status \(status))")
        }
    }
}
