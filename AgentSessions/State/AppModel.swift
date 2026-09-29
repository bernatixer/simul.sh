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

    /// Modal state for the new-session sheet, rename dialog, delete dialog.
    var showingNewSession = false
    var renaming: Session.ID?
    var pendingDelete: Session.ID?

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
        selectedSessionID = session.id
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
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

    // MARK: - Creation / teardown

    func createSession(title: String, workingDirectory: String, agent: AgentDefinition) {
        let order = (sessions.map(\.sortOrder).max() ?? -1) + 1
        let session = Session(
            title: title.isEmpty ? defaultTitle(for: agent, workingDirectory: workingDirectory) : title,
            workingDirectory: workingDirectory,
            agentID: agent.id,
            sortOrder: order
        )
        sessions.append(session)
        persist()
        selectedSessionID = session.id

        Task {
            await launch(session)
        }
    }

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
