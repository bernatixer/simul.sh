import Foundation

struct ChatAgentConfiguration: Sendable {
    var executable: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var workingDirectory: String
    var conversationID: String?
    var sessionID: UUID
    var skipPermissions = false
    var model: String?
    var effort: String?
}

struct ChatOutgoingMessage: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var pieces: [PromptPiece]
}

struct ChatAgentChoice: Codable, Equatable, Sendable, Identifiable {
    var label: String
    var description: String = ""
    var id: String { label }
}

struct ChatAgentQuestion: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var prompt: String
    var options: [ChatAgentChoice] = []
    var allowsMultiple = false
    var isSecret = false
}

struct ChatAgentRequest: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String = ""
    var questions: [ChatAgentQuestion] = []
    var allowsSessionApproval = false
    var isBlocking = true
}

enum ChatAgentDecision: String, Codable, Sendable {
    case allow, allowSession, deny, cancel
}

struct ChatAgentModel: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var efforts: [String] = []
    var resolvedID: String? = nil
}

enum ChatTurnOutcome: String, Codable, Sendable {
    case completed, interrupted, failed
}

enum ChatAgentError: LocalizedError, Sendable {
    case rejected(String)
    case uncertain(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message), let .uncertain(message): return message
        }
    }
}

enum ChatAgentEvent: Sendable {
    case ready(conversationID: String, model: String?)
    case accepted(messageID: String)
    case text(id: String, delta: String)
    case reply(id: String, text: String)
    case tool(ChatTool)
    case history([ChatEntry])
    case started
    case finished(outcome: ChatTurnOutcome, error: String?)
    case request(ChatAgentRequest)
    case requestResolved(id: String)
    case models([ChatAgentModel])
    case modelChanged(String)
    case effortChanged(String?)
    case titleChanged(String)
    case disconnected(String)
    case error(String)
}

@MainActor
protocol ChatAgentClient: AnyObject {
    var processID: Int32? { get }
    var onEvent: ((ChatAgentEvent) -> Void)? { get set }
    func start(_ configuration: ChatAgentConfiguration) async throws
    func send(_ message: ChatOutgoingMessage) async throws
    func setOptions(model: String?, effort: String?) async throws
    func respond(to requestID: String, decision: ChatAgentDecision, answers: [String: [String]]) throws
    func interrupt()
    func close()
}
