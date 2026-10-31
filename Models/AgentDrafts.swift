import CryptoKit
import Foundation

/// "Ask agent to review": the agent writes its findings as JSON
/// (`{"version":1,"comments":[{"path","line","endLine","body"}]}`), and they
/// come in as queued comments marked by agent. Version 2 adds an overview
/// (AgentOverview) next to the comments.
enum AgentDrafts {
    /// Bigger files aren't read.
    static let maxBytes = 1_000_000
    /// Longer bodies are rejected: a comment says the problem and the fix, not an essay.
    static let maxBody = 600

    /// The file isn't a version 1 or 2 review at all.
    struct Problem: Error, Equatable {
        let message: String
    }

    /// What the panel's banner says, and what "Ask agent to fix" tells the agent.
    struct Issue: Equatable {
        let banner: String
        let reasons: [String]
    }

    /// One comment as written; fields left out or of the wrong type are nil.
    struct Entry: Equatable, Sendable {
        var path: String?
        var line: Int?
        /// 0 when present but not a number, so it fails the range check.
        var endLine: Int?
        var body: String?
        /// The entry's JSON as the agent wrote it, to write back if it's rejected.
        var raw: String
    }

    struct Rejected: Equatable {
        let entry: Entry
        let reason: String
    }

    /// Where the agent writes its review of `source` in `session`.
    static func file(session: UUID, source: ReviewSource) -> URL {
        let hash = SHA256.hash(data: Data(source.key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        return Paths.agentDrafts.appendingPathComponent("\(session.uuidString)-\(hash).json")
    }

    /// Deletes every review file of `session` (the session was deleted).
    static func removeFiles(session: UUID, in dir: URL = Paths.agentDrafts) {
        let prefix = session.uuidString + "-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// The file's entries; throws the first problem when it isn't a version 1 or 2 review at all.
    static func parse(_ data: Data) throws -> [Entry] { try parseFile(data).entries }

    /// The entries and, for version 2, the root object minus "version" and
    /// "comments" (the overview, for AgentOverview.validate; nil if nothing
    /// else is there). Version 2 may leave out "comments".
    static func parseFile(_ data: Data) throws -> (entries: [Entry], overview: [String: Any]?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Problem(message: "it isn't valid JSON") }
        guard var root = object as? [String: Any] else { throw Problem(message: "it isn't a JSON object") }
        let version = root["version"] as? Int
        guard version == 1 || version == 2 else { throw Problem(message: "\"version\" must be 1 or 2") }
        let found: Any? = root["comments"] ?? (version == 2 ? [] as [Any] : nil)
        guard let comments = found as? [Any] else { throw Problem(message: "\"comments\" must be an array") }
        root["version"] = nil
        root["comments"] = nil
        return (entries(comments), version == 2 && !root.isEmpty ? root : nil)
    }

    private static func entries(_ comments: [Any]) -> [Entry] {
        comments.map { item in
            let c = item as? [String: Any] ?? [:]
            let raw = (try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return Entry(path: c["path"] as? String, line: c["line"] as? Int,
                         endLine: c["endLine"].map { $0 as? Int ?? 0 }, body: c["body"] as? String, raw: raw)
        }
    }

    /// The entries that point at lines of a file in the diff, as new comments,
    /// and the invalid ones with why. Ones already in `existing` (same path,
    /// lines, text) are neither. `lines` gives a file's current lines.
    static func comments(_ entries: [Entry], diffPaths: Set<String>, lines: (String) -> [String],
                         existing: [ReviewComment], now: Date = Date()) -> (comments: [ReviewComment], rejected: [Rejected]) {
        var result: [ReviewComment] = [], rejected: [Rejected] = []
        for (n, e) in entries.enumerated() {
            let name = e.path.map { p in e.line.map { "\(p):\($0)" } ?? p } ?? "comment \(n + 1)"
            func reject(_ why: String) { rejected.append(Rejected(entry: e, reason: "\(name): \(why)")) }
            guard let path = e.path, !path.isEmpty else { reject("\"path\" is missing"); continue }
            guard diffPaths.contains(path) else { reject("not a file in the diff"); continue }
            guard let line = e.line, line >= 1 else { reject("\"line\" must be a line number"); continue }
            guard let trimmed = e.body?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                reject("\"body\" is missing"); continue
            }
            guard trimmed.count <= maxBody else { reject("\"body\" is over \(maxBody) characters; keep it to the problem and the fix"); continue }
            let end = e.endLine ?? line
            guard end >= line else { reject("\"endLine\" must be a line number, not before \"line\""); continue }
            let text = lines(path)
            let count = lineCount(text)
            guard end <= count else { reject("the file has \(count) lines"); continue }
            let duplicate = (existing + result).contains { $0.path == path && $0.line == line && $0.endLine == end && $0.text == trimmed }
            guard !duplicate else { continue }
            result.append(ReviewComment(id: UUID(), path: path, line: line, endLine: end, quote: text[line - 1], text: trimmed,
                                        state: .queued, isOutdated: false, createdAt: now, byAgent: true))
        }
        return (result, rejected)
    }

    /// A source's comments after an import: with `replacing` (a new review, not a fix of the
    /// rejected rest of the last one), the agent's earlier drafts not kept go if any new one
    /// came in, so asking again doesn't stack near-identical drafts. Kept and user comments stay.
    static func imported(_ entries: [Entry], into existing: [ReviewComment], replacing: Bool, diffPaths: Set<String>,
                         lines: (String) -> [String], now: Date = Date()) -> (comments: [ReviewComment], rejected: [Rejected]) {
        let base = replacing ? existing.filter { !$0.byAgent } : existing
        let found = comments(entries, diffPaths: diffPaths, lines: lines, existing: base, now: now)
        return (found.comments.isEmpty ? existing : base + found.comments, found.rejected)
    }

    /// Lines in a file as `ReviewGit.fileLines` gives them: a trailing newline isn't a line.
    static func lineCount(_ lines: [String]) -> Int { lines.last == "" ? lines.count - 1 : lines.count }

    /// A file holding just these entries, as the agent wrote them: version 1,
    /// or version 2 with `overview` (one that wasn't imported) kept as written.
    static func file(keeping rejected: [Rejected], overview: [String: Any]? = nil) -> Data {
        let comments = #""comments":["# + rejected.map(\.entry.raw).joined(separator: ",") + "]"
        guard let overview, let data = try? JSONSerialization.data(withJSONObject: overview, options: [.sortedKeys]),
              let rest = String(data: data, encoding: .utf8)?.dropFirst().dropLast() else {
            return Data((#"{"version":1,"# + comments + "}").utf8)
        }
        return Data((#"{"version":2,"# + comments + (rest.isEmpty ? "" : ",") + rest + "}").utf8)
    }
}
