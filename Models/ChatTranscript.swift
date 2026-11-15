import Foundation

/// One row of the Chat view: your prompt, the agent's reply, a run of tool
/// calls between them (collapsed to one line until opened), or a muted note
/// ("/model", "Interrupted", "Conversation compacted").
enum ChatEntry: Identifiable, Equatable, Sendable {
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

struct ChatTool: Identifiable, Equatable, Sendable {
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

/// A transcript's entries, and what its latest records say about the model,
/// effort and permission mode.
struct ChatConversation: Equatable, Sendable {
    var entries: [ChatEntry] = []
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
// ponytail: follows line order, so after a rewind both branches show
// (follow `parentUuid` from the last record to fix); subagent sidechains
// are left out.
struct ChatTranscript: Sendable {
    private(set) var conversation = ChatConversation() { didSet { changed = true } }
    private var changed = false
    private var toolAt: [String: ToolPosition] = [:]
    /// The end of the last chunk, until its line is complete.
    private var partial = Data()

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
        let recordID = record["uuid"] as? String ?? UUID().uuidString
        let role = record["type"] as? String
        if role == "permission-mode", let mode = record["permissionMode"] as? String {
            conversation.permissionMode = mode
            return
        }
        if role == "system", record["subtype"] as? String == "turn_duration" {
            if conversation.turnOpen { conversation.turnOpen = false }
            return
        }
        if record["isCompactSummary"] as? Bool == true {
            return append(.note(id: recordID, text: "Conversation compacted"))
        }
        guard record["isMeta"] as? Bool != true, let message = record["message"] as? [String: Any] else { return }

        if role == "assistant" {
            if let id = message["model"] as? String, let name = Self.modelName(id) { conversation.model = name }
            if let level = record["effort"] as? String, !level.isEmpty { conversation.effort = level.capitalized }
        }
        if role == "user", let content = message["content"] as? String {
            if let text = userText(content, id: recordID) { append(.prompt(id: recordID, text: text)) }
            return
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        // What you typed with the images you sent, as one prompt.
        var typed: [String] = []
        var images: [Data] = []
        for (index, block) in blocks.enumerated() {
            let blockID = "\(recordID)-\(index)"
            switch (role, block["type"] as? String) {
            case ("user", "text"):
                if let text = userText(block["text"] as? String ?? "", id: blockID) { typed.append(text) }
            case ("user", "image"):
                let source = block["source"] as? [String: Any]
                if let base64 = source?["data"] as? String, let data = Data(base64Encoded: base64),
                   let thumbnail = ClipboardPaste.thumbnailJPEG(of: data) {
                    images.append(thumbnail)
                }
            case ("user", "tool_result"):
                guard let toolID = block["tool_use_id"] as? String, let at = toolAt[toolID],
                      case .tools(let id, var tools) = conversation.entries[at.entry] else { continue }
                tools[at.tool].result = Self.clip(Self.resultText(block["content"]))
                tools[at.tool].isError = block["is_error"] as? Bool == true
                conversation.entries[at.entry] = .tools(id: id, tools)
            case ("assistant", "text"):
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { append(.reply(id: blockID, text: text)) }
            case ("assistant", "tool_use"):
                let input = block["input"] as? [String: Any] ?? [:]
                addTool(ChatTool(
                    id: block["id"] as? String ?? blockID,
                    name: block["name"] as? String ?? "Tool",
                    summary: Self.summary(input),
                    detail: Self.clip(Self.detail(input))
                ), id: blockID)
            default:
                continue // thinking, anything new
            }
        }
        if !typed.isEmpty || !images.isEmpty {
            append(.prompt(id: "\(recordID)-prompt", text: typed.joined(separator: "\n\n"), images: images))
        }
    }

    private mutating func append(_ entry: ChatEntry) {
        conversation.entries.append(entry)
        switch entry {
        case .prompt:
            conversation.prompts += 1
            conversation.turnOpen = true
        case .note(_, "Interrupted"):
            conversation.turnOpen = false
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
    @discardableResult
    private mutating func userText(_ text: String, id: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted by user") {
            append(.note(id: id, text: "Interrupted"))
            return nil
        }
        if let command = Self.tag("command-name", in: trimmed) {
            let args = Self.tag("command-args", in: trimmed) ?? ""
            append(.note(id: id, text: args.isEmpty ? command : "\(command) \(args)"))
            return nil
        }
        return trimmed.isEmpty || trimmed.hasPrefix("<") ? nil : trimmed
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

    /// Tool output can be MBs; the chat shows the start.
    static func clip(_ text: String, lines: Int = 40, characters: Int = 4000) -> String {
        var clipped = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(lines).joined(separator: "\n")
        if clipped.count > characters { clipped = String(clipped.prefix(characters)) }
        return clipped.count < text.count ? clipped + "\n…" : clipped
    }
}
