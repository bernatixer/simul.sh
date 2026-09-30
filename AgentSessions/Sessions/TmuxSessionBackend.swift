import Foundation

/// tmux-backed session backend.
///
/// tmux owns long-lived terminal processes; the app only creates, stops,
/// detects, and attaches. All tmux syntax lives in this file.
final class TmuxSessionBackend: SessionBackend {
    private let resolver: ExecutableResolver

    init(resolver: ExecutableResolver) {
        self.resolver = resolver
    }

    /// Stable, sanitized tmux session name derived from the session UUID —
    /// never the human title.
    static func tmuxName(for session: Session) -> String {
        "as-" + session.id.uuidString.lowercased()
    }

    static func sessionID(fromTmuxName name: String) -> UUID? {
        guard name.hasPrefix("as-") else { return nil }
        return UUID(uuidString: String(name.dropFirst(3)))
    }

    // MARK: - SessionBackend

    func exists(_ session: Session) async throws -> Bool {
        let name = Self.tmuxName(for: session)
        guard let tmux = await tmux() else { return false }
        let result = await ProcessRunner.run(tmux, arguments: ["has-session", "-t", name])
        return result.exitCode == 0
    }

    func create(_ session: Session, agent: AgentDefinition) async throws {
        guard let tmux = await tmux() else {
            throw SessionBackendError.missingExecutable(
                command: "tmux",
                reason: "tmux is not installed or not in the login shell PATH."
            )
        }

        let env = await environment(for: agent)
        let name = Self.tmuxName(for: session)
        var arguments = ["new-session", "-d", "-s", name, "-c", session.workingDirectory]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            arguments += ["-e", "\(key)=\(value)"]
        }

        // The shell agent runs the user's login shell directly; real agents
        // exec their resolved absolute path.
        if agent.isShell {
            arguments += ["--", resolver.userShell]
        } else {
            guard let executable = await resolver.resolve(command: agent.executable) else {
                throw SessionBackendError.missingExecutable(
                    command: agent.executable,
                    reason: "Check that it is installed and visible in your shell (\(resolver.userShell) -lic 'command -v \(agent.executable)')."
                )
            }
            arguments += ["--", executable] + Self.launchArguments(for: session, agent: agent)
        }

        let result = await ProcessRunner.run(tmux, arguments: arguments)
        guard result.exitCode == 0 else {
            throw SessionBackendError.launchFailed(
                command: agent.executable,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    func stop(_ session: Session) async throws {
        let name = Self.tmuxName(for: session)
        guard let tmux = await tmux() else { return }
        _ = await ProcessRunner.run(tmux, arguments: ["kill-session", "-t", name])
    }

    func listRunningIDs() async throws -> Set<UUID> {
        guard let tmux = await tmux() else { return [] }
        let result = await ProcessRunner.run(tmux, arguments: ["list-sessions", "-F", "#{session_name}"])
        guard result.exitCode == 0 else { return [] } // no server running
        var ids = Set<UUID>()
        for line in result.stdout.split(separator: "\n") {
            if let id = Self.sessionID(fromTmuxName: String(line)) {
                ids.insert(id)
            }
        }
        return ids
    }

    func attachCommand(for session: Session) throws -> ProcessSpec {
        guard let tmux = tmuxPathSync() else {
            throw SessionBackendError.missingExecutable(
                command: "tmux",
                reason: "tmux is not installed or not in the login shell PATH."
            )
        }
        let name = Self.tmuxName(for: session)
        var env = resolver.shellPathEnvironment
        // The terminal host executes a single command string (as a shell
        // command), so build it with explicit quoting.
        let command = [tmux, "attach-session", "-t", name]
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

    /// Pure function so the exact argv a session starts with is unit-testable.
    static func launchArguments(for session: Session, agent: AgentDefinition) -> [String] {
        agent.launchArguments(skippingPermissions: session.skipPermissions)
    }

    // MARK: - Internals

    private func tmuxPathSync() -> String? {
        // Fast path for callers on the main actor: bootstrap() has normally
        // run already; fall back to common locations if not.
        if let path = resolver.tmuxPath { return path }
        return ExecutableResolver.commonDirectories
            .map { $0 + "/tmux" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func tmux() async -> String? {
        await resolver.bootstrap()
        return resolver.tmuxPath
    }

    /// Environment for a new tmux session: the resolved login-shell PATH so
    /// agent subprocesses (git, gh, ...) behave like in a terminal.
    private func environment(for agent: AgentDefinition) async -> [String: String] {
        var env = resolver.shellPathEnvironment
        if env["PATH"] == nil {
            env["PATH"] = ProcessInfo.processInfo.environment["PATH"]
        }
        for (key, value) in agent.environment {
            env[key] = value
        }
        return env
    }
}
