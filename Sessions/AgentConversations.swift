import Foundation

/// Finds agents' own conversation records so a relaunch resumes exactly the
/// session's conversation. Read-only; the agents own these files.
enum AgentConversations {
    /// Claude keeps one transcript per conversation at
    /// `~/.claude/projects/<encoded cwd>/<id>.jsonl`. Scans every project
    /// folder instead of re-implementing Claude's cwd encoding.
    static func claudeTranscriptExists(
        id: String,
        claudeDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    ) -> Bool {
        let projects = claudeDir.appendingPathComponent("projects")
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projects.path) else { return false }
        return folders.contains {
            fileManager.fileExists(atPath: projects.appendingPathComponent("\($0)/\(id).jsonl").path)
        }
    }

    /// Codex assigns thread IDs itself, so find the thread this session
    /// started: the first TUI (`source = 'cli'`, so no subagents) thread in
    /// `cwd`, created after `since`, with a user message, not already
    /// claimed by another session.
    ///
    /// ponytail: reads Codex's internal `state_N.sqlite` (schema may change
    /// across Codex versions). Any failure returns nil → the session starts
    /// fresh, never resumes the wrong thread.
    static func codexThreadID(
        cwd: String,
        since: Date,
        excluding claimed: Set<String>,
        codexDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    ) async -> String? {
        guard let database = newestStateDatabase(in: codexDir) else { return nil }
        let quotedCwd = "'" + cwd.replacingOccurrences(of: "'", with: "''") + "'"
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let created = "COALESCE(created_at_ms, created_at * 1000)"
        let sql = """
            SELECT id FROM threads
            WHERE cwd = \(quotedCwd) AND \(created) >= \(sinceMs)
              AND source = 'cli' AND first_user_message != ''
            ORDER BY \(created);
            """
        let result = await ProcessRunner.run("/usr/bin/sqlite3", arguments: ["-readonly", database.path, sql])
        guard result.exitCode == 0 else { return nil }
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first { !claimed.contains($0) }
    }

    private static func newestStateDatabase(in codexDir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexDir.path)) ?? []
        let newest = names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                      let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
                return (version, name)
            }
            .max { $0.0 < $1.0 }
        return newest.map { codexDir.appendingPathComponent($0.1) }
    }
}
