import Foundation

/// "Ask agent to review": the agent writes its findings to a file, which is
/// imported as queued comments and an overview on each load (a turn's end
/// loads, or marks the hidden review to load when it shows).
extension ReviewCenter {
    /// Pastes the ask into the session's terminal, with Return only if
    /// Claude's input box was empty and its turn is over. False if the review hasn't loaded or
    /// there is no terminal.
    @discardableResult
    func askAgentToReview(_ session: Session, host: GhosttyTerminalHost) -> Bool {
        guard let snapshot = snapshots[session.id], let source = states[session.id]?.source else { return false }
        let file = AgentDrafts.file(session: session.id, source: source)
        try? FileManager.default.createDirectory(at: Paths.agentDrafts, withIntermediateDirectories: true)
        guard host.sendText(ReviewPrompt.askReview(source: sourceNames[session.id], root: snapshot.root, base: snapshot.base,
                                                   point: snapshot.point, path: file.path),
                            submitIfEmpty: canSubmit(session)) else { return false }
        // The agent writes a whole new file: what comes in is a new review, replacing its drafts.
        setDraftError(session.id, nil)
        return true
    }

    /// Pastes a request to fix the review file, as askAgentToReview.
    @discardableResult
    func askAgentToFixReview(_ session: Session, host: GhosttyTerminalHost) -> Bool {
        guard let issue = draftErrors[session.id], let source = states[session.id]?.source else { return false }
        return host.sendText(ReviewPrompt.fixReview(reasons: issue.reasons, path: AgentDrafts.file(session: session.id, source: source).path),
                             submitIfEmpty: canSubmit(session))
    }

    /// Return after the paste may only go to Claude between turns: mid-turn a
    /// permission prompt could appear and take it.
    private func canSubmit(_ session: Session) -> Bool {
        session.agentID == "claude" && !isWorking(session.id)
    }

    // MARK: - Overview

    /// The agent's overview of the current source; nil until a valid one came in.
    func overview(_ id: Session.ID) -> AgentOverview? { states[id]?.current.overview }

    /// The overview was made for other changes than the ones on screen ("Out of date — Ask again").
    func isOverviewStale(_ id: Session.ID) -> Bool {
        guard let overview = overview(id), let snapshot = snapshots[id] else { return false }
        return overview.isStale(for: snapshot)
    }

    /// The anchor still points where the agent meant (its file is unchanged
    /// since): link it. False also before the review has loaded.
    func overviewAnchorHolds(_ id: Session.ID, _ anchor: AgentOverview.Anchor) -> Bool {
        guard let overview = overview(id), let snapshot = snapshots[id] else { return false }
        return overview.holds(anchor, in: snapshot)
    }

    /// Where Keep would comment; nil: Keep disabled ("Not on a changed line").
    func keepAnchor(_ id: Session.ID, concern: Int) -> AgentOverview.Anchor? {
        guard let snapshot = snapshots[id] else { return nil }
        return overview(id)?.keepAnchor(concern, in: snapshot)
    }

    /// Keep: the concern becomes the user's queued comment on its keepAnchor
    /// ("**title** — why"), so Send to Agent and Submit carry it.
    func keepConcern(_ id: Session.ID, concern: Int) async {
        guard let source = states[id]?.source, let root = snapshots[id]?.root, let kept = overview(id),
              let anchor = keepAnchor(id, concern: concern), let git = await makeGit() else { return }
        let lines = await git.fileLines(root: root, path: anchor.path)
        guard lines.indices.contains(anchor.line - 1) else { return }
        // Only onto the overview and anchor it was asked for: either may have changed meanwhile.
        guard let snapshot = snapshots[id], snapshot.root == root else { return }
        update(id) { state in
            guard state[source].overview?.concerns == kept.concerns,
                  state[source].overview?.keepAnchor(concern, in: snapshot) == anchor else { return }
            state[source].keepConcern(concern, at: anchor, quote: lines[anchor.line - 1])
        }
    }

    func dismissConcern(_ id: Session.ID, concern: Int) {
        update(id) { $0.current.dismissConcern(concern) }
    }

    /// Adds the agent's comments on `source`. The file is deleted once all
    /// of it is in; otherwise it keeps what wasn't, and `draftErrors` says why.
    func importDrafts(_ id: Session.ID, source: ReviewSource, snapshot: ReviewSnapshot) async {
        guard isShowing(id) else { return }  // closed or hidden: it runs when the review shows
        let file = AgentDrafts.file(session: id, source: source)
        // The agent may write it again while this imports: then the newer file stays for the next load.
        func modified() -> Date? { (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date }
        let readAt = modified()
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return setDraftError(id, nil) }
        guard size <= AgentDrafts.maxBytes else {
            return setDraftError(id, AgentDrafts.Issue(banner: "Agent's review file is too large", reasons: ["it is over 1 MB"]))
        }
        guard let data = try? Data(contentsOf: file) else { return }
        let entries: [AgentDrafts.Entry], json: [String: Any]?
        do {
            (entries, json) = try AgentDrafts.parseFile(data)
        } catch {
            let message = (error as? AgentDrafts.Problem)?.message ?? String(describing: error)
            return setDraftError(id, AgentDrafts.Issue(banner: "Agent's review file has problems: \(message)", reasons: [message]))
        }
        let paths = Set(snapshot.files.filter { $0.status != .deleted }.map(\.path))
        guard let git = await makeGit() else { return }  // keep the file for next time
        var lines: [String: [String]] = [:]
        // Files in the diff, and outside it only untouched parts' anchors (bounded by the limits).
        let anchors = json.map(AgentOverview.anchorPaths) ?? []
        let outside = json.map(AgentOverview.outsidePaths) ?? []
        for path in Set(entries.compactMap(\.path)).union(anchors).intersection(paths).union(outside) {
            lines[path] = await git.fileLines(root: snapshot.root, path: path)
        }
        guard isShowing(id) else { return }  // closed or hidden meanwhile
        var overview: AgentOverview?, overviewProblems: [String] = []
        // fileLines gives no lines for a missing file, one ("") for an empty one.
        func lineCount(_ path: String) -> Int? { lines[path].flatMap { $0.isEmpty ? nil : AgentDrafts.lineCount($0) } }
        let deleted = Set(snapshot.files.filter { $0.status == .deleted }.map(\.path))
        switch json.map({ AgentOverview.validate(json: $0, diffPaths: paths, deletedPaths: deleted, lineCount: lineCount) }) {
        case var .success(found)?:
            found.fingerprint = snapshot.fingerprint
            found.anchorHashes = Dictionary(uniqueKeysWithValues: anchors.map { ($0, snapshot.anchorHash($0)) })
            overview = found
        case let .failure(invalid)?: overviewProblems = invalid.reasons
        case nil: break
        }
        // Against the comments as they are now: a second import of the same file adds nothing.
        // A new review replaces the agent's drafts not kept; a fix (a problem pending) adds to them.
        let replacing = draftErrors[id] == nil
        var rejected: [AgentDrafts.Rejected] = []
        update(id) { state in
            let found = AgentDrafts.imported(entries, into: state[source].comments, replacing: replacing,
                                             diffPaths: paths, lines: { lines[$0] ?? [] })
            if state[source].comments != found.comments { state[source].comments = found.comments }
            // A new one replaces the old, marking which concerns are new and which it resolved.
            if let overview { state[source].overview = state[source].overview.map(overview.following) ?? overview }
            rejected = found.rejected
        }
        let rewritten = modified() != readAt
        guard !rejected.isEmpty || !overviewProblems.isEmpty else {
            if !rewritten { try? FileManager.default.removeItem(at: file) }
            return setDraftError(id, nil)
        }
        // Keeps what didn't come in, the overview whole.
        if !rewritten { try? AgentDrafts.file(keeping: rejected, overview: overviewProblems.isEmpty ? nil : json).write(to: file, options: .atomic) }
        let count = rejected.count == 1 ? "1 comment" : "\(rejected.count) comments"
        let banner = [overviewProblems.first.map { "Overview skipped: \($0)" }, rejected.first.map { "\(count) skipped: \($0.reason)" }]
            .compactMap { $0 }.joined(separator: "; ")
        setDraftError(id, AgentDrafts.Issue(banner: banner, reasons: overviewProblems + rejected.map(\.reason)))
    }

    private func setDraftError(_ id: Session.ID, _ issue: AgentDrafts.Issue?) {
        if draftErrors[id] != issue { draftErrors[id] = issue }
    }
}
