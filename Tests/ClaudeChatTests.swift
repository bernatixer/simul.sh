import Foundation
@testable import SimulCore

@MainActor
func registerClaudeChatTests() {
    test("Claude chat: runtime metadata follows the reply and recorded effort") {
        let fixture = try ClaudeChatFixture(mode: "metadata")
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
        try await claudeChatWait { events.contains { if case .finished = $0 { true } else { false } } }
        try await Task.sleep(for: .milliseconds(40))
        expect(events.contains { if case .modelChanged("claude-opus-5-5") = $0 { true } else { false } }, "the reply reports its actual model")
        expect(events.contains { if case .effortChanged("high") = $0 { true } else { false } }, "effort comes from the recorded turn, not a guessed default")
        expect(events.contains { if case .titleChanged("Useful Claude name") = $0 { true } else { false } }, "the recorded provider title reaches the session")
    }
    test("Claude chat: echoed UUID, streaming blocks, questions and tool approval") {
        let fixture = try ClaudeChatFixture()
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration)
        let message = ChatOutgoingMessage(id: "b1094f58-fbf5-4d7d-976b-7a5a40df5944", pieces: [.text("Hello")])
        try await client.send(message)
        try await claudeChatWait { events.contains { if case .request = $0 { true } else { false } } }

        let accepted = events.compactMap { event -> String? in
            if case let .accepted(id) = event { return id }; return nil
        }
        expectEqual(accepted, [message.id], "only its echoed UUID accepts the message, once")
        let textIDs = events.compactMap { event -> String? in
            if case let .text(id, _) = event { return id }; return nil
        }
        let replies = events.compactMap { event -> ChatEntry? in
            if case let .reply(id, text) = event { return .reply(id: id, text: text) }; return nil
        }
        expectEqual(textIDs, ["msg-1-1", "msg-1-1"], "stream UUIDs do not become reply IDs")
        expectEqual(replies, [.reply(id: "msg-1-1", text: "Hello.")], "the full block replaces its streamed text")
        let completedTools = events.compactMap { event -> ChatTool? in
            if case let .tool(tool) = event, tool.result != nil { return tool }; return nil
        }
        let tool = completedTools.first { $0.id == "tool-read" }
        expectEqual(tool?.id, "tool-read", "results keep their tool call identity")
        expectEqual(tool?.result, "", "an empty tool result still completes the call")
        let longOutput = completedTools.first { $0.id == "tool-output" }
        expect(longOutput?.result?.hasSuffix("FINAL ERROR") == true, "the end of a long tool result remains available")
        expect(longOutput?.detail.hasSuffix("FINAL COMMAND") == true, "the full command remains available")

        guard let question = events.compactMap({ event -> ChatAgentRequest? in
            if case let .request(request) = event { return request }; return nil
        }).last else { return expect(false, "Claude's question is shown") }
        expectEqual(question.questions.first?.id, "Which format?", "question text is the answer key")
        expect(question.questions.first?.allowsMultiple == true, "multiple selections are preserved")
        expect(question.detail.isEmpty, "questions show their controls without a duplicate JSON form")
        await expectThrows("an incomplete answer leaves the question pending") {
            try client.respond(to: question.id, decision: .allow, answers: [:])
        }
        try client.respond(to: question.id, decision: .allow, answers: ["Which format?": ["Brief", "Detailed"]])
        try await claudeChatWait {
            events.contains { if case let .request(request) = $0 { request.id == "permission-1" } else { false } }
        }
        try client.respond(to: "permission-1", decision: .allowSession, answers: [:])
        try await claudeChatWait { events.contains { if case .finished = $0 { true } else { false } } }
        expect(events.contains { if case .finished(.completed, nil) = $0 { true } else { false } }, "the result completes the turn")
        try await client.setOptions(model: "sonnet", effort: "high")

        let sent = try fixture.sent()
        let user = sent.first { $0["type"] as? String == "user" }
        expectEqual(user?["uuid"] as? String, message.id, "the user UUID is sent at the top level")
        expectEqual((user?["message"] as? [String: Any])?["role"] as? String, "user", "the user envelope includes its role")
        let answers = fixture.response("question-1", in: sent)
        let updated = answers?["updatedInput"] as? [String: Any]
        expectEqual((updated?["answers"] as? [String: [String]])?["Which format?"], ["Brief", "Detailed"], "question answers use labels and the original text")
        expectEqual((updated?["questions"] as? [[String: Any]])?.count, 1, "original questions reach the tool")
        expectEqual(updated?["extra"] as? String, "preserved", "the input keeps fields unknown to Simul")
        let approval = fixture.response("permission-1", in: sent)
        expectEqual(approval?["behavior"] as? String, "allow", "session approval allows this call")
        expectEqual(((approval?["updatedInput"] as? [String: Any])?["command"] as? String), "echo approved", "the approval preserves tool input")
        let permissions = approval?["updatedPermissions"] as? [[String: Any]]
        expectEqual(permissions?.first?["destination"] as? String, "session", "session approval never writes a saved permission")
        let controls = sent.compactMap { $0["request"] as? [String: Any] }
        expect(controls.contains { $0["subtype"] as? String == "set_model" && $0["model"] as? String == "sonnet" }, "model selection reaches the CLI")
        expect(controls.contains { ($0["settings"] as? [String: Any])?["effortLevel"] as? String == "high" && $0["subtype"] as? String == "apply_flag_settings" }, "effort selection reaches the CLI")
        expect(events.contains { if case .modelChanged("claude-sonnet-5-5") = $0 { true } else { false } }, "the provider's resolved model is published")
    }

    test("Claude chat: failed API result cannot report a completed turn") {
        let fixture = try ClaudeChatFixture(mode: "error")
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
        try await claudeChatWait { events.contains { if case .finished = $0 { true } else { false } } }
        expect(events.contains { if case .finished(.failed, "API Error: unavailable") = $0 { true } else { false } }, "is_error wins even when subtype is success")
    }

    test("Claude chat: a process that exits before echo leaves delivery uncertain") {
        let fixture = try ClaudeChatFixture(mode: "exit")
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var accepted = false
        client.onEvent = { if case .accepted = $0 { accepted = true } }
        try await client.start(fixture.configuration)
        do {
            try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
            expect(false, "a missing echo cannot accept delivery")
        } catch ChatAgentError.uncertain {
            expect(!accepted, "an unacknowledged message stays uncertain")
        } catch {
            expect(false, "the write may have reached Claude: \(error)")
        }
    }

    test("Claude chat: Stop waits for an interrupted turn result") {
        let fixture = try ClaudeChatFixture(mode: "interrupt")
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
        expect(!events.contains { if case .finished = $0 { true } else { false } }, "echoing a prompt doesn't finish the turn")
        client.interrupt()
        try await claudeChatWait { events.contains { if case .finished = $0 { true } else { false } } }
        expect(events.contains { if case .finished(.interrupted, _) = $0 { true } else { false } }, "the abort reason is preserved")
    }

    test("Claude chat: launches resume by exact ID and retains user settings") {
        let fixture = try ClaudeChatFixture()
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var configuration = fixture.configuration
        configuration.conversationID = "c35af4b3-2ba6-4625-ad0a-fe68a0311dcc"
        try await client.start(configuration)
        let arguments = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("arguments.json"))) as? [String] ?? []
        expect(arguments.contains("--resume=c35af4b3-2ba6-4625-ad0a-fe68a0311dcc"), "resume uses the persisted conversation")
        expect(!arguments.contains { $0.hasPrefix("--session-id") }, "resume doesn't create another conversation")
        expect(arguments.contains("--permission-prompt-tool") && arguments.contains("stdio"), "approvals return through the control channel")
        expect(!arguments.contains { $0.hasPrefix("--setting-sources") || $0 == "--strict-mcp-config" || $0 == "--bare" || $0 == "--safe-mode" }, "settings, MCP, instructions, and hooks keep loading")
        expect(!arguments.contains("--dangerously-skip-permissions"), "bypass requires an explicit opt-in")
    }

    test("Claude chat: validates image bytes before sending and preserves piece order") {
        let fixture = try ClaudeChatFixture(mode: "interrupt")
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var configuration = fixture.configuration
        configuration.skipPermissions = true
        try await client.start(configuration)
        let image = fixture.directory.appendingPathComponent("image.png")
        try Data("not an image".utf8).write(to: image)
        await expectThrows("an invalid attachment isn't sent to Claude") {
            try await client.send(ChatOutgoingMessage(pieces: [.image(image)]))
        }
        let beforeImage = try fixture.sent()
        expect(!beforeImage.contains { $0["type"] as? String == "user" }, "validation fails before any user message is written")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP8z8DwnwEIGBkZGRgYGAA/AgP/0z5cgQAAAABJRU5ErkJggg=="
        try Data(base64Encoded: png)!.write(to: image)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Look"), .image(image), .text("at this")]))
        let user = try fixture.sent().first { $0["type"] as? String == "user" }
        let content = (user?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        expectEqual(content.compactMap { $0["type"] as? String }, ["text", "image", "text"], "images stay between their surrounding text")
        let source = content.count > 1 ? content[1]["source"] as? [String: Any] : nil
        expectEqual(source?["media_type"] as? String, "image/png", "the MIME type comes from the image bytes")
        expectEqual(source?["data"] as? String, png, "the actual attachment bytes reach Claude")
        let arguments = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("arguments.json"))) as? [String] ?? []
        expect(arguments.contains("--dangerously-skip-permissions"), "an explicit bypass opt-in reaches the provider")
    }

    test("Claude chat: cancelled requests cannot receive a stale approval") {
        let fixture = try ClaudeChatFixture(mode: "cancel")
        defer { fixture.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        var events: [ChatAgentEvent] = []
        client.onEvent = { events.append($0) }
        try await client.start(fixture.configuration)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
        try await claudeChatWait {
            events.contains { if case .requestResolved("cancelled-request") = $0 { true } else { false } }
        }
        await expectThrows("a cancelled provider request cannot be approved") {
            try client.respond(to: "cancelled-request", decision: .allow, answers: [:])
        }
        let sent = try fixture.sent()
        expect(!sent.contains { ($0["response"] as? [String: Any])?["request_id"] as? String == "cancelled-request" }, "a stale approval never reaches the CLI")
    }

    test("Claude chat: a queued Stop cannot interrupt a replacement connection") {
        let first = try ClaudeChatFixture(mode: "interrupt")
        let replacement = try ClaudeChatFixture(mode: "interrupt")
        defer { first.remove(); replacement.remove() }
        let client = ClaudeChatClient()
        defer { client.close() }
        try await client.start(first.configuration)
        try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
        client.interrupt()
        client.close()
        try await client.start(replacement.configuration)
        let sent = try replacement.sent()
        expect(!sent.contains { ($0["request"] as? [String: Any])?["subtype"] as? String == "interrupt" }, "a Stop belongs only to the connection that requested it")
    }

    test("Claude chat: malformed questions are denied without granting another tool") {
        for invalid in ["duplicate", "blank", "missing", "empty"] {
            let fixture = try ClaudeChatFixture(mode: "invalid-question-\(invalid)")
            defer { fixture.remove() }
            let client = ClaudeChatClient()
            defer { client.close() }
            var events: [ChatAgentEvent] = []
            client.onEvent = { events.append($0) }
            try await client.start(fixture.configuration)
            try await client.send(ChatOutgoingMessage(pieces: [.text("Hello")]))
            try await claudeChatWait {
                events.contains {
                    if case let .request(request) = $0 { return request.id == "invalid-question" }
                    if case .reply("denial-receipt-0", _) = $0 { return true }
                    return false
                }
            }
            expect(!events.contains { if case let .request(request) = $0 { request.id == "invalid-question" } else { false } }, "\(invalid) question IDs never reach the UI")
            expect(events.contains { if case .error = $0 { true } else { false } }, "\(invalid) question IDs produce a visible notice")
            let sent = try fixture.sent()
            let denied = fixture.response("invalid-question", in: sent)
            expectEqual(denied?["behavior"] as? String, "deny", "\(invalid) questions are denied through the exact control request")
            expect(!sent.contains { ($0["response"] as? [String: Any])?["request_id"] as? String == "other-permission" }, "\(invalid) questions cannot grant or deny an unrelated tool")
            expect(!events.contains { if case .requestResolved("other-permission") = $0 { true } else { false } }, "the unrelated approval stays pending")
        }
    }
}

@MainActor
private func claudeChatWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ChatAgentError.rejected("Claude fixture timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct ClaudeChatFixture {
    let directory: URL
    let configuration: ChatAgentConfiguration

    init(mode: String = "normal") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simul-claude-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("claude.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        configuration = ChatAgentConfiguration(
            executable: "/usr/bin/python3", arguments: [script.path],
            environment: ["SIMUL_CLAUDE_FIXTURE_MODE": mode, "CLAUDE_CONFIG_DIR": directory.path],
            workingDirectory: directory.path, sessionID: UUID()
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func sent() throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("sent.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
    }

    func response(_ id: String, in sent: [[String: Any]]) -> [String: Any]? {
        sent.compactMap { $0["response"] as? [String: Any] }
            .first { $0["request_id"] as? String == id }?["response"] as? [String: Any]
    }

    private static let script = #"""
    import json, os, sys
    json.dump(sys.argv[1:], open('arguments.json', 'w'))
    mode = os.environ['SIMUL_CLAUDE_FIXTURE_MODE']
    sid = 'fixture-session'
    current_uuid = None
    def emit(value):
        print(json.dumps(value), flush=True)
    def result(**extra):
        emit(dict(type='result', subtype='success', is_error=False, session_id=sid, user_message_uuid=current_uuid, **extra))
    def stream(event, event_uuid):
        emit(dict(type='stream_event', uuid=event_uuid, session_id=sid, parent_tool_use_id=None, event=event))
    for line in sys.stdin:
        value = json.loads(line)
        with open('sent.jsonl', 'a') as log:
            log.write(json.dumps(value) + '\n')
        if value['type'] == 'control_request':
            request = value['request']
            subtype = request['subtype']
            payload = {}
            if subtype == 'initialize':
                payload = dict(models=[dict(value='opus', resolvedModel='claude-opus-5-5', displayName='Opus', supportedEffortLevels=['low', 'high'])], current_permission_mode='default')
            elif subtype == 'set_model':
                payload = dict(model='claude-sonnet-5-5')
            emit(dict(type='control_response', response=dict(subtype='success', request_id=value['request_id'], response=payload)))
            if subtype == 'interrupt':
                result(terminal_reason='aborted_streaming')
        elif value['type'] == 'user':
            if mode == 'exit':
                sys.exit(7)
            current_uuid = value['uuid']
            emit(dict(value, uuid='unrelated-message'))
            emit(value)
            emit(value)
            if mode == 'metadata':
                stream(dict(type='message_start', message=dict(id='runtime-message', model='claude-opus-5-5', content=[])), 'runtime-start')
                session_id = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--session-id='))
                folder = os.path.join(os.environ['CLAUDE_CONFIG_DIR'], 'projects', 'fixture')
                os.makedirs(folder, exist_ok=True)
                with open(os.path.join(folder, session_id + '.jsonl'), 'w') as transcript:
                    transcript.write(json.dumps(dict(uuid='runtime-record', type='assistant', effort='high', message=dict(id='runtime-message', model='claude-opus-5-5', content=[dict(type='text', text='Hello.')]))) + '\n')
                    transcript.write(json.dumps(dict(type='ai-title', aiTitle='Useful Claude name')) + '\n')
                result(result='Hello.')
                continue
            if mode == 'interrupt':
                continue
            if mode.startswith('invalid-question-'):
                invalid = mode.removeprefix('invalid-question-')
                questions = dict(duplicate=[dict(question='Same question?'), dict(question='Same question?')], blank=[dict(question=' \t\n')], missing=[dict(header='Missing')], empty=[])[invalid]
                emit(dict(type='control_request', request_id='other-permission', request=dict(subtype='can_use_tool', tool_name='Bash', input=dict(command='echo pending'))))
                emit(dict(type='control_request', request_id='invalid-question', request=dict(subtype='can_use_tool', tool_name='AskUserQuestion', input=dict(questions=questions))))
                continue
            if mode == 'cancel':
                emit(dict(type='control_request', request_id='cancelled-request', request=dict(subtype='can_use_tool', tool_name='Bash', input=dict(command='echo waiting'))))
                emit(dict(type='control_cancel_request', request_id='cancelled-request'))
                continue
            if mode == 'error':
                emit(dict(type='result', subtype='success', is_error=True, session_id=sid, user_message_uuid=current_uuid, result='API Error: unavailable'))
                continue
            stream(dict(type='message_start', message=dict(id='msg-1', model='claude-opus-5-5', content=[])), 'stream-1')
            stream(dict(type='content_block_start', index=0, content_block=dict(type='thinking', thinking='')), 'stream-2')
            stream(dict(type='content_block_stop', index=0), 'stream-3')
            stream(dict(type='content_block_start', index=1, content_block=dict(type='text', text='')), 'stream-4')
            stream(dict(type='content_block_delta', index=1, delta=dict(type='text_delta', text='Hel')), 'stream-5')
            stream(dict(type='content_block_delta', index=1, delta=dict(type='text_delta', text='lo')), 'stream-6')
            emit(dict(type='assistant', uuid='full-text', session_id=sid, parent_tool_use_id=None, message=dict(id='msg-1', model='claude-opus-5-5', content=[dict(type='text', text='Hello.')])))
            stream(dict(type='content_block_stop', index=1), 'stream-7')
            stream(dict(type='content_block_start', index=2, content_block=dict(type='tool_use', id='tool-read', name='Read', input={})), 'stream-8')
            emit(dict(type='assistant', uuid='full-tool', session_id=sid, parent_tool_use_id=None, message=dict(id='msg-1', model='claude-opus-5-5', content=[dict(type='tool_use', id='tool-read', name='Read', input=dict(file_path='/repo/App.swift'))])))
            stream(dict(type='content_block_stop', index=2), 'stream-9')
            stream(dict(type='message_stop'), 'stream-10')
            emit(dict(type='user', uuid='tool-result', parent_tool_use_id=None, session_id=sid, message=dict(role='user', content=[dict(type='tool_result', tool_use_id='tool-read', content='')])) )
            emit(dict(type='assistant', uuid='full-output', session_id=sid, parent_tool_use_id=None, message=dict(id='msg-2', model='claude-opus-5-5', content=[dict(type='tool_use', id='tool-output', name='Bash', input=dict(command=('command line\n' * 100) + 'FINAL COMMAND'))])))
            emit(dict(type='user', uuid='long-result', parent_tool_use_id=None, session_id=sid, message=dict(role='user', content=[dict(type='tool_result', tool_use_id='tool-output', is_error=True, content=('output line\n' * 100) + 'FINAL ERROR')])) )
            emit(dict(type='control_request', request_id='question-1', request=dict(subtype='can_use_tool', tool_name='AskUserQuestion', tool_use_id='tool-question', input=dict(extra='preserved', questions=[dict(question='Which format?', header='Format', multiSelect=True, options=[dict(label='Brief', description='Short'), dict(label='Detailed', description='Long')])]))))
        elif value['type'] == 'control_response':
            rid = value['response']['request_id']
            if rid == 'invalid-question':
                emit(dict(type='assistant', uuid='denial-receipt', session_id=sid, parent_tool_use_id=None, message=dict(id='denial-receipt', model='claude-opus-5-5', content=[dict(type='text', text='Question request rejected.')])) )
            elif rid == 'question-1':
                emit(dict(type='control_request', request_id='permission-1', request=dict(subtype='can_use_tool', tool_name='Bash', tool_use_id='tool-bash', input=dict(command='echo approved'), permission_suggestions=[dict(type='addRules', rules=[dict(toolName='Bash', ruleContent='echo approved')], behavior='allow', destination='localSettings')])) )
            elif rid == 'permission-1':
                result(terminal_reason='completed')
    """#
}
