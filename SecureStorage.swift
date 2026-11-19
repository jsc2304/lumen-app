import Foundation
import CryptoKit
import Security
import Darwin

/// A versioned, authenticated archive. It never falls back to plaintext on an error.
/// The injected root/key/writer keep checks entirely away from the user's archive and Keychain.
final class SecureStorage {
    static let magic = Data("LUM1".utf8)
    static let names: Set<String> = ["clipboard.json", "ai-chats.json", "notes.json"]
    static let marker = ".lumen-store-key"
    static let message = "Lumen could not unlock or save its protected history. Clipboard capture, notes and saved AI chats are paused. Unlock the default Keychain or check free disk space. If the problem continues, restart Lumen. If the encryption key was lost, restore the original Keychain together with your data backup. Existing files have not been reset."
    enum Failure: Error {
        case unavailable, keyInteractionRequired, invalidFile, notLoaded, staleRevision, writeFailed
    }
    let root: URL
    private let keyProvider: (Bool) throws -> SymmetricKey
    private let interactiveLookup: () -> Void
    private let writer: (Data, URL) throws -> Void
    private let onFailure: () -> Void
    private let lock = NSRecursiveLock()
    /// The encrypted marker binds legacy import permission to exact bytes, never merely valid JSON.
    /// An empty pending map is a durable completion record: future plaintext is a downgrade, not an import.
    private struct Migration: Codable {
        var version = 2
        var pending: [String: Data]
    }
    private enum Revision: Equatable {
        case missing
        case encrypted(SHA256.Digest)
    }
    private var prepared = false
    private var failed = false
    private var reportedFailure = false
    private var loaded: [String: Revision] = [:]

    init(root: URL, key: @escaping (Bool) throws -> SymmetricKey,
         interactiveLookup: @escaping () -> Void = {},
         writer: @escaping (Data, URL) throws -> Void = SecureStorage.atomicWrite,
         onFailure: @escaping () -> Void = {}) {
        self.root = root
        keyProvider = key
        self.interactiveLookup = interactiveLookup
        self.writer = writer
        self.onFailure = onFailure
    }

    static func protected(_ name: String) -> Bool {
        names.contains(name) || names.contains(String(name.dropLast(4))) && name.hasSuffix(".bak")
            || name.hasPrefix("clipboard/")
    }

    var available: Bool { prepare() }

    @discardableResult
    func prepare(interactive: Bool = false) -> Bool {
        // A Keychain prompt can wait for the user, so run it before taking the archive lock.
        if interactive, Thread.isMainThread { interactiveLookup() }
        return perform { _ = try ready(); return true } == true
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

    private func readIfPresent(_ name: String) throws -> Data? {
        do { return try read(name) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

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
    @discardableResult
    private func write(_ data: Data, _ name: String, _ key: SymmetricKey) throws -> SHA256.Digest {
        let target = try checkedURL(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = target.deletingLastPathComponent().appendingPathComponent(".lumen-encrypt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try writer(try sealed(data, name, key), temp)
        let verified = try Data(contentsOf: temp)
        guard try open(verified, name, key) == data else { throw Failure.writeFailed }
        guard Darwin.rename(temp.path, target.path) == 0 else { throw Failure.writeFailed }
        return SHA256.hash(data: verified)
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

    private func withArchiveLock<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Keep this inode in place. All cooperating Lumen processes serialize through it.
        let url = root.appendingPathComponent(".lumen-store-lock")
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidFile }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure.unavailable }
        }
        return try work()
    }

    private func perform<T>(_ work: () throws -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return nil }
        do {
            let result = try withArchiveLock(work)
            reportedFailure = false
            return result
        }
        catch Failure.keyInteractionRequired {
            reportFailure()
            return nil
        }
        catch {
            failed = true
            reportFailure()
            return nil
        }
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        onFailure()
    }

    func load<T: Decodable>(_ name: String) -> T? {
        perform {
            let key = try ready()
            guard let data = try readIfPresent(name) else { loaded[name] = .missing; return nil }
            let value = try JSONDecoder().decode(T.self, from: open(data, name, key))
            loaded[name] = .encrypted(SHA256.hash(data: data))
            return value
        } ?? nil
    }

    @discardableResult
    func save<T: Encodable>(_ value: T, _ name: String) -> Bool {
        perform {
            let key = try ready()
            guard let expected = loaded[name] else { throw Failure.notLoaded }
            let current: Revision = try readIfPresent(name).map { .encrypted(SHA256.hash(data: $0)) } ?? .missing
            guard current == expected else { throw Failure.staleRevision }
            loaded[name] = .encrypted(try write(JSONEncoder().encode(value), name, key))
            return true
        } == true
    }

    func loadBlob(_ name: String) -> Data? {
        perform {
            let key = try ready()
            guard let data = try readIfPresent(name) else { return nil }
            return try open(data, name, key)
        } ?? nil
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
    private static let interactionLock = NSLock()
    private static let query: [String: Any] = [
         kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jan.lumen", kSecAttrAccount as String: "store-key",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: false]

    static func key(allowCreate: Bool) throws -> SymmetricKey {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        // SecItem's per-query UI setting applies to the Data Protection Keychain only.
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw SecureStorage.Failure.keyInteractionRequired
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try lookup(allowCreate: allowCreate, interactive: false)
    }

    static func interactiveLookup() {
        guard Thread.isMainThread else { return }
        interactionLock.lock()
        defer { interactionLock.unlock() }
        // The noninteractive archive operation independently verifies access and never uses this key.
        _ = try? lookup(allowCreate: false, interactive: true)
    }

    private static func lookup(allowCreate: Bool, interactive: Bool) throws -> SymmetricKey {
        // Lumen uses a self-signed native app, not an entitled Data Protection keychain app.
        // Accessibility attributes are not enforced by the classic macOS keychain. Check
        // its real lock state, then pin both lookup and insertion to that same keychain.
        var selected: SecKeychain?
        guard SecKeychainCopyDefault(&selected) == errSecSuccess, let keychain = selected else {
            throw SecureStorage.Failure.unavailable
        }
        var state: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &state) == errSecSuccess else {
            throw SecureStorage.Failure.unavailable
        }
        if !interactive, state & SecKeychainStatus(kSecUnlockStateStatus) == 0 {
            throw SecureStorage.Failure.keyInteractionRequired
        }
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
        guard status == errSecItemNotFound, allowCreate else { throw failure(for: status) }
        let newKey = SymmetricKey(size: .bits256)
        var add = query
        add[kSecUseKeychain as String] = keychain
        add[kSecValueData as String] = newKey.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem { return try lookup(allowCreate: false, interactive: interactive) }
        guard added == errSecSuccess else { throw failure(for: added) }
        return newKey
    }

    private static func failure(for status: OSStatus) -> SecureStorage.Failure {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
            return .keyInteractionRequired
        default:
            return .unavailable
        }
    }
}
