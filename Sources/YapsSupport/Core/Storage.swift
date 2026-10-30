import Foundation
import Security

/// Secure storage for the device token.
protocol SecureStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ key: String, value: String) throws
    func delete(_ key: String)
}

/// Keychain-backed store. Items use `kSecAttrAccessibleAfterFirstUnlock` so pushes and background
/// refreshes can read them after the first unlock.
struct KeychainStore: SecureStore {
    var service = "ai.yaps.support"

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func read(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw SupportError(code: SupportError.secureStorageUnavailable, message: "Keychain read failed (\(status))")
        }
    }

    func write(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SupportError(code: SupportError.secureStorageUnavailable, message: "Keychain write failed (\(status))")
        }
    }

    func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// In-memory store for tests and as a fallback.
final class MemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    init() {}

    func read(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func write(_ key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}

/// JSON files under `Application Support/YapsSupport/<appID>/`, excluded from backups.
struct FileStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func `default`(appID: String) -> FileStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safeID = appID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return FileStore(directory: base.appendingPathComponent("YapsSupport", isDirectory: true)
            .appendingPathComponent(safeID.isEmpty ? "default" : safeID, isDirectory: true))
    }

    func prepare() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
        }
        // Exclude the SDK's whole folder (cache, outbox, attachments) from iCloud and iTunes backups.
        var root = directory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        var own = directory
        try? own.setResourceValues(values)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? WireJSON.decoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        prepare()
        guard let data = try? WireJSON.encoder().encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func writeData(_ data: Data, to name: String) throws -> URL {
        prepare()
        let target = url(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return target
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
