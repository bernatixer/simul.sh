import Foundation

/// Asks the agents themselves for fresh plan limits, so Simul never reads
/// or stores their credentials.
enum UsageRefresher {
    /// Runs Claude's own `/usage`, which refreshes the cache in
    /// `~/.claude.json` that the sidebar watches. Safe mode skips plugins,
    /// hooks and MCP servers; nothing is written to the session history.
    /// Claude throttles its own fetches, so a run can be a no-op.
    static func refreshClaude(executable: String, environment: [String: String]) async {
        _ = await run(
            executable,
            arguments: ["-p", "--safe-mode", "--no-session-persistence", "/usage"],
            environment: environment,
            input: nil,
            until: { _ in false },
            timeout: 30)
    }

    /// Reads live limits from Codex's app server (JSON-RPC over stdio):
    /// initialize → initialized → `account/rateLimits/read`.
    static func codex(executable: String, environment: [String: String]) async -> AgentUsage? {
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "simul", "title": "Simul", "version": "0.1.0"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
        ]
        let input = requests
            .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) + "\n" }
            .joined()
        let response = await run(
            executable, arguments: ["app-server"], environment: environment,
            input: Data(input.utf8),
            until: { line in line.contains(#""id":2"#) },
            timeout: 15)
        guard let line = response,
              let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let result = message["result"] as? [String: Any] else { return nil }
        return UsageLimits.codexAppServer(result: result, fetchedAt: Date())
    }

    /// Runs a process off the main actor, feeding `input`, and returns the
    /// first stdout line matching `until` (stopping the process there), or
    /// nil at exit. Killed after `timeout` so a stuck CLI can't pile up.
    private static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        input: Data?,
        until match: @escaping @Sendable (String) -> Bool,
        timeout: TimeInterval
    ) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            process.environment = env
            // No input → /dev/null, not an open pipe: `claude -p` reads a
            // piped stdin and would otherwise wait for EOF.
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }

            let running = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if running.isRunning { running.terminate() }
            }
            if let input { stdin.fileHandleForWriting.write(input) }

            var buffer = Data()
            let reader = stdout.fileHandleForReading
            while true {
                let chunk = reader.availableData // blocks; empty at EOF / after terminate
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    if match(line) {
                        process.terminate()
                        return line
                    }
                }
            }
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return nil
        }.value
    }
}
