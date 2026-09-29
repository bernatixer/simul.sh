import Foundation

/// Persistence format:
///
///     { "version": 1, "sessions": [ ... ] }
///
/// Storage rules (see the plan, §13):
///   - versioned top-level file
///   - atomic writes
///   - previous copy kept as sessions.json.prev
///   - never persist ephemeral state (tmux handles, PIDs)
struct SessionStoreSnapshot: Codable, Equatable {
    var version: Int
    var sessions: [Session]

    static let currentVersion = 1
}

/// Atomic JSON persistence for session metadata. No ORM, no database.
final class SessionStore {
    private let fileURL: URL
    private let backupURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = Paths.sessionsFile, backupURL: URL = Paths.sessionsBackupFile) {
        self.fileURL = fileURL
        self.backupURL = backupURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Loads sessions from disk. Missing file returns []. Corrupt primary
    /// falls back to the `.prev` backup; corrupt both returns [].
    func load() -> [Session] {
        do {
            return try readSessions(from: fileURL)
        } catch {
            Log.store.error("failed to load \(self.fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            if fileManager.fileExists(atPath: backupURL.path) {
                if let sessions = try? readSessions(from: backupURL) {
                    Log.store.warning("recovered \(sessions.count) sessions from backup")
                    return sessions
                }
            }
            return []
        }
    }

    /// Atomically persists sessions, keeping the previous file as backup.
    func save(_ sessions: [Session]) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = SessionStoreSnapshot(
                version: SessionStoreSnapshot.currentVersion,
                sessions: sessions
            )
            let data = try encoder.encode(snapshot)

            // Rotate backup, then write atomically.
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: fileURL, to: backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.store.error("failed to save: \(String(describing: error), privacy: .public)")
        }
    }

    private func readSessions(from url: URL) throws -> [Session] {
        let data = try Data(contentsOf: url)
        let snapshot = try decoder.decode(SessionStoreSnapshot.self, from: data)
        // Explicit, tiny migration hook. Version 1 is the only format today.
        switch snapshot.version {
        case SessionStoreSnapshot.currentVersion:
            return snapshot.sessions
        default:
            Log.store.warning("unknown store version \(snapshot.version), ignoring contents")
            return []
        }
    }
}
