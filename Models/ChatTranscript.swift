import Foundation

/// One row of the Chat view: your prompt, the agent's reply, a run of tool
/// calls between them (collapsed to one line until opened), or a muted note
/// ("/model", "Interrupted", "Conversation compacted").
enum ChatEntry: Codable, Identifiable, Equatable, Sendable {
    /// `images`: small JPEGs of the images sent with it.
    case prompt(id: String, text: String, images: [Data] = [])
    case reply(id: String, text: String)
    case tools(id: String, [ChatTool])
    case note(id: String, text: String)

    var id: String {
        switch self {
        case let .prompt(id, _, _), let .reply(id, _), let .tools(id, _), let .note(id, _): return id
        }
    }
}

struct ChatTool: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// One line: a file name, a command's description, a search pattern.
    let summary: String
    /// The command, or the input as JSON, shown when opened.
    let detail: String
    /// nil until the result is in the transcript.
    var result: String?
    var isError = false
}

/// The active branch's entries, model, effort, and permission mode.
struct ChatConversation: Codable, Equatable, Sendable {
    var entries: [ChatEntry] = []
    var title: String?
    /// "Opus 5.5"
    var model: String?
    /// "High"
    var effort: String?
    /// Claude Code's own name: "default", "acceptEdits", "plan", "auto",
    /// "bypassPermissions".
    var permissionMode: String?
    /// How many prompts it holds, so a sender can tell when theirs is in.
    var prompts = 0
    /// The last prompt's turn is still going: no `turn_duration` record
    /// (which Claude Code writes as a turn ends) since, and no interrupt.
    var turnOpen = false
    /// Goes up with every change, so callers compare one number.
    var revision = 0
}

/// Reads a Claude transcript (`~/.claude/projects/<cwd>/<id>.jsonl`) into
/// chat entries, a chunk at a time: `consume` takes the bytes appended
/// since the last call. Read-only; Claude owns the file.
struct ChatTranscript: Sendable {
    private(set) var conversation = ChatConversation() { didSet { changed = true } }
    private var changed = false
    private var toolAt: [String: ToolPosition] = [:]
    private var replyAt: [String: Int] = [:]
    private var records: [String: Record] = [:]
    private var activePath: [String] = []
    private var prefix: [Event] = []
    private var nextRecord = 0
    private var customTitle: String?
    private var aiTitle: String?
    /// The end of the last chunk, until its line is complete.
    private var partial = Data()

    private struct Record: Sendable {
        let parent: String?
        var events: [Event]
    }

    private enum Event: Sendable {
        case entry(ChatEntry)
        case tool(ChatTool, id: String)
        case result(id: String, text: String, isError: Bool)
        case model(String), effort(String), permission(String)
        case endTurn
    }

    private struct ToolPosition: Sendable {
        let entry: Int
        let tool: Int
    }

    /// The whole file at once (tests); a last line without a newline counts.
    static func parse(_ data: Data) -> ChatConversation {
        var transcript = ChatTranscript()
        transcript.consume(data)
        transcript.consume(Data([UInt8(ascii: "\n")]))
        return transcript.conversation
    }

    mutating func consume(_ data: Data) {
        partial.append(data)
        guard let end = partial.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let lines = partial[partial.startIndex..<end].split(separator: UInt8(ascii: "\n"))
        for line in lines { read(line) }
        partial = Data(partial[partial.index(after: end)...])
        if changed { conversation.revision += 1 }
        changed = false
    }

    private mutating func read(_ line: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["isSidechain"] as? Bool != true else { return }
        if let type = record["type"] as? String, type == "custom-title" || type == "ai-title" {
            if type == "custom-title" { customTitle = (record["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            else { aiTitle = (record["aiTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let title = customTitle ?? aiTitle
            if conversation.title != title { conversation.title = title }
            return
        }
        nextRecord += 1
        let recordID = record["uuid"] as? String ?? "transcript-record-\(nextRecord)"
        let parent = record.keys.contains("parentUuid")
            ? record["parentUuid"] as? String : records[recordID]?.parent ?? activePath.last
        let events = Self.events(record, id: recordID)
        let role = record["type"] as? String
        let selectsBranch = (role == "user" || role == "assistant")
            && record["message"] is [String: Any] && record["isMeta"] as? Bool != true && !events.isEmpty
        if selectsBranch {
            let replacing = records[recordID] != nil
            records[recordID] = Record(parent: parent, events: events)
            if !replacing, let continuation = continuation(from: parent) {
                activePath.append(contentsOf: continuation)
                activePath.append(recordID)
                apply(events)
            } else {
                rebuild(from: recordID)
            }
        } else {
            // Auxiliary records update their branch without selecting it.
            if record["uuid"] is String { records[recordID] = Record(parent: parent, events: []) }
            if let parent {
                if records[parent] == nil { records[parent] = Record(parent: nil, events: []) }
                records[parent]?.events.append(contentsOf: events)
                if parent == activePath.last { apply(events) }
            } else if activePath.isEmpty {
                prefix.append(contentsOf: events)
                apply(events)
            }
        }
    }

    private func continuation(from parent: String?) -> [String]? {
        var path: [String] = []
        var visited: Set<String> = []
        var current = parent
        while current != activePath.last {
            guard let id = current, visited.insert(id).inserted,
                  let record = records[id], record.events.isEmpty else { return nil }
            path.append(id)
            current = record.parent
        }
        return path.reversed()
    }

    private mutating func rebuild(from leaf: String) {
        var path: [String] = []
        var visited: Set<String> = []
        var current: String? = leaf
        while let id = current, visited.insert(id).inserted, let record = records[id] {
            path.append(id)
            current = record.parent
        }
        var fresh = ChatTranscript()
        fresh.apply(prefix)
        for id in path.reversed() { fresh.apply(records[id]?.events ?? []) }
        fresh.conversation.title = conversation.title
        fresh.conversation.revision = conversation.revision
        // boffin: Publish the selected branch only after its rows and tool results are rebuilt.
        if conversation != fresh.conversation { conversation = fresh.conversation }
        toolAt = fresh.toolAt
        replyAt = fresh.replyAt
        activePath = path.reversed()
    }

    private mutating func apply(_ events: [Event]) {
        for event in events {
            switch event {
            case let .entry(entry): append(entry)
            case let .tool(tool, id): addTool(tool, id: id)
            case let .result(id, text, isError):
                guard let at = toolAt[id], case .tools(let entryID, var tools) = conversation.entries[at.entry] else { continue }
                if tools[at.tool].result != text || tools[at.tool].isError != isError {
                    tools[at.tool].result = text
                    tools[at.tool].isError = isError
                    conversation.entries[at.entry] = .tools(id: entryID, tools)
                }
            case let .model(name):
                if conversation.model != name { conversation.model = name }
            case let .effort(level):
                if conversation.effort != level { conversation.effort = level }
            case let .permission(mode):
                if conversation.permissionMode != mode { conversation.permissionMode = mode }
            case .endTurn:
                if conversation.turnOpen { conversation.turnOpen = false }
            }
        }
    }

    private static func events(_ record: [String: Any], id recordID: String) -> [Event] {
        let role = record["type"] as? String
        if role == "permission-mode", let mode = record["permissionMode"] as? String {
            return [.permission(mode)]
        }
        if role == "system", record["subtype"] as? String == "turn_duration" {
            return [.endTurn]
        }
        if record["isCompactSummary"] as? Bool == true {
            return [.entry(.note(id: recordID, text: "Conversation compacted"))]
        }
        guard record["isMeta"] as? Bool != true, let message = record["message"] as? [String: Any] else { return [] }
        var events: [Event] = []
        if role == "assistant" {
            if let id = message["model"] as? String, let name = modelName(id) { events.append(.model(name)) }
            if let level = record["effort"] as? String, !level.isEmpty { events.append(.effort(level.capitalized)) }
        }
        if role == "user", let content = message["content"] as? String {
            if let entry = userText(content, id: recordID) { events.append(.entry(entry)) }
            return events
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        // What you typed with the images you sent, as one prompt.
        var typed: [String] = []
        var images: [Data] = []
        for (index, block) in blocks.enumerated() {
            let blockID = "\(recordID)-\(index)"
            switch (role, block["type"] as? String) {
            case ("user", "text"):
                if let entry = userText(block["text"] as? String ?? "", id: blockID) {
                    if case let .prompt(_, text, _) = entry { typed.append(text) }
                    else { events.append(.entry(entry)) }
                }
            case ("user", "image"):
                let source = block["source"] as? [String: Any]
                if let base64 = source?["data"] as? String, let data = Data(base64Encoded: base64),
                   let thumbnail = ClipboardPaste.thumbnailJPEG(of: data) {
                    images.append(thumbnail)
                }
            case ("user", "tool_result"):
                if let id = block["tool_use_id"] as? String {
                    events.append(.result(id: id, text: resultText(block["content"]), isError: block["is_error"] as? Bool == true))
                }
            case ("assistant", "text"):
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let messageID = message["id"] as? String ?? recordID
                if !text.isEmpty { events.append(.entry(.reply(id: "\(messageID)-\(index)", text: text))) }
            case ("assistant", "tool_use"):
                let input = block["input"] as? [String: Any] ?? [:]
                events.append(.tool(ChatTool(
                    id: block["id"] as? String ?? blockID,
                    name: block["name"] as? String ?? "Tool",
                    summary: summary(input),
                    detail: detail(input)
                ), id: blockID))
            default:
                continue // thinking, anything new
            }
        }
        if !typed.isEmpty || !images.isEmpty {
            events.append(.entry(.prompt(id: recordID, text: typed.joined(separator: "\n\n"), images: images)))
        }
        return events
    }

    private mutating func append(_ entry: ChatEntry) {
        if case .reply = entry, let index = replyAt[entry.id] {
            if conversation.entries[index] != entry { conversation.entries[index] = entry }
            return
        }
        conversation.entries.append(entry)
        switch entry {
        case .prompt:
            conversation.prompts += 1
            conversation.turnOpen = true
        case .note(_, "Interrupted"):
            conversation.turnOpen = false
        case .reply:
            replyAt[entry.id] = conversation.entries.count - 1
        default:
            break
        }
    }

    private mutating func addTool(_ tool: ChatTool, id: String) {
        if case .tools(let runID, var tools) = conversation.entries.last {
            tools.append(tool)
            conversation.entries[conversation.entries.count - 1] = .tools(id: runID, tools)
            toolAt[tool.id] = ToolPosition(entry: conversation.entries.count - 1, tool: tools.count - 1)
        } else {
            append(.tools(id: id, [tool]))
            toolAt[tool.id] = ToolPosition(entry: conversation.entries.count - 1, tool: 0)
        }
    }

    /// Notes what Claude Code records as a user turn (slash commands,
    /// interrupts) and returns what you typed; other injected text
    /// (`<system-reminder>`, `<task-notification>`, …) is left out.
    private static func userText(_ text: String, id: String) -> ChatEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted by user") {
            return .note(id: id, text: "Interrupted")
        }
        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>"),
           let command = tag("command-name", in: trimmed) {
            let args = tag("command-args", in: trimmed) ?? ""
            return .note(id: id, text: args.isEmpty ? command : "\(command) \(args)")
        }
        let injected = ["<system-reminder>", "<task-notification>", "<local-command-caveat>",
                        "<local-command-stdout>", "<local-command-stderr>"]
        return trimmed.isEmpty || injected.contains(where: trimmed.hasPrefix) ? nil : .prompt(id: id, text: trimmed)
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5";
    /// nil for ids that aren't Claude's (`<synthetic>`).
    static func modelName(_ id: String) -> String? {
        guard id.hasPrefix("claude-") else { return nil }
        let words = id.dropFirst(7).split(separator: "-").map(String.init).filter { $0.count < 8 } // drop a date suffix
        guard let family = words.first, !family.allSatisfy(\.isNumber) else { return nil }
        let version = words.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    static func summary(_ input: [String: Any]) -> String {
        func value(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let path = value("file_path") ?? value("notebook_path") {
            return (path as NSString).lastPathComponent
        }
        for key in ["description", "command", "pattern", "url", "query", "skill", "prompt"] {
            if let text = value(key) {
                return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            }
        }
        return ""
    }

    private static func detail(_ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        guard let data = try? JSONSerialization.data(
            withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool result is a string or a list of blocks; keep the text ones.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A short preview; full tool input and output stay in the transcript.
    static func clip(_ text: String, lines: Int = 40, characters: Int = 4000) -> String {
        var clipped = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(lines).joined(separator: "\n")
        if clipped.count > characters { clipped = String(clipped.prefix(characters)) }
        return clipped.count < text.count ? clipped + "\n…" : clipped
    }
}
