// SPDX-License-Identifier: GPL-3.0-or-later
//
// The keys of an upload target. They live in the login Keychain, one item per target (service
// `dev.esclop.upload`, account the target's name), and nowhere else: not in the settings file,
// the logs, `esclop settings`, MCP replies or crash reports. Only the app reads them; the command
// line and the MCP server send their uploads to it.

import EsclopCore
import Foundation
import Security

public struct UploadCredentials: Codable, Equatable, Sendable {
    public var accessKeyID: String
    public var secret: String

    public init(accessKeyID: String, secret: String) {
        self.accessKeyID = accessKeyID
        self.secret = secret
    }
}

/// Where the keys are kept: the Keychain in the app, memory in tests.
public protocol UploadCredentialStore: Sendable {
    func credentials(for target: String) throws -> UploadCredentials?
    func save(_ credentials: UploadCredentials, for target: String) throws
    func remove(for target: String) throws
}

public struct KeychainCredentialStore: UploadCredentialStore {
    public let service: String

    public init(service: String = "dev.esclop.upload") {
        self.service = service
    }

    private func query(_ target: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: target]
    }

    public func credentials(for target: String) throws -> UploadCredentials? {
        var query = query(target)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error(status) }
        guard let keys = try? JSONDecoder().decode(UploadCredentials.self, from: data) else {
            // Not "no keys": the person should know the saved ones are there but unreadable.
            throw EsclopError.other(Strings.format("The keys saved for “%@” in the Keychain cannot be read. Enter them again in Settings › Uploads.", target))
        }
        return keys
    }

    public func save(_ credentials: UploadCredentials, for target: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = SecItemUpdate(query(target) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.error(update) }
        var add = query(target)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "L'Esclop upload: \(target)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    public func remove(for target: String) throws {
        let status = SecItemDelete(query(target) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    /// The Keychain's own words for the failure; never the keys.
    static func error(_ status: OSStatus) -> EsclopError {
        let words = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return .other(Strings.format("The Keychain refused: %@", words))
    }
}

/// Keys in memory, for tests and previews.
public final class MemoryCredentialStore: UploadCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: UploadCredentials] = [:]

    public init(_ items: [String: UploadCredentials] = [:]) {
        self.items = items
    }

    public func credentials(for target: String) throws -> UploadCredentials? { lock.withLock { items[target] } }
    public func save(_ credentials: UploadCredentials, for target: String) throws { lock.withLock { items[target] = credentials } }
    public func remove(for target: String) throws { _ = lock.withLock { items.removeValue(forKey: target) } }
}
