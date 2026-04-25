import Foundation
import CryptoKit
import Security

// MARK: - LicenseManager
//
// Responsibility: Ensure this copy of Clip Saske was downloaded from
//                 clip.saske.in and has not been tampered with.
//
// Behaviour (SILENT — zero UI):
//   • First launch (no token in Keychain):
//       → POST /license.php?action=activate
//       → On success: store signed token in Keychain, continue
//       → On failure (no network): continue — will retry next launch
//
//   • Subsequent launches (token present) + ONLINE:
//       → POST /license.php?action=verify  (sends token + bundle hash)
//       → Server says INVALID → silently exit(0)  — no dialog
//       → Network error / offline → skip, continue normally
//
//   • Offline: app works fully, no verification attempted
//
// The bundle hash prevents distributing a modified binary — the server
// knows the SHA-256 of every official release.

@MainActor
final class LicenseManager {
    // MARK: - Configuration

    private static let baseURL      = "https://clip.saske.in"
    private static let activateURL  = URL(string: "\(baseURL)/license.php?action=activate")!
    private static let verifyURL    = URL(string: "\(baseURL)/license.php?action=verify")!

    private static let keychainService = "com.clipsaske.app"
    private static let keychainAccount = "license-token"
    private static let machineIDKey    = "machine-id"

    // How often (seconds) to silently re-verify when online.
    private static let verifyInterval: TimeInterval = 12 * 60 * 60   // 12 hours

    // MARK: - State

    private var verifyTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        Task { await performStartupCheck() }
    }

    func stop() {
        verifyTimer?.invalidate()
        verifyTimer = nil
    }

    // MARK: - Startup

    private func performStartupCheck() async {
        guard await isOnline() else { return }

        if loadToken() == nil {
            // First launch — activate silently.
            await activate()
        } else {
            // Already activated — verify silently.
            await verify()
        }

        // Schedule periodic background re-verification.
        schedulePeriodicVerification()
    }

    // MARK: - Activation (first launch)

    private func activate() async {
        let machineID = getMachineID()
        let bundleHash = bundleSHA256()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        var request = URLRequest(url: Self.activateURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "machine_id":   machineID,
            "bundle_hash":  bundleHash,
            "app_version":  version,
            "platform":     "macOS"
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONDecoder().decode(LicenseResponse.self, from: data),
              json.status == "ok",
              let token = json.token else {
            // Network error or server down — try again next launch.
            return
        }

        saveToken(token)
    }

    // MARK: - Verification (background, every 12h)

    private func verify() async {
        guard let token = loadToken() else { return }
        let bundleHash = bundleSHA256()
        let machineID  = getMachineID()

        var request = URLRequest(url: Self.verifyURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "token":        token,
            "machine_id":   machineID,
            "bundle_hash":  bundleHash
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            // Network error — skip; do not penalise offline users.
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Server error — skip.
            return
        }
        guard let json = try? JSONDecoder().decode(LicenseResponse.self, from: data) else {
            return
        }

        if json.status == "invalid" || json.status == "revoked" || json.status == "tampered" {
            // Server has confirmed this copy is invalid/tampered — exit silently.
            exit(0)
        }

        // status == "ok" or any other value: continue normally.
    }

    // MARK: - Periodic timer

    private func schedulePeriodicVerification() {
        verifyTimer = Timer.scheduledTimer(withTimeInterval: Self.verifyInterval,
                                           repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard await self?.isOnline() == true else { return }
                await self?.verify()
            }
        }
    }

    // MARK: - Machine ID

    /// Returns a stable, per-install UUID stored in the Keychain.
    /// This is NOT a hardware ID — it resets on reinstall, which is intentional.
    private func getMachineID() -> String {
        if let data = keychainLoad(account: Self.machineIDKey),
           let id = String(data: data, encoding: .utf8) {
            return id
        }
        let id = UUID().uuidString
        keychainSave(data: Data(id.utf8), account: Self.machineIDKey)
        return id
    }

    // MARK: - Bundle SHA-256

    /// Computes SHA-256 of the main executable.
    /// The server keeps a registry of known-good hashes per version.
    private func bundleSHA256() -> String {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url) else { return "unknown" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Connectivity check

    private func isOnline() async -> Bool {
        var request = URLRequest(url: URL(string: "https://clip.saske.in/license.php?action=ping")!,
                                  timeoutInterval: 5)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...599).contains(http.statusCode)
    }

    // MARK: - Token Keychain

    private func loadToken() -> String? {
        guard let data = keychainLoad(account: Self.keychainAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveToken(_ token: String) {
        keychainSave(data: Data(token.utf8), account: Self.keychainAccount)
    }

    private func keychainLoad(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    Self.keychainService as CFString,
            kSecAttrAccount:    account as CFString,
            kSecReturnData:     true,
            kSecMatchLimit:     kSecMatchLimitOne,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainSave(data: Data, account: String) {
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: account as CFString
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    Self.keychainService as CFString,
            kSecAttrAccount:    account as CFString,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

// MARK: - Response Model

private struct LicenseResponse: Decodable {
    let status: String      // "ok" | "invalid" | "revoked" | "tampered"
    let token: String?
}
