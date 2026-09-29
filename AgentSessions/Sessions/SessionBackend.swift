import Foundation

/// A program to run inside a terminal surface, plus the environment it
/// should see. The terminal host owns the PTY; this is just a description.
struct ProcessSpec: Equatable {
    var command: String
    var arguments: [String]
    var environment: [String: String] = [:]
    var workingDirectory: String? = nil
}

/// The complete contract between the app and the process backend.
/// Nothing outside `Sessions/` may know tmux command syntax.
protocol SessionBackend {
    /// Whether the backing terminal process for the session exists.
    func exists(_ session: Session) async throws -> Bool

    /// Starts the backing terminal for the session (detached from any UI).
    /// Throws `SessionBackendError.missingExecutable` with details when the
    /// agent command cannot be resolved.
    func create(_ session: Session, agent: AgentDefinition) async throws

    /// Terminates the backing terminal. Metadata is unaffected.
    func stop(_ session: Session) async throws

    /// The set of session IDs that currently have a live backing process.
    func listRunningIDs() async throws -> Set<UUID>

    /// The command a terminal surface should run to attach to the session.
    func attachCommand(for session: Session) throws -> ProcessSpec
}

enum SessionBackendError: LocalizedError {
    case missingExecutable(command: String, reason: String)
    case launchFailed(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .missingExecutable(command, reason):
            return "Cannot find “\(command)”. \(reason)"
        case let .launchFailed(command, exitCode, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Failed to start “\(command)” (exit \(exitCode)).\(detail.isEmpty ? "" : " " + detail)"
        }
    }
}

// MARK: - Small process helpers

enum ProcessRunner {
    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs a short-lived command. tmux control commands are the only users.
    static func run(
        _ command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async -> Result {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            if let environment {
                var env = ProcessInfo.processInfo.environment
                environment.forEach { env[$0.key] = $0.value }
                process.environment = env
            }
            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return Result(exitCode: 127, stdout: "", stderr: String(describing: error))
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return Result(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
