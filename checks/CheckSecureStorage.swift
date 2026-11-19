import Foundation
import CryptoKit

func checkSecureStorage() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("Lumen-secure-check-" + UUID().uuidString)
    try! fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let key = SymmetricKey(size: .bits256)
    func store(_ suffix: String, keyProvider: ((Bool) throws -> SymmetricKey)? = nil,
               writer: @escaping (Data, URL) throws -> Void = SecureStorage.atomicWrite,
               onFailure: @escaping () -> Void = {}) -> SecureStorage {
        SecureStorage(root: base.appendingPathComponent(suffix), key: keyProvider ?? { _ in key }, writer: writer, onFailure: onFailure)
    }
    func bytes(_ storage: SecureStorage, _ name: String) -> Data { try! Data(contentsOf: storage.root.appendingPathComponent(name)) }
    func legacy(_ storage: SecureStorage, _ name: String, _ data: Data) {
        let url = storage.root.appendingPathComponent(name)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }
    let s = store("roundtrip")
    let plaintext = Data(#"["private note"]"#.utf8)
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array("private screenshot".utf8))
    for name in SecureStorage.names {
        legacy(s, name, plaintext)
        legacy(s, name + ".bak", plaintext)
    }
    legacy(s, "clipboard/orphan.png", png)
    legacy(s, "clipboard/old.png.bak", png)
    expect(s.prepare(), "legacy archive migrates")
    for name in SecureStorage.names {
        expect(bytes(s, name).starts(with: SecureStorage.magic) && !bytes(s, name).contains(plaintext), "primary JSON encrypted")
        expect(bytes(s, name + ".bak").starts(with: SecureStorage.magic), "legacy backups encrypted too")
        let values: [String]? = s.load(name)
        expect(values == ["private note"], "legacy JSON round trips")
    }
    expect(s.loadBlob("clipboard/orphan.png") == png && s.loadBlob("clipboard/old.png.bak") == png, "orphan and backup images migrated")
    expect(s.save(["changed"], "notes.json"), "save after load succeeds")
    let first = bytes(s, "notes.json")
    expect(s.save(["changed"], "notes.json") && bytes(s, "notes.json") != first, "random nonce changes ciphertext for equal values")
    expect(s.saveBlob(png, "clipboard/new.png") && s.loadBlob("clipboard/new.png") == png, "new image encrypted and loaded")
    expect(s.loadBlob("clipboard/missing.png") == nil && s.available, "missing legacy image does not pause protected storage")
    var createAllowed = [Bool]()
    let reopened = store("roundtrip", keyProvider: { allowed in createAllowed.append(allowed); return key })
    let restored: [String]? = reopened.load("notes.json")
    expect(restored == ["changed"] && createAllowed.allSatisfy { !$0 }, "restart reopens original key without creation")

    let changed = bytes(s, "notes.json")
    let wrong = store("roundtrip", keyProvider: { _ in SymmetricKey(size: .bits256) })
    let unreadable: [String]? = wrong.load("notes.json")
    expect(unreadable == nil && !wrong.save([String](), "notes.json") && bytes(s, "notes.json") == changed, "wrong key never overwrites ciphertext")
    var notifications = 0
    var attemptedCreate = false
    let missing = store("roundtrip", keyProvider: { allowed in attemptedCreate = attemptedCreate || allowed; throw SecureStorage.Failure.unavailable },
                        onFailure: { notifications += 1 })
    expect(!missing.prepare() && !missing.save([String](), "notes.json") && !attemptedCreate && notifications == 1,
           "missing or locked key blocks, does not regenerate, reports once")
    expect(bytes(s, "notes.json") == changed, "missing key retains originals")

    // If history was removed externally, the durable marker still forbids key regeneration.
    let markerOnly = store("marker-only")
    expect(markerOnly.prepare(), "fresh marker created")
    var markerCreate = false
    let markerMissing = store("marker-only", keyProvider: { allowed in markerCreate = allowed; throw SecureStorage.Failure.unavailable })
    expect(!markerMissing.prepare() && !markerCreate, "marker alone forbids regenerating a lost key")
    // Ciphertext without a marker (e.g. interrupted/older archive) also forbids creation.
    let orphanCipher = store("orphan-cipher")
    legacy(orphanCipher, "clipboard/orphan.png", bytes(s, "clipboard/orphan.png"))
    var orphanCreate = false
    let orphanMissing = store("orphan-cipher", keyProvider: { allowed in orphanCreate = allowed; throw SecureStorage.Failure.unavailable })
    expect(!orphanMissing.prepare() && !orphanCreate, "orphan ciphertext alone forbids key creation")

    let tampered = store("tampered")
    expect(tampered.prepare(), "tamper fixture initialized")
    var altered = changed
    altered[altered.count - 1] ^= 1
    legacy(tampered, "notes.json", altered)
    let tamperRead: [String]? = tampered.load("notes.json")
    expect(tamperRead == nil && !tampered.save([String](), "notes.json") && bytes(tampered, "notes.json") == altered,
           "tampered file stays byte-for-byte intact, subsequent save blocked")
    let swapped = store("swapped")
    legacy(swapped, "clipboard.json", changed)
    expect(!swapped.prepare(), "authenticated file name rejects ciphertext swapping")

    let malformed = store("malformed")
    let broken = Data("not valid JSON".utf8)
    legacy(malformed, "notes.json", broken)
    let malformedRead: [String]? = malformed.load("notes.json")
    expect(malformedRead == nil && !malformed.save([String](), "notes.json") && bytes(malformed, "notes.json") == broken,
           "damaged legacy JSON is retained unchanged")
    let invalidShape = store("shape")
    legacy(invalidShape, "notes.json", Data("{}".utf8))
    let invalidRead: [String]? = invalidShape.load("notes.json")
    let invalidCipher = bytes(invalidShape, "notes.json")
    expect(invalidRead == nil && !invalidShape.save([String](), "notes.json") && bytes(invalidShape, "notes.json") == invalidCipher,
           "typed decode failure blocks empty-default writes")

    var writes = 0
    let interrupted = store("interrupted", writer: { data, url in
        writes += 1
        if writes > 1 { throw SecureStorage.Failure.writeFailed }
        try SecureStorage.atomicWrite(data, url)
    })
    legacy(interrupted, "notes.json", plaintext)
    expect(!interrupted.prepare() && bytes(interrupted, "notes.json") == plaintext, "failed migration write retains original plaintext")
    let resumed = store("interrupted")
    let resumedRead: [String]? = resumed.load("notes.json")
    expect(resumedRead == ["private note"], "restart completes an interrupted migration with the same key")
    // A completed migration must never reinterpret a substituted plaintext file as legacy input.
    for (i, name) in ["notes.json", "clipboard.json", "ai-chats.json", "notes.json.bak", "clipboard/image.png"].enumerated() {
        let suffix = "downgrade-" + String(i)
        let migrated = store(suffix)
        legacy(migrated, name, name.hasPrefix("clipboard/") ? png : plaintext)
        expect(migrated.prepare(), "downgrade fixture completes migration")
        let substitution = name.hasPrefix("clipboard/") ? png + Data("injected".utf8) : Data(#"["injected"]"#.utf8)
        legacy(migrated, name, substitution)
        let restarted = store(suffix)
        expect(!restarted.prepare() && bytes(restarted, name) == substitution
               && !restarted.save([String](), "notes.json"),
               "restart rejects and preserves substituted plaintext JSON, backup or image")
    }
    let addedImage = store("added-plaintext-image")
    expect(addedImage.prepare(), "empty migration is durably complete")
    legacy(addedImage, "clipboard/unexpected.png", png)
    expect(!store("added-plaintext-image").prepare() && bytes(addedImage, "clipboard/unexpected.png") == png,
           "a later plaintext orphan is not silently imported into a completed archive")

    var pendingWrites = 0
    let pendingChanged = store("changed-pending", writer: { data, url in
        pendingWrites += 1
        if pendingWrites > 1 { throw SecureStorage.Failure.writeFailed }
        try SecureStorage.atomicWrite(data, url)
    })
    legacy(pendingChanged, "notes.json", plaintext)
    expect(!pendingChanged.prepare(), "pending migration manifest is committed before failed conversion")
    let injected = Data(#"["not the original pending note"]"#.utf8)
    legacy(pendingChanged, "notes.json", injected)
    expect(!store("changed-pending").prepare() && bytes(pendingChanged, "notes.json") == injected,
           "changed pending plaintext cannot bypass authentication during restart")

    var partialWrites = 0
    let partial = store("partial-migration", writer: { data, url in
        partialWrites += 1
        if partialWrites >= 4 { throw SecureStorage.Failure.writeFailed }
        try SecureStorage.atomicWrite(data, url)
    })
    legacy(partial, "ai-chats.json", plaintext)
    legacy(partial, "notes.json", plaintext)
    expect(!partial.prepare() && bytes(partial, "ai-chats.json").starts(with: SecureStorage.magic)
           && bytes(partial, "notes.json") == plaintext, "partial migration has one checkpointed file and one pending file")
    legacy(partial, "ai-chats.json", plaintext)
    expect(!store("partial-migration").prepare() && bytes(partial, "ai-chats.json") == plaintext,
           "even original plaintext cannot replace an already checkpointed file during interrupted migration")

    var checkpointWrites = 0
    let checkpoint = store("checkpoint-interruption", writer: { data, url in
        checkpointWrites += 1
        if checkpointWrites == 3 { throw SecureStorage.Failure.writeFailed }
        try SecureStorage.atomicWrite(data, url)
    })
    legacy(checkpoint, "notes.json", plaintext)
    expect(!checkpoint.prepare() && bytes(checkpoint, "notes.json").starts(with: SecureStorage.magic),
           "checkpoint interruption leaves verified ciphertext and an authenticated pending digest")
    let checkpointBytes = bytes(checkpoint, "notes.json")
    let checkpointRestart = store("checkpoint-interruption")
    let checkpointRead: [String]? = checkpointRestart.load("notes.json")
    expect(checkpointRead == ["private note"] && bytes(checkpointRestart, "notes.json") == checkpointBytes,
           "restart completes an interrupted checkpoint without rewriting authenticated ciphertext")

    let badWriter = store("bad-writer", writer: { _, url in try Data("bad ciphertext".utf8).write(to: url) })
    legacy(badWriter, "notes.json", plaintext)
    expect(!badWriter.prepare() && bytes(badWriter, "notes.json") == plaintext, "readback failure leaves original untouched")
    expect(try! fm.contentsOfDirectory(atPath: badWriter.root.path).allSatisfy { !$0.hasPrefix(".lumen-encrypt-") }, "own failed temp is removed")

    var locked = false
    var lockReports = 0
    let relock = store("relock", keyProvider: { _ in
        if locked { throw SecureStorage.Failure.keyInteractionRequired }
        return key
    }, onFailure: { lockReports += 1 })
    let empty: [String]? = relock.load("notes.json")
    expect(empty == nil && relock.save(["kept"], "notes.json"), "fresh notes saved")
    let kept = bytes(relock, "notes.json")
    locked = true
    expect(!relock.save(["lost"], "notes.json") && bytes(relock, "notes.json") == kept, "locking after initialization stops writes without a cached key")
    expect(!relock.available && !relock.available && lockReports == 1, "locked key reports once while unavailable")
    locked = false
    expect(relock.available && relock.save(["after unlock"], "notes.json"), "the same archive can save after unlock")
    locked = true
    expect(!relock.available && lockReports == 2, "another lock after successful access reports again")
    let noLoad = store("roundtrip")
    expect(!noLoad.save([String](), "notes.json") && bytes(s, "notes.json") == changed,
           "save without successful load cannot replace an existing archive")
    let laterDamage = store("later-damage")
    let initial: [String]? = laterDamage.load("notes.json")
    expect(initial == nil && laterDamage.save(["kept"], "notes.json"), "mid-session damage fixture saved")
    var damaged = bytes(laterDamage, "notes.json")
    damaged[damaged.count - 1] ^= 1
    legacy(laterDamage, "notes.json", damaged)
    expect(!laterDamage.save(["new"], "notes.json") && bytes(laterDamage, "notes.json") == damaged,
           "corruption after successful load is not overwritten by later edits")

    let missingRevision = store("concurrent-create")
    let firstCreate = store("concurrent-create")
    let absentForBoth: [String]? = missingRevision.load("notes.json")
    let absentForFirst: [String]? = firstCreate.load("notes.json")
    expect(absentForBoth == nil && absentForFirst == nil && firstCreate.save(["first"], "notes.json"),
           "two owners can observe a missing archive before the first save")
    let firstRevision = bytes(firstCreate, "notes.json")
    expect(!missingRevision.save(["second"], "notes.json") && bytes(firstCreate, "notes.json") == firstRevision,
           "a writer which saw a missing archive cannot overwrite the first saved revision")

    let removed = store("concurrent-remove")
    let initialMissing: [String]? = removed.load("notes.json")
    expect(initialMissing == nil && removed.save(["first"], "notes.json"), "removed archive fixture saved")
    let removedURL = removed.root.appendingPathComponent("notes.json")
    try! fm.removeItem(at: removedURL)
    expect(!removed.save(["second"], "notes.json") && !fm.fileExists(atPath: removedURL.path),
           "a writer which saw an archive cannot recreate an externally removed file")

    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let firstWriter = store("concurrent-create", writer: { data, url in
        writerEntered.signal()
        guard releaseWriter.wait(timeout: .now() + 5) == .success else { throw SecureStorage.Failure.writeFailed }
        try SecureStorage.atomicWrite(data, url)
    })
    let secondWriter = store("concurrent-create")
    let firstWriterRead: [String]? = firstWriter.load("notes.json")
    let secondWriterRead: [String]? = secondWriter.load("notes.json")
    expect(firstWriterRead == ["first"] && secondWriterRead == firstWriterRead, "both writers load the same revision")
    DispatchQueue.global().async {
        expect(firstWriter.save(["first edit"], "notes.json"), "first writer commits its revision")
        firstFinished.signal()
    }
    expect(writerEntered.wait(timeout: .now() + 5) == .success, "first writer holds the archive lock")
    DispatchQueue.global().async {
        secondStarted.signal()
        expect(!secondWriter.save(["stale edit"], "notes.json"), "second writer refuses to overwrite the new revision")
        secondFinished.signal()
    }
    expect(secondStarted.wait(timeout: .now() + 5) == .success, "second writer starts")
    expect(secondFinished.wait(timeout: .now() + 0.1) == .timedOut, "second writer waits for the archive lock")
    releaseWriter.signal()
    expect(firstFinished.wait(timeout: .now() + 5) == .success && secondFinished.wait(timeout: .now() + 5) == .success,
           "concurrent writes finish after releasing the archive lock")
    let committed: [String]? = store("concurrent-create").load("notes.json")
    expect(committed == ["first edit"], "the archive retains the only committed edit")

    var interactiveLookups = 0
    let preflight = SecureStorage(root: base.appendingPathComponent("preflight"), key: { _ in key },
                                  interactiveLookup: { interactiveLookups += 1 })
    expect(preflight.prepare(interactive: true) && interactiveLookups == 1, "main thread opts into the startup lookup")
    DispatchQueue.global().sync { expect(preflight.prepare(), "ordinary preparation can run on a worker") }
    expect(preflight.available && interactiveLookups == 1, "ordinary protected access does not ask for interaction")

    var failSave = false
    let failedSave = store("failed-save", writer: { data, url in
        if failSave { throw SecureStorage.Failure.writeFailed }
        try SecureStorage.atomicWrite(data, url)
    })
    let missingNote: [String]? = failedSave.load("notes.json")
    expect(missingNote == nil && failedSave.save(["preserved"], "notes.json"), "failed-save fixture saved")
    let beforeFailure = bytes(failedSave, "notes.json")
    failSave = true
    expect(!failedSave.save(["new"], "notes.json") && bytes(failedSave, "notes.json") == beforeFailure,
           "failed ciphertext save preserves the previous committed archive")

    let symlink = store("symlink")
    let external = base.appendingPathComponent("external")
    try! plaintext.write(to: external)
    try! fm.createDirectory(at: symlink.root, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: symlink.root.appendingPathComponent("notes.json"), withDestinationURL: external)
    expect(!symlink.prepare() && (try! Data(contentsOf: external)) == plaintext, "symlink is refused without touching external data")
}
