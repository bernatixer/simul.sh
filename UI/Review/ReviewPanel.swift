import AppKit
import Combine
import SwiftUI

/// The review, in place of the terminal: what changed in the session's
/// folder against a base, with viewed marks and comments for the agent.
/// All data comes from ReviewCenter; git runs only from user actions.
struct ReviewPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    @State private var baseText = ""
    @State private var editingBase = false
    @FocusState private var baseFocused: Bool
    @State private var choosingSource = false
    /// The repo's worktrees, as the picker last listed them (names a worktree source in the pill).
    @State private var worktrees: [Worktree] = []
    /// The name clicked in the diff, and whether its uses are listed in the drawer.
    @State private var followed: String?
    @State private var listingUses = false
    @State private var jumpTo: NameUse?
    /// The diff's files showing their changes since viewed.
    @State private var sinceViewed: [String: ReviewDiffView.SinceViewed] = [:]
    /// The PR the Submit sheet is open for (kept, so a refresh can't close it).
    @State private var submitting: PullRequest?
    @AppStorage(Preferences.Key.reviewSplit) private var split = true
    @AppStorage(Preferences.Key.reviewLight) private var light = false
    @AppStorage(Preferences.Key.reviewTree) private var showTree = true
    /// The tree's filter; it filters the diff too.
    @State private var filter = ""
    /// The tree in the agent's layers (when it sent some), the diff in their order.
    @State private var layered = true
    @State private var showOverview = true
    @State private var focus = ReviewFocus()
    /// Keyboard review: the key-down monitor, the ? card, the concern ⌥↓ / ⌥↑ last went to.
    @State private var keyMonitor: Any?
    @State private var showKeys = false
    @State private var concern: Int?

    private var reviews: ReviewCenter { model.reviews }
    private var scheme: ColorScheme { light ? .light : .dark }
    private var palette: ReviewPalette { ReviewPalette(light: light) }
    private var state: ReviewState? { reviews.states[session.id] }
    private var snapshot: ReviewSnapshot? { reviews.snapshots[session.id] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.divider).frame(height: 1)
            if let issue = reviews.draftErrors[session.id] {
                draftProblem(issue.banner)
                Rectangle().fill(palette.divider).frame(height: 1)
            }
            content
        }
        .background(palette.panel)
        .sheet(item: $submitting) { pr in
            SubmitReviewSheet(session: session, pullRequest: pr) { submitting = nil }
                .preferredColorScheme(scheme)
        }
        // Only the review: its views read the palette from this, and system text and controls follow.
        .environment(\.colorScheme, scheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: light)
        .onAppear {
            syncBaseText()
            installKeys()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulDevCommand)) { devCommand($0.object as? String ?? "") }
        // Each source has its own base, files and names: don't carry one source's to another.
        .onChange(of: state?.source) {
            syncBaseText()
            if !sinceViewed.isEmpty { sinceViewed = [:] }
            if followed != nil { followed = nil }
            if listingUses { listingUses = false }
            if !filter.isEmpty { filter = "" }
        }
        // A worktree source's pill shows its branch.
        .task(id: state?.source) {
            guard case .folder = state?.source, !worktrees.contains(where: { .folder($0.path) == state?.source }) else { return }
            let trees = await reviews.worktrees(for: session.id)
            if worktrees != trees { worktrees = trees }
        }
    }

    /// Files whose since-viewed diff is on screen (loaded, and the file changed since).
    private var showingSinceViewed: Set<String> {
        Set(sinceViewed.filter { path, shown in
            guard case .diff = shown else { return false }
            return reviews.changedSinceViewed(session.id, path: path)
        }.keys)
    }

    // MARK: - Header

    /// One row, as GitHub's: the tree and overview toggles, progress and summary on the left;
    /// settings, base, source (and a PR's title), refresh and the actions on the right.
    private var header: some View {
        HStack(spacing: 8) {
            if let snapshot, !snapshot.files.isEmpty {
                toggle("sidebar.left", on: showTree, help: showTree ? "Hide file tree" : "Show file tree") {
                    showTree.toggle()
                }
                if reviews.overview(session.id) != nil {
                    toggle("text.magnifyingglass", "Overview", on: showOverview,
                           help: showOverview ? "Hide the agent's overview" : "Show the agent's overview") {
                        showOverview.toggle()
                    }
                }
                progress(snapshot)
            }
            if reviews.loading.contains(session.id) {
                Text("Loading…").foregroundStyle(palette.secondaryText).fixedSize()
            }
            Spacer(minLength: 8)
            settings
            basePill
            sourcePill
            pullRequestTitle
            Button { Task { await reviews.refresh(session) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.primer())
            .help("Refresh")
            actions
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A toolbar toggle: a Primer button, pressed-looking while on.
    private func toggle(_ icon: String, _ title: String? = nil, on: Bool, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(on ? palette.text : palette.secondaryText)
                if let title { Text(title) }
            }
        }
        .buttonStyle(.primer())
        .overlay(RoundedRectangle(cornerRadius: 6).fill(on ? palette.ink.opacity(0.05) : .clear).allowsHitTesting(false))
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The gear: Split / Unified and Light / Dark (both remembered).
    private var settings: some View {
        Menu {
            Picker("Layout", selection: Binding(get: { split }, set: { if split != $0 { split = $0 } })) {
                Text("Split").tag(true)
                Text("Unified").tag(false)
            }
            .pickerStyle(.inline)
            Picker("Colours", selection: Binding(get: { light }, set: { if light != $0 { light = $0 } })) {
                Text("Light").tag(true)
                Text("Dark").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.buttonFill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.buttonBorder, lineWidth: 1))
        .help("Diff layout and colours")
    }

    /// Ask agent to review; Send to agent; on a PR, Submit review (the green one) — else Send is.
    @ViewBuilder
    private var actions: some View {
        let count = reviews.queued(session.id).count
        let live = model.hostCenter.hasHost(for: session.id)
        Button("Ask agent to review", action: askReview)
            .buttonStyle(.primer())
            .disabled(!live || snapshot == nil)
            .help(live ? "Paste a request for the agent to review these changes and draft comments" : "Start the session to ask")
        let pr = snapshot == nil ? nil : reviews.currentPullRequest(session.id)
        Button("Send to agent (\(count))") {
            // Back to the agent (which takes the keyboard) to see them land.
            if reviews.sendQueued(session, host: model.hostCenter.host(for: session)) { reviews.hide() }
        }
        .buttonStyle(.primer(primary: pr == nil))
        .disabled(count == 0 || !live)
        .help(live ? "Paste the queued comments into the terminal" : "Start the session to send")
        if let pr {
            Button("Submit review") { submitting = pr }
                .buttonStyle(.primer(primary: true))
                .help("Post the queued comments as a review of PR #\(pr.number) on GitHub")
        }
    }

    private var basePill: some View {
        Button {
            syncBaseText()
            editingBase = true
        } label: {
            pillLabel(icon: "arrow.triangle.branch", Self.short(state?.current.base ?? snapshot?.base ?? "auto"))
        }
        .buttonStyle(.primer())
        .help("Base: what the changes are compared against")
        .popover(isPresented: $editingBase, arrowEdge: .bottom) {
            // As GitHub's SelectPanel: a title, a divider, then the field.
            VStack(alignment: .leading, spacing: 0) {
                Text("Compare against")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Rectangle().fill(palette.cardBorder).frame(height: 1)
                HStack(spacing: 6) {
                    TextField(snapshot?.base ?? "auto", text: $baseText)
                        .simulField()
                        .frame(width: 200)
                        .focused($baseFocused)
                        .onSubmit {
                            submitBase()
                            editingBase = false
                        }
                    Button("Auto") {
                        baseText = ""
                        reviews.setBase(session.id, nil)
                        editingBase = false
                    }
                    .buttonStyle(.primer())
                    .disabled(state?.current.base == nil)
                    .help("The pull request's target, else the default branch")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Text("A branch, tag or commit. ↩ applies.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.text)
            .presentationBackground(palette.panel)
            .preferredColorScheme(scheme)
            .onAppear { DispatchQueue.main.async { baseFocused = true } }  // a popover takes focus a beat later
        }
    }

    /// What the review looks at: the session folder, a worktree, a folder or a PR.
    private var sourcePill: some View {
        Button { choosingSource = true } label: {
            pillLabel(icon: sourceIcon, sourceLabel)
        }
        .buttonStyle(.primer())
        .help(folder)
        .popover(isPresented: $choosingSource, arrowEdge: .bottom) {
            SourcePicker(session: session, worktrees: $worktrees, chooseFolder: chooseFolder) { choosingSource = false }
                .presentationBackground(palette.panel)
                .preferredColorScheme(scheme)
        }
    }

    /// The PR's title, opening it in the browser.
    @ViewBuilder
    private var pullRequestTitle: some View {
        if let pr = reviews.currentPullRequest(session.id), let url = URL(string: pr.url), url.scheme == "https", url.host == "github.com" {
            Button { NSWorkspace.shared.open(url) } label: {
                Text(verbatim: pr.title).foregroundStyle(palette.secondaryText).truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 200, alignment: .leading)
            .layoutPriority(-1)
            .help("Open on GitHub: \(pr.url)")
        }
    }

    private var sourceIcon: String {
        switch state?.source ?? .sessionFolder {
        case .pullRequest: "arrow.triangle.pull"
        case .folder where branch != nil: "arrow.triangle.branch"
        default: "folder"
        }
    }

    /// "PR #123", a worktree's branch, else the folder's name.
    private var sourceLabel: String {
        if case let .pullRequest(_, number) = state?.source { return "PR #\(number)" }
        return branch ?? URL(fileURLWithPath: folder).lastPathComponent
    }

    /// The branch of the worktree a folder source is.
    private var branch: String? {
        guard case let .folder(path) = state?.source else { return nil }
        return worktrees.first { $0.path == path }?.branch
    }

    /// A dropdown button's label, as GitHub's: icon, text (hugged, truncated from the head
    /// when squeezed, so a path keeps its end) and a ▾.
    private func pillLabel(icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(palette.secondaryText)
            Text(verbatim: text).truncationMode(.head)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(palette.secondaryText)
        }
    }

    /// A commit id as git abbreviates it; names as they are.
    static func short(_ ref: String) -> String {
        ref.count >= 20 && ref.allSatisfy(\.isHexDigit) ? String(ref.prefix(8)) : ref
    }

    private var folder: String {
        if case let .folder(path) = state?.source { return path }
        return snapshot?.root ?? session.workingDirectory
    }

    /// The base field shows the current source's base.
    private func syncBaseText() {
        let base = state?.current.base ?? ""
        if baseText != base { baseText = base }
    }

    private func submitBase() {
        let base = baseText.trimmingCharacters(in: .whitespaces)
        reviews.setBase(session.id, base.isEmpty ? nil : base)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reviews.setSource(session.id, .folder(url.path))
    }

    /// "V / N viewed" with a ring, the summary (lines changed · moved · whitespace ·
    /// functions changed), then the lines in files not yet viewed.
    private func progress(_ snapshot: ReviewSnapshot) -> some View {
        let left = snapshot.files.filter { !reviews.isViewed(session.id, path: $0.path) }
        let viewed = snapshot.files.count - left.count
        let roll: Animation? = reduceMotion ? nil : .snappy(duration: 0.25)
        let functions = (reviews.insights[session.id] ?? [:]).values.reduce(0) { n, insight in
            n + insight.symbols.filter { $0.kind != .formatting }.count
        }
        let summary = [reviews.analysis[session.id]?.summary(snapshot.files) ?? "",
                       functions == 0 ? "" : "\(functions) function\(functions == 1 ? "" : "s") changed"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(viewed) / CGFloat(snapshot.files.count))
                    .stroke(palette.addedText, lineWidth: 2)
                    .rotationEffect(.degrees(-90))
                    .animation(roll, value: viewed)
            }
            .frame(width: 12, height: 12)
            Text("\(viewed) / \(snapshot.files.count) viewed").foregroundStyle(palette.secondaryText)
                .contentTransition(.numericText(value: Double(viewed)))
                .animation(roll, value: viewed)
            }
            .fixedSize()
            DiffStatBar(added: left.reduce(0) { $0 + $1.added }, removed: left.reduce(0) { $0 + $1.removed })
                .help("Lines left to review")
                .padding(.leading, 4)
            if !summary.isEmpty {
                Text(summary).foregroundStyle(palette.secondaryText).truncationMode(.tail).padding(.leading, 4)
                    .help(summary)
            }
        }
        .layoutPriority(-1)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = reviews.errors[session.id] {
            message(error)
        } else if let snapshot {
            if snapshot.files.isEmpty {
                message("No changes against \(snapshot.base)")
            } else {
                let (shown, groups) = arranged(snapshot)
                HStack(spacing: 0) {
                    if showTree {
                        FileTreeView(session: session, files: shown, groups: groups,
                                     canLayer: reviews.overview(session.id)?.layers.isEmpty == false,
                                     layered: $layered, filter: $filter, focus: focus)
                        Rectangle().fill(palette.divider).frame(width: 1)
                    }
                    GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Pinned above the files: it doesn't scroll with them.
                        if showOverview, let overview = reviews.overview(session.id) {
                            OverviewPane(session: session, snapshot: snapshot, overview: overview, maxHeight: geo.size.height * 0.65,
                                         onJump: { jump($0) },
                                         onAskAgain: model.hostCenter.hasHost(for: session.id) ? { askReview() } : nil)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .layoutPriority(1)
                        }
                        files(snapshot, shown)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showKeys {
                            ReviewKeysHelp { showKeys = false }
                                .padding(16)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showKeys)
                    }
                }
            }
        } else {
            message("Loading…")
        }
    }

    /// The diff, and the followed name's uses beside it.
    private func files(_ snapshot: ReviewSnapshot, _ shown: [FileDiff]) -> some View {
        HStack(spacing: 0) {
            ReviewDiffView(session: session, snapshot: snapshot, files: shown, focus: focus,
                           followed: $followed, listingUses: $listingUses,
                           jumpTo: $jumpTo, editingBase: editingBase, sinceViewed: $sinceViewed)
            // The diff narrows beside it; closing it keeps the name marked.
            if listingUses, let followed {
                Rectangle().fill(palette.divider).frame(width: 1)
                NameUsesList(name: followed, session: session, snapshot: snapshot,
                             sinceViewed: showingSinceViewed) { go(to: $0) } onClose: {
                    listingUses = false
                } onClear: {
                    self.followed = nil
                    listingUses = false
                }
            }
        }
    }

    /// The files to show, filtered, in the tree's order, or the layers' with their groups.
    private func arranged(_ snapshot: ReviewSnapshot) -> ([FileDiff], [(layer: AgentOverview.Layer?, paths: [String])]?) {
        let byPath = Dictionary(snapshot.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let order = FileTree.order(snapshot.files.map(\.path))
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let keep = { (path: String) in query.isEmpty || path.lowercased().contains(query) }
        if layered, let overview = reviews.overview(session.id), !overview.layers.isEmpty {
            let groups = overview.fileOrder(diffPaths: order).map { ($0.layer, $0.paths.filter(keep)) }.filter { !$0.1.isEmpty }
            return (groups.flatMap(\.1).compactMap { byPath[$0] }, groups)
        }
        return (order.filter(keep).compactMap { byPath[$0] }, nil)
    }

    /// DevHooks' view commands: "filter <text>", "layers on|off", "overview", "jump <path> <line>".
    private func devCommand(_ line: String) {
        let words = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "filter": filter = words.count > 1 ? words[1] : ""
        case "layers": layered = words.last == "on"
        case "overview": showOverview.toggle()
        case "jump":
            let w = line.split(separator: " ").map(String.init)
            if w.count == 3, let n = Int(w[2]) { go(to: NameUse(path: w[1], line: n, text: "")) }
        case "key": if words.count > 1 { _ = press(words[1]) }
        default: break
        }
    }

    // MARK: - Keys

    /// One monitor while the panel is mounted; it acts only while the review shows (ReviewKeys).
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard model.reviews.isShowing(session.id), let key = ReviewKeys.key(for: event) else { return false }
                // Held down, v would mark file after file viewed: toggles take one press each.
                if event.isARepeat, ReviewKeys.once.contains(key) { return true }
                return press(key)
            }
            return handled ? nil : event
        }
    }

    /// ? and Esc for the card, ⌥↓ / ⌥↑ for concerns here; the diff's keys go to the diff.
    private func press(_ key: String) -> Bool {
        switch key {
        case "?": showKeys.toggle()
        case "esc":
            guard showKeys else { return false }
            showKeys = false
        case "⌥↓", "⌥↑": nextConcern(forward: key == "⌥↓")
        default:
            guard snapshot?.files.isEmpty == false else { return false }
            NotificationCenter.default.post(name: .simulReviewKey, object: key)
        }
        return true
    }

    /// Jumps to the next (previous) open concern whose code is still there.
    private func nextConcern(forward: Bool) {
        guard let o = reviews.overview(session.id) else { return }
        let target = { (i: Int) in o.concerns[i].at.first { reviews.overviewAnchorHolds(session.id, $0) } }
        let open = o.concerns.indices.filter { !o.dismissed.contains($0) && target($0) != nil }
        guard let next = forward ? open.first(where: { $0 > concern ?? -1 }) : open.last(where: { $0 < concern ?? .max }),
              let anchor = target(next) else { return }
        concern = next
        jump(anchor)
    }

    /// Scrolls the diff to an overview anchor (ReviewDiffView's jump to a name use).
    private func jump(_ anchor: AgentOverview.Anchor) {
        go(to: NameUse(path: anchor.path, line: anchor.line, text: ""))
    }

    /// Scrolls the diff to `use`; a file the filter hides clears the filter first, and the
    /// diff gets the jump once it lists the file again.
    private func go(to use: NameUse) {
        guard let snapshot, !filter.isEmpty, !arranged(snapshot).0.contains(where: { $0.path == use.path }) else {
            return jumpTo = use
        }
        filter = ""
        DispatchQueue.main.async { jumpTo = use }
    }

    private func askReview() {
        if reviews.askAgentToReview(session, host: model.hostCenter.host(for: session)) { reviews.hide() }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Some or all of the agent's review file couldn't be imported: say why, and let the agent fix it.
    private func draftProblem(_ problem: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(palette.removedText)
            Text(problem).foregroundStyle(palette.secondaryText)
            Spacer(minLength: 8)
            Button("Ask agent to fix") {
                if reviews.askAgentToFixReview(session, host: model.hostCenter.host(for: session)) { reviews.hide() }
            }
            .buttonStyle(.simul(.pill))
            .disabled(!model.hostCenter.hasHost(for: session.id))
        }
        .font(.system(size: 12))
        .lineLimit(2)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
