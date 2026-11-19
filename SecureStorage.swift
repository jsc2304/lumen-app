import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

/// A versioned, authenticated archive. It never falls back to plaintext on an error.
/// The injected root/key/writer keep checks entirely away from the user's archive and Keychain.
final class SecureStorage {
    static let magic = Data("LUM1".utf8)
    static let names: Set<String> = ["clipboard.json", "ai-chats.json", "notes.json"]
    static let marker = ".lumen-store-key"
    static let message = "Lumen could not unlock or save its protected history. Clipboard capture, notes and saved AI chats are paused. Unlock your login keychain, check free disk space, then restart Lumen. If the encryption key was lost, restore the original keychain together with your data backup. Existing files have not been reset."
    enum Failure: Error { case unavailable, invalidFile, unreadable, notLoaded, writeFailed }
    let root: URL
    private let keyProvider: (Bool) throws -> SymmetricKey
    private let writer: (Data, URL) throws -> Void
    private let onFailure: () -> Void
    private let lock = NSRecursiveLock()
    /// The encrypted marker binds legacy import permission to exact bytes, never merely valid JSON.
    /// An empty pending map is a durable completion record: future plaintext is a downgrade, not an import.
    private struct Migration: Codable {
        var version = 2
        var pending: [String: Data]
    }
    private var prepared = false
    private var failed = false
    private var loaded: Set<String> = []

    init(root: URL, key: @escaping (Bool) throws -> SymmetricKey,
         writer: @escaping (Data, URL) throws -> Void = SecureStorage.atomicWrite,
         onFailure: @escaping () -> Void = {}) {
        self.root = root; keyProvider = key; self.writer = writer; self.onFailure = onFailure
    }

    static func protected(_ name: String) -> Bool {
        names.contains(name) || names.contains(String(name.dropLast(4))) && name.hasSuffix(".bak")
            || name.hasPrefix("clipboard/")
    }

    var available: Bool { prepare() }

    @discardableResult
    func prepare() -> Bool {
        perform { _ = try ready(); return true } == true
    }

    /// Includes old backups and orphaned images, not just images referenced by the current index.
    private func archiveFiles() throws -> [String] {
        let fm = FileManager.default
        var found = [String]()
        for name in Self.names.sorted() {
            for candidate in [name, name + ".bak"] where fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                found.append(candidate)
            }
        }
        let images = root.appendingPathComponent("clipboard")
        if fm.fileExists(atPath: images.path) {
            guard try images.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true else { throw Failure.invalidFile }
            for file in try fm.contentsOfDirectory(at: images, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw Failure.invalidFile }
                // A process crash can leave our ciphertext-only sibling behind. It is not an archive entry.
                if values.isRegularFile == true, !file.lastPathComponent.hasPrefix(".lumen-encrypt-") {
                    found.append("clipboard/" + file.lastPathComponent)
                }
            }
        }
        return found.sorted()
    }

    private func checkedURL(_ name: String) throws -> URL {
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
              Self.protected(name) || name == Self.marker else { throw Failure.invalidFile }
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path),
           try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.invalidFile }
        return url
    }

    private func read(_ name: String) throws -> Data { try Data(contentsOf: checkedURL(name)) }
    private func open(_ data: Data, _ name: String, _ key: SymmetricKey) throws -> Data {
        guard data.starts(with: Self.magic) else { throw Failure.invalidFile }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count)), using: key,
                                authenticating: Data(name.utf8))
    }

    private func sealed(_ data: Data, _ name: String, _ key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(name.utf8)).combined else { throw Failure.invalidFile }
        return Self.magic + combined
    }

    /// Ciphertext is read back and authenticated from a private sibling before atomically replacing an original.
    private func write(_ data: Data, _ name: String, _ key: SymmetricKey) throws {
        let target = try checkedURL(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = target.deletingLastPathComponent().appendingPathComponent(".lumen-encrypt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try writer(try sealed(data, name, key), temp)
        guard try open(Data(contentsOf: temp), name, key) == data else { throw Failure.writeFailed }
        guard Darwin.rename(temp.path, target.path) == 0 else { throw Failure.writeFailed }
    }

    static func atomicWrite(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func migration(_ key: SymmetricKey) throws -> Migration {
        let state = try JSONDecoder().decode(Migration.self, from: open(read(Self.marker), Self.marker, key))
        guard state.version == 2, state.pending.keys.allSatisfy(Self.protected) else { throw Failure.invalidFile }
        return state
    }

    /// No in-memory key cache: a keychain that becomes locked must stop new disk access too.
    private func ready() throws -> SymmetricKey {
        let fm = FileManager.default
        let markerURL = root.appendingPathComponent(Self.marker)
        if prepared {
            let key = try keyProvider(false)
            guard try migration(key).pending.isEmpty else { throw Failure.unavailable }
            return key
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try archiveFiles()
        var hasCiphertext = false
        for name in files {
            if try read(name).starts(with: Self.magic) { hasCiphertext = true }
        }
        let hasMarker = fm.fileExists(atPath: markerURL.path)
        let key = try keyProvider(!hasMarker && !hasCiphertext)
        var state: Migration
        if hasMarker {
            state = try migration(key)
        } else {
            var pending = [String: Data]()
            for name in files {
                let data = try read(name)
                if data.starts(with: Self.magic) { _ = try open(data, name, key) }
                else {
                    // Mixed ciphertext/plaintext without a manifest has no trustworthy import history.
                    guard !hasCiphertext else { throw Failure.invalidFile }
                    if Self.names.contains(name) { _ = try JSONSerialization.jsonObject(with: data) }
                    pending[name] = Data(SHA256.hash(data: data))
                }
            }
            state = Migration(pending: pending)
            // Record exact import permissions before replacing even the first legacy file.
            try write(JSONEncoder().encode(state), Self.marker, key)
        }
        guard Set(state.pending.keys).isSubset(of: Set(files)) else { throw Failure.invalidFile }
        // Validate the entire archive before resuming any interrupted writes. Completed imports never
        // accept plaintext, and pending imports accept only the bytes authenticated in their manifest.
        for name in files {
            let data = try read(name)
            if data.starts(with: Self.magic) {
                let clear = try open(data, name, key)
                if let digest = state.pending[name], Data(SHA256.hash(data: clear)) != digest { throw Failure.invalidFile }
            } else {
                guard let digest = state.pending[name], Data(SHA256.hash(data: data)) == digest else { throw Failure.invalidFile }
                if Self.names.contains(name) { _ = try JSONSerialization.jsonObject(with: data) }
            }
        }
        for name in files where state.pending[name] != nil {
            let data = try read(name)
            guard let digest = state.pending[name] else { throw Failure.invalidFile }
            // Recheck the exact snapshot used for conversion, not only the earlier validation pass.
            if data.starts(with: Self.magic) {
                guard Data(SHA256.hash(data: try open(data, name, key))) == digest else { throw Failure.invalidFile }
            } else {
                guard Data(SHA256.hash(data: data)) == digest else { throw Failure.invalidFile }
                try write(data, name, key)
            }
            state.pending.removeValue(forKey: name)
            // Crash after conversion but before this checkpoint: resume authenticates the converted
            // bytes against the original digest, then records completion without re-importing them.
            try write(JSONEncoder().encode(state), Self.marker, key)
        }
        prepared = true
        return key
    }

    private func perform<T>(_ work: () throws -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return nil }
        do { return try work() }
        catch {
            failed = true
            onFailure() // sanitized, once per session; never log user contents or keys
            return nil
        }
    }

    func load<T: Decodable>(_ name: String) -> T? {
        perform {
            let key = try ready()
            let url = try checkedURL(name)
            guard FileManager.default.fileExists(atPath: url.path) else { loaded.insert(name); return nil }
            let value = try JSONDecoder().decode(T.self, from: open(read(name), name, key))
            loaded.insert(name)
            return value
        } ?? nil
    }

    @discardableResult
    func save<T: Encodable>(_ value: T, _ name: String) -> Bool {
        perform {
            let key = try ready()
            if FileManager.default.fileExists(atPath: try checkedURL(name).path) {
                guard loaded.contains(name) else { throw Failure.notLoaded }
                // A changed or damaged file after the initial load must not be silently overwritten either.
                _ = try open(read(name), name, key)
            }
            try write(JSONEncoder().encode(value), name, key)
            loaded.insert(name)
            return true
        } == true
    }

    func loadBlob(_ name: String) -> Data? {
        perform { let key = try ready(); return try open(read(name), name, key) }
    }

    @discardableResult
    func saveBlob(_ data: Data, _ name: String) -> Bool {
        perform {
            let key = try ready()
            // Images have immutable UUID names. Never replace an existing image through capture.
            guard !FileManager.default.fileExists(atPath: try checkedURL(name).path) else { throw Failure.writeFailed }
            try write(data, name, key)
            return true
        } == true
    }
}

/// Separate from API-key helpers: do not delete/recreate the encryption key on lookup failures.
enum ArchiveKeychain {
    private static var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jan.lumen", kSecAttrAccount as String: "store-key",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: false,
         kSecUseAuthenticationContext as String: context]
    }
    static func key(allowCreate: Bool) throws -> SymmetricKey {
        // Lumen uses a self-signed native app, not an entitled Data Protection keychain app.
        // Accessibility attributes are not enforced by the classic macOS keychain. Check
        // its real lock state, then pin both lookup and insertion to that same keychain.
        var selected: SecKeychain?
        guard SecKeychainCopyDefault(&selected) == errSecSuccess, let keychain = selected else {
            throw SecureStorage.Failure.unavailable
        }
        var state: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &state) == errSecSuccess,
              state & SecKeychainStatus(kSecUnlockStateStatus) != 0 else { throw SecureStorage.Failure.unavailable }
        var q = query
        q[kSecMatchSearchList as String] = [keychain]
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else { throw SecureStorage.Failure.unavailable }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound, allowCreate else { throw SecureStorage.Failure.unavailable }
        let newKey = SymmetricKey(size: .bits256)
        var add = query
        add[kSecUseAuthenticationContext as String] = nil
        add[kSecUseKeychain as String] = keychain
        add[kSecValueData as String] = newKey.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key(allowCreate: false) }
        guard added == errSecSuccess else { throw SecureStorage.Failure.unavailable }
        return newKey
    }
}
