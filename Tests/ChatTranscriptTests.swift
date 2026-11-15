import Foundation
@testable import SimulCore

@MainActor
func registerChatTranscriptTests() {
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
        expectEqual(id, "p1-prompt", "one entry for the record")
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
}
