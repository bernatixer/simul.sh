import Foundation

/// Direct-PTY backend: the terminal surface spawns the agent process itself.
///
/// Fastest path — no attach clients, no relay hop for input/resize, and the
/// terminal is the process (no Start/Attach placeholder dance). Tradeoff:
/// agent processes live and die with the app; conversations stay in the
/// agents' own storage (e.g. `claude --continue`, `codex resume`).
///
/// `TmuxSessionBackend` remains available for an opt-in later.
@MainActor
final class DirectSessionBackend: SessionBackend {
    private let resolver: ExecutableResolver

    /// Resolved agent executables, populated by create().
    private var resolved: [String: String] = [:]

    init(resolver: ExecutableResolver) {
        self.resolver = resolver
    }

    // MARK: - SessionBackend

    var processesOutliveApp: Bool { false }

    /// Nothing exists out-of-band: the process comes with its surface.
    func exists(_ session: Session) async throws -> Bool {
        false
    }

    /// Resolves the agent executable so `attachCommand` is synchronous.
    func create(_ session: Session, agent: AgentDefinition, conversation: Conversation) async throws {
        await resolver.bootstrap()
        if agent.isShell {
            resolved[agent.id] = resolver.userShell
            return
        }
        guard let path = await resolver.resolve(command: agent.executable) else {
            throw SessionBackendError.missingExecutable(
                command: agent.executable,
                reason: "Check that it is installed and visible in your shell (\(resolver.userShell) -lic 'command -v \(agent.executable)')."
            )
        }
        resolved[agent.id] = path
    }

    /// Stopping happens by closing the surface (which closes the PTY).
    func stop(_ session: Session) async throws {}

    /// Running state is derived from live surfaces, not from this backend.
    func listRunningIDs() async throws -> Set<UUID> {
        []
    }

    /// Uses the agent as given (with the user's extra arguments), not the
    /// built-in definition.
    func attachCommand(for session: Session, agent: AgentDefinition, conversation: Conversation) throws -> ProcessSpec {
        var env = resolver.shellPathEnvironment
        if env["PATH"] == nil {
            env["PATH"] = ProcessInfo.processInfo.environment["PATH"]
        }
        for (key, value) in agent.environment {
            env[key] = value
        }
        let executable = resolved[agent.id] ?? agent.executable
        // The terminal host runs a single shell command string.
        let command = ([executable] + agent.launchArguments(
            skippingPermissions: session.skipPermissions,
            conversation: conversation
        ))
            .map { shellQuote($0) }
            .joined(separator: " ")
        return ProcessSpec(
            command: command,
            arguments: [],
            environment: env,
            workingDirectory: session.workingDirectory
        )
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
