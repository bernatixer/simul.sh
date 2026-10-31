import SwiftUI

/// Hunk expanders: the unchanged lines between hunks, read from the file once per snapshot.
extension ReviewDiffView {
    /// Lines shown of a gap: from its start (under the hunk above) and from its end (over the hunk below).
    struct Reveal: Equatable {
        var down = 0
        var up = 0
    }

    /// A gap's revealed lines, and how many are still hidden.
    struct GapRows {
        let down: [DiffLine]
        let up: [DiffLine]
        let hidden: Int
    }

    /// Each gap's rows; nil if the file can't expand (only modified and renamed text files
    /// against the base; added and deleted ones show whole), or once read it was unreadable
    /// or no longer the snapshot's. Until it's read, the last gap's size is unknown: a ↓ for 20.
    func gapRows(_ file: FileDiff, shown: FileDiff) -> [GapRows]? {
        guard shown == file, !file.isBinary, file.status == .modified || file.status == .renamed else { return nil }
        let lines = fileLines[file.path]
        if lines?.isEmpty == true { return nil }
        let gaps = DiffGap.gaps(file.hunks, lineCount: lines?.count)
        return gaps.enumerated().map { g, gap in
            let r = revealed["\(file.path)#\(g)"] ?? Reveal()
            let down = min(r.down, gap.size), up = min(r.up, gap.size - down)
            func rows(_ range: Range<Int>) -> [DiffLine] {
                guard let lines else { return [] }
                return range.filter { $0 >= 1 && $0 <= lines.count }
                    .map { DiffLine(kind: .context, oldNumber: $0 + gap.offset, newNumber: $0, text: lines[$0 - 1]) }
            }
            return GapRows(down: rows(gap.first..<gap.first + down), up: rows(gap.last - up + 1..<gap.last + 1),
                           hidden: lines == nil && g == gaps.count - 1 ? 20 : gap.size - down - up)
        }
    }

    /// Gap g's buttons: ↑ before the first hunk, ↓ after the last; between, ↕ for 20 or fewer, else ↓ and ↑.
    func expanders(_ g: Int, of count: Int, hidden: Int) -> [HunkHeaderRow.Expand] {
        guard hidden > 0 else { return [] }
        if g == 0 { return [.up] }
        if g == count - 1 { return [.down] }
        return hidden <= 20 ? [.all] : [.down, .up]
    }

    func expandGap(_ path: String, _ g: Int, _ how: HunkHeaderRow.Expand, hidden: Int) {
        var r = revealed["\(path)#\(g)"] ?? Reveal()
        switch how {
        case .down: r.down += min(20, hidden)
        case .up: r.up += min(20, hidden)
        case .all: r.down += hidden
        }
        revealed["\(path)#\(g)"] = r
        loadLines(path)
        colourRevealed(path)
    }

    /// Reads the file's lines off the main actor, once per snapshot, on the first expander click
    /// (reading as headers scroll in redrew the diff while scrolling). None if unreadable or changed since.
    func loadLines(_ path: String) {
        guard fileLines[path] == nil else { return }
        guard let hash = snapshot.hashes[path] else { return fileLines[path] = [] }
        Task {
            let lines = await model.reviews.newSideLines(session.id, path: path, hash: hash)
            // Another snapshot meanwhile: its lines are read when asked.
            guard fileLines[path] == nil, model.reviews.snapshots[session.id]?.hashes[path] == hash else { return }
            fileLines[path] = lines ?? []
            colourRevealed(path)
        }
    }

    /// Syntax colours for the revealed lines the diff's highlights don't cover, off the main actor
    /// (the snapshot's parse, cached), kept until the snapshot changes.
    func colourRevealed(_ path: String) {
        guard let lines = fileLines[path], !lines.isEmpty, let hash = snapshot.hashes[path],
              let file = snapshot.files.first(where: { $0.path == path }), let gaps = gapRows(file, shown: file) else { return }
        let parsed = model.reviews.insights[session.id]?[path]?.newLines, have = revealedColours[path]
        let wanted = gaps.flatMap { $0.down + $0.up }.compactMap(\.newNumber).filter { parsed?[$0] == nil && have?[$0] == nil }
        guard !wanted.isEmpty else { return }
        Task {
            let colours = await model.reviews.highlightRevealed(session.id, path: path, hash: hash, lines: lines, numbers: wanted)
            guard !colours.isEmpty, model.reviews.snapshots[session.id]?.hashes[path] == hash else { return }
            revealedColours[path, default: [:]].merge(colours) { old, _ in old }
        }
    }

    /// DevHooks: "expand <file index> <gap> <down|up|all>".
    func devExpand(_ line: String) {
        let w = line.split(separator: " ").map(String.init)
        guard w.count == 4, w[0] == "expand", let i = Int(w[1]), files.indices.contains(i), let g = Int(w[2]) else { return }
        let file = files[i]
        guard let rows = gapRows(file, shown: file), rows.indices.contains(g) else { return }
        let how: HunkHeaderRow.Expand = w[3] == "up" ? .up : w[3] == "all" ? .all : .down
        expandGap(file.path, g, how, hidden: rows[g].hidden)
    }
}
