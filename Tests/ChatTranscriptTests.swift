import Foundation
@testable import SimulCore

@MainActor
func registerChatTranscriptTests() {
    test("chat transcript: provider titles survive branch rewinds and custom names win") {
        var transcript = ChatTranscript()
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"content":"Fix the sidebar"}}"#,
            #"{"type":"ai-title","aiTitle":"Improve sidebar"}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"content":[{"type":"text","text":"First reply"}]}}"#,
        ]
        transcript.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        expectEqual(transcript.conversation.title, "Improve sidebar", "an AI title is independent of branch ancestry")
        transcript.consume(Data((#"{"type":"custom-title","customTitle":"My sidebar task"}"# + "\n" + #"{"type":"ai-title","aiTitle":"Later generated title"}"# + "\n" + #"{"type":"user","uuid":"u2","parentUuid":"u1","message":{"content":"Try again"}}"# + "\n").utf8))
        expectEqual(transcript.conversation.title, "My sidebar task", "a CLI rename survives new generated names and a rewind")
    }
    test("chat transcript: prompts, replies, grouped tool calls with results") {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Fix the build"}}"#,
            #"{"type":"user","uuid":"m1","isMeta":true,"message":{"role":"user","content":"injected"}}"#,
            #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Looking."}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/repo/App/Main.swift"}}]}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift build\nmore","description":"Build it"}}]}}"#,
            #"{"type":"user","uuid":"r1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"line 1"}]}}"#,
            #"{"type":"user","uuid":"r2","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":[{"type":"text","text":"error: nope"}]}]}}"#,
            "not json",
            #"{"type":"assistant","uuid":"a4","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Fixed."}]}}"#,
        ]
        let conversation = ChatTranscript.parse(Data(lines.joined(separator: "\n").utf8))
        let entries = conversation.entries
        expectEqual(conversation.model, "Opus 5.5", "model of the latest reply")
        expectEqual(conversation.effort, "High", "effort of the latest reply")
        guard entries.count == 5 else {
            return expect(false, "expected prompt, note, reply, tools, reply; got \(entries)")
        }
        expectEqual(entries[0], .prompt(id: "u1", text: "Fix the build"), "typed prompt; meta and sidechains skipped")
        expectEqual(entries[1], .note(id: "c1", text: "/clear"), "slash command as a note")
        expectEqual(entries[2], .reply(id: "a1-1", text: "Looking."), "reply text; thinking skipped")
        guard case let .tools(_, tools) = entries[3] else { return expect(false, "tool calls grouped") }
        expectEqual(tools.map(\.summary), ["Main.swift", "Build it"], "file name, then description")
        expectEqual(tools[0].result, "line 1", "string result attached to its call")
        expectEqual(tools[1].result, "error: nope", "block result attached to its call")
        expect(tools[1].isError && !tools[0].isError, "error flag per call")
        expectEqual(tools[1].detail, "swift build\nmore", "command shown in full")
        expectEqual(entries[4], .reply(id: "a4-0", text: "Fixed."), "text after tools starts a new entry")
    }

    test("chat transcript: notes, permission mode, and reading in chunks") {
        let lines = [
            #"{"type":"permission-mode","permissionMode":"auto"}"#,
            #"{"type":"user","uuid":"c1","message":{"content":"<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args>high</command-args>"}}"#,
            #"{"type":"user","uuid":"s1","isCompactSummary":true,"message":{"content":"This session is being continued from a previous conversation"}}"#,
            #"{"type":"user","uuid":"u1","message":{"content":"Go on"}}"#,
            #"{"type":"user","uuid":"i1","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
            #"{"type":"permission-mode","permissionMode":"plan"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let whole = ChatTranscript.parse(data)
        expectEqual(whole.entries, [
            .note(id: "c1", text: "/effort high"),
            .note(id: "s1", text: "Conversation compacted"),
            .prompt(id: "u1", text: "Go on"),
            .note(id: "i1-0", text: "Interrupted"),
        ], "commands, compaction and interrupts are notes, not prompts")
        expectEqual(whole.permissionMode, "plan", "latest permission mode")

        var chunked = ChatTranscript()
        var revisions: [Int] = []
        for start in stride(from: 0, to: data.count, by: 37) { // splits lines mid-record
            chunked.consume(data.subdata(in: start..<min(start + 37, data.count)))
            revisions.append(chunked.conversation.revision)
        }
        expectEqual(chunked.conversation.entries, whole.entries, "chunks give the same entries")
        expectEqual(chunked.conversation.permissionMode, "plan", "chunks give the same mode")
        expect(revisions == revisions.sorted() && revisions.last! > 0, "revision only goes up")
        let settled = chunked.conversation.revision
        chunked.consume(Data())
        expectEqual(chunked.conversation.revision, settled, "nothing new, same revision")
    }

    test("chat transcript: images you sent show with your text") {
        // A 2x2 PNG, base64.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP8z8DwnwEIGBkZGRgYGAA/AgP/0z5cgQAAAABJRU5ErkJggg=="
        let line = #"{"type":"user","uuid":"p1","message":{"content":[{"type":"text","text":"what is this [Image #1]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}}"#
        let entries = ChatTranscript.parse(Data(line.utf8)).entries
        guard case let .prompt(id, text, images)? = entries.first, entries.count == 1 else {
            return expect(false, "one prompt; got \(entries)")
        }
        expectEqual(id, "p1", "prompt keeps its record UUID")
        expectEqual(text, "what is this [Image #1]", "the text")
        expectEqual(images.count, 1, "the image, as a thumbnail")
        expect(images.first.map { $0.starts(with: [0xFF, 0xD8]) } == true, "thumbnail is a JPEG")
    }

    test("chat transcript: a turn is open from its prompt until turn_duration") {
        var transcript = ChatTranscript()
        transcript.consume(Data((#"{"type":"user","uuid":"u1","message":{"content":"hi"}}"# + "\n").utf8))
        expect(transcript.conversation.turnOpen, "open once the prompt is in")
        expectEqual(transcript.conversation.prompts, 1, "one prompt")
        transcript.consume(Data((#"{"type":"assistant","uuid":"a1","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Hi."}]}}"# + "\n").utf8))
        expect(transcript.conversation.turnOpen, "a reply alone doesn't end it (stop hooks still run)")
        transcript.consume(Data((#"{"type":"system","subtype":"turn_duration","durationMs":1200}"# + "\n").utf8))
        expect(!transcript.conversation.turnOpen, "closed by turn_duration")
        transcript.consume(Data((#"{"type":"user","uuid":"u2","message":{"content":"more"}}"# + "\n").utf8))
        transcript.consume(Data((#"{"type":"user","uuid":"i1","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
        expect(!transcript.conversation.turnOpen, "closed by an interrupt")
        expectEqual(transcript.conversation.prompts, 2, "interrupts aren't prompts")
    }

    test("chat transcript: model names") {
        expectEqual(ChatTranscript.modelName("claude-sonnet-4-5-20250929"), "Sonnet 4.5", "date suffix dropped")
        expectEqual(ChatTranscript.modelName("claude-haiku-5-5"), "Haiku 5.5", "family and version")
        expectEqual(ChatTranscript.modelName("<synthetic>"), nil, "not a Claude id")
    }

    test("chat transcript: long output is clipped") {
        let long = (1...100).map(String.init).joined(separator: "\n")
        let clipped = ChatTranscript.clip(long)
        expect(clipped.hasSuffix("\n…"), "marked as clipped")
        expectEqual(clipped.split(separator: "\n").count, 41, "40 lines and the marker")
        expectEqual(ChatTranscript.clip("short"), "short", "short text untouched")
    }

    test("chat transcript: HTML prompts stay visible and injected wrappers stay hidden") {
        let lines = [
            #"{"type":"user","uuid":"html","message":{"content":"<div>Fix this HTML</div>"}}"#,
            #"{"type":"user","uuid":"block","message":{"content":[{"type":"text","text":"<span>Block input</span>"}]}}"#,
            #"{"type":"user","uuid":"literal","message":{"content":"Explain <command-name>literal</command-name>"}}"#,
            #"{"type":"user","uuid":"system","message":{"content":"<system-reminder>Injected</system-reminder>"}}"#,
            #"{"type":"user","uuid":"task","message":{"content":"<task-notification>Injected</task-notification>"}}"#,
        ]
        let entries = ChatTranscript.parse(Data(lines.joined(separator: "\n").utf8)).entries
        expectEqual(entries, [
            .prompt(id: "html", text: "<div>Fix this HTML</div>"),
            .prompt(id: "block", text: "<span>Block input</span>"),
            .prompt(id: "literal", text: "Explain <command-name>literal</command-name>"),
        ], "only known injected envelopes are hidden")
    }

    test("chat transcript: appending a rewind selects only the active ancestors") {
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"content":"Start"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","effort":"high","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Original"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","message":{"content":"Discard me"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","effort":"low","message":{"id":"m2","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Discarded reply"}]}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"a1","message":{"content":"Replacement"}}"#,
        ]
        var transcript = ChatTranscript()
        transcript.consume(Data((lines.prefix(4).joined(separator: "\n") + "\n").utf8))
        let before = transcript.conversation.revision
        transcript.consume(Data((lines[4] + "\n").utf8))
        expectEqual(transcript.conversation.entries, [
            .prompt(id: "u1", text: "Start"),
            .reply(id: "m1-0", text: "Original"),
            .prompt(id: "u3", text: "Replacement"),
        ], "discarded branch is gone")
        expectEqual(transcript.conversation.model, "Opus 5.5", "discarded model does not leak")
        expectEqual(transcript.conversation.effort, "High", "discarded effort does not leak")
        expectEqual(transcript.conversation.prompts, 2, "only active prompts count")
        expect(transcript.conversation.revision > before, "a rewind publishes a new revision")
        let whole = ChatTranscript.parse(Data(lines.joined(separator: "\n").utf8))
        expectEqual(transcript.conversation.entries, whole.entries, "streaming and whole-file branches match")
    }

    test("chat transcript: tool details stay complete and discarded results are removed") {
        let detail = String(repeating: "command ", count: 800)
        let result = (1...100).map { "Line \($0): " + String(repeating: "output ", count: 20) }.joined(separator: "\n")
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let lines = try [
            line(["type": "user", "uuid": "u1", "parentUuid": NSNull(), "message": ["content": "Run"]]),
            line(["type": "assistant", "uuid": "a1", "parentUuid": "u1", "message": ["content": [
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": detail]],
            ]]]),
            line(["type": "user", "uuid": "r1", "parentUuid": "a1", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": result],
            ]]]),
        ]
        var transcript = ChatTranscript()
        transcript.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        guard case let .tools(_, initial)? = transcript.conversation.entries.last else { return expect(false, "tool run") }
        expectEqual(initial[0].detail, detail, "full command retained")
        expectEqual(initial[0].result, result, "full output retained")
        let fork = #"{"type":"user","uuid":"u2","parentUuid":"a1","message":{"content":"Try again"}}"#
        transcript.consume(Data((fork + "\n").utf8))
        guard transcript.conversation.entries.count == 3,
              case let .tools(_, selected) = transcript.conversation.entries[1] else { return expect(false, "active tool run") }
        expectEqual(selected[0].result, nil, "result from discarded branch removed")
        expect(!selected[0].isError, "discarded failure flag removed")
    }

    test("chat transcript: sidechains and stale system records cannot select a branch") {
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"content":"Start"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"content":[{"type":"text","text":"Old"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"u1","message":{"content":"New"}}"#,
            #"{"type":"assistant","uuid":"side","parentUuid":"a1","isSidechain":true,"message":{"content":[{"type":"text","text":"Sidechain"}]}}"#,
            #"{"type":"system","uuid":"end","parentUuid":"a1","subtype":"turn_duration"}"#,
            #"{"type":"user","uuid":"injected","parentUuid":"a1","message":{"content":"<system-reminder>Old branch</system-reminder>"}}"#,
        ]
        let conversation = ChatTranscript.parse(Data(lines.joined(separator: "\n").utf8))
        expectEqual(conversation.entries, [.prompt(id: "u1", text: "Start"), .prompt(id: "u2", text: "New")], "newest main branch stays selected")
        expect(conversation.turnOpen, "old branch end cannot close the current turn")
    }

    test("chat transcript: assistant revisions use one stable message row") {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"Partial"}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"Complete"}]}}"#,
        ]
        let entries = ChatTranscript.parse(Data(lines.joined(separator: "\n").utf8)).entries
        expectEqual(entries, [.reply(id: "m1-0", text: "Complete")], "same API message updates its existing row")
    }

    test("chat transcript: missing parents and cycles terminate safely") {
        let lines = [
            #"{"type":"user","uuid":"one","parentUuid":"missing","message":{"content":"One"}}"#,
            #"{"type":"user","uuid":"two","parentUuid":"two","message":{"content":"Two"}}"#,
        ]
        let conversation = ChatTranscript.parse(Data(lines.joined(separator: "\n").utf8))
        expectEqual(conversation.entries, [.prompt(id: "two", text: "Two")], "self-cycle has one visible record")
    }
}
