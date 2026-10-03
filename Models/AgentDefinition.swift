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

    /// How a relaunched session gets back to its own conversation.
    var resume: ResumeStrategy

    /// Terminal title the agent shows while working, for agents without
    /// OSC 9;4 progress reports. Any other title means idle.
    var busyTitle: String?

    init(
        id: String,
        name: String,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        dangerousArguments: [String] = [],
        resume: ResumeStrategy = .none,
        busyTitle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.dangerousArguments = dangerousArguments
        self.resume = resume
        self.busyTitle = busyTitle
    }
}

extension AgentDefinition {
    /// Initial built-ins. Everything here must also work in a plain terminal.
    static let builtIns: [AgentDefinition] = [
        AgentDefinition(
            id: "claude", name: "Claude", executable: "claude",
            dangerousArguments: ["--dangerously-skip-permissions"],
            resume: .claude
        ),
        AgentDefinition(
            id: "codex", name: "Codex", executable: "codex",
            // Codex has no OSC 9;4 progress. Have it put its run state in the
            // terminal title ("Working" / "Ready") and send OSC 9 at the end
            // of a turn, so the sidebar shows working/finished like Claude.
            // Overrides the user's own [tui] title/notification config here.
            arguments: [
                "-c", #"tui.terminal_title=["run-state"]"#,
                "-c", "tui.notifications=true",
                "-c", #"tui.notification_method="osc9""#,
                "-c", #"tui.notification_condition="always""#,
            ],
            dangerousArguments: ["--dangerously-bypass-approvals-and-sandbox"],
            resume: .codex,
            busyTitle: "Working"
        ),
        AgentDefinition(
            id: "opencode", name: "OpenCode / Z.ai", executable: "opencode",
            // No resume: OpenCode has no way to pin a session ID we can
            // discover, and "continue the latest" can open the wrong one.
            dangerousArguments: ["--dangerously-skip-permissions"]
        ),
        AgentDefinition(id: "shell", name: "Shell", executable: "shell"),
    ]

    /// The shell "agent" resolves to the user's login shell.
    static let shellID = "shell"

    var isShell: Bool { id == Self.shellID }

    /// Full argument list for launching this agent. Danger flags come
    /// before resume subcommands (e.g. `codex --flag resume <id>`).
    func launchArguments(skippingPermissions: Bool, conversation: Conversation = .none) -> [String] {
        var args = arguments
        if skippingPermissions {
            args += dangerousArguments
        }
        switch (resume, conversation) {
        case let (.claude, .start(id)): args += ["--session-id", id]
        case let (.claude, .resume(id)): args += ["--resume", id]
        case let (.codex, .resume(id)): args += ["resume", id]
        default: break
        }
        return args
    }
}

enum ResumeStrategy: String, Codable, Hashable {
    /// Always starts fresh.
    case none
    /// We pick the ID: `--session-id <id>` first, `--resume <id>` after.
    case claude
    /// Codex picks the ID; we find it later and `resume <id>`.
    case codex
}

/// Which agent conversation a launch should attach to.
enum Conversation: Equatable {
    case none
    /// Start a new conversation under this ID.
    case start(String)
    /// Resume this existing conversation.
    case resume(String)
}
