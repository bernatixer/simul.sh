import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ClaudeChatClient: ChatAgentClient {
    var onEvent: ((ChatAgentEvent) -> Void)?
    var processID: Int32? { process.processID }

    private enum State { case closed, initializing, ready, running }
    private enum Control { case initialize, model(String), other }
    private struct PendingControl {
        var continuation: CheckedContinuation<Void, Error>
        var deadline: Task<Void, Never>
        var kind: Control
    }
    private struct PendingSend {
        var id: String
        var continuation: CheckedContinuation<Void, Error>
        var deadline: Task<Void, Never>
    }

    private let process = ChatJSONProcess()
    private var state = State.closed
    private var generation = UUID()
    private var conversationID = ""
    private var selectedModel: String?
    private var selectedEffort: String?
    private var resolvedModel: String?
    private var transcriptDirectory = AgentConversations.defaultClaudeDir
    private var controls: [String: PendingControl] = [:]
    private var pendingSend: PendingSend?
    private var requests: [String: [String: Any]] = [:]
    private var messageID: String?
    private var blockIndex: Int?
    private var nextBlockIndex: [String: Int] = [:]
    private var completedRecords: Set<String> = []
    private var tools: [String: ChatTool] = [:]
    private var hasReply = false

    func start(_ configuration: ChatAgentConfiguration) async throws {
        guard state == .closed else { throw ChatAgentError.rejected("Claude is already connected.") }
        if let id = configuration.conversationID, UUID(uuidString: id) == nil {
            throw ChatAgentError.rejected("Claude's conversation ID is invalid.")
        }
        state = .initializing
        let token = UUID()
        generation = token
        conversationID = configuration.conversationID ?? UUID().uuidString.lowercased()
        selectedModel = configuration.model
        selectedEffort = configuration.effort
        resolvedModel = configuration.model
        let directory = configuration.environment["CLAUDE_CONFIG_DIR"]
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        transcriptDirectory = directory.map { URL(fileURLWithPath: $0) } ?? AgentConversations.defaultClaudeDir
        var recordedEffort: String?
        var recordedTitle: String?

        if let id = configuration.conversationID {
            let conversation = await ChatTranscripts.shared.conversation(id: id, claudeDir: transcriptDirectory)
            let history = conversation?.entries ?? []
            recordedEffort = conversation?.effort?.lowercased()
            recordedTitle = conversation?.title
            await Task.detached(priority: .userInitiated) { ChatMarkdown.cache.prewarm(Array(history.suffix(200))) }.value
            guard generation == token, state == .initializing else { throw CancellationError() }
            if !history.isEmpty { onEvent?(.history(history)) }
        }

        var arguments = configuration.arguments + [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--replay-user-messages",
            "--permission-prompt-tool", "stdio",
        ]
        arguments.append(configuration.conversationID == nil ? "--session-id=\(conversationID)" : "--resume=\(conversationID)")
        if configuration.skipPermissions { arguments.append("--dangerously-skip-permissions") }
        if let model = configuration.model { arguments += ["--model", model] }
        if let effort = configuration.effort { arguments += ["--effort", effort] }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(configuration.environment) { _, value in value }
        environment.removeValue(forKey: "CLAUDECODE")
        process.onMessage = { [weak self] in self?.receive($0) }
        process.onError = { [weak self] in self?.fail($0) }
        process.onExit = { [weak self] status, stderr in
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.fail(detail.isEmpty ? "Claude disconnected (exit \(status))." : detail)
        }
        do {
            try process.start(executable: configuration.executable, arguments: arguments,
                              environment: environment, workingDirectory: configuration.workingDirectory)
            try await control(["subtype": "initialize", "hooks": NSNull()], kind: .initialize)
            guard generation == token, state == .initializing else { throw CancellationError() }
            state = .ready
            onEvent?(.ready(conversationID: conversationID, model: resolvedModel))
            onEvent?(.effortChanged(selectedEffort ?? recordedEffort))
            if let recordedTitle { onEvent?(.titleChanged(recordedTitle)) }
        } catch {
            if generation == token { close() }
            throw error
        }
    }

    func send(_ message: ChatOutgoingMessage) async throws {
        guard state == .ready else { throw ChatAgentError.rejected("Wait for Claude to finish before sending another message.") }
        let token = generation
        let contentData = try await Task.detached(priority: .userInitiated) {
            try Self.content(message.pieces)
        }.value
        guard generation == token, state == .ready else { throw ChatAgentError.rejected("Claude disconnected before the message was sent.") }
        let content = try JSONSerialization.jsonObject(with: contentData)
        hasReply = false
        state = .running
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard let self, self.pendingSend?.id == message.id else { return }
                self.fail("Claude has not acknowledged this message. Delivery is uncertain; check the conversation before retrying.")
            }
            pendingSend = PendingSend(id: message.id, continuation: continuation, deadline: deadline)
            do {
                try process.send([
                    "type": "user", "uuid": message.id, "session_id": conversationID,
                    "parent_tool_use_id": NSNull(), "message": ["role": "user", "content": content],
                ])
                onEvent?(.started)
            } catch {
                pendingSend = nil
                deadline.cancel()
                state = .ready
                continuation.resume(throwing: ChatAgentError.rejected(error.localizedDescription))
            }
        }
    }

    func setOptions(model: String?, effort: String?) async throws {
        guard state == .ready else { throw ChatAgentError.rejected("Wait for Claude to finish before changing its options.") }
        if let effort, !["low", "medium", "high", "xhigh", "max"].contains(effort) {
            throw ChatAgentError.rejected("Claude doesn't support that effort level.")
        }
        if let model, model != selectedModel {
            guard !model.isEmpty else { throw ChatAgentError.rejected("Choose a Claude model.") }
            try await control(["subtype": "set_model", "model": model], kind: .model(model))
            selectedModel = model
        }
        if let effort, effort != selectedEffort {
            try await control(["subtype": "apply_flag_settings", "settings": ["effortLevel": effort]])
            selectedEffort = effort
            onEvent?(.effortChanged(effort))
        }
    }

    func respond(to requestID: String, decision: ChatAgentDecision, answers: [String: [String]]) throws {
        guard let request = requests[requestID], let input = request["input"] as? [String: Any] else {
            throw ChatAgentError.rejected("Claude is no longer waiting for that response.")
        }
        var response: [String: Any]
        if decision == .deny || decision == .cancel {
            response = ["behavior": "deny", "message": decision == .cancel ? "The user cancelled this request." : "The user declined this request."]
            if decision == .cancel { response["interrupt"] = true }
        } else {
            var updated = input
            if request["tool_name"] as? String == "AskUserQuestion" {
                let questions = input["questions"] as? [[String: Any]] ?? []
                var supplied: [String: [String]] = [:]
                for question in questions {
                    guard let text = question["question"] as? String, let values = answers[text],
                          !values.isEmpty, values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                          question["multiSelect"] as? Bool == true || values.count == 1 else {
                        throw ChatAgentError.rejected("Answer each of Claude's questions before continuing.")
                    }
                    supplied[text] = values
                }
                updated["answers"] = supplied
            }
            response = ["behavior": "allow", "updatedInput": updated]
            if decision == .allowSession, request["tool_name"] as? String != "AskUserQuestion",
               let suggestions = request["permission_suggestions"] as? [[String: Any]], !suggestions.isEmpty {
                response["updatedPermissions"] = suggestions.map { suggestion in
                    var scoped = suggestion
                    scoped["destination"] = "session"
                    return scoped
                }
            }
        }
        try process.send(["type": "control_response", "response": [
            "subtype": "success", "request_id": requestID, "response": response,
        ]])
        requests.removeValue(forKey: requestID)
        onEvent?(.requestResolved(id: requestID))
    }

    func interrupt() {
        guard state == .running else { return }
        let token = generation
        Task { [weak self] in
            // boffin: keep a queued Stop attached to the connection that requested it.
            guard let self, self.generation == token else { return }
            do { try await self.control(["subtype": "interrupt"]) }
            catch {
                if self.generation == token { self.fail("Could not stop Claude: \(error.localizedDescription)") }
            }
        }
    }

    func close() {
        generation = UUID()
        process.close()
        state = .closed
        rejectPending("Claude disconnected.")
        for id in requests.keys { onEvent?(.requestResolved(id: id)) }
        requests.removeAll()
        messageID = nil
        blockIndex = nil
        nextBlockIndex.removeAll()
        completedRecords.removeAll()
        tools.removeAll()
    }

    private func control(_ request: [String: Any], kind: Control = .other) async throws {
        guard process.isRunning else { throw ChatAgentError.rejected("Claude is disconnected.") }
        let id = UUID().uuidString
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.controls[id] != nil else { return }
                self.fail("Claude did not answer a control request.")
            }
            controls[id] = PendingControl(continuation: continuation, deadline: deadline, kind: kind)
            do { try process.send(["type": "control_request", "request_id": id, "request": request]) }
            catch {
                controls.removeValue(forKey: id)
                deadline.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func receive(_ record: [String: Any]) {
        switch record["type"] as? String {
        case "control_response":
            guard let response = record["response"] as? [String: Any], let id = response["request_id"] as? String,
                  let pending = controls.removeValue(forKey: id) else { return }
            pending.deadline.cancel()
            guard response["subtype"] as? String == "success" else {
                pending.continuation.resume(throwing: ChatAgentError.rejected(response["error"] as? String ?? "Claude rejected the request."))
                return
            }
            let result = response["response"] as? [String: Any] ?? [:]
            switch pending.kind {
            case .initialize:
                if let models = result["models"] as? [[String: Any]] {
                    let catalog = models.compactMap { model -> ChatAgentModel? in
                        guard let id = model["value"] as? String else { return nil }
                        if id == (selectedModel ?? "default") { resolvedModel = model["resolvedModel"] as? String ?? id }
                        return ChatAgentModel(id: id, name: model["displayName"] as? String ?? id,
                                              efforts: model["supportedEffortLevels"] as? [String] ?? [],
                                              resolvedID: model["resolvedModel"] as? String)
                    }
                    onEvent?(.models(catalog))
                }
            case let .model(model):
                resolvedModel = result["model"] as? String ?? model
                onEvent?(.modelChanged(resolvedModel!))
            case .other: break
            }
            pending.continuation.resume()
        case "control_request":
            receiveRequest(record)
        case "control_cancel_request":
            if let id = record["request_id"] as? String, requests.removeValue(forKey: id) != nil {
                onEvent?(.requestResolved(id: id))
            }
        case "user":
            if let id = record["uuid"] as? String, let pending = pendingSend, id == pending.id {
                pendingSend = nil
                pending.deadline.cancel()
                onEvent?(.accepted(messageID: id))
                pending.continuation.resume()
            }
            guard record["parent_tool_use_id"] is NSNull || record["parent_tool_use_id"] == nil else { return }
            let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, var tool = tools[id] else { continue }
                tool.result = Self.resultText(block["content"])
                tool.isError = block["is_error"] as? Bool == true
                tools[id] = tool
                onEvent?(.tool(tool))
            }
        case "stream_event":
            guard record["parent_tool_use_id"] is NSNull || record["parent_tool_use_id"] == nil,
                  let event = record["event"] as? [String: Any] else { return }
            receiveStream(event)
        case "assistant":
            receiveAssistant(record)
        case "result":
            receiveResult(record)
        case "system":
            if record["subtype"] as? String == "init" { publishModel(record["model"] as? String) }
        default: break
        }
    }

    private func receiveStream(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            messageID = message?["id"] as? String
            publishModel(message?["model"] as? String)
            blockIndex = nil
            if state == .ready { state = .running; hasReply = false; onEvent?(.started) }
        case "content_block_start":
            blockIndex = event["index"] as? Int
            if let id = messageID, let index = blockIndex,
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "text",
               let text = block["text"] as? String, !text.isEmpty {
                hasReply = true
                onEvent?(.text(id: "\(id)-\(index)", delta: text))
            }
        case "content_block_delta":
            guard let id = messageID, let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return }
            hasReply = true
            onEvent?(.text(id: "\(id)-\(index)", delta: text))
        case "content_block_stop": blockIndex = nil
        case "message_stop": messageID = nil; blockIndex = nil
        default: break
        }
    }

    private func receiveAssistant(_ record: [String: Any]) {
        guard record["parent_tool_use_id"] is NSNull || record["parent_tool_use_id"] == nil,
              let message = record["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        if let uuid = record["uuid"] as? String, !completedRecords.insert(uuid).inserted { return }
        publishModel(message["model"] as? String)
        let id = message["id"] as? String ?? record["uuid"] as? String ?? UUID().uuidString
        let start = messageID == id ? (blockIndex ?? nextBlockIndex[id, default: 0]) : nextBlockIndex[id, default: 0]
        for (offset, block) in blocks.enumerated() {
            let index = start + offset
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    hasReply = true
                    // boffin: streamed and completed blocks keep one row despite different envelope UUIDs.
                    onEvent?(.reply(id: "\(id)-\(index)", text: text))
                }
            case "tool_use":
                guard let toolID = block["id"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let tool = ChatTool(id: toolID, name: block["name"] as? String ?? "Tool",
                                    summary: ChatTranscript.summary(input), detail: Self.detail(input))
                tools[toolID] = tool
                onEvent?(.tool(tool))
            default: break
            }
        }
        nextBlockIndex[id] = start + blocks.count
    }

    private func receiveResult(_ record: [String: Any]) {
        guard let isError = record["is_error"] as? Bool, let subtype = record["subtype"] as? String else {
            return fail("Claude returned an invalid turn result.")
        }
        let terminal = record["terminal_reason"] as? String
        let interrupted = terminal == "aborted_streaming" || terminal == "aborted_tools"
        // boffin: an error remains a failure when Claude labels the result subtype "success".
        let failed = isError || subtype != "success"
        let error: String?
        if failed {
            let errors = (record["errors"] as? [String] ?? []).filter { !$0.isEmpty }
            error = !errors.isEmpty ? errors.joined(separator: "\n") : (record["result"] as? String ?? "Claude could not complete this turn.")
        } else { error = nil }
        if let pending = pendingSend {
            pendingSend = nil
            pending.deadline.cancel()
            pending.continuation.resume(throwing: ChatAgentError.uncertain("Claude finished without acknowledging this message. Check the conversation before retrying."))
        }
        if !failed, !interrupted, !hasReply, let text = record["result"] as? String, !text.isEmpty {
            onEvent?(.reply(id: record["uuid"] as? String ?? UUID().uuidString, text: text))
        }
        state = .ready
        for id in requests.keys { onEvent?(.requestResolved(id: id)) }
        requests.removeAll()
        messageID = nil
        blockIndex = nil
        onEvent?(.finished(outcome: interrupted ? .interrupted : failed ? .failed : .completed, error: error))
        let token = generation
        let id = conversationID
        let root = transcriptDirectory
        Task { [weak self] in
            let conversation = await ChatTranscripts.shared.conversation(id: id, claudeDir: root)
            guard let self, self.generation == token, self.state != .closed else { return }
            if let effort = conversation?.effort?.lowercased() { self.onEvent?(.effortChanged(effort)) }
            if let title = conversation?.title { self.onEvent?(.titleChanged(title)) }
        }
    }

    private func publishModel(_ model: String?) {
        guard let model, !model.isEmpty, !model.hasPrefix("<"), resolvedModel != model else { return }
        resolvedModel = model
        onEvent?(.modelChanged(model))
    }

    private func receiveRequest(_ record: [String: Any]) {
        guard let id = record["request_id"] as? String, let request = record["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool", let name = request["tool_name"] as? String,
              let input = request["input"] as? [String: Any] else {
            try? process.send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Simul doesn't support this control request."]])
            return
        }
        if name == "AskUserQuestion" {
            let questions = input["questions"] as? [[String: Any]] ?? []
            var keys: Set<String> = []
            // boffin: refuse question keys that cannot be answered without ambiguity.
            guard !questions.isEmpty, questions.allSatisfy({ question in
                guard let text = question["question"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                return keys.insert(text).inserted
            }) else {
                let message = "Claude sent an invalid question request. Each question needs unique, nonempty text."
                do {
                    try process.send(["type": "control_response", "response": [
                        "subtype": "success", "request_id": id,
                        "response": ["behavior": "deny", "message": message],
                    ]])
                    onEvent?(.error(message))
                } catch { fail("Could not reject Claude's question request: \(error.localizedDescription)") }
                return
            }
        }
        requests[id] = request
        let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { question -> ChatAgentQuestion? in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> ChatAgentChoice? in
                guard let label = option["label"] as? String else { return nil }
                return ChatAgentChoice(label: label, description: option["description"] as? String ?? "")
            }
            return ChatAgentQuestion(id: text, prompt: text, options: options, allowsMultiple: question["multiSelect"] as? Bool == true)
        }
        let description = request["description"] as? String ?? ""
        let detail = name == "AskUserQuestion" ? description : [description, Self.detail(input)].filter { !$0.isEmpty }.joined(separator: "\n\n")
        onEvent?(.request(ChatAgentRequest(
            id: id, title: request["title"] as? String ?? (name == "AskUserQuestion" ? "Claude has a question" : "Allow \(name)?"),
            detail: detail, questions: name == "AskUserQuestion" ? questions : [],
            allowsSessionApproval: name != "AskUserQuestion" && !(request["permission_suggestions"] as? [[String: Any]] ?? []).isEmpty
        )))
    }

    private func fail(_ message: String) {
        guard state != .closed else { return }
        let wasRunning = state == .running
        rejectPending(message)
        close()
        if wasRunning { onEvent?(.finished(outcome: .failed, error: message)) }
        onEvent?(.disconnected(message))
    }

    private func rejectPending(_ message: String) {
        if let pending = pendingSend {
            pendingSend = nil
            pending.deadline.cancel()
            pending.continuation.resume(throwing: ChatAgentError.uncertain(message))
        }
        let waiting = controls.values
        controls.removeAll()
        for pending in waiting {
            pending.deadline.cancel()
            pending.continuation.resume(throwing: ChatAgentError.rejected(message))
        }
    }

    private nonisolated static func content(_ pieces: [PromptPiece]) throws -> Data {
        var blocks: [[String: Any]] = []
        for piece in pieces {
            switch piece {
            case let .text(text):
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            case let .image(url):
                guard url.isFileURL else { throw ChatAgentError.rejected("Choose an image saved on this Mac.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
                      let mime = UTType(type as String)?.preferredMIMEType,
                      ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else {
                    throw ChatAgentError.rejected("Claude accepts PNG, JPEG, GIF, and WebP images.")
                }
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]])
            }
        }
        guard !blocks.isEmpty else { throw ChatAgentError.rejected("Write a message or attach an image.") }
        return try JSONSerialization.data(withJSONObject: blocks)
    }

    private static func detail(_ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
