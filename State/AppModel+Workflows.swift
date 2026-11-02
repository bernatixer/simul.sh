import AppKit
import Foundation

/// What workflow runs need from the app: sessions of their own, and typing
/// prompts into a session the way a person would.
extension AppModel {
    enum PromptDelivery: Equatable {
        /// Typed in and Return pressed.
        case submitted
        /// Typed in; Return is left to the user.
        case pasted
        /// Claude isn't showing its input box (a question, a dialog, text
        /// typed in it): nothing was typed; try again later.
        case notReady
        /// No terminal to type into.
        case failed
    }

    /// Working, starting, launching, or asking the user something.
    func isBusy(_ id: Session.ID) -> Bool {
        isWorking(id) || starting.contains(id) || waitingIDs.contains(id)
            || sessions.first(where: { $0.id == id }).map(isLaunching) == true
    }

    /// Types `text` into the session and presses Return when that's safe:
    /// Claude between turns with an empty input box that then holds just the
    /// prompt (PromptBox), Codex when it's idle. Other agents get the paste only.
    /// ponytail: Codex's input box isn't read, so anything typed there goes out with the prompt.
    func sendPrompt(_ text: String, to id: Session.ID) -> PromptDelivery {
        guard let session = sessions.first(where: { $0.id == id }), hostCenter.hasHost(for: id) else { return .failed }
        let host = hostCenter.host(for: session)
        let claude = session.agentID == "claude"
        // A paste into a dialog (say "trust this folder?") could answer it: wait for the box.
        // Text in the box nobody typed since the last turn is Claude's own suggestion.
        if claude {
            let screen = host.surfaceView?.screenText() ?? ""
            let typed = typedAt[id].map { $0 > (turnEndedAt[id] ?? session.lastLaunchedAt ?? .distantPast) } ?? false
            guard PromptBox.isEmptyOrHint(screen) || (PromptBox.hasBox(screen) && !typed) else { return .notReady }
        }
        let canSubmit = !isBusy(id) && (claude || session.agentID == "codex")
        guard host.sendText(text) else { return .failed }
        guard canSubmit else { return .pasted }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak host] in
            MainActor.assumeIsolated {
                guard let view = host?.surfaceView else { return }
                if claude, !PromptBox.holds(text, view.screenText()) { return }
                view.pressReturn()
            }
        }
        return .submitted
    }

    /// A reviewer session a run starts for itself: in the same sidebar folder
    /// as `alongside`, launched with `prompt` as its first message, never
    /// selected. It may read, run read-only git and gh, and write `report`
    /// without asking; reviewing someone else's code (`trusted` false) it
    /// never skips permissions, whatever the run's session does.
    @discardableResult
    func startReviewerSession(agentID: String, title: String, folder: String, code: String, alongside builder: Session,
                              prompt: String, report: String, trusted: Bool) -> Session {
        var session = Session(title: title, workingDirectory: folder, agentID: agentID,
                              skipPermissions: trusted && builder.skipPermissions)
        session.folderID = builder.folderID  // hidden from the sidebar while it reviews; beside its session after
        session.sortOrder = (sessions.map(\.sortOrder).max() ?? 0) + 1
        sessions.append(session)
        saveSessions()
        let extra = Self.reviewerArguments(agentID, report: report, code: code, trusted: trusted, skipping: session.skipPermissions)
        Task { await launch(session, prompt: prompt, extraArguments: extra) }
        return session
    }

    /// What a reviewer may do without asking: read, inspect git and the PR, write its report.
    /// `skipping`: the session skips permissions, so Codex gets no sandbox
    /// flags (they conflict with its bypass flag).
    /// `code`: the folder under review (untrusted: not where the agent runs).
    static func reviewerArguments(_ agentID: String, report: String, code: String, trusted: Bool, skipping: Bool) -> [String] {
        switch agentID {
        case "claude":
            // Untrusted code gets no commands at all: even read-only git has flags that run or write
            // things (`git grep -O`, `--output`); Simul writes the diff for it instead.
            var rules = ["Read", "Grep", "Glob", "Write(/\(report))", "Edit(/\(report))"]
            guard trusted else {
                // Runs outside the PR's folder (its .claude settings, hooks and MCP servers don't load),
                // with only the user's settings, and no shell or web whatever they allow.
                return ["--setting-sources", "user", "--strict-mcp-config", "--permission-mode", "default",
                        "--add-dir", code, "--disallowedTools", "Bash,WebFetch,WebSearch",
                        "--allowedTools", rules.joined(separator: ",")]
            }
            rules += ["git diff", "git log", "git show", "git status", "git blame", "gh pr view", "gh pr diff"].map { "Bash(\($0):*)" }
            return ["--allowedTools", rules.joined(separator: ",")]
        case "codex":
            if skipping { return [] }
            // Sandboxed, no network; writes only where its report goes (untrusted: it works in that folder).
            let dir = (report as NSString).deletingLastPathComponent
            // ponytail: untrusted Codex can write any run's files under runs/ (its workspace); a folder per run would ask to trust each.
            return trusted ? ["-s", "workspace-write", "-a", "never", "-c", "sandbox_workspace_write.writable_roots=[\"\(dir)\"]"]
                           : ["-s", "workspace-write", "-a", "never", "-c", "sandbox_workspace_write.network_access=false"]
        default:
            return []
        }
    }

    /// Done with a helper session: archived (its conversation stays with the agent).
    func archiveHelper(_ id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }), !session.isArchived else { return }
        setArchived(session, true)
    }

    /// Takes a session out of Sleeping without selecting it.
    func wake(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }), sessions[index].sleptAt != nil else { return }
        sessions[index].sleptAt = nil
        saveSessions()
    }

    /// The Runs view, on `run` if given.
    func showRuns(_ run: UUID? = nil) {
        if draft != nil {
            draft = nil
            if selectedSession == nil { selectedSessionID = activeSessions.first?.id }
        }
        if let run {
            // Runs lists the selected session's runs: make it this run's.
            if let r = workflows.run(run), let selected = selectedSessionID,
               selected != r.sessionID, !r.reviewerSessionIDs.contains(selected),
               let session = sessions.first(where: { $0.id == r.sessionID }) {
                select(session)  // hides runs; shown again below
            }
            workflows.composing = nil
            if workflows.selectedRunID != run { workflows.selectedRunID = run }
            notifier.remove([run])
        }
        if !workflows.showing { workflows.showing = true }
        if let open = reviews.openFor, reviews.isShowing(open) { reviews.hide() }
    }
}
