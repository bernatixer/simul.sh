import AppKit
import Foundation
import Observation

/// Central application state. No TCA, no Redux, no DI container —
/// initializer injection and native Observation.
@MainActor
@Observable
final class AppModel {
    var sessions: [Session] = []
    var selectedSessionID: Session.ID?

    /// Sessions whose backing tmux process is alive.
    var runningIDs: Set<UUID> = []

    /// Per-session launch error surfaced in the terminal placeholder.
    var launchErrors: [Session.ID: String] = [:]

    /// Modal state for rename (inline in the sidebar) and delete dialog.
    var renaming: Session.ID?
    var pendingDelete: Session.ID?

    /// A new session being configured (⌘N / ⌘T). UI-only until an agent is
    /// picked; never persisted.
    var draft: Session?

    /// Sessions with an in-flight launch, to avoid duplicate tmux creates.
    private var launching: Set<UUID> = []

    let store: SessionStore
    let backend: SessionBackend
    let resolver: ExecutableResolver
    let hostCenter = TerminalHostCenter()

    var agents: [AgentDefinition] { AgentDefinition.builtIns }

    init(store: SessionStore, backend: SessionBackend, resolver: ExecutableResolver) {
        self.store = store
        self.backend = backend
        self.resolver = resolver
    }

    // MARK: - Derived

    var activeSessions: [Session] {
        sessions
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var archivedSessions: [Session] {
        sessions
            .filter { $0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedSession: Session? {
        selectedSessionID.flatMap { id in sessions.first { $0.id == id } }
    }

    /// Sessions with a live terminal surface (kept in the layer ZStack).
    var liveSessions: [Session] {
        sessions.filter { hostCenter.hasHost(for: $0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var isDraftSelected: Bool {
        if let draft, draft.id == selectedSessionID { return true }
        return false
    }

    func isRunning(_ session: Session) -> Bool {
        runningIDs.contains(session.id)
    }

    func agent(for session: Session) -> AgentDefinition? {
        agents.first { $0.id == session.agentID }
    }

    // MARK: - Lifecycle

    func start() {
        sessions = store.load()
        renumberSortOrder()

        Task {
            await resolver.bootstrap()
            await refreshRunning()
            selectFirstOnLaunch()
        }

        // Lightweight reconciliation only when it matters (plan §19).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshRunning()
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

    // MARK: - Running state

    func refreshRunning() async {
        if let ids = try? await backend.listRunningIDs() {
            runningIDs = ids
        }
    }

    // MARK: - Draft sessions (⌘N / ⌘T)

    /// Creates an unstarted draft session and selects it. The detail area
    /// shows the agent picker; no modal.
    func createDraft() {
        let directory = selectedSession?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
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
        Task { await launch(session) }
    }

    // MARK: - Creation / teardown

    /// Starts the backing tmux session (if needed) and attaches a terminal.
    func launch(_ session: Session) async {
        guard !launching.contains(session.id) else { return }
        launching.insert(session.id)
        defer { launching.remove(session.id) }

        launchErrors[session.id] = nil
        do {
            if try await !backend.exists(session) {
                guard let agent = agent(for: session) else { return }
                try await backend.create(session, agent: agent)
            }
            await refreshRunning()
            attachTerminal(to: session)
        } catch {
            Log.backend.error(
                "launch failed for \(session.title, privacy: .public): \(String(describing: error), privacy: .public)")
            launchErrors[session.id] = error.localizedDescription
            await refreshRunning()
        }
    }

    private func attachTerminal(to session: Session) {
        guard let spec = try? backend.attachCommand(for: session) else {
            launchErrors[session.id] = "tmux could not be resolved."
            return
        }
        let host = hostCenter.host(for: session)
        host.onChildExited = { [weak self] in
            guard let self else { return }
            // The attach client exited (detached or killed). Drop the surface;
            // running state decides what the placeholder offers next.
            self.hostCenter.closeHost(for: session.id)
            Task { await self.refreshRunning() }
        }
        host.attach(to: spec)
    }

    /// Explicit stop: terminates the tmux session. Metadata remains.
    func stop(_ session: Session) async {
        try? await backend.stop(session)
        hostCenter.closeHost(for: session.id)
        await refreshRunning()
    }

    /// Delete metadata only (keeps the tmux session running if present).
    func deleteMetadata(_ session: Session) {
        hostCenter.closeHost(for: session.id)
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = activeSessions.first?.id
        }
        persist()
    }

    // MARK: - Editing

    func rename(_ session: Session, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessions[index].title = trimmed
        persist()
    }

    func setArchived(_ session: Session, _ archived: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].isArchived = archived
        if archived, selectedSessionID == session.id {
            selectedSessionID = activeSessions.first?.id
        }
        persist()
    }

    func toggleArchived(_ session: Session) {
        setArchived(session, !session.isArchived)
    }

    func move(session: Session, offset: Int) {
        var active = activeSessions
        guard let index = active.firstIndex(where: { $0.id == session.id }) else { return }
        let target = index + offset
        guard active.indices.contains(target) else { return }
        active.swapAt(index, target)
        for (order, s) in active.enumerated() {
            if let i = sessions.firstIndex(where: { $0.id == s.id }) {
                sessions[i].sortOrder = order
            }
        }
        persist()
    }

    func reorder(from source: Session.ID, to destination: Session.ID) {
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
        let dirName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return dirName.isEmpty ? agent.name : "\(agent.name) — \(dirName)"
    }
}
