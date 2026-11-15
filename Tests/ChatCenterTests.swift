import Foundation
@testable import SimulCore

@MainActor
private final class ChatFixtureClient: ChatAgentClient {
    var processID: Int32?
    var onEvent: ((ChatAgentEvent) -> Void)?
    var sent: [ChatOutgoingMessage] = []
    var finishesBeforeAcceptance = false
    var startDelay = false
    var starts = 0
    func start(_ configuration: ChatAgentConfiguration) async throws {
        starts += 1
        if startDelay { try await Task.sleep(for: .milliseconds(60)) }
        onEvent?(.ready(conversationID: "exact-id", model: nil))
    }
    func send(_ message: ChatOutgoingMessage) async throws {
        sent.append(message)
        if finishesBeforeAcceptance {
            onEvent?(.finished(outcome: .completed, error: nil))
            try await Task.sleep(for: .milliseconds(15))
        }
        onEvent?(.accepted(messageID: message.id))
    }
    func setOptions(model: String?, effort: String?) async throws {}
    func respond(to requestID: String, decision: ChatAgentDecision, answers: [String: [String]]) throws {}
    func interrupt() {}
    func close() {}
}

@MainActor
func registerChatCenterTests() {
    test("Cancelling a waiting Chat reconnect returns without blocking the UI") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.7"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let client = ChatFixtureClient()
        let center = ChatCenter(store: ChatStore(folder: folder), makeClient: { _ in client })
        let configuration = ChatAgentConfiguration(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id)
        await center.connect(session, configuration: configuration)
        client.processID = child.processIdentifier
        _ = center.close(session.id)
        let reconnect = Task { await center.connect(session, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(20))
        let started = ContinuousClock.now
        reconnect.cancel()
        await reconnect.value
        expect(started.duration(to: .now) < .milliseconds(200), "a cancelled wait never spins on the main actor")
        expectEqual(client.starts, 1, "a cancelled reconnect cannot create a replacement")
        center.finish()
    }
    test("Chat history is ready to lay out before the session is published") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let text = "### \(UUID().uuidString)\n\n- A list item\n- Another item\n\n> A quoted paragraph"
        let store = ChatStore(folder: folder)
        var state = ChatState()
        state.conversation.entries = [.reply(id: "reply", text: text)]
        try store.save(state, for: id)
        let center = ChatCenter(store: store)
        await center.prepare(id)
        expectEqual(ChatMarkdown.cache.cached(text), ChatMarkdown.parse(text), "mounting or scrolling to an imported reply needs no asynchronous reflow")
        center.finish()
    }
    test("Chat Stop during persistence cannot send the message afterwards") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let client = ChatFixtureClient()
        let center = ChatCenter(store: ChatStore(folder: folder), makeClient: { _ in client })
        await center.connect(session, configuration: .init(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id))
        center.update(session.id) { $0.conversation.entries = [.reply(id: "large", text: String(repeating: "history ", count: 700_000))] }
        center.setDraft([.text("do not send after Stop")], for: session.id)
        let submission = Task { await center.submitDraft(session.id) }
        while center.sessions[session.id]?.state.phase != .sending { await Task.yield() }
        center.interrupt(session.id)
        await submission.value
        expect(client.sent.isEmpty, "Stop invalidates delivery before the pipe write")
        expectEqual(center.sessions[session.id]?.state.outbox.first?.status, .uncertain, "the message remains recoverable")
        center.finish()
    }
    test("Chat cache eviction preserves a draft edited while its snapshot saves") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ChatStore(folder: folder)
        let center = ChatCenter(store: store)
        let old = UUID()
        await center.prepare(old)
        center.update(old) {
            $0.draft = [.text("old draft")]
            $0.conversation.entries = [.reply(id: "large", text: String(repeating: "history ", count: 700_000))]
        }
        for _ in 0..<7 { await center.prepare(UUID()) }
        let newest = UUID()
        let loading = Task { await center.prepare(newest) }
        while center.sessions[newest] == nil { await Task.yield() }
        center.setDraft([.text("new draft")], for: old)
        await loading.value
        center.finish()
        let saved = try store.load(for: old)
        expectEqual(saved?.draft, [.text("new draft")], "an edit during eviction remains durable")
    }
    test("Chat center exposes an idle provider exit immediately") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let client = ChatFixtureClient()
        let center = ChatCenter(store: ChatStore(folder: folder), makeClient: { _ in client })
        await center.connect(session, configuration: .init(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id))
        client.onEvent?(.disconnected("Connection closed"))
        expect(!center.connected.contains(session.id), "a dead provider no longer appears running")
        expectEqual(center.sessions[session.id]?.state.phase, .disconnected, "Reconnect is available before another send fails")
        expectEqual(center.sessions[session.id]?.state.notice, "Connection closed", "the cause remains visible")
        center.finish()
    }
    test("Chat review handoff saves a message without overwriting the user's draft") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let store = ChatStore(folder: folder)
        let client = ChatFixtureClient()
        let center = ChatCenter(store: store, makeClient: { _ in client })
        await center.connect(session, configuration: .init(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id))
        center.setDraft([.text("my unfinished question")], for: session.id)
        center.update(session.id) { $0.phase = .working }
        let queued = await center.enqueue([.text("Review these changes")], for: session.id)
        expect(queued, "Review can mark its comments sent after the queue is durable")
        let saved = try store.load(for: session.id)
        expectEqual(saved?.draft, [.text("my unfinished question")], "Review never borrows the user's draft")
        expectEqual(saved?.outbox.first?.message.pieces, [.text("Review these changes")], "Review's prompt is in the saved queue")
        expect(client.sent.isEmpty, "a working turn retains ownership until completion")
        center.finish()
    }
    test("Chat center retains a closing owner across repeated handoffs") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.3"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let client = ChatFixtureClient()
        let center = ChatCenter(store: ChatStore(folder: folder), makeClient: { _ in client })
        let config = ChatAgentConfiguration(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id)
        await center.connect(session, configuration: config)
        client.processID = child.processIdentifier
        let first = center.close(session.id)
        let repeated = center.close(session.id)
        expectEqual(repeated, first, "a second close must still wait for the original owner")
        let reconnect = Task { await center.connect(session, configuration: config) }
        try await Task.sleep(for: .milliseconds(30))
        expectEqual(client.starts, 1, "replacement cannot start while the old PID is alive")
        _ = center.close(session.id)
        await reconnect.value
        expectEqual(client.starts, 1, "Stop cancels a reconnect waiting for the old child")
        center.finish()
    }
    test("Chat center drains a queued message after a late acknowledgement") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let client = ChatFixtureClient()
        client.finishesBeforeAcceptance = true
        let center = ChatCenter(store: ChatStore(folder: folder), makeClient: { _ in client })
        await center.prepare(session.id)
        center.update(session.id) {
            $0.outbox = [.init(message: .init(id: "first", pieces: [.text("first")])), .init(message: .init(id: "second", pieces: [.text("second")]))]
            $0.queuePaused = false
        }
        await center.connect(session, configuration: .init(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id))
        try await Task.sleep(for: .milliseconds(80))
        expectEqual(client.sent.map(\.id), ["first", "second"], "completion before acknowledgement cannot strand the queue")
        center.finish()
    }
    test("Chat center rejects a stale edit after a queued message starts sending") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let center = ChatCenter(store: ChatStore(folder: folder))
        await center.prepare(id)
        let copied = ChatPendingMessage(message: .init(pieces: [.text("already on the wire")]))
        center.update(id) { $0.outbox = [copied]; $0.phase = .idle; _ = $0.beginNext() }
        center.returnToDraft(copied, for: id)
        center.removeQueued(copied, for: id)
        expectEqual(center.sessions[id]?.state.outbox.first?.status, .sending, "stale UI actions cannot remove an in-flight send")
        expect(center.sessions[id]?.state.draft.isEmpty == true, "an in-flight send cannot become a resendable draft")
        center.finish()
    }
    test("Chat center concurrent preparation publishes saved state before connecting") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(title: "Fixture", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
        let store = ChatStore(folder: folder)
        var state = ChatState()
        state.draft = [.text("saved draft")]
        try store.save(state, for: session.id)
        let client = ChatFixtureClient()
        let center = ChatCenter(store: store, makeClient: { _ in client })
        async let preparation: Void = center.prepare(session.id)
        await center.connect(session, configuration: .init(executable: "/tmp/fixture", workingDirectory: "/tmp", sessionID: session.id))
        await preparation
        expectEqual(center.sessions[session.id]?.state.draft, state.draft, "saved draft survives concurrent preparation")
        expectEqual(center.sessions[session.id]?.state.conversationID, "exact-id", "ready events cannot be overwritten by a late load")
        center.finish()
    }
}
