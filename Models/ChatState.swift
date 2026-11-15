import Foundation

struct ComposerImage: Codable, Equatable, Sendable, Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}

enum ComposerPart: Codable, Equatable, Sendable {
    case text(String)
    case image(ComposerImage)

    static func normalized(_ parts: [ComposerPart]) -> [ComposerPart] {
        parts.reduce(into: []) { result, part in
            if case let .text(next) = part, case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else if part != .text("") { result.append(part) }
        }
    }

    static func pieces(_ parts: [ComposerPart]) -> [PromptPiece] {
        var pieces = parts.map { part -> PromptPiece in
            switch part {
            case let .text(text): .text(text)
            case let .image(image): .image(image.url)
            }
        }
        if case let .text(text)? = pieces.first { pieces[0] = .text(String(text.drop(while: \.isWhitespace))) }
        if case let .text(text)? = pieces.last {
            pieces[pieces.count - 1] = .text(String(text.reversed().drop(while: \.isWhitespace).reversed()))
        }
        return pieces.filter { $0 != .text("") }
    }
}

struct ChatPendingMessage: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case queued, sending, uncertain, failed }
    var message: ChatOutgoingMessage
    var status: Status = .queued
    var error: String?
    var id: String { message.id }
}

struct ChatState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case disconnected, connecting, idle, sending, working, waiting, stopping, failed
    }
    var conversationID: String?
    var conversation = ChatConversation()
    var draft: [ComposerPart] = []
    var outbox: [ChatPendingMessage] = []
    var attachments: [String: [URL]] = [:]
    var phase: Phase = .idle
    var queuePaused = false
    var requests: [ChatAgentRequest] = []
    var models: [ChatAgentModel] = []
    var selectedModel: String?
    var effort: String?
    var conversationTitle: String?
    var notice: String?
    var expanded: Set<String> = []
    var readingAnchor: String?
    var followsLatest = true

    var isBusy: Bool { [.sending, .working, .waiting, .stopping].contains(phase) }

    var modelLabel: String? {
        guard let id = selectedModel ?? conversation.model, !id.isEmpty else { return nil }
        let model = models.first { $0.id == id }
        let resolved = model?.resolvedID ?? id
        guard resolved != "default" else { return nil }
        if let name = ChatTranscript.modelName(resolved) { return name }
        return model?.resolvedID == nil ? model?.name ?? resolved : resolved
    }

    mutating func recover() {
        let interrupted = isBusy
        for index in outbox.indices where outbox[index].status == .sending {
            outbox[index].status = .uncertain
            outbox[index].error = "Simul closed before the agent acknowledged this message. Reconnect to check its history."
        }
        if interrupted || !outbox.isEmpty { queuePaused = true }
        requests = []
        phase = .disconnected
        conversation.turnOpen = false
    }

    @discardableResult
    mutating func enqueueDraft() -> ChatOutgoingMessage? {
        let pieces = ComposerPart.pieces(draft)
        guard !pieces.isEmpty else { return nil }
        let message = ChatOutgoingMessage(pieces: pieces)
        outbox.append(ChatPendingMessage(message: message))
        draft = []
        return message
    }

    mutating func beginNext() -> ChatOutgoingMessage? {
        guard phase == .idle, !queuePaused, outbox.first?.status == .queued else { return nil }
        outbox[0].status = .sending
        phase = .sending
        return outbox[0].message
    }

    mutating func accept(_ id: String) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        let message = outbox.remove(at: index).message
        let text = message.pieces.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined()
        let images = message.pieces.compactMap { if case let .image(url) = $0 { url } else { nil } }
        if !images.isEmpty { attachments[id] = images }
        if !conversation.entries.contains(where: { $0.id == id }) {
            conversation.entries.append(.prompt(id: id, text: text))
            conversation.prompts += 1
            conversation.revision += 1
        }
        if phase == .sending { phase = .working }
    }

    mutating func deliveryFailed(_ id: String, message: String, uncertain: Bool) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].status = uncertain ? .uncertain : .failed
        outbox[index].error = message
        queuePaused = true
        phase = .failed
    }

    mutating func apply(_ event: ChatAgentEvent) {
        switch event {
        case let .ready(id, model):
            conversationID = id
            if let model { selectedModel = model; conversation.model = model }
            if [.connecting, .disconnected, .failed].contains(phase) { phase = .idle }
        case let .accepted(id): accept(id)
        case let .text(id, delta):
            if let index = conversation.entries.firstIndex(where: { $0.id == id }),
               case let .reply(_, text) = conversation.entries[index] {
                conversation.entries[index] = .reply(id: id, text: text + delta)
            } else { conversation.entries.append(.reply(id: id, text: delta)) }
            conversation.revision += 1
        case let .reply(id, text):
            let entry = ChatEntry.reply(id: id, text: text)
            if let index = conversation.entries.firstIndex(where: { $0.id == id }) {
                if conversation.entries[index] != entry { conversation.entries[index] = entry; conversation.revision += 1 }
            } else { conversation.entries.append(entry); conversation.revision += 1 }
        case let .tool(tool):
            for index in conversation.entries.indices {
                if case let .tools(id, tools) = conversation.entries[index], let at = tools.firstIndex(where: { $0.id == tool.id }) {
                    if tools[at] != tool {
                        var fresh = tools; fresh[at] = tool
                        conversation.entries[index] = .tools(id: id, fresh)
                        conversation.revision += 1
                    }
                    return
                }
            }
            if case let .tools(id, tools)? = conversation.entries.last {
                conversation.entries[conversation.entries.count - 1] = .tools(id: id, tools + [tool])
            } else { conversation.entries.append(.tools(id: tool.id, [tool])) }
            conversation.revision += 1
        case let .history(entries):
            if conversation.entries != entries {
                conversation.entries = entries
                conversation.prompts = entries.filter { if case .prompt = $0 { true } else { false } }.count
                conversation.revision += 1
            }
            let accepted = Set(entries.compactMap { if case let .prompt(id, _, _) = $0 { id } else { nil } })
            for pending in outbox where accepted.contains(pending.id) { accept(pending.id) }
        case .started:
            if phase != .waiting { phase = .working }
            conversation.turnOpen = true
        case let .finished(outcome, error):
            phase = outcome == .failed ? .failed : .idle
            conversation.turnOpen = false
            requests.removeAll { $0.isBlocking }
            if outcome != .completed { queuePaused = true }
            if let error { notice = error }
        case let .request(request):
            if !requests.contains(where: { $0.id == request.id }) { requests.append(request) }
            if request.isBlocking { phase = .waiting }
        case let .requestResolved(id):
            requests.removeAll { $0.id == id }
            if !requests.contains(where: \.isBlocking), phase == .waiting { phase = .working }
        case let .models(models): if self.models != models { self.models = models }
        case let .modelChanged(model):
            if selectedModel != model { selectedModel = model; conversation.model = model }
        case let .effortChanged(effort): if self.effort != effort { self.effort = effort }
        case let .titleChanged(title): if conversationTitle != title { conversationTitle = title }
        case let .error(error): notice = error
        case let .disconnected(error): recover(); notice = error
        }
    }
}
