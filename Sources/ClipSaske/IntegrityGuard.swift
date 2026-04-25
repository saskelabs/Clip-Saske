import Foundation
import Security
import AppKit

// MARK: - IntegrityGuard
// Verifies the app bundle has not been tampered with or copied.
// ALL checks are SILENT — no alerts, no popups, no text shown to the user.
// If any check fails, the process exits with code 0 (looks like a clean quit).
// When offline, only local checks run; server-side checks are skipped.
//
// Checks:
//   1. Bundle structure integrity
//   2. Bundle identifier match
//   3. Code signature validity via SecStaticCode
//   4. Team ID match (enable after signing)
//   5. Anti-debug detection (release builds only)
//   6. Screen-capture protection (window.sharingType = .none)

enum IntegrityGuard {
    // MARK: - Constants

    private static let expectedTeamID   = "XXXXXXXXXX"   // Set to your Apple Team ID
    private static let expectedBundleID = "com.clipsaske.app"

    // MARK: - Public API

    /// Runs all local integrity checks synchronously at launch.
    /// Silent: exits with code 0 on any failure (no UI shown).
    @MainActor
    static func verify() {
        guard verifyBundleStructure()    else { silentExit() }
        guard verifyBundleIdentifier()   else { silentExit() }
        guard verifyCodeSignature()      else { silentExit() }
        // guard verifyTeamID()          else { silentExit() }  // ← enable after signing
        detectDebugger()
        detectScreenCapture()
    }

    // MARK: - Bundle structure

    private static func verifyBundleStructure() -> Bool {
        let bundle = Bundle.main
        // Must be running as an .app bundle, not a bare executable.
        guard let bundlePath = bundle.bundlePath as String?,
              bundlePath.hasSuffix(".app") else { return false }
        // Contents/MacOS must exist.
        let execURL = bundle.executableURL
        return execURL != nil
    }

    // MARK: - Bundle identifier

    private static func verifyBundleIdentifier() -> Bool {
        Bundle.main.bundleIdentifier == expectedBundleID
    }

    // MARK: - Code signature

    private static func verifyCodeSignature() -> Bool {
        // Skip strict signature check if Developer ID is not yet configured (ad-hoc signing)
        if expectedTeamID == "XXXXXXXXXX" { return true }

        var staticCode: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        // Validate the signature with the system's default policy.
        let policy = SecPolicyCreateBasicX509()
        var requirement: SecRequirement?
        // Basic check: just require a valid Apple-issued signature chain.
        let reqString = "anchor apple generic" as CFString
        guard SecRequirementCreateWithString(reqString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            // If we can't even parse the requirement, just check the signature exists.
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess
        }
        _ = policy // suppress unused warning
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), req) == errSecSuccess
    }

    // MARK: - Team ID (optional, enable after setting expectedTeamID)

    private static func verifyTeamID() -> Bool {
        var staticCode: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let teamID = dict["teamid"] as? String else { return false }
        return teamID == expectedTeamID
    }

    // MARK: - Anti-debug

    /// Detects an attached debugger using `sysctl` and terminates if found in
    /// release builds. Debug builds skip this to preserve developer workflow.
    @MainActor
    private static func detectDebugger() {
        #if !DEBUG
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        if info.kp_proc.p_flag & P_TRACED != 0 {
            silentExit()
        }
        #endif
    }

    // MARK: - Screen capture protection

    /// Marks every app window so its content is excluded from system-level
    /// screen recordings and screenshots (requires macOS 14+).
    @MainActor
    private static func detectScreenCapture() {
        // Apply `.contentSharingPickerMode = .excluded` equivalent via the
        // sharingType property on each window. We set this in MenuBarController
        // and popup, but also enforce globally here for any future windows.
        for window in NSApp.windows {
            window.sharingType = .none
        }
    }

    // MARK: - Silent exit

    /// Silently terminates the process. No dialog, no log entry visible to the user.
    private static func silentExit() -> Never {
        exit(0)
    }
}
