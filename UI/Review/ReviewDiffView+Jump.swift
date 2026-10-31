import SwiftUI

/// Scrolling to symbols, name uses and the other end of a move, opening the folds on the way.
extension ReviewDiffView {
    /// Diffs and fold keys computed against older files or another base.
    func resetFolds() {
        if !sinceViewed.isEmpty { sinceViewed = [:] }
        if !opened.isEmpty { opened = [] }
        if !revealed.isEmpty { revealed = [:] }
        if !fileLines.isEmpty { fileLines = [:] }
        if !revealedColours.isEmpty { revealedColours = [:] }
        if cursor != nil { cursor = nil }  // its hunk numbers are the old diff's
    }

    func toggle(_ fold: String) {
        if opened.contains(fold) { opened.remove(fold) } else { opened.insert(fold) }
    }

    /// A quiet hunk's key and its moved runs' keys.
    func foldKeys(_ path: String, _ h: Int, _ hunk: DiffHunk, analysis: DiffAnalysis) -> [String] {
        let key = "\(path)#\(h)"
        let rows = hunk.rows(split: false, note: { analysis.notes[LineRef(path: path, hunk: h, index: $0)] }) { _ in false }
        return [key] + rows.compactMap { if case let .moved(run) = $0 { "\(key)#m\(run.start)" } else { nil } }
    }

    /// Folded lines stay open while a comment or the draft ends on one of them.
    func holdsComment(_ path: String, _ lines: ArraySlice<DiffLine>, _ comments: [ReviewComment]) -> Bool {
        lines.contains { line in
            guard let n = line.newNumber else { return false }
            return comments.contains { $0.endLine == n } || (draft?.path == path && draft?.lines.upperBound == n)
        }
    }

    /// Scrolls to the other end of the move starting at `ref`, opening its file and hunk;
    /// to the file's header if it shows its since-viewed diff.
    func jump(from ref: LineRef, analysis: DiffAnalysis, proxy: ScrollViewProxy) {
        guard let block = analysis.moves.first(where: { $0.added.first == ref || $0.removed.first == ref }),
              let target = block.added.first == ref ? block.removed.first : block.added.first,
              let file = snapshot.files.first(where: { $0.path == target.path }) else { return }
        if isCollapsed(file) { flip(file.path) }
        var id = file.path
        if !showsSinceViewed(file.path) {
            let hunk = "\(file.path)#\(target.hunk)"
            if analysis.quietHunks.contains(hunk), !opened.contains(hunk) {
                opened.formUnion(foldKeys(file.path, target.hunk, file.hunks[target.hunk], analysis: analysis))
            }
            id = "\(hunk)\(sideBySide(file) ? "s" : "")#m\(target.index)"
        }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }  // once the opened rows exist
    }

    /// Scrolls to the symbol's first line (old side if deleted).
    func jump(to symbol: SymbolChange, in file: FileDiff, proxy: ScrollViewProxy) {
        let old = symbol.kind == .deleted
        guard let first = (old ? symbol.oldLines : symbol.newLines)?.lowerBound else { return }
        jump(toLine: first, old: old, in: file, proxy: proxy)
    }

    /// Scrolls to a use of the followed name, opening its file if collapsed or large.
    /// A file showing its since-viewed diff has no rows for it: to its header.
    func jump(to use: NameUse, proxy: ScrollViewProxy) {
        guard let file = snapshot.files.first(where: { $0.path == use.path }) else { return }
        if isCollapsed(file) { flip(file.path) }
        // A header that appears already pinned (after the filter cleared) never flips: highlight it here.
        if focus.current != file.path { focus.current = file.path }
        if showsSinceViewed(file.path) {
            DispatchQueue.main.async { proxy.scrollTo(file.path, anchor: .top) }
            return
        }
        if file.lineCount > Self.largeDiff, !expanded.contains(file.path) { expanded.insert(file.path) }
        jump(toLine: use.line, old: false, in: file, proxy: proxy)
    }

    /// Scrolls to line `first` (old side if `old`), opening the folds around it;
    /// if that line isn't in the diff, to the next one that is.
    func jump(toLine first: Int, old: Bool, in file: FileDiff, proxy: ScrollViewProxy) {
        // An unchanged line an expander revealed: its own row.
        if let line = gapRows(file, shown: file)?.flatMap({ $0.down + $0.up }).first(where: { (old ? $0.oldNumber : $0.newNumber) == first }),
           let n = line.newNumber {
            DispatchQueue.main.async { proxy.scrollTo("\(file.path)#e\(n)", anchor: .center) }
            return
        }
        var place: (h: Int, i: Int)?
        for (h, hunk) in file.hunks.enumerated() where place == nil {
            if let i = hunk.lines.firstIndex(where: { (old ? $0.oldNumber : $0.newNumber).map { $0 >= first } ?? false }) {
                place = (h, i)
            }
        }
        guard let (h, i) = place else {
            DispatchQueue.main.async { proxy.scrollTo(file.path, anchor: .top) }  // past the last hunk
            return
        }
        let hunk = file.hunks[h], key = "\(file.path)#\(h)"
        let analysis = model.reviews.analysis[session.id]
        let note = { (k: Int) in analysis?.notes[LineRef(path: file.path, hunk: h, index: k)] }
        var open = opened
        if let analysis, analysis.quietHunks.contains(key), !open.contains(key) {
            open.formUnion(foldKeys(file.path, h, hunk, analysis: analysis))
        }
        for case let .moved(run) in hunk.rows(split: false, note: note, isOpen: { _ in false })
        where (run.start..<run.start + run.count).contains(i) {
            open.insert("\(key)#m\(run.start)")
        }
        if open != opened { opened = open }
        // The rows as lineRows will draw them, to find the one holding line i.
        let split = sideBySide(file), comments = comments(for: file.path).filter { !$0.isOutdated }
        let rows = hunk.rows(split: split, note: note) { run in
            open.contains("\(key)#m\(run.start)")
                || holdsComment(file.path, hunk.lines[run.start..<run.start + run.count], comments)
        }
        guard let row = rows.first(where: { row in
            switch row {
            case let .line(k): k == i
            case let .pair(l, r): l == i || r == i
            case .moved: false
            }
        }) else { return }
        let id = "\(key)\(split ? "s" : "")#\(row.id)"
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }  // once the opened rows exist
    }
}
