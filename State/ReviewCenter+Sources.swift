import Foundation

/// Choosing what the review looks at: the session folder, another worktree
/// or folder, or a pull request checked out in a worktree.
extension ReviewCenter {
    /// Where a source's files are and what to compare them against.
    struct ResolvedSource {
        let folder: String
        /// nil = automatic.
        let base: String?
        /// What the prompt calls it; nil when it is the session folder.
        let name: String?
        let pullRequest: PullRequest?
    }

    /// The user's choice; it stays until they choose again.
    func setSource(_ id: Session.ID, _ source: ReviewSource) {
        if !ReviewState.isCurrent(states[id], source) { sourceChanged(id) }
        update(id) {
            $0.source = source
            $0.sourceChosen = true
        }
        refreshOpen(id)
    }

    // MARK: - Picker (only while the review shows)

    func worktrees(for id: Session.ID) async -> [Worktree] {
        guard let (git, root) = try? await picker(id) else { return [] }
        return await git.worktrees(root: root)
    }

    func pullRequests(for id: Session.ID) async throws -> [PullRequest] {
        let (git, root) = try await picker(id)
        return try await git.pullRequests(root: root)
    }

    func pullRequest(_ input: String, for id: Session.ID) async throws -> PullRequest {
        let (git, root) = try await picker(id)
        return try await git.pullRequest(input, root: root)
    }

    func removeSimulWorktree(_ path: String, for id: Session.ID, force: Bool = false) async throws {
        let (git, root) = try await picker(id)
        try await git.removeSimulWorktree(path, root: root, worktreesDir: Paths.reviewWorktrees, force: force)
    }

    // MARK: - Loading

    /// On opening, until the user has chosen a source: the worktree a Claude
    /// agent is working in, when it isn't the session folder's own.
    func followAgent(_ session: Session) async {
        guard states[session.id]?.sourceChosen != true, let transcript = transcriptID(session),
              let git = await makeGit() else { return }
        let folder = session.workingDirectory
        let picked = await Task.detached(priority: .utility) { () async -> ReviewSource? in
            guard let cwd = AgentConversations.claudeCwd(id: transcript) else { return nil }
            return ReviewSource.preferred(sessionFolder: folder, agentCwd: cwd, worktrees: await git.worktrees(root: folder))
        }.value
        guard let picked, states[session.id]?.sourceChosen != true else { return }  // chosen meanwhile
        if !ReviewState.isCurrent(states[session.id], picked) { sourceChanged(session.id) }
        update(session.id) { $0.source = picked }
    }

    /// A pull request is looked up and its worktree prepared (fetching) on every load.
    func resolve(_ source: ReviewSource, _ session: Session, _ git: ReviewGit) async throws -> ResolvedSource {
        let home = session.workingDirectory
        switch source {
        case .sessionFolder:
            return ResolvedSource(folder: home, base: nil, name: nil, pullRequest: nil)
        case let .folder(path):
            let name = path == home ? nil : source.promptName(worktrees: await git.worktrees(root: path))
            return ResolvedSource(folder: path, base: nil, name: name, pullRequest: nil)
        case let .pullRequest(repo, number):
            // ponytail: github.com only; GitHub Enterprise needs the host kept in the source.
            let pr = try await git.pullRequest("https://github.com/\(repo)/pull/\(number)", root: home)
            let (folder, remote) = try await git.prepare(pr, root: home, worktreesDir: Paths.reviewWorktrees)
            return ResolvedSource(folder: folder, base: "\(remote)/\(pr.baseRef)",
                                  name: folder == home ? nil : source.promptName(worktrees: []), pullRequest: pr)
        }
    }

    /// git and the session folder for the picker's calls; throws unless the review shows.
    private func picker(_ id: Session.ID) async throws -> (ReviewGit, String) {
        guard isShowing(id), let session = openSession, session.id == id else { throw ReviewGitError.gitFailed("The review isn't open") }
        guard let git = await makeGit() else { throw ReviewGitError.gitFailed("git not found") }
        return (git, session.workingDirectory)
    }
}
