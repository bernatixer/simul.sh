import Foundation
@testable import SimulCore

@MainActor
func registerChatStateTests() {
    test("Chat runtime labels show the resolved model instead of its default alias") {
        var state = ChatState()
        state.models = [.init(id: "default", name: "Default (recommended)", resolvedID: "claude-opus-5-5")]
        state.apply(.ready(conversationID: "thread", model: "claude-opus-5-5"))
        expectEqual(state.modelLabel, "Opus 5.5", "the label names the model in use")
        state.apply(.modelChanged("default"))
        expectEqual(state.modelLabel, "Opus 5.5", "a reported alias resolves through the provider catalog")
        state.models = []
        expectEqual(state.modelLabel, nil, "an unresolved default is not presented as an actual model")
        state.models = [.init(id: "gpt-6.1-sol", name: "GPT-6.1-Sol")]
        state.apply(.modelChanged("gpt-6.1-sol"))
        expectEqual(state.modelLabel, "GPT-6.1-Sol", "Codex uses its model's reported display name")
    }
    test("Chat draft normalization matches native text storage") {
        expectEqual(ComposerPart.normalized([.text("queued"), .text("\n"), .text("draft"), .text("")]), [.text("queued\ndraft")], "adjacent text has one representation, so streaming never rebuilds an unchanged editor")
    }
    test("Chat history reconciles uncertain sends without resending") {
        var state = ChatState()
        state.outbox = [.init(message: .init(id: "ack", pieces: [.text("hello")]), status: .uncertain)]
        state.queuePaused = true
        state.apply(.history([.prompt(id: "ack", text: "hello"), .reply(id: "answer", text: "Hi")]))
        expect(state.outbox.isEmpty, "provider history confirms the original message identity")
        expectEqual(state.conversation.prompts, 1, "reconciliation doesn't duplicate the prompt")
        expect(state.queuePaused, "recovery doesn't resume queued work")
    }
    test("Chat store protects newer snapshots and recovers a corrupt primary") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let store = ChatStore(folder: folder)
        var state = ChatState()
        state.draft = [.text("saved draft")]
        try store.save(state, for: id)
        try store.save(state, for: id)
        let file = folder.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        try Data("broken".utf8).write(to: file)
        let recovered = try store.load(for: id)
        expectEqual(recovered?.draft, state.draft, "backup recovers the complete draft")
        try store.save(state, for: id)
        let backupData = try Data(contentsOf: file.appendingPathExtension("prev"))
        expect((try? JSONSerialization.jsonObject(with: backupData)) != nil, "saving after recovery never rotates corrupt bytes over the valid backup")
        let future = Data("{\"version\":99,\"future\":true}".utf8)
        try future.write(to: file)
        await expectThrows("newer primary isn't replaced by an older backup") { _ = try store.load(for: id) }
        await expectThrows("newer primary cannot be overwritten") { try store.save(state, for: id) }
        let preserved = try Data(contentsOf: file)
        expectEqual(preserved, future, "the newer file remains byte-for-byte unchanged")
    }
    test("Chat outbox keeps stable identities and pauses uncertain sends") {
        var state = ChatState()
        state.draft = [.text("first")]
        let first = state.enqueueDraft()!
        state.draft = [.text("second")]
        let second = state.enqueueDraft()!
        expect(state.draft.isEmpty, "the persisted outbox owns submitted draft contents")
        expectEqual(state.beginNext()?.id, first.id, "first queued message is sent first")
        expectEqual(state.beginNext(), nil, "a second send cannot overlap")
        state.deliveryFailed(first.id, message: "Connection lost", uncertain: true)
        expectEqual(state.outbox.first?.status, .uncertain, "written but unacknowledged is uncertain")
        expectEqual(state.beginNext(), nil, "uncertain sends block automatic queue draining")
        state.accept(first.id)
        expectEqual(state.conversation.entries, [.prompt(id: first.id, text: "first")], "late acknowledgement settles exactly once")
        state.accept(first.id)
        expectEqual(state.conversation.prompts, 1, "duplicate acknowledgement is harmless")
        state.apply(.finished(outcome: .completed, error: nil))
        state.queuePaused = false
        expectEqual(state.beginNext()?.id, second.id, "remaining queue retains its original identity")
    }
    test("Chat recovery preserves drafts and never replays an in-flight message") {
        var state = ChatState()
        state.conversationID = "exact-thread"
        state.draft = [.image(ComposerImage(url: URL(fileURLWithPath: "/tmp/draft.png"), name: "draft.png")), .text(" explain")]
        let draft = state.draft
        state.outbox = [ChatPendingMessage(message: .init(id: "send-id", pieces: [.text("already written")]), status: .sending)]
        state.phase = .working
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ChatStore(folder: folder)
        try store.save(state, for: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var recovered = try store.load(for: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)!
        recovered.recover()
        expectEqual(recovered.conversationID, "exact-thread", "resume identity is durable")
        expectEqual(recovered.draft, draft, "text and attachment tokens survive restart")
        expectEqual(recovered.outbox.first?.message.id, "send-id", "send identity survives restart")
        expectEqual(recovered.outbox.first?.status, .uncertain, "an in-flight send needs reconciliation")
        expectEqual(recovered.beginNext(), nil, "restart never automatically resends")
        expectEqual(recovered.phase, .disconnected, "there is no live child after restart")
    }
    test("Chat reducer converges streamed text and full replies without losing tool tails") {
        var state = ChatState()
        state.apply(.text(id: "reply", delta: "Hel"))
        state.apply(.text(id: "reply", delta: "lo"))
        state.apply(.reply(id: "reply", text: "Hello!"))
        state.apply(.reply(id: "reply", text: "Hello!"))
        expectEqual(state.conversation.entries, [.reply(id: "reply", text: "Hello!")], "full reply replaces deltas")
        let output = String(repeating: "log\n", count: 1500) + "FINAL ERROR"
        state.apply(.tool(ChatTool(id: "tool", name: "Run", summary: "Build", detail: "swift build")))
        state.apply(.tool(ChatTool(id: "tool", name: "Run", summary: "Build", detail: "swift build", result: output, isError: true)))
        guard case let .tools(_, tools) = state.conversation.entries.last else { return expect(false, "one grouped tool run") }
        expectEqual(tools.count, 1, "completion replaces the running tool")
        expect(tools[0].result?.hasSuffix("FINAL ERROR") == true, "the final error remains available")
        state.apply(.finished(outcome: .interrupted, error: nil))
        expect(state.queuePaused, "interrupt pauses queued work")
    }
}
