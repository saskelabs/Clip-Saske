import Foundation
import AppKit

// MARK: - UpdateChecker
// Lightweight Sparkle-compatible auto-update mechanism.
//
// Protocol:
//   1. Fetches an `appcast.xml` (Sparkle RSS format) from your update server.
//   2. Compares the latest `sparkle:version` (CFBundleVersion integer) with
//      the running app's CFBundleVersion.
//   3. If a newer version is available it shows an NSAlert offering to open
//      the download URL in the browser (delta/full zip download or App Store).
//   4. Checks run automatically at launch (with a 5-second delay) and every
//      24 hours in the background.
//   5. The user can also trigger a manual check from the menu bar.
//
// HOW TO PUBLISH AN UPDATE
// ────────────────────────
// 1. Increment CFBundleShortVersionString and CFBundleVersion in Info.plist.
// 2. Build, sign, and notarize the new .zip / .dmg.
// 3. Upload the artifact to your server.
// 4. Update `appcast.xml` on your server with the new version entry.
//    Minimal example:
//      <item>
//        <title>Clip Saske 1.1.0</title>
//        <sparkle:version>2</sparkle:version>
//        <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
//        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
//        <enclosure url="https://your.host/ClipSaske-1.1.0.zip"
//                   length="4096000" type="application/octet-stream"/>
//      </item>

@MainActor
final class UpdateChecker {
    // MARK: - Configuration

    /// Public URL of your appcast.xml on clip.saske.in
    static let appcastURL = URL(string: "https://clip.saske.in/updates/appcast.xml")!

    /// How often (seconds) to auto-check in the background.
    private static let checkInterval: TimeInterval = 24 * 60 * 60   // 24 hours

    // MARK: - State

    private var timer: Timer?
    private var lastCheckDate: Date?
    private var isChecking = false

    // MARK: - Lifecycle

    func startAutoChecks() {
        // Initial check shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { [weak self] in await self?.checkForUpdates(userInitiated: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval,
                                     repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.checkForUpdates(userInitiated: false) }
        }
    }

    func stopAutoChecks() {
        timer?.invalidate()
        timer = nil
    }

    /// Call this when the user taps "Check for Updates…" in the menu.
    func checkForUpdatesManually() {
        Task { await checkForUpdates(userInitiated: true) }
    }

    // MARK: - Core check

    private func checkForUpdates(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        lastCheckDate = Date()

        do {
            let (data, response) = try await URLSession.shared.data(from: Self.appcastURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if userInitiated { showError("Could not reach the update server.") }
                return
            }
            let latest = try AppcastParser.parse(data)
            compareAndNotify(latest: latest, userInitiated: userInitiated)
        } catch {
            if userInitiated { showError(error.localizedDescription) }
        }
    }

    // MARK: - Version comparison

    private func compareAndNotify(latest: AppcastEntry, userInitiated: Bool) {
        let runningBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        if latest.buildNumber > runningBuild {
            promptInstall(latest: latest, currentVersion: runningVersion)
        } else if userInitiated {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Clip Saske is up to date."
            alert.informativeText = "You are running version \(runningVersion)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - UI

    private func promptInstall(latest: AppcastEntry, currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Clip Saske \(latest.shortVersion) is available"
        alert.informativeText = """
        You are using version \(currentVersion). \
        Version \(latest.shortVersion) is now available.

        \(latest.releaseNotes.isEmpty ? "" : latest.releaseNotes + "\n\n")\
        Would you like to download the update?
        """
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(latest.downloadURL)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update check failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - AppcastParser

private struct AppcastEntry {
    var buildNumber: Int        // sparkle:version (integer build number)
    var shortVersion: String    // sparkle:shortVersionString e.g. "1.1.0"
    var downloadURL: URL
    var releaseNotes: String
}

private enum AppcastParser {
    /// Parses a Sparkle-format appcast.xml and returns the highest-versioned entry.
    static func parse(_ data: Data) throws -> AppcastEntry {
        let parser = XMLParser(data: data)
        let delegate = AppcastXMLDelegate()
        parser.delegate = delegate
        guard parser.parse(), let best = delegate.bestEntry else {
            throw URLError(.cannotParseResponse)
        }
        return best
    }
}

// MARK: - XML Delegate

private final class AppcastXMLDelegate: NSObject, XMLParserDelegate {
    var bestEntry: AppcastEntry?

    private var currentBuild  = 0
    private var currentShort  = ""
    private var currentURL: URL?
    private var currentNotes  = ""
    private var insideItem    = false
    private var currentElement = ""
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        currentElement = element
        buffer = ""
        if element == "item" {
            insideItem = true
            currentBuild = 0; currentShort = ""; currentURL = nil; currentNotes = ""
        }
        if element == "enclosure", let urlStr = attributes["url"],
           let url = URL(string: urlStr) {
            currentURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "sparkle:version":         currentBuild = Int(text) ?? 0
        case "sparkle:shortVersionString": currentShort = text
        case "sparkle:releaseNotesLink", "description": currentNotes = text
        case "item":
            if insideItem, let url = currentURL, currentBuild > 0 {
                let entry = AppcastEntry(buildNumber: currentBuild,
                                         shortVersion: currentShort,
                                         downloadURL: url,
                                         releaseNotes: currentNotes)
                if bestEntry == nil || entry.buildNumber > bestEntry!.buildNumber {
                    bestEntry = entry
                }
            }
            insideItem = false
        default: break
        }
        buffer = ""
    }
}
