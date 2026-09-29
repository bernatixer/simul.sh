import Foundation

/// Well-known filesystem locations used by the app.
enum Paths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentSessions", isDirectory: true)
    }

    static var sessionsFile: URL {
        applicationSupport.appendingPathComponent("sessions.json")
    }

    static var sessionsBackupFile: URL {
        applicationSupport.appendingPathComponent("sessions.json.prev")
    }
}
