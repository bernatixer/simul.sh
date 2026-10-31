import Foundation

/// A line in a diff: `index` is into `files[path].hunks[hunk].lines`.
struct LineRef: Hashable, Sendable {
    let path: String
    let hunk: Int
    let index: Int
}

enum LineNote: Equatable, Sendable {
    case movedFrom(path: String, line: Int)   // on an added line: its block came from old path:line
    case movedTo(path: String, line: Int)     // on a removed line: its block went to new path:line
    case formatting                           // removed/added pair equal ignoring whitespace
}

struct MoveBlock: Equatable, Sendable {
    let removed: [LineRef]
    let added: [LineRef]
}

struct DiffAnalysis: Equatable, Sendable {
    var notes: [LineRef: LineNote] = [:]
    var moves: [MoveBlock] = []
    /// Removed/added pairs that only changed whitespace.
    var formattingLines = 0
    /// Hunks whose every removed/added line has a note (fully noise).
    var quietHunks: Set<String> = []          // "path#hunk"
}

/// Finds moved blocks and whitespace-only changes, language-agnostic.
enum ReviewAnalysis {
    static let minMoveLines = 3
    static let maxFileLines = 1500

    /// Trims and collapses runs of whitespace to one space.
    static func normalize(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Closers and keywords (`}`, `)`, `end`) that match anywhere; they never anchor a move.
    static func isTrivial(_ normalized: String) -> Bool {
        normalized.count { $0.isLetter || $0.isNumber } < 4
    }

    /// A maximal run of consecutive removed (or added) lines in one hunk.
    private struct Run {
        let path: String        // old path for removed runs, new path for added
        let hunk: Int           // index into the analyzed hunks, to tell adjacent runs apart
        let start: Int          // index of the first line in its hunk
        let refs: [LineRef]
        let numbers: [Int]
        let norms: [String]
    }

    private struct Stretch {
        let removedRun: Int, removedAt: Int, addedRun: Int, addedAt: Int, count: Int
    }

    static func analyze(_ files: [FileDiff]) -> DiffAnalysis {
        var result = DiffAnalysis()
        let files = files.filter { $0.lineCount <= maxFileLines }

        var removedRuns: [Run] = [], addedRuns: [Run] = []
        var hunkKey = 0
        for file in files {
            for (h, hunk) in file.hunks.enumerated() {
                var i = 0
                while i < hunk.lines.count {
                    let kind = hunk.lines[i].kind
                    var j = i
                    while j < hunk.lines.count, hunk.lines[j].kind == kind { j += 1 }
                    if kind != .context {
                        let lines = hunk.lines[i..<j]
                        let run = Run(path: kind == .removed ? file.oldPath ?? file.path : file.path, hunk: hunkKey, start: i,
                                      refs: (i..<j).map { LineRef(path: file.path, hunk: h, index: $0) },
                                      numbers: lines.map { (kind == .removed ? $0.oldNumber : $0.newNumber) ?? 0 },
                                      norms: lines.map { normalize($0.text) })
                        if kind == .removed { removedRuns.append(run) } else { addedRuns.append(run) }
                    }
                    i = j
                }
                hunkKey += 1
            }
        }

        // Index added lines by text; only non-trivial lines anchor a stretch.
        var addedIndex: [String: [(run: Int, at: Int)]] = [:]
        for (a, run) in addedRuns.enumerated() {
            for (j, norm) in run.norms.enumerated() where !isTrivial(norm) { addedIndex[norm, default: []].append((a, j)) }
        }

        // Every maximal diagonal of equal lines, found once from its first non-trivial pair.
        // ponytail: a text repeated n times on each side costs n² pairs; cap occurrences if real diffs hit it.
        var stretches: [Stretch] = []
        for (r, removed) in removedRuns.enumerated() {
            for (i, norm) in removed.norms.enumerated() {
                for (a, j) in addedIndex[norm] ?? [] {
                    let added = addedRuns[a]
                    // A removed run followed by its added run is an edit in place, not a move.
                    if removed.hunk == added.hunk, removed.start + removed.refs.count == added.start { continue }
                    var back = 1, anchored = false
                    while i - back >= 0, j - back >= 0, removed.norms[i - back] == added.norms[j - back] {
                        if !isTrivial(removed.norms[i - back]) { anchored = true; break }
                        back += 1
                    }
                    if anchored { continue }  // an earlier pair on this diagonal covers it
                    let (i0, j0) = (i - back + 1, j - back + 1)
                    var n = 0
                    while i0 + n < removed.norms.count, j0 + n < added.norms.count,
                          removed.norms[i0 + n] == added.norms[j0 + n] { n += 1 }
                    stretches.append(Stretch(removedRun: r, removedAt: i0, addedRun: a, addedAt: j0, count: n))
                }
            }
        }

        // Longest first; a stretch overlapping an accepted move is cut into its free pieces and requeued.
        func qualifies(_ s: Stretch) -> Bool {
            s.count >= minMoveLines
                && removedRuns[s.removedRun].norms[s.removedAt..<s.removedAt + s.count].count { !isTrivial($0) } >= 2
        }
        var queue = stretches.filter(qualifies).sorted { $0.count < $1.count }
        var used = Set<LineRef>()
        while let s = queue.popLast() {
            let removed = removedRuns[s.removedRun], added = addedRuns[s.addedRun]
            let free = (0..<s.count).map { !used.contains(removed.refs[s.removedAt + $0]) && !used.contains(added.refs[s.addedAt + $0]) }
            if free.allSatisfy({ $0 }) {
                let r = Array(removed.refs[s.removedAt..<s.removedAt + s.count])
                let a = Array(added.refs[s.addedAt..<s.addedAt + s.count])
                result.moves.append(MoveBlock(removed: r, added: a))
                used.formUnion(r); used.formUnion(a)
                let to = LineNote.movedTo(path: added.path, line: added.numbers[s.addedAt])
                let from = LineNote.movedFrom(path: removed.path, line: removed.numbers[s.removedAt])
                for ref in r { result.notes[ref] = to }
                for ref in a { result.notes[ref] = from }
                continue
            }
            var k = 0
            while k < s.count {
                guard free[k] else { k += 1; continue }
                var e = k
                while e < s.count, free[e] { e += 1 }
                let piece = Stretch(removedRun: s.removedRun, removedAt: s.removedAt + k,
                                    addedRun: s.addedRun, addedAt: s.addedAt + k, count: e - k)
                if qualifies(piece) {
                    queue.insert(piece, at: queue.firstIndex { $0.count >= piece.count } ?? queue.endIndex)
                }
                k = e
            }
        }

        // Formatting pairs (GitHub's split pairing, broken around moved runs as the view does), then quiet hunks.
        for file in files {
            for (h, hunk) in file.hunks.enumerated() {
                let moved = { (i: Int) in result.notes[LineRef(path: file.path, hunk: h, index: i)] }
                for row in hunk.rows(split: true, note: moved, isOpen: { _ in false }) {
                    guard case let .pair(li?, ri?) = row else { continue }
                    let left = hunk.lines[li], right = hunk.lines[ri]
                    guard left.kind == .removed, right.kind == .added,
                          left.text != right.text, normalize(left.text) == normalize(right.text) else { continue }
                    let l = LineRef(path: file.path, hunk: h, index: li), r = LineRef(path: file.path, hunk: h, index: ri)
                    guard result.notes[l] == nil, result.notes[r] == nil else { continue }
                    result.notes[l] = .formatting; result.notes[r] = .formatting
                    result.formattingLines += 1
                }
                let changed = hunk.lines.indices.filter { hunk.lines[$0].kind != .context }
                if !changed.isEmpty, changed.allSatisfy({ result.notes[LineRef(path: file.path, hunk: h, index: $0)] != nil }) {
                    result.quietHunks.insert("\(file.path)#\(h)")
                }
            }
        }
        return result
    }
}
