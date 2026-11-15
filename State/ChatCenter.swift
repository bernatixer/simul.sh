import Foundation
import Observation

@MainActor
@Observable
final class ChatSessionModel {
    var state: ChatState
    init(_ state: ChatState) { self.state = state }
}

/// Owns Chat children and session state while the views come and go.
@MainActor
@Observable
final class ChatCenter {
    private(set) var sessions: [UUID: ChatSessionModel] = [:]
    private(set) var connected: Set<UUID> = []
    @ObservationIgnored var onEvent: ((UUID, ChatAgentEvent) -> Void)?
    @ObservationIgnored private var clients: [UUID: any ChatAgentClient] = [:]
    @ObservationIgnored private var closing: [UUID: Int32] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []
    @ObservationIgnored private var loadTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var recent: [UUID] = []
    @ObservationIgnored private var loadErrors: Set<UUID> = []
    @ObservationIgnored private var submitting: Set<UUID> = []
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var flushes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var buffered: [UUID: [ChatAgentEvent]] = [:]
    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let makeClient: (Session) -> any ChatAgentClient
    @ObservationIgnored private let disk = DispatchQueue(label: "sh.simul.chat.store", qos: .utility)

    init(store: ChatStore = ChatStore(), makeClient: @escaping (Session) -> any ChatAgentClient = {
        $0.agentID == "codex" ? CodexChatClient() : ClaudeChatClient()
    }) {
        self.store = store
        self.makeClient = makeClient
    }

    func prepare(_ id: UUID) async {
        recent.removeAll { $0 == id }
        recent.append(id)
        guard sessions[id] == nil else { return }
        if loading.contains(id) {
            while loading.contains(id) {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            return
        }
        loading.insert(id)
        let token = UUID()
        loadTokens[id] = token
        defer { loading.remove(id) }
        let loaded: Result<ChatState?, Error> = await withCheckedContinuation { continuation in
            disk.async { [store] in
                continuation.resume(returning: Result {
                    let state = try store.load(for: id)
                    if let state {
                        let entries = state.conversation.entries
                        if let anchor = state.readingAnchor, let index = entries.firstIndex(where: { $0.id == anchor }) {
                            ChatMarkdown.cache.prewarm(Array(entries[index..<min(index + 200, entries.count)]))
                        }
                        ChatMarkdown.cache.prewarm(Array(entries.suffix(200)))
                    }
                    return state
                })
            }
        }
        guard loadTokens[id] == token else { return }
        var state: ChatState
        switch loaded {
        case let .success(saved): state = saved ?? ChatState()
        case let .failure(error):
            loadErrors.insert(id)
            state = ChatState()
            state.notice = "Could not read the saved Chat: \(error.localizedDescription)"
        }
        state.recover()
        sessions[id] = ChatSessionModel(state)
        await prune(except: id)
    }

    private func prune(except current: UUID) async {
        while sessions.count > 8, let old = recent.first(where: {
            $0 != current && sessions[$0] != nil && !connected.contains($0) && !loading.contains($0) && !submitting.contains($0) && !loadErrors.contains($0)
        }) {
            let saved = sessions[old]?.state
            do { try await save(old) } catch { return }
            guard sessions[old]?.state == saved, !connected.contains(old), !submitting.contains(old), recent.last != old else { return }
            saves.removeValue(forKey: old)?.cancel()
            sessions[old] = nil
            recent.removeAll { $0 == old }
        }
    }

    func update(_ id: UUID, _ body: (inout ChatState) -> Void) {
        guard let session = sessions[id] else { return }
        var state = session.state
        body(&state)
        if state != session.state { session.state = state }
    }

    func connect(_ session: Session, configuration: ChatAgentConfiguration) async {
        let id = session.id
        guard clients[id] == nil else { return }
        let token = UUID()
        generations[id] = token
        await prepare(id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while closingProcess(id) != nil {
            if ContinuousClock.now >= deadline {
                update(id) { $0.phase = .failed; $0.notice = "The previous Chat process is still closing. Try reconnecting again." }
                return
            }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        }
        guard !Task.isCancelled, generations[id] == token, clients[id] == nil, !loadErrors.contains(id) else { return }
        let client = makeClient(session)
        clients[id] = client
        connected.insert(id)
        update(id) { $0.phase = .connecting; $0.notice = nil }
        client.onEvent = { [weak self] event in
            guard let self, self.generations[id] == token else { return }
            switch event {
            case .text, .tool:
                self.buffered[id, default: []].append(event)
                if self.flushes[id] == nil {
                    self.flushes[id] = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(32))
                        guard !Task.isCancelled else { return }
                        self?.flush(id)
                    }
                }
            default:
                self.flush(id)
                self.receive(event, id: id)
            }
        }
        do {
            try await client.start(configuration)
            guard generations[id] == token else { return }
            await drain(id)
        } catch {
            guard generations[id] == token else { return }
            if let pid = client.processID { closing[id] = pid }
            client.onEvent = nil
            client.close()
            clients[id] = nil
            connected.remove(id)
            update(id) { $0.phase = .failed; $0.notice = error.localizedDescription; $0.queuePaused = true }
            saveSoon(id)
        }
    }

    private func flush(_ id: UUID) {
        flushes.removeValue(forKey: id)?.cancel()
        let events = buffered.removeValue(forKey: id) ?? []
        guard !events.isEmpty else { return }
        update(id) { state in for event in events { state.apply(event) } }
    }

    private func receive(_ event: ChatAgentEvent, id: UUID) {
        update(id) { $0.apply(event) }
        onEvent?(id, event)
        if case let .disconnected(message) = event {
            _ = close(id)
            update(id) { $0.notice = message }
        }
        saveSoon(id)
        switch event {
        case .finished(.completed, _), .accepted: Task { await drain(id) }
        default: break
        }
    }

    func setDraft(_ draft: [ComposerPart], for id: UUID) {
        update(id) { $0.draft = ComposerPart.normalized(draft) }
        saveSoon(id)
    }

    func submitDraft(_ id: UUID) async {
        guard !submitting.contains(id), let slot = sessions[id] else { return }
        guard !ComposerPart.pieces(slot.state.draft).isEmpty else { return }
        submitting.insert(id)
        defer { submitting.remove(id) }
        var messageID: String?
        update(id) { state in
            if state.outbox.isEmpty, state.phase == .idle { state.queuePaused = false }
            messageID = state.enqueueDraft()?.id
            state.notice = nil
            state.followsLatest = true
        }
        guard let messageID else { return }
        do { try await save(id) }
        catch {
            update(id) { $0.deliveryFailed(messageID, message: "Could not save this message: \(error.localizedDescription)", uncertain: false) }
            return
        }
        let pieces = sessions[id]?.state.outbox.first(where: { $0.id == messageID })?.message.pieces ?? []
        let missing = await Task.detached {
            pieces.contains { if case let .image(url) = $0 { !FileManager.default.fileExists(atPath: url.path) } else { false } }
        }.value
        guard !missing else {
            update(id) { $0.deliveryFailed(messageID, message: "An attachment is missing. Edit this message to attach it again.", uncertain: false) }
            saveSoon(id)
            return
        }
        await drain(id)
    }

    func enqueue(_ pieces: [PromptPiece], for id: UUID) async -> Bool {
        guard connected.contains(id), !pieces.isEmpty, sessions[id] != nil else { return false }
        let message = ChatOutgoingMessage(pieces: pieces)
        update(id) { state in
            if state.outbox.isEmpty, state.phase == .idle { state.queuePaused = false }
            state.outbox.append(ChatPendingMessage(message: message))
        }
        do { try await save(id) }
        catch {
            update(id) { $0.deliveryFailed(message.id, message: error.localizedDescription, uncertain: false) }
            return false
        }
        Task { await drain(id) }
        return true
    }

    private func drain(_ id: UUID) async {
        guard let client = clients[id], connected.contains(id) else { return }
        var next: ChatOutgoingMessage?
        update(id) { next = $0.beginNext() }
        guard let next else { return }
        let token = generations[id]
        do {
            // boffin: persist sending before writing; a restart must check history before a retry.
            try await save(id)
            guard generations[id] == token else { return }
            try await client.send(next)
        } catch {
            guard generations[id] == token else { return }
            let uncertain: Bool
            if case .uncertain = error as? ChatAgentError { uncertain = true } else { uncertain = false }
            update(id) { $0.deliveryFailed(next.id, message: error.localizedDescription, uncertain: uncertain) }
            saveSoon(id)
        }
    }

    func resumeQueue(_ id: UUID) {
        guard connected.contains(id), sessions[id]?.state.isBusy == false else { return }
        update(id) { $0.queuePaused = false; $0.phase = .idle }
        saveSoon(id)
        Task { await drain(id) }
    }

    func returnToDraft(_ message: ChatPendingMessage, for id: UUID) {
        guard let current = sessions[id]?.state.outbox.first(where: { $0.id == message.id }), current.status != .sending else { return }
        update(id) { state in
            let parts = current.message.pieces.map { piece -> ComposerPart in
                switch piece {
                case let .text(text): .text(text)
                case let .image(url): .image(ComposerImage(url: url, name: url.lastPathComponent))
                }
            }
            state.draft = ComposerPart.normalized(parts + (state.draft.isEmpty ? [] : [.text("\n")]) + state.draft)
            state.outbox.removeAll { $0.id == message.id }
        }
        saveSoon(id)
    }

    func removeQueued(_ message: ChatPendingMessage, for id: UUID) {
        guard let current = sessions[id]?.state.outbox.first(where: { $0.id == message.id }), current.status != .sending else { return }
        update(id) { $0.outbox.removeAll { $0.id == message.id } }
        saveSoon(id)
    }

    func interrupt(_ id: UUID) {
        guard let client = clients[id], sessions[id]?.state.isBusy == true else { return }
        if sessions[id]?.state.phase == .sending {
            _ = close(id)
            let notice = "Stopped while sending. Reconnect to check whether the agent received this message."
            update(id) { $0.notice = notice }
            onEvent?(id, .disconnected(notice))
            return
        }
        update(id) { $0.queuePaused = true; $0.phase = .stopping }
        saveSoon(id)
        client.interrupt()
        let token = generations[id]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.generations[id] == token, self.sessions[id]?.state.phase == .stopping else { return }
            _ = self.close(id)
            self.update(id) { $0.notice = "The agent did not confirm Stop. Chat disconnected; reconnect to check the conversation." }
        }
    }

    func respond(_ request: ChatAgentRequest, id: UUID, decision: ChatAgentDecision, answers: [String: [String]] = [:]) {
        guard let client = clients[id], sessions[id]?.state.requests.contains(where: { $0.id == request.id }) == true else { return }
        do {
            try client.respond(to: request.id, decision: decision, answers: answers)
            update(id) { $0.apply(.requestResolved(id: request.id)) }
        } catch { update(id) { $0.notice = error.localizedDescription } }
    }

    @discardableResult
    func close(_ id: UUID) -> Int32? {
        flush(id)
        generations[id] = nil
        let client = clients.removeValue(forKey: id)
        let pid = client?.processID ?? closingProcess(id)
        if let pid { closing[id] = pid }
        client?.onEvent = nil
        client?.close()
        connected.remove(id)
        update(id) { $0.recover() }
        saveSoon(id)
        return pid
    }

    func closingProcess(_ id: UUID) -> Int32? {
        guard let pid = closing[id] else { return nil }
        if kill(pid, 0) == 0 { return pid }
        closing[id] = nil
        return nil
    }

    func forget(_ id: UUID) {
        _ = close(id)
        loadTokens[id] = nil
        saves.removeValue(forKey: id)?.cancel()
        sessions[id] = nil
        disk.async { [store] in try? store.remove(for: id) }
    }

    func saveSoon(_ id: UUID) {
        saves.removeValue(forKey: id)?.cancel()
        saves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            do { try await self.save(id) }
            catch { self.update(id) { $0.notice = "Chat could not be saved: \(error.localizedDescription)" } }
        }
    }

    private func save(_ id: UUID) async throws {
        guard !loadErrors.contains(id) else { throw ChatAgentError.rejected("The saved Chat could not be read. Its files have been kept.") }
        guard let state = sessions[id]?.state else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            disk.async { [store] in
                do { try store.save(state, for: id); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func finish() {
        for id in Array(clients.keys) { _ = close(id) }
        let states = sessions.filter { !loadErrors.contains($0.key) }.mapValues(\.state)
        for task in saves.values { task.cancel() }
        disk.sync { [store] in for (id, state) in states { try? store.save(state, for: id) } }
    }
}
