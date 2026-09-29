import Foundation

/// An agent is nothing more than a command. The app never talks to provider
/// APIs, manages authentication, or understands agent protocols.
struct AgentDefinition: Identifiable, Codable, Hashable {
    /// Stable identifier, e.g. "claude".
    let id: String

    var name: String
    var executable: String
    var arguments: [String]
    var environment: [String: String]

    /// Arguments appended when the user opts into "skip permission prompts".
    var dangerousArguments: [String]

    init(
        id: String,
        name: String,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        dangerousArguments: [String] = []
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.dangerousArguments = dangerousArguments
    }
}

extension AgentDefinition {
    /// Initial built-ins. Everything here must also work in a plain terminal.
    static let builtIns: [AgentDefinition] = [
        AgentDefinition(
            id: "claude", name: "Claude", executable: "claude",
            dangerousArguments: ["--dangerously-skip-permissions"]
        ),
        AgentDefinition(
            id: "codex", name: "Codex", executable: "codex",
            dangerousArguments: ["--dangerously-bypass-approvals-and-sandbox"]
        ),
        AgentDefinition(
            id: "opencode", name: "OpenCode / Z.ai", executable: "opencode",
            dangerousArguments: ["--dangerously-skip-permissions"]
        ),
        AgentDefinition(id: "shell", name: "Shell", executable: "shell"),
    ]

    /// The shell "agent" resolves to the user's login shell.
    static let shellID = "shell"

    var isShell: Bool { id == Self.shellID }
}
