import Foundation

/// Consecutive lines of a hunk that moved together: one side of a MoveBlock.
struct MovedRun: Equatable {
    let start: Int          // index of its first line in the hunk
    let count: Int
    let note: LineNote      // .movedFrom (added lines) or .movedTo (removed lines)
}

/// One row the review draws for a hunk.
enum DiffRow: Equatable {
    case line(Int)                          // unified: index into the hunk's lines
    case pair(left: Int?, right: Int?)      // side by side
    case moved(MovedRun)                    // "N lines moved …", its lines follow when open

    /// Unique within its hunk and layout.
    var id: String {
        switch self {
        case let .line(i): "\(i)"
        case let .pair(l, r): "\(l.map(String.init) ?? "")|\(r.map(String.init) ?? "")"
        case let .moved(run): "m\(run.start)"
        }
    }
}

extension DiffHunk {
    /// The hunk's rows: each moved run as one row (followed by its lines when
    /// `isOpen`), everything else as lines, or as GitHub pairs them when `split`
    /// (see splitRows). An open run's lines sit alone on their side.
    func rows(split: Bool, note: (Int) -> LineNote?, isOpen: (MovedRun) -> Bool) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removed: [Int] = [], added: [Int] = []
        func flush() {
            for k in 0..<max(removed.count, added.count) {
                rows.append(.pair(left: k < removed.count ? removed[k] : nil, right: k < added.count ? added[k] : nil))
            }
            removed = []; added = []
        }
        func emit(_ i: Int) {
            guard split else { return rows.append(.line(i)) }
            switch lines[i].kind {
            case .context:
                flush()
                rows.append(.pair(left: i, right: i))
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(i)
            case .added:
                added.append(i)
            }
        }
        var i = 0
        while i < lines.count {
            guard let n = note(i), n != .formatting else {
                emit(i)
                i += 1
                continue
            }
            var j = i + 1
            while j < lines.count, note(j) == n { j += 1 }
            let run = MovedRun(start: i, count: j - i, note: n)
            flush()
            rows.append(.moved(run))
            if isOpen(run) {
                for k in i..<j { emit(k) }
                flush()
            }
            i = j
        }
        flush()
        return rows
    }
}

extension DiffAnalysis {
    /// "C lines changed · M moved · F whitespace", zero parts left out: C counts removed
    /// and added lines without a note, M moved blocks, F whitespace-only line pairs.
    func summary(_ files: [FileDiff]) -> String {
        let changed = files.reduce(0) { $0 + $1.added + $1.removed } - notes.count
        return [(changed, "lines changed"), (moves.count, "moved"), (formattingLines, "whitespace")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
    }
}
