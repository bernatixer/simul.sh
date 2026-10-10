import Foundation

/// Finds agents' own conversation records so a relaunch resumes exactly the
/// session's conversation. Read-only; the agents own these files.
enum AgentConversations {
    /// Claude keeps one transcript per conversation at
    /// `~/.claude/projects/<encoded cwd>/<id>.jsonl`. Scans every project
    /// folder instead of re-implementing Claude's cwd encoding.
    static func claudeTranscriptExists(
        id: String,
        claudeDir: URL = defaultClaudeDir
    ) -> Bool {
        claudeTranscript(id: id, claudeDir: claudeDir) != nil
    }

    static let defaultClaudeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")

    private static func claudeTranscript(id: String, claudeDir: URL) -> URL? {
        let projects = claudeDir.appendingPathComponent("projects")
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projects.path) else { return nil }
        return folders.lazy
            .map { projects.appendingPathComponent("\($0)/\(id).jsonl") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Claude's last written reply, for notifications. Reads only the
    /// transcript's tail (they grow to MBs); nil when not found there. Call
    /// off the main thread.
    // ponytail: relies on Claude's transcript format (assistant "text"
    // blocks); anything unexpected just yields nil.
    static func claudeLastReply(
        id: String,
        claudeDir: URL = defaultClaudeDir,
        tailBytes: Int = 256 * 1024
    ) -> String? {
        guard let url = claudeTranscript(id: id, claudeDir: claudeDir),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        // The first line may be cut mid-record; it just fails to parse.
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "assistant" else { continue }
            let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            if let reply = snippet(text.joined(separator: " ")) { return reply }
        }
        return nil
    }

    /// One line of plain text, short enough for a notification.
    static func snippet(_ text: String, limit: Int = 240) -> String? {
        let plain = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.allSatisfy { $0 == "#" } } // markdown headings
            .joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        return plain.count > limit ? String(plain.prefix(limit - 1)) + "…" : plain
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
