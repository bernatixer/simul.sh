import AppKit
import Combine
import SwiftUI

/// The changed files' diffs, one collapsible section per file, with inline
/// comments. Click a line number or hover "+" to comment on it, shift-click to extend the range.
/// Click a name to follow it: its uses are marked and listed (Esc clears).
struct ReviewDiffView: View {
    @Environment(AppModel.self) var model
    let session: Session
    let snapshot: ReviewSnapshot
    /// The files shown (filtered, ordered by the panel).
    let files: [FileDiff]
    /// The file at the top, for the tree; a file the tree asks to show.
    let focus: ReviewFocus
    /// The name being followed; the panel lists its other uses.
    @Binding var followed: String?
    /// The panel lists the followed name's uses.
    @Binding var listingUses: Bool
    /// A use picked in the panel's list, to scroll to; cleared once done.
    @Binding var jumpTo: NameUse?
    /// The panel's base field is open (it takes Esc).
    var editingBase = false
    /// Files the user collapsed, or opened while viewed (viewed files start collapsed).
    @State var flipped: Set<String> = []
    /// Large files the user opened.
    @State var expanded: Set<String> = []
    /// Files showing their changes since viewed instead of against the base (the panel's,
    /// so the name-uses list knows which files' rows aren't there).
    @Binding var sinceViewed: [String: SinceViewed]
    @State var draft: CommentDraft?
    /// Folded rows the user opened: moved runs ("path#hunk#mN") and quiet hunks ("path#hunk").
    @State var opened: Set<String> = []
    /// Hunk gaps' revealed lines ("path#gap"), and the files' lines they come from.
    @State var revealed: [String: Reveal] = [:]
    @State var fileLines: [String: [String]] = [:]
    /// Revealed lines' syntax colours, by path and new line number.
    @State var revealedColours: [String: [Int: AttributedString]] = [:]
    /// The keyboard's place (j / k / n / p); its hunk gets a bar in the gutter.
    @State var cursor: ReviewCursor?
    /// When a key last moved the cursor: the scroll it causes doesn't forget it (`scrolledTo`).
    @State var keyMoved = Date.distantPast
    /// Bumped to focus the composer again (c with a draft already written).
    @State var focusDraft = 0
    /// The file whose gutter is being dragged, and where its lines are meanwhile.
    @State var dragging: String?
    @State var spots = SpotBox()
    /// Side by side or unified; the header's switch sets it.
    @AppStorage(Preferences.Key.reviewSplit) private var split = true
    @Environment(\.reviewPalette) private var palette

    enum SinceViewed: Equatable { case loading, diff(FileDiff), unavailable }

    /// Files with more diff lines than this start collapsed.
    static let largeDiff = 1_500
    /// Corner radius of a file's card.
    nonisolated static let radius: CGFloat = 6
    nonisolated static let space = "reviewDiff"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(files) { file in
                        let c = context(file)
                        Section {
                            ForEach(c.items) { itemView($0, c, proxy: proxy) }
                        } header: {
                            fileHeader(file)
                                // Pinned at the top now (not pushed off by the next): the tree highlights it.
                                // Only the flip calls back; scrolling back up flips the one above again.
                                .onGeometryChange(for: Bool.self) {
                                    let frame = $0.frame(in: .named(Self.space))
                                    return frame.minY < 12 && frame.maxY > 12
                                } action: { top in
                                    if top, focus.current != file.path {
                                        focus.current = file.path
                                        scrolledTo(file.path)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onPreferenceChange(GutterSpots.self) { found in MainActor.assumeIsolated { spots.lines = found } }
            }
            .coordinateSpace(name: Self.space)
            .onChange(of: jumpTo) { _, use in
                guard let use else { return }
                jumpTo = nil
                jump(to: use, proxy: proxy)
                // The keyboard carries on from there: the hunk at or before the line.
                let hunks = files.first { $0.path == use.path }.map(shownDiff)?.hunks ?? []
                let h = hunks.lastIndex { ($0.lines.lazy.compactMap(\.newNumber).first ?? .max) <= use.line } ?? -1
                if cursor != ReviewCursor(path: use.path, hunk: h) { cursor = ReviewCursor(path: use.path, hunk: h) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .simulDevCommand)) {
                devExpand($0.object as? String ?? "")
                devDraft($0.object as? String ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .simulReviewKey)) { key($0.object as? String ?? "", proxy: proxy) }
            .onChange(of: focus.reveal) { _, path in
                guard let path else { return }
                focus.reveal = nil
                if cursor?.path != path { cursor = ReviewCursor(path: path, hunk: -1) }
                proxy.scrollTo(path, anchor: .top)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "simul-name", let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
                  !name.isEmpty else { return .systemAction }
            if followed != name { followed = name }
            if !listingUses { listingUses = true }  // the same name again reopens the list
            return .handled
        })
        .background {
            // Esc clears the followed name. It's a window-wide shortcut, so it only exists
            // while nothing else takes Esc: composer, sidebar renames, base field, hidden review.
            if followed != nil, draft == nil, !editingBase, model.renaming == nil, model.renamingFolder == nil,
               model.reviews.isShowing(session.id) {
                Button("") {
                    followed = nil
                    if listingUses { listingUses = false }
                }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        // Computed against older files or another base; fold keys are line indices.
        .onChange(of: snapshot.hashes) { _, _ in resetFolds() }
        .onChange(of: snapshot.point) { _, _ in resetFolds() }
        // Lines revealed before the review parsed the files couldn't be coloured then.
        .onChange(of: model.reviews.insights[session.id] == nil) { _, missing in
            if !missing { fileLines.keys.forEach(colourRevealed) }
        }
    }

    // MARK: - Sections

    /// What a file's rows draw from, worked out once per file per update.
    struct FileContext {
        let file: FileDiff
        let shown: FileDiff
        let insight: FileInsight?
        let analysis: DiffAnalysis?
        let gutter: DiffGutter
        let split: Bool
        let items: [FileItem]
    }

    /// One row of a file's section. Each draws exactly one view, so the lazy
    /// stack counts a file's rows without walking them. Ids carry the path:
    /// plain indices from different files collide and rows get drawn under the wrong file.
    struct FileItem: Identifiable {
        enum Kind {
            case symbols([SymbolChange])
            case notice(String, large: Bool)
            /// With the commented lines' text for a suggestion's mini diff, while they're still there.
            case comment(ReviewComment, original: [String]?)
            case composer(CommentDraft)
            /// The `@@` row before hunk `gap` (or after the last, with no text), and its expanders.
            case hunkHeader(String, gap: Int, expand: [HunkHeaderRow.Expand], hidden: Int)
            /// An unchanged line an expander revealed.
            case context(DiffLine)
            /// A whitespace-only or moved-only hunk, folded.
            case quiet(h: Int, key: String, text: String, open: Bool, held: Bool)
            case row(h: Int, key: String, DiffRow, held: Bool)
            case bottom
            case gap
        }
        let id: String
        let kind: Kind
    }

    /// The file's rows in order: notice or symbols, comments not under a line, then each hunk's
    /// header, fold and lines with their comments; the card's bottom and the gap to the next file.
    func context(_ file: FileDiff) -> FileContext {
        let path = file.path, shown = shownDiff(file), split = sideBySide(file)
        let gap = FileItem(id: "\(path)#gap", kind: .gap)
        // Symbols, highlights and notes are for the diff against the base.
        let since = showsSinceViewed(path)
        let insight = since ? nil : model.reviews.insights[session.id]?[path]
        // Notes index into snapshot.files: a since-viewed diff shows plain.
        let analysis = since ? nil : model.reviews.analysis[session.id]
        let all = comments(for: path), current = all.filter { !$0.isOutdated }
        var items: [FileItem] = []
        var whitespace = false
        var revealedLines: [DiffLine] = []
        if isCollapsed(file) {
            // The gap only.
        } else if let notice = notice(file, shown: shown) {
            items = [FileItem(id: "\(path)#notice", kind: .notice(notice.text, large: notice.large))]
        } else {
            if let symbols = insight?.symbols, !symbols.isEmpty {
                items.append(FileItem(id: "\(path)#symbols", kind: .symbols(symbols)))
            }
            let gaps = gapRows(file, shown: shown)
            revealedLines = (gaps ?? []).flatMap { $0.down + $0.up }
            let lines = Set(shown.hunks.flatMap { $0.lines.compactMap(\.newNumber) } + revealedLines.compactMap(\.newNumber))
            // Suggestions' commented lines, unless outdated or their first line changed since.
            var text: [Int: String] = [:]
            if current.contains(where: { Suggestion.contains($0.text) }) {
                for line in shown.hunks.flatMap(\.lines) + revealedLines { if let n = line.newNumber { text[n] = line.text } }
            }
            func original(_ c: ReviewComment) -> [String]? {
                guard !c.isOutdated, Suggestion.contains(c.text), text[c.line] == c.quote else { return nil }
                let found = (c.line...c.endLine).compactMap { text[$0] }
                return found.count == c.endLine - c.line + 1 ? found : nil
            }
            // Outdated, or anchored outside what's shown: listed under the header.
            for c in all where c.isOutdated || !lines.contains(c.endLine) {
                items.append(FileItem(id: "\(path)#c\(c.id)", kind: .comment(c, original: original(c))))
            }
            // The comments ending on new-side line n, then the composer if it's there.
            func attach(_ n: Int) {
                for c in current where c.endLine == n {
                    items.append(FileItem(id: "\(path)#c\(c.id)", kind: .comment(c, original: original(c))))
                }
                if let draft, draft.path == path, draft.lines.upperBound == n {
                    items.append(FileItem(id: "\(path)#draft", kind: .composer(draft)))
                }
            }
            func reveal(_ revealed: [DiffLine]) {
                for line in revealed {
                    guard let n = line.newNumber else { continue }
                    items.append(FileItem(id: "\(path)#e\(n)", kind: .context(line)))
                    attach(n)
                }
            }
            for (h, hunk) in shown.hunks.enumerated() {
                let key = "\(path)#\(h)"
                let note = { (i: Int) in analysis?.notes[LineRef(path: path, hunk: h, index: i)] }
                if analysis != nil, !whitespace { whitespace = hunk.lines.indices.contains { note($0) == .formatting } }
                if let gaps {
                    // Fully shown, a gap's row goes and the hunks join, as on GitHub.
                    let gap = gaps[h]
                    reveal(gap.down)
                    if h == 0 || gap.hidden > 0 {
                        items.append(FileItem(id: "\(key)#header", kind: .hunkHeader(
                            hunk.header, gap: h, expand: expanders(h, of: gaps.count, hidden: gap.hidden),
                            hidden: gap.hidden)))
                    }
                    reveal(gap.up)
                } else {
                    items.append(FileItem(id: "\(key)#header", kind: .hunkHeader(hunk.header, gap: h, expand: [], hidden: 0)))
                }
                if let analysis, analysis.quietHunks.contains(key) {
                    let held = holdsComment(path, hunk.lines[...], current)
                    let open = opened.contains(key) || held
                    let notes = hunk.lines.indices.compactMap(note)
                    let text = !notes.contains { $0 != .formatting } ? "Whitespace only"
                        : notes.contains(.formatting) ? "Moved code and whitespace" : "Moved code"
                    items.append(FileItem(id: "\(key)#quiet", kind: .quiet(h: h, key: key, text: text, open: open, held: held)))
                    if !open { continue }
                }
                // The hunk's lines, moved runs folded unless opened or holding a comment.
                let held = { (run: MovedRun) in holdsComment(path, hunk.lines[run.start..<run.start + run.count], current) }
                let prefix = split ? key + "s" : key
                for row in hunk.rows(split: split, note: note, isOpen: { opened.contains("\(key)#m\($0.start)") || held($0) }) {
                    let id = "\(prefix)#\(row.id)"
                    var n: Int?
                    switch row {
                    case let .line(i): n = hunk.lines[i].newNumber
                    case let .pair(_, r): n = r.flatMap { hunk.lines[$0].newNumber }
                    case let .moved(run):
                        items.append(FileItem(id: id, kind: .row(h: h, key: key, row, held: held(run))))
                        continue
                    }
                    items.append(FileItem(id: id, kind: .row(h: h, key: key, row, held: false)))
                    if let n { attach(n) }
                }
            }
            if let gaps, let gap = gaps.last {
                reveal(gap.down)
                if gap.hidden > 0 {
                    items.append(FileItem(id: "\(path)#tail", kind: .hunkHeader(
                        "", gap: gaps.count - 1, expand: [.down], hidden: gap.hidden)))
                }
            }
        }
        if !items.isEmpty { items.append(FileItem(id: "\(path)#bottom", kind: .bottom)) }
        items.append(gap)
        return FileContext(file: file, shown: shown, insight: insight, analysis: analysis,
                           gutter: DiffGutter(status: file.status, lines: shown.hunks.flatMap(\.lines) + revealedLines, whitespace: whitespace),
                           split: split, items: items)
    }

    /// One item's view; every case is a single view (see FileItem).
    @ViewBuilder
    private func itemView(_ item: FileItem, _ c: FileContext, proxy: ScrollViewProxy) -> some View {
        let path = c.file.path
        switch item.kind {
        case let .symbols(symbols):
            SymbolStrip(symbols: symbols) { jump(to: $0, in: c.file, proxy: proxy) }.cardSides(palette)
        case let .notice(text, large):
            HStack(spacing: 8) {
                noticeText(text)
                if large { Button("Show") { expanded.insert(path) }.buttonStyle(.simul(.pill)) }
            }
            .cardSides(palette)
        case let .comment(comment, original):
            ReviewCommentRow(sessionID: session.id, comment: comment, original: original)
                .cardSides(palette)
        case let .composer(draft):
            ReviewComposer(draft: draft, text: draftText, focus: focusDraft,
                           onSuggest: suggestion(c.file, draft.lines).map { block in { suggest(block) } },
                           onQueue: queue, onCancel: endDraft)
                .cardSides(palette)
        case let .hunkHeader(header, g, expand, hidden):
            // Side by side, the expanders sit in the left numbers' column.
            HunkHeaderRow(text: header, gutter: c.split ? c.gutter.badge + (c.gutter.old ?? 0) : c.gutter.width,
                          expand: expand) { expandGap(path, g, $0, hidden: hidden) }
                .cardSides(palette)
        case let .context(line):
            let highlighted = line.newNumber.flatMap { c.insight?.newLines[$0] ?? revealedColours[path]?[$0] }
            Group {
                if c.split {
                    SplitDiffRow(row: SplitRow(left: line, right: line), highlighted: (highlighted, highlighted), marking: followed,
                                 gutter: c.gutter, selected: isSelected(path, line)) { gutter(path, line, $0) }
                } else {
                    DiffLineRow(line: line, highlighted: highlighted, marking: followed, gutter: c.gutter,
                                selected: isSelected(path, line)) { gutter(path, line, $0) }
                }
            }
            .gutterSpot(line, active: dragging == path)
            .cardSides(palette)
        case let .quiet(h, key, text, open, held):
            DiffFoldRow(text: text, open: open, held: held) {
                // Its moved runs open and fold with it.
                guard let analysis = c.analysis else { return }
                let keys = foldKeys(path, h, c.shown.hunks[h], analysis: analysis)
                if opened.contains(key) { opened.subtract(keys) } else { opened.formUnion(keys) }
            }
            .cardSides(palette)
        case let .row(h, key, row, held):
            rowView(row, h: h, key: key, held: held, c, proxy: proxy)
                .gutterSpot(spotLine(row, c.shown.hunks[h]), active: dragging == path)
                .cardSides(palette)
        case .bottom:
            CardBottom()
                .fill(palette.code)
                .overlay(CardBottom().stroke(palette.cardBorder, lineWidth: 1))
                .frame(height: Self.radius + 1)
        case .gap:
            Color.clear.frame(height: 10)  // between files
        }
    }

    @ViewBuilder
    private func rowView(_ row: DiffRow, h: Int, key: String, held: Bool, _ c: FileContext,
                         proxy: ScrollViewProxy) -> some View {
        let path = c.file.path, hunk = c.shown.hunks[h], insight = c.insight
        let note = { (i: Int) in c.analysis?.notes[LineRef(path: path, hunk: h, index: i)] }
        let current = cursor == ReviewCursor(path: path, hunk: h)
        switch row {
        case let .line(i):
            let line = hunk.lines[i]
            let highlighted = line.kind == .removed ? line.oldNumber.flatMap { insight?.oldLines[$0] }
                                                    : line.newNumber.flatMap { insight?.newLines[$0] }
            DiffLineRow(line: line, highlighted: highlighted, marking: followed, gutter: c.gutter,
                        selected: isSelected(path, line), formatting: note(i) == .formatting, current: current) {
                gutter(path, line, $0)
            }
        case let .pair(l, r):
            let row = SplitRow(left: l.map { hunk.lines[$0] }, right: r.map { hunk.lines[$0] })
            // Context lines are highlighted once, on the new side.
            let highlighted = (row.left.flatMap { $0.kind == .context ? $0.newNumber.flatMap { insight?.newLines[$0] }
                                                                       : $0.oldNumber.flatMap { insight?.oldLines[$0] } },
                               row.right?.newNumber.flatMap { insight?.newLines[$0] })
            SplitDiffRow(row: row, highlighted: highlighted, marking: followed, gutter: c.gutter,
                         selected: row.right.map { isSelected(path, $0) } ?? false,
                         formatting: (l.flatMap(note) == .formatting, r.flatMap(note) == .formatting),
                         current: current) {
                if let line = row.right { gutter(path, line, $0) }
            }
        case let .moved(run):
            let runKey = "\(key)#m\(run.start)"
            let ref = LineRef(path: path, hunk: h, index: run.start)
            let (verb, place, side): (String, String, DiffFoldRow.Side) = switch run.note {
            case let .movedFrom(path, line): ("from", "\(path):\(line)", .right)
            case let .movedTo(path, line): ("to", "\(path):\(line)", .left)
            case .formatting: ("", "", .left)  // never: formatting isn't folded
            }
            DiffFoldRow(text: "\(run.count) lines moved \(verb)", link: place, open: opened.contains(runKey) || held,
                        held: held, side: c.split ? side : nil) { toggle(runKey) } onLink: {
                if let analysis = c.analysis { jump(from: ref, analysis: analysis, proxy: proxy) }
            }
        }
    }

    private func fileHeader(_ file: FileDiff) -> some View {
        let reviews = model.reviews, id = session.id, path = file.path
        return FileHeader(file: file, root: snapshot.root, collapsed: isCollapsed(file),
                          viewed: snapshot.hashes[path] == nil ? nil : reviews.isViewed(id, path: path),
                          comments: comments(for: path).count, concern: concernBadge(path),
                          sinceViewed: reviews.changedSinceViewed(id, path: path) ? sinceViewed[path] != nil : nil,
                          onToggle: { flip(path) },
                          onViewed: { viewed in
                              if flipped.contains(path) { flipped.remove(path) }  // viewed collapses, unviewed opens
                              reviews.setViewed(id, path: path, viewed)
                          },
                          onSinceViewed: { toggleSinceViewed(path, $0) },
                          onAll: { open in
                              // Flipped is what differs from the default: viewed files collapsed, the rest open.
                              let all = Set(snapshot.files.filter { reviews.isViewed(id, path: $0.path) == open }.map(\.path))
                              if flipped != all { flipped = all }
                          })
    }

    /// The overview's open concerns anchored in the file: "1 high", or "3 concerns" in the highest's colours.
    private func concernBadge(_ path: String) -> (text: String, severity: AgentOverview.Severity)? {
        guard let o = model.reviews.overview(session.id) else { return nil }
        let open = o.concerns.indices.filter { !o.dismissed.contains($0) && o.concerns[$0].at.contains { $0.path == path } }
            .map { o.concerns[$0].severity }
        guard let top = AgentOverview.Severity.allCases.first(where: open.contains) else { return nil }
        return (open.count == 1 ? "1 \(top.rawValue)" : "\(open.count) concerns", top)
    }

    func isCollapsed(_ file: FileDiff) -> Bool {
        model.reviews.isViewed(session.id, path: file.path) != flipped.contains(file.path)
    }

    func flip(_ path: String) {
        if flipped.contains(path) { flipped.remove(path) } else { flipped.insert(path) }
    }

    /// One line instead of the hunks: binary, large (with a Show button) or empty.
    func notice(_ file: FileDiff, shown: FileDiff) -> (text: String, large: Bool)? {
        if file.isBinary { return ("Binary file", false) }
        if shown == file, model.reviews.changedSinceViewed(session.id, path: file.path),
           sinceViewed[file.path] == .unavailable {
            return ("Viewed copy unavailable", false)
        }
        if shown.hunks.isEmpty {
            return (shown == file ? "No content changes" : "No changes since viewed", false)
        }
        if shown.lineCount > Self.largeDiff, !expanded.contains(file.path) {
            return ("Large diff — \(shown.lineCount) lines", true)
        }
        return nil
    }

    private func noticeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    // MARK: - Helpers

    /// Added and deleted files have one side only: one column, as on GitHub.
    func sideBySide(_ file: FileDiff) -> Bool {
        split && (file.status == .modified || file.status == .renamed)
    }

    func showsSinceViewed(_ path: String) -> Bool {
        guard case .diff? = sinceViewed[path] else { return false }
        return model.reviews.changedSinceViewed(session.id, path: path)
    }

    func shownDiff(_ file: FileDiff) -> FileDiff {
        guard model.reviews.changedSinceViewed(session.id, path: file.path) else { return file }
        if case let .diff(diff)? = sinceViewed[file.path] { return diff }
        return file
    }

    /// The file's comments still worth showing (resolved ones are done).
    func comments(for path: String) -> [ReviewComment] {
        (model.reviews.states[session.id]?.current.comments ?? []).filter { $0.path == path && $0.state != .resolved }
    }

    private func toggleSinceViewed(_ path: String, _ on: Bool) {
        // The cursor's hunk numbers are the other diff's.
        if let cursor, cursor.path == path, cursor.hunk != -1 { self.cursor = ReviewCursor(path: path, hunk: -1) }
        guard on else {
            sinceViewed[path] = nil
            return
        }
        sinceViewed[path] = .loading
        Task {
            let diff = await model.reviews.sinceViewedDiff(session.id, path: path)
            guard sinceViewed[path] == .loading else { return }  // switched off meanwhile
            sinceViewed[path] = diff.map { .diff($0) } ?? .unavailable
        }
    }

    func isSelected(_ path: String, _ line: DiffLine) -> Bool {
        guard let draft, draft.path == path, let n = line.newNumber else { return false }
        return draft.lines.contains(n)
    }

    /// Comments anchor to new-side lines, so removed lines can't take one: false for those.
    @discardableResult
    func gutterTapped(_ path: String, _ line: DiffLine, extend: Bool) -> Bool {
        guard let n = line.newNumber else { return false }
        if extend, let d = draft, d.path == path {
            let low = min(d.anchor, n), lines = low...max(d.anchor, n)
            if lines != d.lines { resize(d, to: lines, quote: low == n ? line.text : d.anchorText) }
        } else {
            draft = CommentDraft(path: path, anchor: n, anchorText: line.text, lines: n...n, quote: line.text, text: "")
        }
        return true
    }

    /// The draft's text lives here, so it survives the composer moving rows.
    private var draftText: Binding<String> {
        Binding(get: { draft?.text ?? "" }, set: { if draft?.text != $0 { draft?.text = $0 } })
    }

    func queue(_ text: String) {
        guard let draft else { return }
        model.reviews.addComment(session.id, path: draft.path, lines: draft.lines, quote: draft.quote, text: text)
        endDraft()
    }

    private func endDraft() {
        draft = nil
    }
}

/// A file card's rounded bottom: its sides and bottom edge, open at the top
/// where the rows above continue it.
private struct CardBottom: Shape {
    func path(in rect: CGRect) -> Path {
        // The stroke's centre line, as the header's strokeBorder draws it: half a point in, radius − ½.
        let rect = CGRect(x: rect.minX + 0.5, y: rect.minY, width: rect.width - 1, height: rect.height - 0.5)
        let r = ReviewDiffView.radius - 0.5
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private extension View {
    /// A row inside a file card: the code background, with the card's side borders
    /// (as an inset over the border colour: overlays cost each row a layout while scrolling).
    func cardSides(_ palette: ReviewPalette) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.code)
            .padding(.horizontal, 1)
            .background(palette.cardBorder)
    }
}
