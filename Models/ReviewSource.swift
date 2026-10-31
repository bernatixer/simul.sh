import Foundation

/// What a review looks at. Each source keeps its own base, viewed marks and comments.
enum ReviewSource: Hashable, Codable, Sendable {
    /// The session's workingDirectory.
    case sessionFolder
    /// An absolute path: another worktree or a chosen folder.
    case folder(String)
    /// repo = "owner/name".
    case pullRequest(repo: String, number: Int)

    /// Key of this source's state in `ReviewState.sources`.
    var key: String {
        switch self {
        case .sessionFolder: "session"
        case let .folder(path): "folder:\(path)"
        case let .pullRequest(repo, number): "pr:\(repo)#\(number)"
        }
    }
}

extension ReviewSource {
    /// Where to review: the worktree the agent is working in when that isn't
    /// the session folder's own, else the session folder.
    static func preferred(sessionFolder: String, agentCwd: String?, worktrees: [Worktree]) -> ReviewSource {
        guard let agentCwd, let agent = containing(agentCwd, in: worktrees),
              agent.path != containing(sessionFolder, in: worktrees)?.path else { return .sessionFolder }
        return .folder(agent.path)
    }

    /// What the agent prompt calls it: "PR #123", "the <branch> worktree" or the folder's name.
    func promptName(worktrees: [Worktree]) -> String {
        switch self {
        case .sessionFolder: return "your changes"
        case let .pullRequest(_, number): return "PR #\(number)"
        case let .folder(path):
            let target = Self.resolved(path)
            if let branch = worktrees.first(where: { Self.resolved($0.path) == target })?.branch { return "the \(branch) worktree" }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// The deepest worktree that is `path` or an ancestor of it (by path components).
    static func containing(_ path: String, in worktrees: [Worktree]) -> Worktree? {
        let target = resolved(path)
        return worktrees
            .filter { let root = resolved($0.path); return target.starts(with: root) }
            .max { resolved($0.path).count < resolved($1.path).count }
    }

    private static func resolved(_ path: String) -> [String] {
        // realpath resolves /var → /private/var; a path that is gone just stays as written.
        let standard = URL(fileURLWithPath: path).standardized.path
        return URL(fileURLWithPath: realpath(standard, nil).map { defer { free($0) }; return String(cString: $0) } ?? standard).pathComponents
    }
}
