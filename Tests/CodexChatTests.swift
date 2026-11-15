import Foundation
@testable import SimulCore

@MainActor
func registerCodexChatTests() {
    test("Codex Chat: thread names load and updates stay scoped to their thread") {
        let fixture = try CodexFixture(mode: "titles")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var names: [String] = []
        var finished = false
        client.onEvent = {
            if case let .titleChanged(title) = $0 { names.append(title) }
            if case .finished = $0 { finished = true }
        }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
        try await codexWait { finished }
        expectEqual(names, ["Imported title", "Useful conversation name"], "another thread and empty updates cannot rename this conversation")
    }
    test("Codex Chat: native payloads, streamed replies and explicit completion") {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.setOptions(model: "model-two", effort: "high")
        try await client.send(ChatOutgoingMessage(id: "send-one", pieces: [.text("Fix this"), .image(URL(fileURLWithPath: "/tmp/image.png"))]))
        try await codexWait { events.contains { if case .finished = $0 { return true }; return false } }

        let messages = try fixture.messages()
        let initialize = messages.first { $0["method"] as? String == "initialize" }?["params"] as? [String: Any]
        let capabilities = initialize?["capabilities"] as? [String: Any]
        expectEqual(capabilities?["experimentalApi"] as? Bool, true, "questions enabled")
        expectEqual(capabilities?["requiredHumanApproval"] as? Bool, true, "human command approvals enabled")
        let thread = messages.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any]
        expectEqual(thread?["sandbox"] as? String, "read-only", "manual mode preserves its sandbox")
        expectEqual(thread?["approvalPolicy"] as? String, "on-request", "manual mode asks before escalation")
        expectEqual(thread?["approvalsReviewer"] as? String, "user", "approval belongs to the user")
        let turn = messages.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any]
        expectEqual(turn?["threadId"] as? String, "thread-one", "send reaches its own thread")
        expectEqual(turn?["clientUserMessageId"] as? String, "send-one", "send identity survives the wire")
        expectEqual(turn?["model"] as? String, "model-two", "selected model reaches the provider")
        expectEqual(turn?["effort"] as? String, "high", "selected effort reaches the provider")
        let input = turn?["input"] as? [[String: Any]] ?? []
        expectEqual(input.first?["text"] as? String, "Fix this", "prompt text stays intact")
        expectEqual(input.last?["path"] as? String, "/tmp/image.png", "local image uses structured input")
        expect(events.contains { if case .accepted(messageID: "send-one") = $0 { return true }; return false }, "acknowledged send")
        expectEqual(events.compactMap { if case let .text(_, delta) = $0 { return delta }; return nil }, ["Hel", "lo"], "thread-scoped text deltas")
        expect(events.contains { if case .reply(id: "reply-one", text: "Hello") = $0 { return true }; return false }, "completed item supplies authoritative text")
        expect(events.contains { if case .finished(outcome: .completed, error: nil) = $0 { return true }; return false }, "explicit turn completion")
        let tools = events.compactMap { if case let .tool(tool) = $0 { return tool }; return nil }
        expectEqual(tools.first?.result, nil, "running command has no result")
        expectEqual(tools.last?.result, "", "successful empty command has a result")
    }

    test("Codex Chat: paginated history keeps client identities and failed tools") {
        let fixture = try CodexFixture(mode: "history")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration(conversationID: "thread-one"))
        let history: [ChatEntry] = events.compactMap { if case let .history(entries) = $0 { return entries }; return nil }.last ?? []
        expectEqual(history.first, .prompt(id: "persisted-send", text: "Earlier prompt"), "persisted client ID reconciles the local outbox")
        expect(history.contains(.reply(id: "old-reply", text: "Earlier reply")), "history spans pages")
        let tools: [ChatTool] = history.flatMap { if case let .tools(_, tools) = $0 { return tools }; return [] }
        expectEqual(tools.first?.result, "build failed", "failed command output stays in history")
        expectEqual(tools.first?.isError, true, "failed command stays failed")
        expect(events.contains { if case .accepted(messageID: "persisted-send") = $0 { return true }; return false }, "historical acknowledgment recovers uncertain sends")
        let requests = try fixture.messages().filter { $0["method"] as? String == "thread/turns/list" }
        expectEqual(requests.count, 2, "loads every page")
        let params = requests.first?["params"] as? [String: Any]
        expectEqual(params?["itemsView"] as? String, "full", "asks for full tool output")
        expectEqual(params?["sortDirection"] as? String, "asc", "oldest turn first")
        expect(!events.contains { if case .finished = $0 { return true }; return false }, "old completed turns do not finish a new send")
    }

    test("Codex Chat: approvals and questions reply using their original RPC IDs") {
        let fixture = try CodexFixture(mode: "approvals")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(id: "approval-send", pieces: [.text("Run it")]))
        try await codexWait { codexRequests(events).count == 1 }
        let command = codexRequests(events)[0]
        expect(command.detail.contains("touch /tmp/example"), "approval shows the full command")
        expect(command.allowsSessionApproval, "ordinary command supports session approval")
        try client.respond(to: command.id, decision: .allowSession, answers: [:])
        try await codexWait { codexRequests(events).count == 2 }
        let question = codexRequests(events)[1]
        expectEqual(question.questions.first?.id, "color", "question identity is preserved")
        expectEqual(question.questions.first?.options.map(\.label), ["Blue", "Green"], "question choices are native data")
        try client.respond(to: question.id, decision: .allow, answers: ["color": ["Green"]])
        try await codexWait { events.contains { if case .finished = $0 { return true }; return false } }
        let responses = try fixture.messages().filter { $0["method"] == nil && $0["result"] != nil }
        expectEqual(responses.first?["id"] as? Int, 71, "numeric request ID stays numeric")
        expectEqual((responses.first?["result"] as? [String: Any])?["decision"] as? String, "acceptForSession", "approval decision uses protocol value")
        expectEqual(responses.last?["id"] as? String, "question-rpc", "string request ID stays a string")
        let result = responses.last?["result"] as? [String: Any]
        let answers = result?["answers"] as? [String: [String: [String]]]
        expectEqual(answers?["color"]?["answers"], ["Green"], "answer maps to its question")
        expect(events.contains { if case .requestResolved(id: command.id) = $0 { return true }; return false }, "resolved approvals leave the UI")
    }

    test("Codex Chat: human checkpoints cannot receive session approval") {
        let fixture = try CodexFixture(mode: "human")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(pieces: [.text("Run it")]))
        try await codexWait { !codexRequests(events).isEmpty }
        let request = codexRequests(events)[0]
        expect(!request.allowsSessionApproval, "human checkpoint requires a fresh decision")
        await expectThrows("session approval rejected for a human checkpoint") {
            try client.respond(to: request.id, decision: .allowSession, answers: [:])
        }
        try client.respond(to: request.id, decision: .deny, answers: [:])
        try await codexWait { events.contains { if case .finished = $0 { return true }; return false } }
        let response = try fixture.messages().first { $0["method"] == nil && $0["result"] != nil }
        expectEqual((response?["result"] as? [String: Any])?["decision"] as? String, "decline", "denial leaves the agent able to continue")
    }

    test("Codex Chat: Stop targets the active turn and waits for interruption") {
        let fixture = try CodexFixture(mode: "interrupt")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration(skipPermissions: true))
        try await client.send(ChatOutgoingMessage(pieces: [.text("Work")]))
        expect(!events.contains { if case .finished = $0 { return true }; return false }, "acknowledgment alone does not finish the turn")
        client.interrupt()
        try await codexWait { events.contains { if case .finished(outcome: .interrupted, error: nil) = $0 { return true }; return false } }
        let messages = try fixture.messages()
        let interrupt = messages.first { $0["method"] as? String == "turn/interrupt" }?["params"] as? [String: Any]
        expectEqual(interrupt?["threadId"] as? String, "thread-one", "Stop targets its thread")
        expectEqual(interrupt?["turnId"] as? String, "turn-one", "Stop targets its active turn")
        let params = messages.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any]
        expectEqual(params?["sandbox"] as? String, "danger-full-access", "explicit bypass reaches the server")
        expectEqual(params?["approvalPolicy"] as? String, "never", "explicit bypass skips approvals")
    }

    test("Codex Chat: rejected and uncertain sends remain distinct") {
        for mode in ["rejected", "lost"] {
            let fixture = try CodexFixture(mode: mode)
            defer { fixture.remove() }
            let client = CodexChatClient()
            defer { client.close() }
            try await client.start(fixture.configuration())
            do {
                try await client.send(ChatOutgoingMessage(pieces: [.text("Keep this draft")]))
                expect(false, "\(mode) send throws")
            } catch let error as ChatAgentError {
                switch (mode, error) {
                case ("rejected", .rejected), ("lost", .uncertain): expect(true, "delivery outcome preserved")
                default: expect(false, "wrong delivery outcome: \(error)")
                }
            }
        }
    }

    test("Codex Chat: missing threads fail without creating replacements") {
        let fixture = try CodexFixture(mode: "missing")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        await expectThrows("missing saved thread is visible") {
            try await client.start(fixture.configuration(conversationID: "thread-missing"))
        }
        let messages = try fixture.messages()
        expect(!messages.contains { $0["method"] as? String == "thread/start" }, "resume never falls back to a new conversation")
    }

    test("Codex Chat: optional secure questions survive turn completion") {
        let fixture = try CodexFixture(mode: "optional")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(pieces: [.text("Work")]))
        try await codexWait { events.contains { if case .finished = $0 { return true }; return false } }
        guard let question = codexRequests(events).first else { return expect(false, "optional question is shown") }
        expect(!question.isBlocking, "optional question does not block the queue")
        expectEqual(question.questions.first?.isSecret, true, "secret answer uses secure entry")
        try client.respond(to: question.id, decision: .allow, answers: ["color": ["example-value"]])
        try await codexWait {
            (try? fixture.messages().contains { $0["method"] == nil && $0["id"] as? String == "question-rpc" }) == true
        }
    }

    test("Codex Chat: a late start response cannot reopen a completed turn") {
        let fixture = try CodexFixture(mode: "late-ack")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(id: "first", pieces: [.text("One")]))
        try await client.send(ChatOutgoingMessage(id: "second", pieces: [.text("Two")]))
        expectEqual(events.filter { if case .finished = $0 { return true }; return false }.count, 2, "each turn finishes once")
        expectEqual(events.filter { if case .started = $0 { return true }; return false }.count, 2, "late response adds no extra started event")
    }

    test("Codex Chat: unrecognized tool status cannot appear successful") {
        let fixture = try CodexFixture(mode: "bad-status")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration(conversationID: "thread-one"))
        let history: [ChatEntry] = events.compactMap { if case let .history(entries) = $0 { return entries }; return nil }.last ?? []
        let tools: [ChatTool] = history.flatMap { if case let .tools(_, tools) = $0 { return tools }; return [] }
        expectEqual(tools.first?.isError, true, "unknown status is visible as an error")
    }

    test("Codex Chat: queued Stop cannot reach a replacement process") {
        let first = try CodexFixture(mode: "interrupt")
        let second = try CodexFixture()
        defer { first.remove(); second.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        try await client.start(first.configuration())
        try await client.send(ChatOutgoingMessage(pieces: [.text("Work")]))
        client.interrupt()
        client.close()
        try await client.start(second.configuration())
        let messages = try second.messages()
        expect(!messages.contains { $0["method"] as? String == "turn/interrupt" }, "Stop belongs only to the connection it was requested on")
    }

    test("Codex Chat: a model change uses its advertised default effort") {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        try await client.start(fixture.configuration())
        try await client.setOptions(model: "model-two", effort: nil)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Work")]))
        let messages = try fixture.messages()
        let turn = messages.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any]
        expectEqual(turn?["effort"] as? String, "high", "old model's effort cannot carry into a new model")
    }

    test("Codex Chat: long tool commands and output keep their final lines") {
        let fixture = try CodexFixture(mode: "full-output")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration(conversationID: "thread-one"))
        let history: [ChatEntry] = events.compactMap { if case let .history(entries) = $0 { return entries }; return nil }.last ?? []
        let tools: [ChatTool] = history.flatMap { if case let .tools(_, tools) = $0 { return tools }; return [] }
        expect(tools.first?.detail.hasSuffix("exit 1") == true, "full command stays available")
        expect(tools.first?.result?.hasSuffix("final failure") == true, "the final failure stays available")
    }

    test("Codex Chat: file and permission approvals preserve the requested scope") {
        let fixture = try CodexFixture(mode: "permissions")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(pieces: [.text("Work")]))
        try await codexWait { codexRequests(events).count == 1 }
        let file = codexRequests(events)[0]
        expect(file.detail.contains("+new value"), "file approval shows the actual diff")
        try client.respond(to: file.id, decision: .deny, answers: [:])
        try await codexWait { codexRequests(events).count == 2 }
        let permission = codexRequests(events)[1]
        expect(permission.detail.contains("/tmp/requested-folder"), "permission root is visible")
        try client.respond(to: permission.id, decision: .allow, answers: [:])
        try await codexWait { events.contains { if case .finished = $0 { return true }; return false } }
        let responses = try fixture.messages().filter { $0["method"] == nil && $0["result"] != nil }
        expectEqual((responses.first?["result"] as? [String: Any])?["decision"] as? String, "decline", "file denial reaches the server")
        let result = responses.last?["result"] as? [String: Any]
        let permissions = result?["permissions"] as? [String: Any]
        let fileSystem = permissions?["fileSystem"] as? [String: Any]
        expectEqual(fileSystem?["write"] as? [String], ["/tmp/requested-folder"], "approval grants only the requested root")
        expectEqual(result?["scope"] as? String, "turn", "one-time permission stays scoped to the turn")
    }

    test("Codex Chat: failed Stop closes its process and reports a failed turn") {
        let fixture = try CodexFixture(mode: "interrupt-error")
        defer { fixture.remove() }
        let client = CodexChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration())
        try await client.send(ChatOutgoingMessage(pieces: [.text("Work")]))
        client.interrupt()
        try await codexWait { events.contains { if case .finished(outcome: .failed, error: _) = $0 { return true }; return false } }
        expectEqual(client.processID, nil, "failed interruption cannot leave an agent working behind Chat")
    }
}

@MainActor
private func codexRequests(_ events: [ChatAgentEvent]) -> [ChatAgentRequest] {
    events.compactMap { if case let .request(request) = $0 { return request }; return nil }
}

@MainActor
private func codexWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "CodexFixture", code: 1) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct CodexFixture {
    let directory: URL
    let mode: String

    init(mode: String = "normal") throws {
        self.mode = mode
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simul-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
    }

    func configuration(conversationID: String? = nil, skipPermissions: Bool = false) -> ChatAgentConfiguration {
        ChatAgentConfiguration(executable: "/usr/bin/python3", arguments: ["-u", directory.appendingPathComponent("fixture.py").path, mode], workingDirectory: directory.path, conversationID: conversationID, sessionID: UUID(), skipPermissions: skipPermissions)
    }

    func messages() throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("requests.jsonl"))
        return try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let script = #"""
import json, os, sys
mode = sys.argv[1]
turn_number = 0
turn_id = "turn-one"
log = open("requests.jsonl", "a", buffering=1)
def emit(message):
    print(json.dumps(message), flush=True)
def response(request, result):
    emit({"id": request["id"], "result": result})
def event(method, **params):
    emit({"method": method, "params": {"threadId": "thread-one", **params}})
def finish(status="completed"):
    event("turn/completed", turn={"id":turn_id, "status":status, "items":[], "error":None})
def approval(kind="command"):
    emit({"id":71,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-one","turnId":"turn-one","itemId":"command-one","startedAtMs":1,"kind":kind,"command":"touch /tmp/example","cwd":"/tmp","reason":"Write access"}})
for line in sys.stdin:
    request = json.loads(line)
    log.write(json.dumps(request) + "\n")
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        response(request, {"userAgent":"fixture/0.169.0","platformFamily":"unix","platformOs":"macos","codexHome":"/tmp/fixture"})
    elif method == "model/list":
        if not params.get("cursor"):
            response(request, {"data":[{"id":"model-one","model":"model-one","displayName":"Model One","isDefault":True,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Low"}],"description":"First model","hidden":False}], "nextCursor":"models-two"})
        else:
            response(request, {"data":[{"id":"model-two","model":"model-two","displayName":"Model Two","isDefault":False,"defaultReasoningEffort":"high","supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"description":"Second model","hidden":False}], "nextCursor":None})
    elif method in ("thread/start", "thread/resume"):
        if mode == "missing":
            emit({"id":request["id"],"error":{"code":-32600,"message":"Thread not found"}})
        else:
            response(request, {"thread":{"id":"thread-one","name":"Imported title" if mode == "titles" else None,"turns":[],"status":{"type":"idle"}},"model":"model-one","reasoningEffort":"low","cwd":"/tmp","approvalPolicy":"on-request","approvalsReviewer":"user","modelProvider":"openai","sandbox":{"type":"readOnly"}})
    elif method == "thread/turns/list":
        if not params.get("cursor"):
            response(request, {"data":[{"id":"old-turn","status":"completed","itemsView":"full","items":[{"id":"server-prompt","type":"userMessage","clientId":"persisted-send","content":[{"type":"text","text":"Earlier prompt"}]}]}], "nextCursor":"history-two"})
        else:
            command = ("echo line\n" * 100 + "exit 1") if mode == "full-output" else "swift build"
            output = ("middle line\n" * 100 + "final failure") if mode == "full-output" else "build failed"
            response(request, {"data":[{"id":"old-turn-two","status":"completed","itemsView":"full","items":[{"id":"old-reply","type":"agentMessage","text":"Earlier reply"},{"id":"old-command","type":"commandExecution","command":command,"cwd":"/tmp","commandActions":[],"status":"future-status" if mode == "bad-status" else "failed","aggregatedOutput":output,"exitCode":0 if mode == "bad-status" else 1}]}], "nextCursor":None})
    elif method == "turn/start":
        if mode == "rejected":
            emit({"id":request["id"],"error":{"code":-32602,"message":"Unsupported input"}})
            continue
        if mode == "lost": os._exit(2)
        turn_number += 1
        turn_id = "turn-two" if turn_number > 1 else "turn-one"
        event("turn/started", turn={"id":turn_id,"status":"inProgress","items":[],"error":None})
        if mode == "late-ack":
            finish()
            response(request, {"turn":{"id":turn_id,"status":"inProgress","items":[],"error":None}})
            continue
        response(request, {"turn":{"id":turn_id,"status":"inProgress","items":[],"error":None}})
        if mode == "titles":
            emit({"method":"thread/name/updated","params":{"threadId":"another-thread","threadName":"Wrong name"}})
            event("thread/name/updated", threadName="Useful conversation name")
            event("thread/name/updated", threadName=None)
        if mode in ("approvals", "human"):
            approval("humanCommand" if mode == "human" else "command")
        elif mode == "optional":
            emit({"id":"question-rpc","method":"item/tool/requestUserInput","params":{"threadId":"thread-one","turnId":turn_id,"itemId":"question-one","isBlocking":False,"questions":[{"id":"color","header":"Value","question":"Optional value?","isSecret":True}]}})
            finish()
        elif mode == "permissions":
            event("item/started", turnId=turn_id, startedAtMs=1, item={"id":"file-one","type":"fileChange","changes":[{"path":"/tmp/example","kind":{"type":"update","move_path":None},"diff":"-old value\n+new value"}],"status":"inProgress"})
            emit({"id":"file-rpc","method":"item/fileChange/requestApproval","params":{"threadId":"thread-one","turnId":turn_id,"itemId":"file-one","startedAtMs":1,"reason":"Apply change"}})
        elif mode not in ("interrupt", "interrupt-error"):
            event("item/started", turnId="turn-one", startedAtMs=1, item={"id":"command-one","type":"commandExecution","command":"true","cwd":"/tmp","commandActions":[],"status":"inProgress"})
            event("item/completed", turnId="turn-one", completedAtMs=2, item={"id":"command-one","type":"commandExecution","command":"true","cwd":"/tmp","commandActions":[],"status":"completed","aggregatedOutput":"","exitCode":0})
            emit({"method":"item/agentMessage/delta","params":{"threadId":"another-thread","turnId":"another-turn","itemId":"wrong-reply","delta":"Ignore this"}})
            event("item/agentMessage/delta", turnId="turn-one", itemId="reply-one", delta="Hel")
            event("item/agentMessage/delta", turnId="turn-one", itemId="reply-one", delta="lo")
            event("item/completed", turnId="turn-one", completedAtMs=3, item={"id":"reply-one","type":"agentMessage","text":"Hello"})
            finish()
    elif method == "turn/interrupt":
        if mode == "interrupt-error": emit({"id":request["id"],"error":{"code":-32603,"message":"Cannot interrupt"}})
        else:
            response(request, {})
            finish("interrupted")
    elif method is None and request.get("id") == 71:
        event("serverRequest/resolved", requestId=71)
        if mode == "human": finish()
        else:
            emit({"id":"question-rpc","method":"item/tool/requestUserInput","params":{"threadId":"thread-one","turnId":"turn-one","itemId":"question-one","isBlocking":True,"questions":[{"id":"color","header":"Color","question":"Which color?","options":[{"label":"Blue","description":"First"},{"label":"Green","description":"Second"}]}]}})
    elif method is None and request.get("id") == "question-rpc" and mode != "optional":
        finish()
    elif method is None and request.get("id") == "file-rpc":
        emit({"id":72,"method":"item/permissions/requestApproval","params":{"threadId":"thread-one","turnId":turn_id,"itemId":"permission-one","startedAtMs":1,"cwd":"/tmp","permissions":{"fileSystem":{"write":["/tmp/requested-folder"]}},"reason":"Write output"}})
    elif method is None and request.get("id") == 72:
        finish()
"""#
}
