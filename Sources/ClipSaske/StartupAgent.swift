import Foundation
import ServiceManagement

enum StartupAgent {
    private static let label = "com.clipsaske.app"
    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
    private static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.register()
            return
        }
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.unregister()
            return
        }
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
