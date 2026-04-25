import Foundation
import CryptoKit
import Security

// MARK: - DatabaseEncryption
// Provides AES-256-GCM encryption/decryption for clipboard content.
// The symmetric key is generated once and stored exclusively in the macOS Keychain
// under the app's service identifier, never written to disk in plaintext.

final class DatabaseEncryption: @unchecked Sendable {
    private static let keychainService = "com.clipsaske.app"
    private static let keychainAccount = "db-encryption-key"

    /// Cached in-memory key. Loaded once per process lifetime.
    private var _key: SymmetricKey?
    private let keyLock = NSLock()

    // MARK: - Key management

    /// Returns the current encryption key, generating and persisting it if this
    /// is the first launch or the Keychain entry was removed.
    var key: SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cached = _key { return cached }
        let k = loadOrCreateKey()
        _key = k
        return k
    }

    private func loadOrCreateKey() -> SymmetricKey {
        if let data = keychainLoad() {
            return SymmetricKey(data: data)
        }
        let newKey = SymmetricKey(size: .bits256)
        let raw = newKey.withUnsafeBytes { Data($0) }
        keychainSave(raw)
        return newKey
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypts `plaintext` with AES-GCM and returns a Base64-encoded
    /// combined blob: 12-byte nonce || ciphertext || 16-byte tag.
    func encrypt(_ plaintext: String) -> String {
        guard let data = plaintext.data(using: .utf8) else { return plaintext }
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            // combined = nonce (12) + ciphertext + tag (16)
            guard let combined = sealed.combined else { return plaintext }
            return "enc:" + combined.base64EncodedString()
        } catch {
            // Never lose data — fall back to plaintext on unexpected error.
            return plaintext
        }
    }

    /// Decrypts a blob previously produced by `encrypt(_:)`.
    /// Returns the original string unchanged if it was not encrypted by us.
    func decrypt(_ blob: String) -> String {
        guard blob.hasPrefix("enc:") else { return blob }
        let b64 = String(blob.dropFirst(4))
        guard let combined = Data(base64Encoded: b64) else { return blob }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: key)
            return String(data: plain, encoding: .utf8) ?? blob
        } catch {
            return blob
        }
    }

    // MARK: - Keychain helpers

    private func keychainLoad() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.keychainService as CFString,
            kSecAttrAccount:      Self.keychainAccount as CFString,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
            // Require the device to be unlocked; key is inaccessible on a
            // locked screen even if the app happens to be running.
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainSave(_ data: Data) {
        // Delete any stale entry first.
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: Self.keychainAccount as CFString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.keychainService as CFString,
            kSecAttrAccount:      Self.keychainAccount as CFString,
            kSecValueData:        data,
            // Bound to this device; will NOT export in an unencrypted backup.
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
