import AppKit
import Foundation
import Observation

enum SessionProgress: Equatable {
    case percent(Int)
    case indeterminate

    var label: String {
        switch self {
        case let .percent(value): return "\(value)%"
        case .indeterminate: return "⋯"
        }
    }

    var percent: Int? {
        switch self {
        case let .percent(value): return value
        case .indeterminate: return nil
        }
    }
}

struct TitleBarMetrics: Equatable {
    /// x where Simul's own title-bar buttons start.
    var leading: CGFloat
    /// Vertical center of the buttons, from the window's top.
    var centerY: CGFloat
    /// Area at the very top nothing should draw in (the notch band in
    /// full screen on notched displays).
    var topInset: CGFloat = 0
    /// Height of the strip the buttons sit in (content starts below it):
    /// the inset plus a band centered on `centerY`.
    var height: CGFloat { 2 * centerY - topInset }
}

/// Central application state. No TCA, no Redux, no DI container —
/// initializer injection and native Observation.
@MainActor
@Observable
final class AppModel {
    var sessions: [Session] = []
    var selectedSessionID: Session.ID?

    /// Sessions whose backing tmux process is alive.
    var runningIDs: Set<UUID> = []

    /// Sessions that rang the bell while not being viewed. Clearing one
    /// (viewed, working again, closed) also clears its notification.
    var attentionIDs: Set<UUID> = [] {
        didSet { notifier.remove(oldValue.subtracting(attentionIDs)) }
    }

    /// macOS notifications for attention while Simul is in the background.
    let notifier = Notifier()

    /// Terminal-reported progress per session.
    var sessionProgress: [UUID: SessionProgress] = [:]

    /// When each session started its current turn (shown as elapsed time).
    var workingSince: [UUID: Date] = [:]

    /// Branch/worktree per active session (polled; see refreshGitInfo).
    var gitInfo: [UUID: GitInfo] = [:]

    /// Plan limits per agent ("claude", "codex"), as the agents report them
    /// (see refreshLiveUsage).
    var usage: [AgentUsage] = []

    /// Terminals attached but not yet showing the agent's UI. Cleared on the
    /// agent's first sign of life (title, progress, notification) or after
    /// a timeout, so the loading screen covers the blank boot period.
    var starting: Set<UUID> = []

    /// Sessions being explicitly stopped (suppresses auto-archive).
    private var stopping: Set<UUID> = []

    /// Per-session launch error surfaced in the terminal placeholder.
    var launchErrors: [Session.ID: String] = [:]

    /// Modal state for rename (inline in the sidebar), delete and close dialogs.
    var renaming: Session.ID?
    var pendingDelete: Session.ID?
    var pendingClose: Session.ID?

    /// Where the window's title-bar strip is: right of the traffic lights
    /// and centered on them (measured from AppKit; see AppDelegate).
    var titleBar = TitleBarMetrics(leading: 78, centerY: 14)

    /// Sidebar shown (⌘B toggles; remembered across launches).
    var sidebarVisible = Preferences.flag(Preferences.Key.sidebarVisible) {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Preferences.Key.sidebarVisible) }
    }

    /// A new session being configured (⌘N). UI-only until an agent is
    /// picked; never persisted.
    var draft: Session?

    /// Sessions with an in-flight launch, to avoid duplicate spawns.
    private var launching: Set<UUID> = []

    func isLaunching(_ session: Session) -> Bool {
        launching.contains(session.id)
    }

    let store: SessionStore
    let backend: SessionBackend
    let resolver: ExecutableResolver
    let hostCenter = TerminalHostCenter()

    /// Built-in agents plus the user's extra arguments (Settings ▸ Agents).
    var agents: [AgentDefinition] {
        AgentDefinition.builtIns.map { agent in
            var agent = agent
            agent.arguments += Preferences.extraArguments(for: agent.id)
            return agent
        }
    }

    init(store: SessionStore, backend: SessionBackend, resolver: ExecutableResolver) {
        self.store = store
        self.backend = backend
        self.resolver = resolver
        AppDelegate.appModel = self // quit guard needs live-session state
        notifier.onOpen = { [weak self] id in self?.openFromNotification(id) }
    }

    // MARK: - Derived

    var activeSessions: [Session] {
        sessions
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Most recently archived first.
    var archivedSessions: [Session] {
        sessions
            .filter { $0.isArchived }
            .sorted { archivedDate($0) > archivedDate($1) }
    }

    /// Sessions archived before `archivedAt` existed fall back to lastOpenedAt.
    func archivedDate(_ session: Session) -> Date {
        session.archivedAt ?? session.lastOpenedAt
    }

    var selectedSession: Session? {
        selectedSessionID.flatMap { id in sessions.first { $0.id == id } }
    }

    /// Sessions with a live terminal surface (kept in the layer ZStack).
    var liveSessions: [Session] {
        sessions.filter { hostCenter.hasHost(for: $0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Number of sessions with live processes (used by the quit guard).
    var liveSessionCount: Int {
        sessions.filter { hostCenter.hasHost(for: $0.id) }.count
    }

    var isDraftSelected: Bool {
        if let draft, draft.id == selectedSessionID { return true }
        return false
    }

    func isRunning(_ session: Session) -> Bool {
        // Direct mode: the surface IS the process.
        backend.processesOutliveApp
            ? runningIDs.contains(session.id)
            : hostCenter.hasHost(for: session.id)
    }

    func agent(for session: Session) -> AgentDefinition? {
        agents.first { $0.id == session.agentID }
    }

    // MARK: - Lifecycle

    func start() {
        sessions = store.load()
        renumberSortOrder()
        notifier.setUp()
        // Pasted images are read by the time a message is sent; last run's are done.
        try? FileManager.default.removeItem(at: Paths.pastedImages)

        Task {
            await resolver.bootstrap()
            await refreshRunning()
            selectFirstOnLaunch()
        }

        // Agents switch branches on their own; a few small file reads per
        // active session every few seconds keeps the cards honest.
        refreshGitInfo()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGitInfo() }
        }
        // Last known Claude numbers right away; then ask the agents for fresh
        // ones: now, every 5 min while Simul is in front, and when it comes
        // back to the front.
        Task {
            if let cached = await Task.detached(operation: { UsageLimits.claude() }).value {
                setUsage(cached)
            }
        }
        refreshLiveUsage()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSApp.isActive { self?.refreshLiveUsage() }
            }
        }

        // Lightweight reconciliation only when it matters.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshRunning()
                self?.refreshLiveUsage()
            }
        }
    }

    private func selectFirstOnLaunch() {
        if selectedSessionID == nil || selectedSession == nil {
            selectedSessionID = activeSessions.first?.id
        }
    }

    // MARK: - Selection

    func select(_ session: Session) {
        if draft != nil, session.id != draft?.id {
            draft = nil // switching away discards an unstarted draft
        }
        selectedSessionID = session.id
        attentionIDs.remove(session.id)
        turnEndAttention.remove(session.id)
        // Cheap: no disk write on every switch — persist lastOpenedAt at most
        // every few minutes per session.
        if let index = sessions.firstIndex(where: { $0.id == session.id }),
           Date().timeIntervalSince(sessions[index].lastOpenedAt) > 300 {
            sessions[index].lastOpenedAt = Date()
            persist()
        }
    }

    /// ⌘1 … ⌘9
    func selectSlot(_ slot: Int) {
        guard (1...9).contains(slot) else { return }
        let active = activeSessions
        guard slot <= active.count else { return }
        select(active[slot - 1])
    }

    // MARK: - Git

    func refreshGitInfo() {
        var info: [UUID: GitInfo] = [:]
        for session in activeSessions {
            info[session.id] = GitInfo.read(directory: session.workingDirectory)
        }
        if info != gitInfo { gitInfo = info } // avoid invalidating on no-op polls
    }

    // MARK: - Usage limits

    private var lastLiveUsageRefresh: Date?

    /// Asks Claude and Codex themselves for fresh limits (see
    /// UsageRefresher; no credentials pass through Simul). Throttled.
    func refreshLiveUsage() {
        guard Preferences.flag(Preferences.Key.showLimits) else { return } // hidden → don't fetch
        if let last = lastLiveUsageRefresh, Date().timeIntervalSince(last) < 120 { return }
        lastLiveUsageRefresh = Date()
        Task {
            await resolver.bootstrap()
            let environment = resolver.shellPathEnvironment
            if let codex = await resolver.resolve(command: "codex"),
               let live = await UsageRefresher.codex(executable: codex, environment: environment) {
                setUsage(live)
            }
            if let claude = await resolver.resolve(command: "claude") {
                // /usage prints prose; its structured result is the cache it
                // just rewrote in ~/.claude.json.
                await UsageRefresher.refreshClaude(executable: claude, environment: environment)
                if let fresh = await Task.detached(operation: { UsageLimits.claude() }).value {
                    setUsage(fresh)
                }
            }
        }
    }

    private func setUsage(_ fresh: AgentUsage) {
        let updated = (usage.filter { $0.agentID != fresh.agentID } + [fresh])
            .sorted { $0.agentID < $1.agentID } // claude, codex
        if updated != usage { usage = updated }
    }

    // MARK: - Running state

    func refreshRunning() async {
        if let ids = try? await backend.listRunningIDs() {
            if ids != runningIDs { runningIDs = ids } // avoid invalidating on no-op polls
        }
    }

    // MARK: - Draft sessions (⌘N)

    /// Creates an unstarted draft session and selects it. The detail area
    /// shows the agent picker; no modal.
    func createDraft() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = UserDefaults.standard
        let mode = Preferences.DirectoryMode(rawValue: defaults.string(forKey: Preferences.Key.directoryMode) ?? "")
            ?? .currentSession
        let directory: String
        switch mode {
        case .currentSession: directory = selectedSession?.workingDirectory ?? home
        case .home: directory = home
        case .custom:
            let custom = defaults.string(forKey: Preferences.Key.customDirectory) ?? ""
            directory = custom.isEmpty ? home : custom
        }
        let draft = Session(
            title: "",
            workingDirectory: directory,
            agentID: ""
        )
        self.draft = draft
        selectedSessionID = draft.id
    }

    func updateDraft(title: String? = nil, workingDirectory: String? = nil) {
        guard draft != nil else { return }
        if let title { draft?.title = title }
        if let workingDirectory { draft?.workingDirectory = workingDirectory }
    }

    /// Persists and launches the draft with the chosen agent.
    func startDraft(agent: AgentDefinition, skipPermissions: Bool = false) {
        guard var session = draft else { return }
        session.agentID = agent.id
        session.skipPermissions = skipPermissions && !agent.dangerousArguments.isEmpty
        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.title = defaultTitle(for: agent, workingDirectory: session.workingDirectory)
        }
        draft = nil
        sessions.append(session)
        persist()
        selectedSessionID = session.id
        refreshGitInfo()
        Task { await launch(session) }
    }

    // MARK: - Creation / teardown

    /// Starts the session's process (if needed) and attaches a terminal,
    /// resuming the session's own agent conversation when there is one.
    func launch(_ session: Session) async {
        guard !launching.contains(session.id) else { return }
        launching.insert(session.id)
        defer { launching.remove(session.id) }

        launchErrors[session.id] = nil
        guard let agent = agent(for: session) else { return }
        let conversation = await prepareConversation(for: session.id, agent: agent)
        guard let session = sessions.first(where: { $0.id == session.id }) else { return }
        do {
            if try await !backend.exists(session) {
                try await backend.create(session, agent: agent, conversation: conversation)
            }
            await refreshRunning()
            attachTerminal(to: session, agent: agent, conversation: conversation)
        } catch {
            Log.backend.error(
                "launch failed for \(session.title, privacy: .public): \(String(describing: error), privacy: .public)")
            launchErrors[session.id] = error.localizedDescription
            await refreshRunning()
        }
    }

    /// Decides which conversation this launch attaches to and records the
    /// launch. Never falls back to "latest conversation in the directory":
    /// no exact match means a fresh conversation.
    private func prepareConversation(for id: Session.ID, agent: AgentDefinition) async -> Conversation {
        guard let session = sessions.first(where: { $0.id == id }) else { return .none }
        var agentSessionID = session.agentSessionID
        var conversation = Conversation.none

        switch agent.resume {
        case .none:
            break
        case .claude:
            // Our session UUID doubles as Claude's session ID.
            let claudeID = agentSessionID ?? session.id.uuidString.lowercased()
            agentSessionID = claudeID
            conversation = AgentConversations.claudeTranscriptExists(id: claudeID)
                ? .resume(claudeID) : .start(claudeID)
        case .codex:
            // The thread id is learned when this session finishes a turn
            // (discoverCodexThread); until then it starts fresh.
            if let agentSessionID { conversation = .resume(agentSessionID) }
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].agentSessionID = agentSessionID
            sessions[index].lastLaunchedAt = Date()
            persist()
        }
        return conversation
    }

    private func attachTerminal(to session: Session, agent: AgentDefinition, conversation: Conversation) {
        guard let spec = try? backend.attachCommand(for: session, agent: agent, conversation: conversation) else {
            launchErrors[session.id] = "The session command could not be resolved."
            return
        }
        let host = hostCenter.host(for: session)
        host.sessionID = session.id
        // Agents take a moment to draw their UI; shells are instant.
        if !agent.isShell {
            starting.insert(session.id)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.starting.remove(session.id)
            }
        }
        host.onEvent = { [weak self] id, event in
            guard let self else { return }
            if self.starting.contains(id) { self.starting.remove(id) } // first sign of life
            switch event {
            case let .attention(message):
                self.flagAttention(id, message: message, fallback: "Needs your attention")
                // A Claude/Codex turn ended → its limits just changed.
                if self.agent(for: session)?.resume != ResumeStrategy.none {
                    self.refreshLiveUsage()
                }
            case let .progress(active, percent):
                self.setProgress(id, active
                    ? (percent.map { SessionProgress.percent($0) } ?? .indeterminate)
                    : nil)
            case let .title(title):
                // Title-driven agents (Codex): busy title = working.
                if let busyTitle = self.agent(for: session)?.busyTitle {
                    self.setProgress(id, title == busyTitle ? .indeterminate : nil)
                }
            }
        }
        host.onChildExited = { [weak self] in
            guard let self else { return }
            // The attach client exited (detached or killed). Drop the surface;
            // running state decides what happens next.
            self.closeTerminal(session.id)
            Task { @MainActor in
                await self.refreshRunning()
                let stillRunning = self.runningIDs.contains(session.id)
                // Terminal exited and the tmux session is gone → auto-archive
                // (explicit Stop is exempt; the user stays in control there).
                if !stillRunning,
                   !self.stopping.contains(session.id),
                   !session.isArchived,
                   self.sessions.contains(where: { $0.id == session.id && !$0.isArchived }) {
                    self.setArchived(session, true)
                }
            }
        }
        host.attach(to: spec)
    }

    /// Pending "turn finished" checks, per session (see setProgress).
    private var turnEndChecks: [Session.ID: Task<Void, Never>] = [:]
    /// Dots that came from a finished turn (not from a bell/notification).
    private var turnEndAttention: Set<Session.ID> = []

    private func setProgress(_ id: Session.ID, _ progress: SessionProgress?) {
        if sessionProgress[id] != nil, progress == nil {
            // Agents can clear progress briefly between steps of one turn.
            // Only call it finished if it stays off for a moment.
            turnEndChecks[id]?.cancel()
            turnEndChecks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let self, self.sessionProgress[id] == nil else { return }
                self.turnEndChecks[id] = nil
                self.workingSince.removeValue(forKey: id)
                if self.selectedSessionID != id || !NSApp.isActive {
                    self.turnEndAttention.insert(id)
                }
                self.flagAttention(id, message: nil, fallback: "Finished, waiting for you")
                self.discoverCodexThread(id)
            }
        } else if sessionProgress[id] == nil, progress != nil {
            turnEndChecks[id]?.cancel()
            turnEndChecks[id] = nil
            if workingSince[id] == nil { workingSince[id] = Date() } // a short gap keeps the timer
            // Working again on its own: a "turn finished" dot is stale.
            if turnEndAttention.remove(id) != nil {
                attentionIDs.remove(id)
            }
        }
        if sessionProgress[id] != progress {
            sessionProgress[id] = progress
        }
    }

    /// Learns which Codex thread a session is, right after its own turn
    /// ends: the first unclaimed thread in its folder since it launched.
    /// Doing it while the session is live (not at relaunch) means a session
    /// that never got a message can't claim another session's thread.
    /// ponytail: two Codex sessions in one folder, started together, can
    /// still swap; a per-session thread id from Codex itself would fix it.
    private func discoverCodexThread(_ id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }), session.agentSessionID == nil,
              agent(for: session)?.resume == .codex, let launchedAt = session.lastLaunchedAt else { return }
        let claimed = Set(sessions.compactMap(\.agentSessionID))
        Task {
            let found = await AgentConversations.codexThreadID(
                cwd: session.workingDirectory,
                since: launchedAt.addingTimeInterval(-5), // clock slack
                excluding: claimed)
            // Re-check after the await: another session may have claimed it.
            guard let found, !sessions.contains(where: { $0.agentSessionID == found }),
                  let index = sessions.firstIndex(where: { $0.id == id }),
                  sessions[index].agentSessionID == nil else { return }
            sessions[index].agentSessionID = found
            persist()
        }
    }

    /// Attention badge on sessions the user is not looking at. Skips the write when
    /// already flagged so observers aren't invalidated.
    /// Marks a session as needing you and posts a notification. One per
    /// session until it's looked at. Text: the agent's own message (e.g. a
    /// permission request), else Claude's last reply from its transcript,
    /// else `fallback`.
    private func flagAttention(_ id: Session.ID, message: String?, fallback: String) {
        guard selectedSessionID != id || !NSApp.isActive,
              !attentionIDs.contains(id),
              let session = sessions.first(where: { $0.id == id }) else { return }
        attentionIDs.insert(id)
        let transcriptID = agent(for: session)?.resume == .claude ? session.agentSessionID : nil
        Task {
            let reply = await Task.detached(priority: .utility) {
                transcriptID.flatMap { AgentConversations.claudeLastReply(id: $0) }
            }.value
            guard attentionIDs.contains(id) else { return } // looked at meanwhile
            notifier.post(for: session, message: message ?? reply ?? fallback)
        }
    }

    /// A notification was clicked: show Simul on that session.
    private func openFromNotification(_ id: Session.ID) {
        NSApp.activate()
        AppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
        if let session = sessions.first(where: { $0.id == id }) {
            select(session)
        }
    }

    /// Explicit stop: terminates the process. Metadata remains and the
    /// session stays unarchived (no auto-archive for explicit stops).
    func stop(_ session: Session) async {
        stopping.insert(session.id)
        defer { stopping.remove(session.id) }
        try? await backend.stop(session)
        closeTerminal(session.id)
        await refreshRunning()
    }

    /// Drops the surface (terminating a direct-mode process) and its
    /// transient UI state. Does not trigger auto-archive.
    private func closeTerminal(_ id: Session.ID) {
        hostCenter.closeHost(for: id)
        starting.remove(id)
        attentionIDs.remove(id)
        sessionProgress.removeValue(forKey: id)
        workingSince.removeValue(forKey: id)
        turnEndChecks.removeValue(forKey: id)?.cancel()
        turnEndAttention.remove(id)
    }

    /// Delete metadata only (keeps the tmux session running if present).
    func deleteMetadata(_ session: Session) {
        try? FileManager.default.removeItem(
            at: Paths.pastedImages.appendingPathComponent(session.id.uuidString, isDirectory: true))
        closeTerminal(session.id)
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = activeSessions.first?.id
        }
        persist()
    }

    // MARK: - Closing sessions (⌘W)

    /// ⌘W on the selected session. Shell sessions close immediately; agent
    /// sessions confirm first (a running agent will terminate).
    func requestCloseSelected() {
        guard let session = selectedSession else { return }
        if draft?.id == session.id {
            // Closing the draft just discards it.
            draft = nil
            selectedSessionID = activeSessions.first?.id
            return
        }
        if agent(for: session)?.isShell == true || !Preferences.flag(Preferences.Key.confirmClose) {
            closeSession(session)
        } else {
            pendingClose = session.id
        }
    }

    /// Terminates the session's process and archives it.
    func closeSession(_ session: Session) {
        pendingClose = nil
        setArchived(session, true)
    }

    // MARK: - Editing

    func rename(_ session: Session, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[index].title = trimmed
        persist()
    }

    /// Archiving also stops the process: archived sessions hold no
    /// resources, and relaunching resumes their conversation by ID.
    func setArchived(_ session: Session, _ archived: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if archived {
            closeTerminal(session.id)
            if backend.processesOutliveApp {
                Task {
                    try? await backend.stop(session)
                    await refreshRunning()
                }
            }
        }
        sessions[index].isArchived = archived
        sessions[index].archivedAt = archived ? Date() : nil
        if archived, selectedSessionID == session.id {
            selectedSessionID = activeSessions.first?.id
        }
        persist()
    }

    func toggleArchived(_ session: Session) {
        if session.isArchived {
            setArchived(session, false)
        } else {
            requestArchive(session)
        }
    }

    /// Archive from the menu or context menu. Archiving stops the process,
    /// so a running agent gets the same confirmation as ⌘W.
    func requestArchive(_ session: Session) {
        if isRunning(session), agent(for: session)?.isShell == false,
           Preferences.flag(Preferences.Key.confirmClose) {
            pendingClose = session.id
        } else {
            setArchived(session, true)
        }
    }

    /// Moves `source` to `destination`'s position. Live drags pass
    /// `persist: false` and call `saveOrder()` once on release.
    func reorder(from source: Session.ID, to destination: Session.ID, persist shouldPersist: Bool = true) {
        var active = activeSessions
        guard let from = active.firstIndex(where: { $0.id == source }),
              let to = active.firstIndex(where: { $0.id == destination })
        else { return }
        let moved = active.remove(at: from)
        active.insert(moved, at: to)
        for (order, s) in active.enumerated() {
            if let i = sessions.firstIndex(where: { $0.id == s.id }) {
                sessions[i].sortOrder = order
            }
        }
        if shouldPersist { persist() }
    }

    func saveOrder() {
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        store.save(sessions)
    }

    private func renumberSortOrder() {
        let ordered = sessions.sorted {
            if $0.isArchived != $1.isArchived { return !$0.isArchived }
            return $0.sortOrder < $1.sortOrder
        }
        for (order, session) in ordered.enumerated() {
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].sortOrder = order
            }
        }
    }

    private func defaultTitle(for agent: AgentDefinition, workingDirectory: String) -> String {
        // Logos carry the agent identity in the sidebar; the title is just
        // the directory.
        let dirName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return dirName.isEmpty ? agent.name : dirName
    }
}
