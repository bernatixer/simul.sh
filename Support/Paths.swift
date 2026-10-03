import Foundation

/// Well-known filesystem locations used by the app.
enum Paths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Simul", isDirectory: true)
    }

    /// The app was called "AgentSessions" before it became Simul: move that
    /// data folder over once, if the new one doesn't exist yet. Never
    /// overwrites; on failure the old folder is left untouched.
    static func migrateLegacyData(
        from legacy: URL = applicationSupport.deletingLastPathComponent()
            .appendingPathComponent("AgentSessions", isDirectory: true),
        to current: URL = applicationSupport
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path) else { return }
        do {
            try fileManager.moveItem(at: legacy, to: current)
        } catch {
            Log.store.error("could not migrate \(legacy.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    static var sessionsFile: URL {
        applicationSupport.appendingPathComponent("sessions.json")
    }

    static var sessionsBackupFile: URL {
        applicationSupport.appendingPathComponent("sessions.json.prev")
    }
}
