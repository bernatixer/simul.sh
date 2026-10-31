import Foundation
import Observation

/// Review panel state: per-session diff snapshots (not saved) and review
/// state (viewed marks, comments; saved through ReviewStore).
@MainActor
@Observable
final class ReviewCenter {
    /// Review open (mounted, keeping its state) for this session; nil = closed.
    private(set) var openFor: Session.ID?
    /// The open review is on screen (Review), not hidden under the terminal (Agent).
    private(set) var showing = false
    private(set) var snapshots: [Session.ID: ReviewSnapshot] = [:]
    /// Moves and formatting in `snapshots[id].files`, published with it.
    private(set) var analysis: [Session.ID: DiffAnalysis] = [:]
    /// Symbols and highlights by path for `snapshots[id]`, published with it.
    private(set) var insights: [Session.ID: [String: FileInsight]] = [:]
    private(set) var errors: [Session.ID: String] = [:]
    private(set) var loading: Set<Session.ID> = []
    private(set) var states: [Session.ID: ReviewState]
    /// The pull request a PR source last resolved to, for the header.
    private(set) var pullRequest: [Session.ID: PullRequest] = [:]
    /// What in the agent's review file couldn't be imported (ReviewCenter+Drafts).
    var draftErrors: [Session.ID: AgentDrafts.Issue] = [:]
    /// Claude's transcript id for a session (nil for other agents), to find the folder it works in. Set by AppModel.
    @ObservationIgnored var transcriptID: @MainActor (Session) -> String? = { _ in nil }
    /// The session's agent is mid-turn (AppModel.isWorking); unknown counts as working. Set by AppModel.
    @ObservationIgnored var isWorking: @MainActor (Session.ID) -> Bool = { _ in true }

    @ObservationIgnored private let resolver: ExecutableResolver
    @ObservationIgnored private let store: ReviewStore
    /// Serial, so saves land in order and snapshot copies before prunes.
    @ObservationIgnored private let disk = DispatchQueue(label: "sh.simul.reviews", qos: .utility)
    @ObservationIgnored private let analyzer = ReviewInsights()
    /// The session the panel was last opened for (turnEnded needs its folder).
    @ObservationIgnored private(set) var openSession: Session?
    /// A turn ended while the review was hidden: refresh when it shows again.
    @ObservationIgnored private var stale = false
    /// Refreshes asked for while one was running; each runs once more after it.
    @ObservationIgnored private var pending: Set<Session.ID> = []
    /// What the prompt calls the last loaded source; absent for the session folder.
    @ObservationIgnored private(set) var sourceNames: [Session.ID: String] = [:]

    init(resolver: ExecutableResolver, store: ReviewStore = ReviewStore()) {
        self.resolver = resolver
        self.store = store
        states = store.load()
    }

    // MARK: - Panel

    /// The review is on screen for this session.
    func isShowing(_ id: Session.ID) -> Bool { showing && openFor == id }

    /// Agent ⇄ Review (⇧⌘R).
    func toggle(_ session: Session) {
        if isShowing(session.id) { hide() } else { show(session) }
    }

    /// Opens the review, or brings back the hidden one; git runs only if it
    /// is new or a turn ended while it was hidden.
    func show(_ session: Session) {
        if !showing { showing = true }
        analyzer.prewarm()
        guard openFor != session.id || stale else { return }
        let opening = openFor != session.id
        openFor = session.id
        openSession = session
        stale = false
        Task {
            if opening { await followAgent(session) }
            await refresh(session)
        }
    }

    /// Back to the agent; the review keeps its state underneath.
    func hide() {
        if showing { showing = false }
    }

    func close() {
        if openFor != nil { openFor = nil }
        if !snapshots.isEmpty { snapshots = [:] }
        if !analysis.isEmpty { analysis = [:] }
        if !insights.isEmpty { insights = [:] }
        sourceNames = [:]
        analyzer.clear()
        stale = false
        hide()
    }

    func turnEnded(_ id: Session.ID) {
        guard openFor == id else { return }
        if showing { refreshOpen(id) } else { stale = true }
    }

    func refresh(_ session: Session) async {
        let id = session.id
        guard !loading.contains(id) else {
            pending.insert(id)  // folder/base may have changed: run again after this one
            return
        }
        loading.insert(id)
        defer { loading.remove(id) }
        repeat { await load(session) } while pending.remove(id) != nil
    }

    private func load(_ session: Session) async {
        let id = session.id
        guard let git = await makeGit() else {
            setError(id, "git not found")
            return
        }
        let state = states[id] ?? ReviewState()
        let loaded = state.source, current = state.current
        if let pr = pullRequest[id], ReviewSource.pullRequest(repo: pr.baseRepo, number: pr.number) != loaded { pullRequest[id] = nil }
        let target: ResolvedSource, snapshot: ReviewSnapshot
        do {
            target = try await resolve(loaded, session, git)
            snapshot = try await git.snapshot(folder: target.folder, baseOverride: current.base ?? target.base)
        } catch {
            guard ReviewState.isCurrent(states[id], loaded) else { return }  // switched meanwhile: the pending reload shows the new one
            switch error as? ReviewGitError {
            case let .notARepository(path): setError(id, "Not a git repository: \(path)")
            case let .gitFailed(message): setError(id, message)
            case nil: setError(id, String(describing: error))
            }
            dropLoaded(id)
            return
        }
        // Parsing only while on screen; hidden, it runs when the review shows again.
        let parse = isShowing(id)
        if !parse, openFor == id { stale = true }
        let (found, fileInsights, changed) = await analyzer.analyze(snapshot, git: git, parse: parse, for: id)

        // Re-anchor comments against the files as they are now.
        var anchored = current.comments
        let deleted = Set(snapshot.files.filter { $0.status == .deleted }.map(\.path))
        for path in Set(anchored.map(\.path)) {
            let lines = deleted.contains(path) ? [] : await git.fileLines(root: snapshot.root, path: path)
            anchored = ReviewAnchoring.reanchor(anchored, path: path, lines: lines)
        }
        let byID = Dictionary(anchored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Another source was picked meanwhile: don't show this one; the pending reload runs.
        guard ReviewState.isCurrent(states[id], loaded) else { return }
        if let pr = target.pullRequest, pullRequest[id] != pr { pullRequest[id] = pr }
        // Closed while analyzing: close() already dropped these; don't bring them back.
        let isOpen = openFor == id
        sourceNames[id] = isOpen ? target.name : nil
        if snapshots[id] != (isOpen ? snapshot : nil) { snapshots[id] = isOpen ? snapshot : nil }
        if analysis[id] != (isOpen ? found : nil) { analysis[id] = isOpen ? found : nil }
        // `changed` was decided off the main actor: comparing highlights here takes up to a second.
        if isOpen ? (changed || insights[id] == nil) : insights[id] != nil { insights[id] = isOpen ? fileInsights : nil }
        if errors[id] != nil { errors[id] = nil }
        // Re-read: comments may have changed during the awaits.
        update(id) { state in
            state[loaded].comments = state[loaded].comments.map { comment in
                guard let a = byID[comment.id] else { return comment }
                var c = comment
                c.line = a.line
                c.endLine = a.endLine
                c.isOutdated = a.isOutdated
                return c
            }
            let paths = Set(snapshot.files.map(\.path))
            state[loaded].viewed = state[loaded].viewed.filter { paths.contains($0.key) }
        }
        let keep = Set(states.values.flatMap { $0.sources.values.flatMap { $0.viewed.values.map(\.hash) } })
        let store = store
        disk.async { store.pruneSnapshots(keeping: keep) }
        await importDrafts(id, source: loaded, snapshot: snapshot)
    }

    // MARK: - Viewed

    func isViewed(_ id: Session.ID, path: String) -> Bool {
        guard let mark = states[id]?.current.viewed[path] else { return false }
        return mark.hash == snapshots[id]?.hashes[path]
    }

    func changedSinceViewed(_ id: Session.ID, path: String) -> Bool {
        guard let mark = states[id]?.current.viewed[path] else { return false }
        return mark.hash != snapshots[id]?.hashes[path]
    }

    func setViewed(_ id: Session.ID, path: String, _ viewed: Bool) {
        guard viewed else {
            update(id) { $0.current.viewed[path] = nil }
            return
        }
        guard let snapshot = snapshots[id], let hash = snapshot.hashes[path] else { return }
        update(id) { $0.current.viewed[path] = ViewedMark(hash: hash, viewedAt: Date()) }
        let file = URL(fileURLWithPath: snapshot.root + "/" + path)
        let store = store
        disk.async { _ = store.keepViewedContent(of: file, hash: hash) }
    }

    /// The file's changes since it was marked viewed: the kept copy against
    /// the working copy (no hunks if none). nil if there is no mark or kept copy.
    func sinceViewedDiff(_ id: Session.ID, path: String) async -> FileDiff? {
        guard let hash = states[id]?.current.viewed[path]?.hash, let root = snapshots[id]?.root else { return nil }
        let store = store
        // On the disk queue, so it lands after the copy setViewed queued.
        let kept: URL? = await withCheckedContinuation { cont in
            disk.async { cont.resume(returning: store.viewedContent(hash: hash)) }
        }
        guard let kept, let git = await makeGit() else { return nil }
        return await git.diffSince(viewedContent: kept, root: root, path: path).first
            ?? FileDiff(path: path, oldPath: nil, status: .modified, isBinary: false, hunks: [])
    }

    // MARK: - Names

    /// Other lines in the repo using `name` (not the ones the diff adds); none unless the review is showing.
    func uses(of name: String, in id: Session.ID) async -> (uses: [NameUse], more: Bool) {
        guard isShowing(id), let snapshot = snapshots[id], let git = await makeGit() else { return ([], false) }
        return await git.uses(of: name, root: snapshot.root, files: snapshot.files)
    }

    /// Up to `radius` working-copy lines either side of `line` (1-based) in `path`.
    func lines(around line: Int, path: String, in id: Session.ID, radius: Int = 3) async -> [NameUse] {
        guard let root = snapshots[id]?.root, let git = await makeGit() else { return [] }
        let lines = await git.fileLines(root: root, path: path)
        let low = max(1, line - radius), high = min(lines.count, line + radius)
        guard low <= high else { return [] }  // file got shorter
        return (low...high).map { NameUse(path: path, line: $0, text: lines[$0 - 1]) }
    }

    /// The file's working-copy lines (the diff's new side), for the hunk expanders; nil if unreadable
    /// or no longer the snapshot's (`hash`, its git blob id): agents keep editing.
    func newSideLines(_ id: Session.ID, path: String, hash: String) async -> [String]? {
        guard let root = snapshots[id]?.root, let git = await makeGit() else { return nil }
        var lines = await git.fileLines(root: root, path: path)
        guard !lines.isEmpty, ReviewGit.blobID(Data(lines.joined(separator: "\n").utf8)) == hash else { return nil }
        if lines.last == "" { lines.removeLast() }  // the final newline
        return lines
    }

    /// Syntax colours for revealed context lines (`numbers`) of `path`, if the review parsed its files.
    func highlightRevealed(_ id: Session.ID, path: String, hash: String, lines: [String],
                           numbers: [Int]) async -> [Int: AttributedString] {
        guard insights[id] != nil else { return [:] }
        return await analyzer.highlight(lines, numbers: numbers, path: path, hash: hash)
    }

    // MARK: - Comments

    func addComment(_ id: Session.ID, path: String, lines: ClosedRange<Int>, quote: String, text: String) {
        let comment = ReviewComment(id: UUID(), path: path, line: lines.lowerBound, endLine: lines.upperBound,
                                    quote: quote, text: text, state: .queued, isOutdated: false, createdAt: Date())
        update(id) { $0.current.comments.append(comment) }
    }

    func setCommentState(_ id: Session.ID, comment: UUID, _ state: ReviewComment.State) {
        update(id) { s in
            if let i = s.current.comments.firstIndex(where: { $0.id == comment }) { s.current.comments[i].state = state }
        }
    }

    /// Makes the agent's draft the user's: from then on Send to Agent counts and sends it.
    func keepComment(_ id: Session.ID, comment: UUID) {
        update(id) { s in
            if let i = s.current.comments.firstIndex(where: { $0.id == comment }), s.current.comments[i].byAgent {
                s.current.comments[i].byAgent = false
            }
        }
    }

    func deleteComment(_ id: Session.ID, comment: UUID) {
        update(id) { $0.current.comments.removeAll { $0.id == comment } }
    }

    /// Comments "Send to Agent" would send: the user's, queued and still anchored
    /// (the agent's drafts only once kept).
    func queued(_ id: Session.ID) -> [ReviewComment] {
        (states[id]?.current.comments ?? []).filter { $0.state == .queued && !$0.isOutdated && !$0.byAgent }
    }

    /// Pastes the queued comments into the session's terminal (no Return)
    /// and marks them sent. False if nothing was sent.
    @discardableResult
    func sendQueued(_ session: Session, host: GhosttyTerminalHost) -> Bool {
        let comments = queued(session.id)
        let state = states[session.id] ?? ReviewState()
        guard !comments.isEmpty else { return false }
        // A PR's folder is only known once it has loaded.
        if case .pullRequest = state.source, snapshots[session.id] == nil { return false }
        let root = snapshots[session.id]?.root ?? folder(of: state, session)
        guard host.sendText(ReviewPrompt.text(for: comments, root: root, source: sourceNames[session.id])) else { return false }  // no terminal: keep them queued
        let sent = Set(comments.map(\.id))
        update(session.id) { s in
            for i in s.current.comments.indices where sent.contains(s.current.comments[i].id) { s.current.comments[i].state = .sent }
        }
        return true
    }

    // MARK: - GitHub

    /// The loaded pull request when the current source is one (then gh works: it found it).
    func currentPullRequest(_ id: Session.ID) -> PullRequest? {
        guard case let .pullRequest(repo, number) = states[id]?.source, let pr = pullRequest[id],
              pr.baseRepo == repo, pr.number == number else { return nil }
        return pr
    }

    /// What the Submit sheet offers: queued comments on the current source, outdated ones included.
    func submittable(_ id: Session.ID) -> [ReviewComment] {
        (states[id]?.current.comments ?? []).filter { $0.state == .queued }
    }

    /// What a review is checked against before it is posted.
    struct SubmitCheck {
        let pr: PullRequest
        let snapshot: ReviewSnapshot
        let source: ReviewSource
        /// Diff paths the PR head doesn't have (local files): their comments go outside.
        let local: Set<String>
        /// The head's lines of each selected comment's file (absent: no such file at the head).
        let headLines: [String: [String]]
    }

    /// The diff on screen is the PR head's: no custom base, the same merge
    /// base, and every changed file the head's blob (or absent from the head).
    /// Throws why not. Nothing awaits after the final re-read, so what is
    /// checked is what a submit posts.
    /// `selected` comments' files are read at the head, so a comment is only
    /// inline where its quote is on its line there, whenever it was anchored.
    func checkSubmit(_ id: Session.ID, selected: Set<UUID> = []) async throws -> SubmitCheck {
        guard let pr = currentPullRequest(id), let snapshot = snapshots[id] else { throw ReviewGitError.gitFailed("The pull request isn't loaded") }
        guard states[id]?.current.base == nil, snapshot.base.hasSuffix("/" + pr.baseRef) else { throw ReviewGitError.gitFailed(GitHubReview.notAtHead) }
        guard let git = await makeGit() else { throw ReviewGitError.gitFailed("git not found") }
        let head = try await git.objects(at: pr.headSHA, paths: snapshot.files.map(\.path), root: snapshot.root)
        let mergeBase = await git.out(["merge-base", "--end-of-options", pr.headSHA, snapshot.base], in: snapshot.root)
        let paths = Set(submittable(id).filter { selected.contains($0.id) }.map(\.path))
        var headLines: [String: [String]] = [:]
        for path in paths { headLines[path] = await git.lines(at: pr.headSHA, path: path, root: snapshot.root) }
        guard currentPullRequest(id) == pr, snapshots[id] == snapshot, states[id]?.current.base == nil,
              let source = states[id]?.source else { throw ReviewGitError.gitFailed("The review changed while submitting — try again") }
        guard mergeBase == snapshot.point, let local = GitHubReview.localOnly(snapshot, head: head) else {
            throw ReviewGitError.gitFailed(GitHubReview.notAtHead)
        }
        return SubmitCheck(pr: pr, snapshot: snapshot, source: source, local: local, headLines: headLines)
    }

    /// Posts the review on the current PR with the selected comments as they
    /// are now (still queued), and marks the ones that went (inline, or into
    /// the summary) posted. Throws the reason; then nothing changes.
    func submitReview(_ id: Session.ID, pullRequest: PullRequest, event: ReviewEvent, summary: String,
                      selected: Set<UUID>, outsideIntoSummary: Bool) async throws {
        let check = try await checkSubmit(id, selected: selected)
        guard check.pr.number == pullRequest.number, check.pr.baseRepo == pullRequest.baseRepo else {
            throw ReviewGitError.gitFailed("The pull request changed — reopen the sheet")
        }
        // No await from the check to the payload.
        let comments = (states[id]?[check.source].comments ?? []).filter { selected.contains($0.id) && $0.state == .queued }
        let diff = check.snapshot.files.filter { !check.local.contains($0.path) }
        let (payload, outside) = GitHubReview.payload(event: event, summary: summary, comments: comments, diff: diff,
                                                      headSHA: check.pr.headSHA, outsideIntoSummary: outsideIntoSummary,
                                                      headLines: check.headLines)
        // Ticked for the diff but the head's lines differ: they would silently go nowhere.
        if !outsideIntoSummary, let message = GitHubReview.notMatchingHead(outside, diff: diff) { throw ReviewGitError.gitFailed(message) }
        guard let git = await makeGit() else { throw ReviewGitError.gitFailed("git not found") }
        try await git.postReview(payload, repo: check.pr.baseRepo, number: check.pr.number, root: check.snapshot.root)
        let posted = Set(comments.map(\.id)).subtracting(outsideIntoSummary ? [] : outside.map(\.id))
        // The source the review was for, even if another was picked meanwhile.
        update(id) { s in
            for i in s[check.source].comments.indices where posted.contains(s[check.source].comments[i].id) {
                s[check.source].comments[i].state = .posted
            }
        }
    }

    // MARK: - Settings

    func setBase(_ id: Session.ID, _ base: String?) {
        update(id) { $0.current.base = base }
        refreshOpen(id)
    }

    func refreshOpen(_ id: Session.ID) {
        guard openFor == id, let session = openSession, session.id == id else { return }  // panel closed: no git
        Task { await refresh(session) }
    }

    /// The session was deleted.
    func forget(_ id: Session.ID) {
        if openFor == id { close() }
        if openSession?.id == id { openSession = nil }
        sourceChanged(id)
        if pullRequest[id] != nil { pullRequest[id] = nil }
        if draftErrors[id] != nil { draftErrors[id] = nil }
        disk.async { AgentDrafts.removeFiles(session: id) }
        if states[id] != nil {
            states[id] = nil
            save()
        }
    }

    // MARK: - Helpers

    /// Forgets what the last load showed; the panel says Loading… (or the error) until the next one.
    func dropLoaded(_ id: Session.ID) {
        if snapshots[id] != nil { snapshots[id] = nil }
        if analysis[id] != nil { analysis[id] = nil }
        if insights[id] != nil { insights[id] = nil }
        sourceNames[id] = nil
    }

    /// The review's source changed: nothing of the old one stays on screen or actionable.
    func sourceChanged(_ id: Session.ID) {
        dropLoaded(id)
        if errors[id] != nil { errors[id] = nil }
    }

    /// Applies `change` to the session's state; writes and saves only if it changed.
    func update(_ id: Session.ID, _ change: (inout ReviewState) -> Void) {
        let old = states[id] ?? ReviewState()
        var new = old
        change(&new)
        guard new != old else { return }
        states[id] = new
        save()
    }

    /// Where the source's files are, without git, before its first load (not for a PR: its worktree isn't known yet).
    private func folder(of state: ReviewState, _ session: Session) -> String {
        if case let .folder(path) = state.source { return path }
        return session.workingDirectory
    }

    func makeGit() async -> ReviewGit? {
        await resolver.bootstrap()
        guard let gitPath = await resolver.resolve(command: "git") else { return nil }
        return ReviewGit(git: gitPath, gh: await resolver.resolve(command: "gh"),
                         environment: resolver.shellPathEnvironment)
    }

    private func setError(_ id: Session.ID, _ message: String) {
        if errors[id] != message { errors[id] = message }
    }

    private func save() {
        let store = store, states = states
        disk.async { store.save(states) }
    }
}
