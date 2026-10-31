import Foundation

/// What a GitHub PR review does besides commenting.
enum ReviewEvent: String, CaseIterable, Sendable {
    case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"

    var title: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }
}

/// The body of `POST repos/{repo}/pulls/{n}/reviews`; keys are GitHub's.
struct GitHubReviewPayload: Encodable, Equatable, Sendable {
    let commit_id: String
    let event: String
    let body: String
    let comments: [Inline]

    /// nil `start_*` are left out (single-line comments).
    struct Inline: Encodable, Equatable, Sendable {
        let path: String
        let line: Int
        let side: String
        let start_line: Int?
        let start_side: String?
        let body: String
    }
}

enum GitHubReview {
    /// GitHub takes inline comments only on lines its diff shows: every line of
    /// the comment must be a new-side line of the file's hunks. Outdated ones never are.
    static func isInline(_ comment: ReviewComment, shown: [String: Set<Int>]) -> Bool {
        guard !comment.isOutdated, comment.line <= comment.endLine, let lines = shown[comment.path] else { return false }
        return (comment.line...comment.endLine).allSatisfy(lines.contains)
    }

    /// The new-side lines the diff shows, by path.
    static func shownLines(_ diff: [FileDiff]) -> [String: Set<Int>] {
        Dictionary(diff.map { ($0.path, Set($0.hunks.flatMap { $0.lines.compactMap(\.newNumber) })) }, uniquingKeysWith: { a, b in a.union(b) })
    }

    /// The comment's lines exist in the PR head's file and its first line is
    /// still the text it was written on (a trailing \r ignored on both sides).
    static func matchesHead(_ comment: ReviewComment, headLines: [String]?) -> Bool {
        guard let lines = headLines, comment.line >= 1, comment.endLine <= lines.count else { return false }
        func bare(_ s: String) -> Substring { s.hasSuffix("\r") ? s.dropLast() : Substring(s) }
        return bare(lines[comment.line - 1]) == bare(comment.quote)
    }

    /// Splits comments into inline (new-side lines inside the PR diff and, when
    /// `headLines` is given, matching the head's file) and outside ones.
    static func payload(event: ReviewEvent, summary: String, comments: [ReviewComment], diff: [FileDiff],
                        headSHA: String, outsideIntoSummary: Bool,
                        headLines: [String: [String]]? = nil) -> (payload: GitHubReviewPayload, outside: [ReviewComment]) {
        var inline: [GitHubReviewPayload.Inline] = [], outside: [ReviewComment] = []
        let shown = shownLines(diff)
        for c in comments {
            guard isInline(c, shown: shown), headLines.map({ matchesHead(c, headLines: $0[c.path]) }) ?? true else { outside.append(c); continue }
            let range = c.endLine > c.line
            inline.append(.init(path: c.path, line: c.endLine, side: "RIGHT", start_line: range ? c.line : nil,
                                start_side: range ? "RIGHT" : nil, body: c.text))
        }
        var body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if outsideIntoSummary, !outside.isEmpty {
            let lines = outside.map { c in
                let at = c.endLine > c.line ? "\(c.line)-\(c.endLine)" : "\(c.line)"
                // Continuation lines indented so they stay in the list item.
                return "- `\(c.path):\(at)` " + c.text.replacingOccurrences(of: "\n", with: "\n  ")
            }
            body += (body.isEmpty ? "" : "\n\n") + "Other comments:\n" + lines.joined(separator: "\n")
        }
        return (GitHubReviewPayload(commit_id: headSHA, event: event.rawValue, body: body, comments: inline), outside)
    }

    /// Why a submit without "Add to summary" stops: `outside` comments that sit
    /// on the diff's lines but were left out because the head's file differs.
    static func notMatchingHead(_ outside: [ReviewComment], diff: [FileDiff]) -> String? {
        let shown = shownLines(diff), n = outside.filter { isInline($0, shown: shown) }.count
        guard n > 0 else { return nil }
        return (n == 1 ? "1 comment no longer matches" : "\(n) comments no longer match") + " the PR head — refresh, or tick Add to summary"
    }

    static let notAtHead = "Your copy of this PR differs from its head on GitHub (local commits, edits, or a custom base) — comments can't be placed safely. Refresh or use the PR worktree."

    /// Paths in the snapshot's diff the PR head doesn't have (local files), or
    /// nil when a file differs from the head (then line numbers can't be trusted).
    static func localOnly(_ snapshot: ReviewSnapshot, head: [String: String]) -> Set<String>? {
        var local: Set<String> = []
        for file in snapshot.files {
            let mine = snapshot.hashes[file.path]
            switch (file.status, head[file.path]) {
            case (.deleted, nil): continue
            case (.deleted, _?): return nil
            case (_, nil): local.insert(file.path)
            case let (_, theirs?): guard mine == theirs || mine == "submodule:" + theirs else { return nil }
            }
        }
        return local
    }

    /// `git ls-tree -z` output ("<mode> <type> <id>\t<path>" NUL-separated) as path -> id.
    static func parseLsTree(_ text: String) -> [String: String] {
        var objects: [String: String] = [:]
        for entry in text.split(separator: "\0") {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let fields = entry[..<tab].split(separator: " ")
            if fields.count == 3 { objects[String(entry[entry.index(after: tab)...])] = String(fields[2]) }
        }
        return objects
    }

    /// What to show when `gh api` fails: GitHub's JSON `message` (and its
    /// `errors`) from stdout, else gh's stderr, else the exit code.
    static func errorMessage(stdout: String, stderr: String, exitCode: Int32) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
           let message = json["message"] as? String {
            let details = (json["errors"] as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? [String: Any])?["message"] as? String }
            return details.isEmpty ? message : message + ": " + details.joined(separator: "; ")
        }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "gh api failed (exit \(exitCode))" : err
    }
}
