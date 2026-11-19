# Encrypted personal storage

Date: 2026-11-13 · Status: proposed in pull request

## Context

Clipboard text and captured images, notes and AI chats with inline screenshots were saved as JSON/PNG
in Application Support. These archives now use AES encryption with a Keychain-held key.

## Decision

Use system CryptoKit AES-256-GCM with a random nonce per write, a versioned LUM1 envelope and path-bound
associated data. Keep a separate random 256-bit storage key in the default macOS Keychain, non-synchronizing.
Explicitly check that keychain is unlocked before lookups and pin lookups/inserts to it. An encrypted
marker detects missing/wrong keys even with empty archives.

Before loading features, migrate clipboard.json, ai-chats.json, notes.json, their .bak files and stored
clipboard PNG copies (including orphan images/backups). Validate ciphertext by decrypting and reading
it back before atomic replacement. Persist authenticated migration state so a later plaintext substitution
is not mistaken for legacy data on restart, while an interrupted first migration can resume.
Do not create a new plaintext backup. Unreadable originals stay intact.

If the key is missing or the Keychain is locked, Lumen stops reading and writing the on-disk archive,
preserves its files and explains the recovery path. Corrupt archives also prevent writes. Lumen preserves
existing data instead of saving empty defaults or falling back to plaintext. A destructive reset would
require a separate design and explicit user action. Content already decrypted into memory may remain
visible or available through existing actions until Lumen quits.

## Consequences

- Clipboard previews and paste decrypt in memory rather than opening encrypted files as PNGs.
- Removing history entries retains encrypted image files: image deletion and asynchronous index writes
  are not transactional. Safe garbage collection after durable index writes is a follow-up; this avoids
  leaving a preserved index referencing images deleted before a failed save.
- Source screenshots, explicit note exports and the system pasteboard are outside archive encryption.
- Codex CLI attachments require temporary plaintext files; normal request cleanup removes them, but
  abrupt termination may leave temporary files. This is not memory or full-disk protection.
- Other preferences, caches and feature data remain outside this scope.
- Restoring files without the original usable key is insufficient; no automatic cross-device recovery
  or key export is implemented. The classic Keychain key is not claimed to be hardware/device-bound.
- Replacing legacy files cannot erase older Time Machine copies, snapshots or physical disk blocks.
- Checks use injected keys and temporary roots. Real Keychain access, signing ACLs and live migration
  are separate installation checks, pending before release.

## Backup and rollback

1. Quit Lumen before upgrading and back up the entire `~/Library/Application Support/Lumen` folder.
   For an encrypted backup, preserve the original usable Keychain key as well.
2. To roll back, quit Lumen and keep a separate copy of the current migrated folder and its original
   usable key. A pre-encryption version can mistake ciphertext for corrupt JSON, replace backup files
   and write plaintext. Use the older version only with the archive from its own pre-upgrade backup.
3. Restore the pre-upgrade folder as a unit before launching the older build. If the backup is encrypted,
   use a version that understands its format and the Keychain key that belongs to that backup. Changes
   made since that backup remain in the separate copy and can be opened with a compatible Lumen build.

## Platform constraint

The bare swiftc/self-signed app uses the classic default Keychain. The macOS SDK states that kSecAttrAccessible applies only with synchronization
or the Data Protection Keychain. Therefore merely adding WhenUnlockedThisDeviceOnly to a non-sync
classic key would not enforce that policy. The implementation checks whether the classic Keychain is unlocked. The Keychain and the screen have independent lock states.

## Options

- FileVault alone: helpful, but not the requested application-level archive encryption.
- Plaintext fallback: rejected because transient Keychain failures would leak data.
- Replacement keys whenever lookup fails: rejected because they strand encrypted files.
- Automatic data discard: rejected; preservation is the non-destructive default.

## Open

- Verify signed-app Keychain access before installation; injected tests do not prove it.
- Exercise the backup and rollback steps with a disposable archive before releasing the migration.
- Cross-device key export/recovery and a destructive reset UI are not included.
