import Foundation

/// Where the review's keyboard is: a file's hunk, or the file itself (`hunk` -1).
struct ReviewCursor: Equatable {
    var path: String
    var hunk: Int
}

/// Keyboard review (j / k files, n / p hunks), over the files in diff order.
enum ReviewNavigation {
    /// The file after (or before) `from`; the first going forward from nowhere; nil past either end.
    static func file(from: String?, in paths: [String], forward: Bool) -> String? {
        guard let from, let i = paths.firstIndex(of: from) else { return forward ? paths.first : paths.last }
        let j = i + (forward ? 1 : -1)
        return paths.indices.contains(j) ? paths[j] : nil
    }

    /// The hunk after (or before) `from`, crossing files; `hunks` is each file's count of
    /// hunks that show (0 for collapsed ones). Nil past either end.
    static func hunk(from: ReviewCursor?, in files: [(path: String, hunks: Int)], forward: Bool) -> ReviewCursor? {
        let all = files.enumerated().flatMap { f, file in (0..<file.hunks).map { (f, $0, file.path) } }
        guard let from else { return forward ? all.first.map { ReviewCursor(path: $0.2, hunk: $0.1) } : nil }
        let at = (files.firstIndex { $0.path == from.path } ?? -1, from.hunk)
        let next = forward ? all.first { ($0.0, $0.1) > at } : all.last { ($0.0, $0.1) < at }
        return next.map { ReviewCursor(path: $0.2, hunk: $0.1) }
    }
}

/// GitHub's suggested changes: a ```suggestion block in a comment holds the lines that replace the commented ones.
enum Suggestion {
    enum Part: Equatable {
        case text(String)
        case suggestion([String])
    }

    /// Fenced with one more backtick than the longest run in the lines (at least three), so a ``` in them stays code.
    static func block(_ lines: [String]) -> String {
        let fence = String(repeating: "`", count: max(3, (lines.map(backtickRun).max() ?? 0) + 1))
        return fence + "suggestion\n" + lines.joined(separator: "\n") + "\n" + fence
    }

    /// The comment as text and suggestion blocks, in order; an unclosed block runs to the end.
    /// A block opens on ```suggestion (or more backticks) and closes on a line of at least as many.
    static func parts(_ text: String) -> [Part] {
        var parts: [Part] = [], prose: [String] = [], code: [String]?, ticks = 0
        func flush() {
            let t = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(.text(t)) }
            prose = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let fence = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let run = fence.prefix { $0 == "`" }.count
            if code == nil, run >= 3, fence.dropFirst(run) == "suggestion" {
                flush()
                code = []
                ticks = run
            } else if code != nil, run >= ticks, run == fence.count {
                parts.append(.suggestion(code ?? []))
                code = nil
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        if let code { parts.append(.suggestion(code)) }
        flush()
        return parts
    }

    /// The longest run of backticks in the line.
    private static func backtickRun(_ line: String) -> Int {
        line.reduce(into: (best: 0, run: 0)) { r, c in
            r.run = c == "`" ? r.run + 1 : 0
            r.best = max(r.best, r.run)
        }.best
    }

    static func contains(_ text: String) -> Bool { text.contains("```suggestion") }
}
