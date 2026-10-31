import Foundation

struct DiffLine: Equatable {
    enum Kind { case context, added, removed }
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

struct DiffHunk: Equatable {
    let header: String
    let lines: [DiffLine]
}

extension DiffHunk {
    /// Its first line on each side, from the header.
    var starts: (old: Int, new: Int) { UnifiedDiff.hunkStarts(Substring(header)) }
    /// The line after its last on each side.
    var ends: (old: Int, new: Int) {
        let s = starts
        return (s.old + lines.count { $0.kind != .added }, s.new + lines.count { $0.kind != .removed })
    }
}

/// Unchanged lines a diff leaves out: gap g is before hunk g, the last one after the
/// last hunk. New-side numbers; the old side is `offset` further.
struct DiffGap: Equatable {
    let first: Int
    /// Past `first` when empty; the file's end for the last gap (unknown: `first - 1`).
    let last: Int
    let offset: Int
    var size: Int { max(0, last - first + 1) }

    /// The file's gaps; `lineCount` (once its lines are read) sets the last one's end.
    static func gaps(_ hunks: [DiffHunk], lineCount: Int?) -> [DiffGap] {
        guard let firstHunk = hunks.first, let lastHunk = hunks.last else { return [] }
        var gaps = [DiffGap(first: 1, last: firstHunk.starts.new - 1, offset: firstHunk.starts.old - firstHunk.starts.new)]
        for (a, b) in zip(hunks, hunks.dropFirst()) {
            gaps.append(DiffGap(first: a.ends.new, last: b.starts.new - 1, offset: a.ends.old - a.ends.new))
        }
        let end = lastHunk.ends
        gaps.append(DiffGap(first: end.new, last: lineCount ?? end.new - 1, offset: end.old - end.new))
        return gaps
    }
}

/// One row of a side-by-side diff: the old line on the left, the new on the right.
struct SplitRow: Equatable {
    let left: DiffLine?
    let right: DiffLine?
}

extension DiffHunk {
    /// GitHub's pairing: context on both sides; each run of removed lines is
    /// paired row by row with the run of added lines right after it, and the
    /// shorter run is padded with nil (see rows(split:note:isOpen:)).
    var splitRows: [SplitRow] {
        rows(split: true, note: { _ in nil }, isOpen: { _ in false }).compactMap {
            guard case let .pair(l, r) = $0 else { return nil }
            return SplitRow(left: l.map { lines[$0] }, right: r.map { lines[$0] })
        }
    }
}

struct FileDiff: Identifiable, Equatable {
    enum Status { case added, modified, deleted, renamed }
    var id: String { path }
    let path: String        // new path (old path for deletions)
    let oldPath: String?    // set for renames
    let status: Status
    let isBinary: Bool
    let hunks: [DiffHunk]
    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
    var added: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    var removed: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }

    /// GitHub's five-square stat: one square per changed line up to five,
    /// green in proportion to added lines, the rest red (grey makes five).
    static func squares(added: Int, removed: Int) -> (green: Int, red: Int) {
        let total = added + removed
        guard total > 0 else { return (0, 0) }
        let filled = min(5, total)
        let green = Int((Double(filled * added) / Double(total)).rounded())
        return (green, filled - green)
    }
}

/// Parses `git diff` output (unified format, one `diff --git` block per file).
enum UnifiedDiff {
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var block: [Substring] = []
        func flush() {
            if let file = parseFile(block) { files.append(file) }
            block = []
        }
        // Split on the newline byte: Swift treats "\r\n" as one Character, so a Character split misses CRLF.
        for bytes in text.utf8.split(separator: 10, omittingEmptySubsequences: false) {
            let line = Substring(bytes)
            if line.hasPrefix("diff --git ") { flush() }
            if !block.isEmpty || line.hasPrefix("diff --git ") { block.append(line) }
        }
        flush()
        return files
    }

    private static func parseFile(_ block: [Substring]) -> FileDiff? {
        guard let first = block.first else { return nil }
        var oldPath: String?, newPath: String?
        var renameFrom: String?, renameTo: String?
        var isNew = false, isDeleted = false, isBinary = false
        var hunks: [DiffHunk] = []
        var header: String?, lines: [DiffLine] = []
        var oldNo = 0, newNo = 0

        func closeHunk() {
            if let h = header { hunks.append(DiffHunk(header: h, lines: lines)) }
            header = nil; lines = []
        }

        for line in block.dropFirst() {
            if header != nil || line.hasPrefix("@@ ") {
                // Hunk body: once a hunk starts, ---/+++ are content, not headers.
                if line.hasPrefix("@@ ") {
                    closeHunk()
                    header = String(line)
                    (oldNo, newNo) = hunkStarts(line)
                    continue
                }
                if line.hasPrefix("\\") { continue }  // "\ No newline at end of file"
                guard let c = line.first else { continue }
                let body = String(line.dropFirst())
                switch c {
                case "+":
                    lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNo, text: body)); newNo += 1
                case "-":
                    lines.append(DiffLine(kind: .removed, oldNumber: oldNo, newNumber: nil, text: body)); oldNo += 1
                default:
                    lines.append(DiffLine(kind: .context, oldNumber: oldNo, newNumber: newNo, text: body)); oldNo += 1; newNo += 1
                }
            } else if line.hasPrefix("new file mode") {
                isNew = true
            } else if line.hasPrefix("deleted file mode") {
                isDeleted = true
            } else if line.hasPrefix("rename from ") {
                renameFrom = unquote(String(line.dropFirst(12)))
            } else if line.hasPrefix("rename to ") {
                renameTo = unquote(String(line.dropFirst(10)))
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            } else if line.hasPrefix("--- ") {
                oldPath = headerPath(line.dropFirst(4), prefix: "a/")
                if oldPath == nil { isNew = true }
            } else if line.hasPrefix("+++ ") {
                newPath = headerPath(line.dropFirst(4), prefix: "b/")
                if newPath == nil { isDeleted = true }
            }
        }
        closeHunk()

        let status: FileDiff.Status = renameFrom != nil ? .renamed : isNew ? .added : isDeleted ? .deleted : .modified
        var path = renameTo ?? (isDeleted ? oldPath : newPath)
        if path == nil { path = pathsFromGitLine(first.dropFirst(11))?.new }
        guard let path else { return nil }
        return FileDiff(path: path, oldPath: renameFrom, status: status, isBinary: isBinary, hunks: hunks)
    }

    /// Old and new start lines from `@@ -a,b +c,d @@ ...`.
    static func hunkStarts(_ line: Substring) -> (Int, Int) {
        let parts = line.split(separator: " ")
        func start(_ s: Substring?) -> Int {
            guard let s else { return 0 }
            return Int(s.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
    }

    /// Path from a `---`/`+++` line: nil for /dev/null; strips the a/ b/ prefix and git's trailing TAB.
    private static func headerPath(_ raw: Substring, prefix: String) -> String? {
        var s = String(raw)
        if !s.hasPrefix("\"") , let tab = s.firstIndex(of: "\t") { s = String(s[..<tab]) }
        s = unquote(s)
        if s == "/dev/null" { return nil }
        return s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    /// Paths from `a/X b/Y` (the `diff --git` line), for blocks with no ---/+++ or rename lines.
    private static func pathsFromGitLine(_ rest: Substring) -> (old: String, new: String)? {
        var s = String(rest)
        var oldRaw = ""
        if s.hasPrefix("\""), let end = closingQuote(s) {
            oldRaw = String(s[...end]); s = String(s[s.index(after: end)...].dropFirst())
        } else if !s.hasPrefix("\"") {
            // Unquoted: with equal paths the two halves are the same length around one space.
            let n = s.count
            if n % 2 == 1 {
                let mid = s.index(s.startIndex, offsetBy: n / 2)
                if s[mid] == " " { oldRaw = String(s[..<mid]); s = String(s[s.index(after: mid)...]) }
            }
            if oldRaw.isEmpty, let r = s.range(of: " b/", options: .backwards) {
                oldRaw = String(s[..<r.lowerBound]); s = String(s[s.index(after: r.lowerBound)...])
            }
        }
        guard !oldRaw.isEmpty else { return nil }
        func strip(_ p: String, _ prefix: String) -> String {
            let u = unquote(p)
            return u.hasPrefix(prefix) ? String(u.dropFirst(prefix.count)) : u
        }
        return (strip(oldRaw, "a/"), strip(s, "b/"))
    }

    private static func closingQuote(_ s: String) -> String.Index? {
        var i = s.index(after: s.startIndex), escaped = false
        while i < s.endIndex {
            if escaped { escaped = false } else if s[i] == "\\" { escaped = true } else if s[i] == "\"" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    /// Undoes git's C-style quoting (`"a/x\tb"`, octal escapes for bytes); unquoted input is returned as is.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        let bytes = Array(s.utf8.dropFirst().dropLast())
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            guard b == UInt8(ascii: "\\"), i < bytes.count else { out.append(b); continue }
            let e = bytes[i]; i += 1
            switch e {
            case UInt8(ascii: "t"): out.append(9)
            case UInt8(ascii: "n"): out.append(10)
            case UInt8(ascii: "r"): out.append(13)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var v = Int(e - 48), digits = 1
                while digits < 3, i < bytes.count, (48...55).contains(bytes[i]) { v = v * 8 + Int(bytes[i] - 48); i += 1; digits += 1 }
                out.append(UInt8(truncatingIfNeeded: v))
            default: out.append(e)  // \" \\ and anything else
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
