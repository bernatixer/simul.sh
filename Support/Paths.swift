import Foundation

/// Well-known filesystem locations used by the app.
enum Paths {
    /// SIMUL_DATA_DIR points a test copy (scripts/smoke.sh, AGENTS.md) at its
    /// own folder. Read once, at first use during app init: LaunchEnvironment
    /// scrubs it from the environment right after, so agents don't inherit it.
    private static let dataDirOverride = ProcessInfo.processInfo.environment["SIMUL_DATA_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static var applicationSupport: URL {
        if let dir = dataDirOverride { return dir }
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

    /// Images pasted into sessions, one folder per session. Caches, not
    /// Application Support: the path normally has no spaces, so it pastes
    /// cleanly, and it's emptied on launch (agents read an image when it's
    /// pasted).
    static var pastedImages: URL {
        if let dir = dataDirOverride { return dir.appendingPathComponent("pastes", isDirectory: true) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Simul/pastes", isDirectory: true)
    }
}
