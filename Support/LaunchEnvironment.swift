import Foundation

/// Makes the app's environment the same however it was launched.
///
/// Launched from the Dock, the app gets launchd's minimal environment.
/// Launched from a terminal (or from inside another agent) it inherits that
/// parent's variables — e.g. `CLAUDE_CODE_SESSION_ID` /
/// `CLAUDE_CODE_CHILD_SESSION`, which make every Claude started here think
/// it is a nested child (transcript saving off, wrong session). Agents get
/// their real environment from the login shell instead (ExecutableResolver).
enum LaunchEnvironment {
    /// What launchd gives a GUI app.
    static let baseline: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG",
        "SSH_AUTH_SOCK", "COMMAND_MODE", "XPC_FLAGS", "XPC_SERVICE_NAME",
        "__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier", "SECURITYSESSIONID", "LaunchInstanceID",
    ]

    static func shouldKeep(_ key: String) -> Bool {
        baseline.contains(key) || key.hasPrefix("LC_")
    }

    /// Call once at startup, before anything spawns processes.
    static func scrub() {
        for key in ProcessInfo.processInfo.environment.keys where !shouldKeep(key) {
            unsetenv(key)
        }
    }
}
