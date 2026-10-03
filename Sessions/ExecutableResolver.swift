import Foundation

/// Resolves commands (tmux, claude, codex, ...) that GUI apps cannot see
/// because they do not inherit the interactive shell environment.
///
/// Strategy:
///   1. Ask the user's login shell (interactive) where the command lives.
///   2. Fall back to common installation directories.
///   3. Cache results; allow explicit refresh.
///
/// Main-actor isolated: the cache is shared by every launch. The shell
/// probes themselves run off-main in ProcessRunner.
@MainActor
final class ExecutableResolver {
    var cache: [String: String?] = [:]
    private(set) var shellPathEnvironment: [String: String] = [:]
    private(set) var tmuxPath: String?

    init(tmuxOverride: String? = nil) {
        self.tmuxPath = tmuxOverride
        // tmux must be present; resolved lazily at bootstrap for real usage.
    }

    var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Where the resolved PATH for sessions comes from.
    static let commonDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.cargo/bin",
    ]

    /// Resolves a command name to an absolute path, or nil.
    func resolve(command: String) async -> String? {
        if let cached = cache[String.key(command)] {
            return cached
        }
        let resolved = await uncachedResolve(command: command)
        cache[String.key(command)] = resolved
        return resolved
    }

    /// Resolves tmux specifically and captures the login-shell environment
    /// (PATH & friends) used for new tmux sessions. Safe to call repeatedly;
    /// only refreshes when asked.
    func bootstrap(refresh: Bool = false) async {
        if refresh {
            cache.removeAll()
            shellPathEnvironment = [:]
        }
        if tmuxPath == nil {
            tmuxPath = await resolve(command: "tmux")
        }
        if shellPathEnvironment.isEmpty {
            shellPathEnvironment = await captureShellEnvironment()
        }
    }

    // MARK: - Internals

    private func uncachedResolve(command: String) async -> String? {
        // Interactive login shell first (covers nvm/mise/asdf PATHs from rc files),
        // plain login shell second.
        for interactive in [true, false] {
            if let path = await shellLookup(command: command, interactive: interactive) {
                return path
            }
        }
        // Common installation directories.
        let fileManager = FileManager.default
        for dir in Self.commonDirectories {
            let candidate = dir + "/" + command
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func shellLookup(command: String, interactive: Bool) async -> String? {
        var args = ["-l"]
        if interactive { args.append("-i") }
        args.append(contentsOf: ["-c", "command -v \(shellQuoted(command))"])
        let result = await ProcessRunner.run(
            userShell,
            arguments: args,
            environment: ["TMUX": "1"] // suppress auto-tmux logic in shell rc files
        )
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    /// Captures the interactive login shell environment and keeps the subset
    /// that matters for agents (PATH above all).
    private func captureShellEnvironment() async -> [String: String] {
        let allowlist: Set<String> = [
            "PATH", "EDITOR", "VISUAL", "LANG", "LC_ALL", "LC_CTYPE",
            "PAGER", "MANPAGER", "HOMEBREW_PREFIX",
        ]
        let result = await ProcessRunner.run(
            userShell,
            arguments: ["-l", "-i", "-c", "env"],
            environment: ["TMUX": "1"] // suppress auto-tmux logic in shell rc files
        )
        guard result.exitCode == 0 else { return [:] }
        var env: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            guard allowlist.contains(key) else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        return env
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    static func key(_ command: String) -> String { "cmd:\(command)" }
}
