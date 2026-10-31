import AppKit
import SwiftUI

/// Keyboard review (ReviewPanel's keys), gutter drags and suggestions.
extension ReviewDiffView {
    /// The gutter drag's view of the dragged file's shown lines; not observed, so collecting
    /// them redraws nothing.
    final class SpotBox {
        var lines: [Int: GutterSpot] = [:]
    }

    // MARK: - Keys

    /// j / k files, n / p hunks, v viewed and on, c comment on the hunk.
    func key(_ key: String, proxy: ScrollViewProxy) {
        switch key {
        case "j", "k": goToFile(forward: key == "j", proxy: proxy)
        case "n", "p": goToHunk(forward: key == "n", proxy: proxy)
        case "v": toggleViewed(proxy: proxy)
        case "c": commentOnHunk(proxy: proxy)
        default: break
        }
    }

    /// Hunks n / p stop at: none in a collapsed file or one showing a notice.
    private func hunkCount(_ file: FileDiff) -> Int {
        let shown = shownDiff(file)
        return isCollapsed(file) || notice(file, shown: shown) != nil ? 0 : shown.hunks.count
    }

    /// Where keys go from: the cursor while its file shows, else the file at the top (scrolling
    /// to another file forgets the cursor, see `scrolledTo`).
    private var place: ReviewCursor? {
        if let cursor, files.contains(where: { $0.path == cursor.path }) { return cursor }
        return focus.current.map { ReviewCursor(path: $0, hunk: -1) }
    }

    /// The pinned file changed: the user scrolled to another file unless a key just moved there.
    func scrolledTo(_ path: String) {
        if let cursor, cursor.path != path, Date().timeIntervalSince(keyMoved) > 1 { self.cursor = nil }
    }

    private func goToFile(forward: Bool, proxy: ScrollViewProxy) {
        guard let path = ReviewNavigation.file(from: place?.path, in: files.map(\.path), forward: forward),
              let file = files.first(where: { $0.path == path }) else { return }
        cursor = ReviewCursor(path: path, hunk: hunkCount(file) > 0 ? 0 : -1)
        keyMoved = Date()
        proxy.scrollTo(path, anchor: .top)
        // Again once the rows on the way are measured: estimated heights land a few rows off.
        DispatchQueue.main.async { proxy.scrollTo(path, anchor: .top) }
    }

    private func goToHunk(forward: Bool, proxy: ScrollViewProxy) {
        guard let next = ReviewNavigation.hunk(from: place, in: files.map { ($0.path, hunkCount($0)) }, forward: forward),
              let file = files.first(where: { $0.path == next.path }) else { return }
        cursor = next
        keyMoved = Date()
        // The hunk's first row: its header, else (joined to the one above) its first line.
        let first = context(file).items.first { item in
            switch item.kind {
            case let .hunkHeader(_, g, _, _): g == next.hunk && !item.id.hasSuffix("#tail")
            case let .quiet(h, _, _, _, _), let .row(h, _, _, _): h == next.hunk
            default: false
            }
        }
        if let id = first?.id { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.2)) }
    }

    /// Marks the current file viewed (it collapses) and goes to the next; unmarks in place.
    private func toggleViewed(proxy: ScrollViewProxy) {
        guard let path = place?.path, snapshot.hashes[path] != nil else { return }
        let viewed = !model.reviews.isViewed(session.id, path: path)
        if flipped.contains(path) { flipped.remove(path) }
        model.reviews.setViewed(session.id, path: path, viewed)
        if viewed { DispatchQueue.main.async { goToFile(forward: true, proxy: proxy) } }  // once it collapsed
    }

    /// Opens the composer on the current hunk's first added line; with removals only, on the
    /// new-side line after the first one (comments take new-side lines). A draft with text
    /// stays: it's shown and focused instead.
    private func commentOnHunk(proxy: ScrollViewProxy) {
        if let d = draft, !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let file = snapshot.files.first(where: { $0.path == d.path }), isCollapsed(file) { flip(d.path) }
            focusDraft += 1
            DispatchQueue.main.async { proxy.scrollTo("\(d.path)#draft", anchor: .center) }
            return
        }
        guard let place, let file = files.first(where: { $0.path == place.path }), hunkCount(file) > 0 else { return }
        let path = place.path, hunks = shownDiff(file).hunks
        // The cursor's hunk may be from an older diff (since viewed, another snapshot).
        let h = hunks.indices.contains(place.hunk) ? place.hunk : 0
        let hunk = hunks[h]
        let change = hunk.lines.firstIndex { $0.kind != .context } ?? 0
        guard let line = hunk.lines.first(where: { $0.kind == .added })
            ?? hunk.lines[change...].first(where: { $0.newNumber != nil }) ?? hunk.lines.last(where: { $0.newNumber != nil })
        else { return }
        let key = "\(path)#\(h)"
        if !showsSinceViewed(path), let analysis = model.reviews.analysis[session.id], analysis.quietHunks.contains(key),
           !opened.contains(key) {
            opened.formUnion(foldKeys(path, h, hunk, analysis: analysis))
        }
        cursor = ReviewCursor(path: path, hunk: h)
        gutterTapped(path, line, extend: false)
        DispatchQueue.main.async { proxy.scrollTo("\(path)#draft", anchor: .center) }  // once it's there
    }

    // MARK: - Gutter drag

    /// The new-side line a row's drag spot stands for.
    func spotLine(_ row: DiffRow, _ hunk: DiffHunk) -> DiffLine? {
        switch row {
        case let .line(i): hunk.lines[i]
        case let .pair(_, r): r.map { hunk.lines[$0] }
        case .moved: nil
        }
    }

    /// The press starts a comment (shift extends the one here) and turns the file's drag spots on;
    /// dragging extends it to the shown line nearest the pointer, as on GitHub.
    func gutter(_ path: String, _ line: DiffLine, _ action: GutterAction) {
        switch action {
        case .release:
            if dragging != nil { dragging = nil }
            spots.lines = [:]
        case .press:
            // Only a press that drafted on a new-side line drags (not a removed line's).
            let drafted = gutterTapped(path, line, extend: NSEvent.modifierFlags.contains(.shift))
            if dragging != (drafted ? path : nil) { dragging = drafted ? path : nil }
        case let .drag(y):
            guard dragging == path else { return }
            let distance = { (f: CGRect) in f.minY <= y && y <= f.maxY ? 0 : min(abs(f.minY - y), abs(f.maxY - y)) }
            guard let (n, spot) = spots.lines.min(by: { distance($0.value.frame) < distance($1.value.frame) }) else { return }
            extendDraft(to: n, text: spot.text)
        }
    }

    private func extendDraft(to n: Int, text: String) {
        guard let d = draft else { return }
        let low = min(d.anchor, n), lines = low...max(d.anchor, n)
        guard lines != d.lines else { return }
        resize(d, to: lines, quote: low == d.anchor ? d.anchorText : text)
    }

    /// The draft on other lines. A suggestion block Suggest put in, unedited, follows them
    /// (or goes, if they can't take one); an edited one stays as typed.
    func resize(_ d: CommentDraft, to lines: ClosedRange<Int>, quote: String) {
        var new = CommentDraft(path: d.path, anchor: d.anchor, anchorText: d.anchorText, lines: lines, quote: quote, text: d.text)
        if let old = d.block, let range = d.text.range(of: old) {
            let block = files.first { $0.path == d.path }.flatMap { suggestion($0, lines) }
            new.text.replaceSubrange(range, with: block ?? "")
            if block == nil { new.text = new.text.trimmingCharacters(in: .newlines) }
            new.block = block
        }
        draft = new
    }

    // MARK: - Suggestions

    /// The suggestion block Suggest inserts for `lines`: pull requests only (GitHub applies them),
    /// and only lines GitHub takes one on: new-side lines of one hunk of the file's diff.
    func suggestion(_ file: FileDiff, _ lines: ClosedRange<Int>) -> String? {
        if case .pullRequest = model.reviews.states[session.id]?.source {} else if !Self.devSuggest { return nil }
        for hunk in file.hunks {
            let text = Dictionary(hunk.lines.compactMap { l in l.newNumber.map { ($0, l.text) } }) { a, _ in a }
            let found = lines.compactMap { text[$0] }
            if found.count == lines.count { return Suggestion.block(found) }
        }
        return nil
    }

    /// DevHooks' "suggest": Suggest off pull requests too (fetching one can't run on a locked screen).
    static var devSuggest = false

    func suggest(_ block: String) {
        guard let text = draft?.text else { return }
        draft?.text = text.isEmpty ? block : text + "\n" + block
        draft?.block = block
    }

    /// DevHooks: "range <file index> <from> <to>" drafts on those lines (as a gutter drag),
    /// "say <text>" types into it, "suggest" presses Suggest (and offers it off PRs), "queue" queues it.
    func devDraft(_ line: String) {
        let w = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch w.first {
        case "range":
            let n = line.split(separator: " ").compactMap { Int($0) }
            guard n.count == 3, files.indices.contains(n[0]) else { return }
            let c = context(files[n[0]])
            let shown = c.shown.hunks.flatMap(\.lines) + (gapRows(c.file, shown: c.shown) ?? []).flatMap { $0.down + $0.up }
            guard let from = shown.first(where: { $0.newNumber == n[1] }), let to = shown.first(where: { $0.newNumber == n[2] })
            else { return }
            gutterTapped(c.file.path, from, extend: false)
            extendDraft(to: n[2], text: to.text)
        case "say": if draft != nil, w.count > 1 { draft?.text = w[1] }
        case "suggest":
            Self.devSuggest = true
            if let d = draft, let file = files.first(where: { $0.path == d.path }), let block = suggestion(file, d.lines) {
                suggest(block)
            }
        case "queue": if let text = draft?.text, !text.isEmpty { queue(text) }
        default: break
        }
    }
}

extension Notification.Name {
    /// A review key (ReviewPanel's monitor, or DevHooks' "key <k>") for the diff: j, k, n, p, v or c.
    static let simulReviewKey = Notification.Name("sh.simul.reviewKey")
}
