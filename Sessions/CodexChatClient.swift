import Foundation
import ImageIO

@MainActor
final class CodexChatClient: ChatAgentClient {
    var onEvent: ((ChatAgentEvent) -> Void)?
    var processID: Int32? { process.processID }

    private enum State { case closed, starting, ready }
    private struct Pending {
        var continuation: CheckedContinuation<Data, Error>
        var deadline: Task<Void, Never>
    }
    private struct Interaction {
        var rpcID: Any
        var method: String
        var params: [String: Any]
        var request: ChatAgentRequest
    }

    private let process = ChatJSONProcess()
    private var state = State.closed
    private var configuration: ChatAgentConfiguration?
    private var generation = 0
    private var nextID = 0
    private var pending: [String: Pending] = [:]
    private var interactions: [String: Interaction] = [:]
    private var buffered: [[String: Any]] = []
    private var threadID: String?
    private var turnID: String?
    private var completedTurns: Set<String> = []
    private var sendingID: String?
    private var model: String?
    private var effort: String?
    private var models: [ChatAgentModel] = []
    private var defaultEfforts: [String: String] = [:]
    private var tools: [String: ChatTool] = [:]

    func start(_ configuration: ChatAgentConfiguration) async throws {
        guard state == .closed else { throw ChatAgentError.rejected("Codex is already connected.") }
        state = .starting
        self.configuration = configuration
        model = configuration.model
        effort = configuration.effort
        let attempt = generation
        process.onMessage = { [weak self] in self?.receive($0) }
        process.onExit = { [weak self] code, stderr in
            self?.disconnected("Codex stopped (exit \(code))." + (stderr.isEmpty ? "" : " \(stderr)"))
        }
        process.onError = { [weak self] in self?.disconnected($0) }
        do {
            try process.start(executable: configuration.executable, arguments: configuration.arguments + ["app-server"],
                              environment: configuration.environment, workingDirectory: configuration.workingDirectory)
            _ = try await rpc("initialize", params: [
                "clientInfo": ["name": "simul", "title": "Simul", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "capabilities": ["experimentalApi": true, "requiredHumanApproval": true],
            ])
            guard generation == attempt, state == .starting else { throw ChatAgentError.uncertain("Codex disconnected.") }
            try process.send(["method": "initialized"])
            var params: [String: Any] = [
                "cwd": configuration.workingDirectory,
                "sandbox": configuration.skipPermissions ? "danger-full-access" : "read-only",
                "approvalPolicy": configuration.skipPermissions ? "never" : "on-request",
                "approvalsReviewer": "user",
            ]
            if let model { params["model"] = model }
            let resuming = configuration.conversationID != nil
            if let id = configuration.conversationID { params["threadId"] = id; params["excludeTurns"] = true }
            let response = try await rpc(resuming ? "thread/resume" : "thread/start", params: params)
            guard generation == attempt, state == .starting,
                  let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty else {
                throw ChatAgentError.rejected("Codex did not return a conversation ID.")
            }
            if let expected = configuration.conversationID, id != expected {
                throw ChatAgentError.rejected("Codex resumed a different conversation.")
            }
            threadID = id
            model = response["model"] as? String ?? model
            effort = effort ?? response["reasoningEffort"] as? String
            let history = resuming ? try await loadHistory() : []
            await Task.detached(priority: .userInitiated) { ChatMarkdown.cache.prewarm(Array(history.suffix(200))) }.value
            guard generation == attempt, state == .starting else { throw ChatAgentError.uncertain("Codex disconnected.") }
            state = .ready
            onEvent?(.ready(conversationID: id, model: model))
            if let name = thread["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onEvent?(.titleChanged(name)) }
            if resuming { onEvent?(.history(history)) }
            if turnID != nil { onEvent?(.started) }
            // boffin: publish saved history before replaying updates received while loading it.
            let updates = buffered
            buffered.removeAll()
            for update in updates { receive(update) }
            do { try await loadModels() }
            catch {
                guard generation == attempt, state == .ready else { throw error }
                onEvent?(.error("Cannot load Codex models: \(error.localizedDescription)"))
            }
        } catch {
            if generation == attempt { close() }
            throw error
        }
    }

    func send(_ message: ChatOutgoingMessage) async throws {
        guard state == .ready, let threadID, let configuration else {
            throw ChatAgentError.rejected("Codex is not connected.")
        }
        guard turnID == nil, sendingID == nil else { throw ChatAgentError.rejected("Codex is still working.") }
        var input: [[String: Any]] = []
        for piece in message.pieces {
            switch piece {
            case let .text(text):
                if !text.isEmpty { input.append(["type": "text", "text": text]) }
            case let .image(url):
                guard url.isFileURL else { throw ChatAgentError.rejected("Codex needs a local image file.") }
                input.append(["type": "localImage", "path": url.path])
            }
        }
        guard !input.isEmpty else { throw ChatAgentError.rejected("The message is empty.") }
        let attempt = generation
        sendingID = message.id
        defer { if generation == attempt { sendingID = nil } }
        var params: [String: Any] = [
            "threadId": threadID, "input": input, "clientUserMessageId": message.id,
            "approvalPolicy": configuration.skipPermissions ? "never" : "on-request",
            "approvalsReviewer": "user",
            "sandboxPolicy": ["type": configuration.skipPermissions ? "dangerFullAccess" : "readOnly"],
        ]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        let result = try await rpc("turn/start", params: params)
        guard generation == attempt else { throw ChatAgentError.uncertain("Codex disconnected before confirming the message.") }
        guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else {
            throw ChatAgentError.uncertain("Codex did not confirm the message. Reconnect before retrying.")
        }
        onEvent?(.accepted(messageID: message.id))
        if turn["status"] as? String == "inProgress", turnID == nil, !completedTurns.contains(id) {
            turnID = id
            onEvent?(.started)
        }
    }

    func setOptions(model: String?, effort: String?) async throws {
        guard state == .ready else { throw ChatAgentError.rejected("Codex is not connected.") }
        guard turnID == nil, sendingID == nil else { throw ChatAgentError.rejected("Wait for Codex to finish before changing the model.") }
        if let model, !models.isEmpty, !models.contains(where: { $0.id == model }) {
            throw ChatAgentError.rejected("That Codex model is not available.")
        }
        let nextModel = model ?? self.model
        if let effort, let available = models.first(where: { $0.id == nextModel }), !available.efforts.contains(effort) {
            throw ChatAgentError.rejected("That reasoning effort is not available for this model.")
        }
        self.model = nextModel
        self.effort = effort ?? defaultEfforts[nextModel ?? ""]
        onEvent?(.effortChanged(self.effort))
        if let nextModel { onEvent?(.modelChanged(nextModel)) }
    }

    func respond(to requestID: String, decision: ChatAgentDecision, answers: [String: [String]]) throws {
        guard let interaction = interactions[requestID] else { throw ChatAgentError.rejected("This Codex request is no longer waiting.") }
        if decision == .allowSession && !interaction.request.allowsSessionApproval {
            throw ChatAgentError.rejected("This request needs a one-time decision.")
        }
        let result: [String: Any]
        switch interaction.method {
        case "item/tool/requestUserInput":
            var values: [String: Any] = [:]
            if decision == .allow {
                for question in interaction.request.questions {
                    guard let answer = answers[question.id], !answer.isEmpty,
                          answer.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw ChatAgentError.rejected("Answer each question before continuing.")
                    }
                    values[question.id] = ["answers": answer]
                }
            }
            result = ["answers": values]
        case "item/permissions/requestApproval":
            let allowed = decision == .allow || decision == .allowSession
            result = ["permissions": allowed ? interaction.params["permissions"] as? [String: Any] ?? [:] : [:],
                      "scope": decision == .allowSession ? "session" : "turn"]
        case "mcpServer/elicitation/request":
            guard decision == .deny || decision == .cancel else {
                throw ChatAgentError.rejected("This MCP form cannot be displayed in Chat. Cancel it to continue.")
            }
            result = ["action": decision == .cancel ? "cancel" : "decline"]
        default:
            let values: [ChatAgentDecision: String] = [.allow: "accept", .allowSession: "acceptForSession", .deny: "decline", .cancel: "cancel"]
            result = ["decision": values[decision]!]
        }
        try process.send(["id": interaction.rpcID, "result": result])
        interactions.removeValue(forKey: requestID)
        onEvent?(.requestResolved(id: requestID))
        if decision == .cancel && interaction.method != "item/commandExecution/requestApproval"
            && interaction.method != "item/fileChange/requestApproval" { interrupt() }
    }

    func interrupt() {
        guard let threadID, let turnID else { return }
        let attempt = generation
        Task { [weak self] in
            // boffin: a queued Stop belongs only to the process that was active when it was requested.
            guard let self, generation == attempt, state == .ready, self.turnID == turnID else { return }
            do { _ = try await rpc("turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
            catch {
                guard generation == attempt, self.turnID == turnID else { return }
                disconnected("Cannot stop Codex: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        generation += 1
        state = .closed
        process.close()
        failPending("Codex disconnected before confirming the request.")
        for id in interactions.keys { onEvent?(.requestResolved(id: id)) }
        interactions.removeAll()
        buffered.removeAll()
        tools.removeAll()
        models.removeAll()
        defaultEfforts.removeAll()
        threadID = nil
        turnID = nil
        completedTurns.removeAll()
        sendingID = nil
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process.isRunning else { throw ChatAgentError.uncertain("Codex disconnected before confirming the request.") }
        nextID += 1
        let id = "simul-\(nextID)"
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let request = pending.removeValue(forKey: id) else { return }
                request.continuation.resume(throwing: ChatAgentError.uncertain("Codex did not confirm \(method). Reconnect before retrying."))
            }
            pending[id] = Pending(continuation: continuation, deadline: deadline)
            do { try process.send(["id": id, "method": method, "params": params]) }
            catch {
                deadline.cancel()
                pending.removeValue(forKey: id)?.continuation.resume(throwing: ChatAgentError.rejected(error.localizedDescription))
            }
        }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatAgentError.uncertain("Codex returned an invalid response.")
        }
        return response
    }

    private func receive(_ message: [String: Any]) {
        guard state != .closed else { return }
        if message["method"] == nil, let id = message["id"] as? String, let request = pending.removeValue(forKey: id) {
            request.deadline.cancel()
            if let error = message["error"] as? [String: Any] {
                request.continuation.resume(throwing: ChatAgentError.rejected(error["message"] as? String ?? "Codex rejected the request."))
            } else if let result = message["result"] as? [String: Any] {
                // boffin: pass JSON bytes through the continuation so decoded values stay on the main actor.
                do { request.continuation.resume(returning: try JSONSerialization.data(withJSONObject: result)) }
                catch { request.continuation.resume(throwing: ChatAgentError.uncertain("Codex returned an invalid response.")) }
            } else {
                request.continuation.resume(throwing: ChatAgentError.uncertain("Codex returned an invalid response."))
            }
            return
        }
        if state == .starting { buffered.append(message); return }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard params["threadId"] as? String == threadID else {
            if let id = message["id"] { try? process.send(["id": id, "error": ["code": -32601, "message": "No matching Simul conversation."]]) }
            return
        }
        if let id = message["id"] { receiveRequest(method, params: params, rpcID: id); return }
        switch method {
        case "thread/name/updated":
            if let name = params["threadName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onEvent?(.titleChanged(name)) }
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
            if turnID != id { turnID = id; onEvent?(.started) }
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String,
                  turnID == nil || turnID == id, let status = turn["status"] as? String,
                  let outcome = ChatTurnOutcome(rawValue: status) else { return }
            turnID = nil
            completedTurns.insert(id)
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            let resolved = interactions.filter { $0.value.request.isBlocking && $0.value.params["turnId"] as? String == id }.map(\.key)
            for id in resolved { interactions.removeValue(forKey: id); onEvent?(.requestResolved(id: id)) }
            onEvent?(.finished(outcome: outcome, error: error))
        case "item/agentMessage/delta", "item/plan/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            onEvent?(.text(id: id, delta: delta))
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            receiveItem(item, completed: method == "item/completed")
        case "serverRequest/resolved":
            guard let raw = params["requestId"], let id = Self.requestID(raw), interactions.removeValue(forKey: id) != nil else { return }
            onEvent?(.requestResolved(id: id))
        case "error":
            let error = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex reported an error."
            onEvent?(.error(error))
        default: break
        }
    }

    private func receiveItem(_ item: [String: Any], completed: Bool) {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return }
        if type == "userMessage" {
            if let clientID = item["clientId"] as? String { onEvent?(.accepted(messageID: clientID)) }
        } else if type == "agentMessage" || type == "plan" {
            if completed, let text = item["text"] as? String { onEvent?(.reply(id: id, text: text)) }
        } else if let tool = Self.tool(item, completed: completed) {
            tools[id] = tool
            onEvent?(.tool(tool))
        }
    }

    private func receiveRequest(_ method: String, params: [String: Any], rpcID: Any) {
        guard let id = Self.requestID(rpcID) else { return }
        guard interactions[id] == nil else { return }
        let reason = params["reason"] as? String ?? ""
        var request: ChatAgentRequest
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String ?? tools[params["itemId"] as? String ?? ""]?.detail ?? ""
            let cwd = params["cwd"] as? String ?? ""
            request = ChatAgentRequest(id: id, title: params["kind"] as? String == "writeStdin" ? "Send input to command?" : "Run command?",
                                       detail: [command, cwd.isEmpty ? "" : "Working directory: \(cwd)", reason].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                       allowsSessionApproval: params["kind"] as? String != "humanCommand")
        case "item/fileChange/requestApproval":
            let detail = tools[params["itemId"] as? String ?? ""]?.detail ?? ""
            let root = params["grantRoot"] as? String
            request = ChatAgentRequest(id: id, title: "Apply file changes?",
                                       detail: [detail, reason, root.map { "Write access: \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n"), allowsSessionApproval: true)
        case "item/permissions/requestApproval":
            guard let permissions = params["permissions"] as? [String: Any] else { rejectRequest(rpcID, message: "Invalid permissions request."); return }
            request = ChatAgentRequest(id: id, title: "Grant additional permissions?", detail: [reason, Self.json(permissions)].filter { !$0.isEmpty }.joined(separator: "\n\n"), allowsSessionApproval: true)
        case "item/tool/requestUserInput":
            guard let questions = params["questions"] as? [[String: Any]], !questions.isEmpty else { rejectRequest(rpcID, message: "Invalid user question."); return }
            var parsed: [ChatAgentQuestion] = []
            for question in questions {
                guard let questionID = question["id"] as? String, let prompt = question["question"] as? String else { rejectRequest(rpcID, message: "Invalid user question."); return }
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> ChatAgentChoice? in
                    guard let label = option["label"] as? String else { return nil }
                    return ChatAgentChoice(label: label, description: option["description"] as? String ?? "")
                }
                parsed.append(ChatAgentQuestion(id: questionID, prompt: prompt, options: options, isSecret: question["isSecret"] as? Bool ?? false))
            }
            guard Set(parsed.map(\.id)).count == parsed.count, parsed.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                rejectRequest(rpcID, message: "Codex sent duplicate or empty question IDs.")
                return
            }
            request = ChatAgentRequest(id: id, title: "Codex has a question", questions: parsed, isBlocking: params["isBlocking"] as? Bool ?? true)
        case "mcpServer/elicitation/request":
            let server = params["serverName"] as? String ?? "MCP server"
            let message = params["message"] as? String ?? ""
            request = ChatAgentRequest(id: id, title: "Input requested by \(server)", detail: message + "\n\nThis form cannot be displayed in Chat. Cancel it to continue.")
        default:
            rejectRequest(rpcID, message: "Simul does not support \(method).")
            return
        }
        interactions[id] = Interaction(rpcID: rpcID, method: method, params: params, request: request)
        onEvent?(.request(request))
    }

    private func rejectRequest(_ id: Any, message: String) {
        do { try process.send(["id": id, "error": ["code": -32601, "message": message]]) }
        catch { disconnected(error.localizedDescription) }
        onEvent?(.error(message))
    }

    private func loadModels() async throws {
        let attempt = generation
        var found: [ChatAgentModel] = []
        var defaults: [String: String] = [:]
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc("model/list", params: params)
            guard generation == attempt, state == .ready else { throw ChatAgentError.uncertain("Codex disconnected.") }
            guard let data = result["data"] as? [[String: Any]] else { throw ChatAgentError.rejected("Codex returned an invalid model list.") }
            for item in data {
                guard let id = item["model"] as? String ?? item["id"] as? String, let name = item["displayName"] as? String else { continue }
                let efforts = (item["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                if let value = item["defaultReasoningEffort"] as? String { defaults[id] = value }
                if !found.contains(where: { $0.id == id }) { found.append(ChatAgentModel(id: id, name: name, efforts: efforts)) }
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw ChatAgentError.rejected("Codex repeated a model-list page.") }
        } while cursor != nil
        models = found
        effort = effort ?? defaults[model ?? ""]
        onEvent?(.effortChanged(effort))
        defaultEfforts = defaults
        onEvent?(.models(found))
    }

    private func loadHistory() async throws -> [ChatEntry] {
        guard let threadID else { return [] }
        let attempt = generation
        var entries: [ChatEntry] = []
        var cursor: String?
        var seen: Set<String> = []
        var itemIDs: Set<String> = []
        repeat {
            var params: [String: Any] = ["threadId": threadID, "sortDirection": "asc", "itemsView": "full", "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc("thread/turns/list", params: params)
            guard generation == attempt, state == .starting else { throw ChatAgentError.uncertain("Codex disconnected.") }
            guard let turns = result["data"] as? [[String: Any]] else { throw ChatAgentError.rejected("Codex returned invalid conversation history.") }
            for turn in turns {
                if turn["status"] as? String == "inProgress" { turnID = turn["id"] as? String }
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    guard let id = item["id"] as? String, itemIDs.insert(id).inserted else { continue }
                    switch item["type"] as? String {
                    case "userMessage":
                        let clientID = item["clientId"] as? String
                        let content = item["content"] as? [[String: Any]] ?? []
                        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        let paths = content.filter { $0["type"] as? String == "localImage" }.compactMap { $0["path"] as? String }
                        let images = await Task.detached(priority: .utility) { paths.compactMap { Self.thumbnail(URL(fileURLWithPath: $0)) } }.value
                        guard generation == attempt, state == .starting else { throw ChatAgentError.uncertain("Codex disconnected.") }
                        entries.append(.prompt(id: clientID ?? id, text: text, images: images))
                        if let clientID { onEvent?(.accepted(messageID: clientID)) }
                    case "agentMessage", "plan":
                        entries.append(.reply(id: id, text: item["text"] as? String ?? ""))
                    case "contextCompaction": entries.append(.note(id: id, text: "Conversation compacted"))
                    default:
                        if let tool = Self.tool(item, completed: item["status"] as? String != "inProgress") {
                            tools[id] = tool
                            if case let .tools(groupID, previous)? = entries.last {
                                entries[entries.count - 1] = .tools(id: groupID, previous + [tool])
                            } else { entries.append(.tools(id: id, [tool])) }
                        }
                    }
                }
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw ChatAgentError.rejected("Codex repeated a history page.") }
        } while cursor != nil
        return entries
    }

    private static func tool(_ item: [String: Any], completed: Bool) -> ChatTool? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let status = item["status"] as? String
        let hasStatus = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall"].contains(type)
        let failed = (completed && hasStatus && status != "completed") || item["success"] as? Bool == false
            || item["error"] as? [String: Any] != nil || (item["exitCode"] as? Int).map { $0 != 0 } == true
        let name: String
        let summary: String
        let detail: String
        var output = ""
        switch type {
        case "commandExecution":
            name = "Bash"
            detail = item["command"] as? String ?? ""
            summary = detail.components(separatedBy: .newlines).first ?? ""
            output = item["aggregatedOutput"] as? String ?? ""
        case "fileChange":
            name = "Edit"
            let changes = item["changes"] as? [[String: Any]] ?? []
            summary = changes.compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }.joined(separator: ", ")
            detail = changes.map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }.joined(separator: "\n\n")
        case "mcpToolCall", "dynamicToolCall":
            name = item["tool"] as? String ?? "Tool"
            summary = (item["server"] as? String).map { "\($0) / \(name)" } ?? name
            detail = json(item["arguments"] ?? [:])
            output = json(item["result"] ?? item["contentItems"] ?? item["error"] ?? "")
        case "webSearch":
            name = "WebSearch"
            summary = item["query"] as? String ?? ""
            detail = summary
        case "collabAgentToolCall":
            name = "Agent"
            summary = item["tool"] as? String ?? "Agent"
            detail = item["prompt"] as? String ?? ""
            output = json(item["agentsStates"] ?? [:])
        default: return nil
        }
        return ChatTool(id: id, name: name, summary: summary, detail: detail,
                        result: completed ? output : nil, isError: failed)
    }

    private static func requestID(_ id: Any) -> String? {
        if let text = id as? String { return "codex-string:\(text)" }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue {
            return "codex-number:\(number.stringValue)"
        }
        return nil
    }

    private static func json(_ value: Any) -> String {
        if let text = value as? String { return text }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func thumbnail(_ url: URL) -> Data? {
        guard let image = ClipboardPaste.thumbnail(of: url, maxPixels: 480) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func failPending(_ message: String) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.deadline.cancel()
            request.continuation.resume(throwing: ChatAgentError.uncertain(message))
        }
    }

    private func disconnected(_ message: String) {
        guard state != .closed else { return }
        let active = turnID != nil
        close()
        if active { onEvent?(.finished(outcome: .failed, error: message)) }
        onEvent?(.disconnected(message))
    }
}
