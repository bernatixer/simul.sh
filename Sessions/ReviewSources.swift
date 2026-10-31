import Foundation

struct Worktree: Equatable, Sendable {
    let path: String
    let branch: String?   // short name; nil when detached
    let head: String
    let isMain: Bool

    /// Parses `git worktree list --porcelain -z`: NUL-terminated fields, an empty field ends a record.
    static func parse(porcelainZ text: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?, branch: String?, head = "", bare = false
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let path, !bare { result.append(Worktree(path: path, branch: branch, head: head, isMain: result.isEmpty)) }
                (path, branch, head, bare) = (nil, nil, "", false)
            } else if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            else if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") {
                let ref = field.dropFirst(7)
                branch = String(ref.hasPrefix("refs/heads/") ? ref.dropFirst(11) : ref)
            } else if field == "bare" { bare = true }
        }
        return result
    }
}

struct PullRequest: Equatable, Sendable, Identifiable {
    let number: Int
    let title: String
    let author: String
    let headRef: String
    let baseRef: String
    let headSHA: String
    let baseRepo: String   // "owner/name", from the URL (gh has no baseRepository field)
    let url: String
    let isCrossRepository: Bool   // head branch lives in a fork
    var id: Int { number }

    static let ghFields = "number,title,author,headRefName,baseRefName,headRefOid,url,isCrossRepository"

    private struct GH: Decodable {
        struct Author: Decodable { let login: String }
        let number: Int, title: String, author: Author?
        let headRefName: String, baseRefName: String, headRefOid: String, url: String, isCrossRepository: Bool?
    }

    static func decode(ghJSON: Data) throws -> PullRequest { try make(decoding(GH.self, ghJSON)) }
    static func decodeList(ghJSON: Data) throws -> [PullRequest] { try decoding([GH].self, ghJSON).map(make) }

    private static func decoding<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ReviewGitError.gitFailed("Unexpected output from gh: \(error.localizedDescription)") }
    }

    private static func make(_ g: GH) throws -> PullRequest {
        // https://github.com/<owner>/<name>/pull/<n>
        let parts = (URL(string: g.url)?.path ?? "").split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull" else { throw ReviewGitError.gitFailed("unexpected PR URL: \(g.url)") }
        return PullRequest(number: g.number, title: g.title, author: g.author?.login ?? "", headRef: g.headRefName,
                           baseRef: g.baseRefName, headSHA: g.headRefOid, baseRepo: "\(parts[0])/\(parts[1])", url: g.url,
                           isCrossRepository: g.isCrossRepository ?? false)
    }

    /// The PR number in "123", "#123" or a …/pull/123 URL; nil for anything else.
    static func number(from input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme == "https" || url.scheme == "http" {
            let parts = url.path.split(separator: "/")
            guard let i = parts.firstIndex(of: "pull"), i == 2, i + 1 < parts.count else { return nil }
            return positive(parts[i + 1])
        }
        return positive(text.hasPrefix("#") ? text.dropFirst() : Substring(text))
    }

    private static func positive(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let n = Int(s), n > 0 else { return nil }
        return n
    }
}

extension ReviewGit {
    static let ghUnavailable = "Install and log in to the GitHub CLI (gh) to review pull requests"

    func worktrees(root: String) async -> [Worktree] {
        let r = await run(["worktree", "list", "--porcelain", "-z"], in: root)
        return r.exitCode == 0 ? Worktree.parse(porcelainZ: r.stdout) : []
    }

    /// owner/name of origin.
    func repoSlug(root: String) async -> String? {
        if gh != nil, let data = try? await ghOutput(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], root: root) {
            let slug = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !slug.isEmpty { return slug }
        }
        return await remotes(root: root).first { $0.name == "origin" }?.slug
    }

    /// Open PRs I wrote or was asked to review, newest first.
    func pullRequests(root: String) async throws -> [PullRequest] {
        let base = ["pr", "list", "--state", "open", "--limit", "50", "--json", PullRequest.ghFields]
        async let mine = ghOutput(base + ["--author", "@me"], root: root)
        async let asked = ghOutput(base + ["--search", "review-requested:@me"], root: root)
        var byNumber: [Int: PullRequest] = [:]
        for pr in try PullRequest.decodeList(ghJSON: await mine) + PullRequest.decodeList(ghJSON: await asked) { byNumber[pr.number] = pr }
        return byNumber.values.sorted { $0.number > $1.number }
    }

    func pullRequest(_ input: String, root: String) async throws -> PullRequest {
        guard let n = PullRequest.number(from: input) else { throw ReviewGitError.gitFailed("Not a pull request: \(input)") }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = text.contains("/pull/") ? text : String(n)   // a URL can name another repo
        return try PullRequest.decode(ghJSON: await ghOutput(["pr", "view", "--json", PullRequest.ghFields, "--", target], root: root))
    }

    /// The folder to review `pr` in: the user's worktree on its head branch when it already has the
    /// PR's head (never touched), else Simul's own detached worktree under `worktreesDir`, created or moved to it.
    /// Fetches the PR head and its base branch (into `<remote>/<baseRef>`) from `remote`, the base repo's remote.
    func prepare(_ pr: PullRequest, root: String, worktreesDir: URL) async throws -> (path: String, remote: String) {
        guard pr.headSHA.count >= 40, pr.headSHA.allSatisfy(\.isHexDigit) else { throw ReviewGitError.gitFailed("Unexpected PR head: \(pr.headSHA)") }
        guard await run(["check-ref-format", "refs/heads/\(pr.baseRef)"], in: root).exitCode == 0 else {
            throw ReviewGitError.gitFailed("Unexpected PR base: \(pr.baseRef)")
        }
        let matching = await remotes(root: root).first { $0.slug.lowercased() == pr.baseRepo.lowercased() }?.name
        let remote = matching ?? "origin", headRef = "refs/pull/\(pr.number)/head"
        let notRemote = ReviewGitError.gitFailed("This PR is in \(pr.baseRepo), which isn't a remote of this folder")
        // The base too: a stale one moves the merge-base back and pulls other commits' files into the diff.
        let fetch = await run(["fetch", "--no-tags", "--end-of-options", remote, headRef,
                               "+refs/heads/\(pr.baseRef):refs/remotes/\(remote)/\(pr.baseRef)"], in: root)
        guard fetch.exitCode == 0 else {
            throw matching == nil ? notRemote : ReviewGitError.gitFailed(fetch.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let trees = await worktrees(root: root)
        // A fork's branch name says nothing about the user's branches.
        if !pr.isCrossRepository, let own = trees.first(where: { $0.branch == pr.headRef }),
           await run(["merge-base", "--is-ancestor", pr.headSHA, own.head], in: root).exitCode == 0 { return (own.path, remote) }

        // origin may be another repo with its own PR #n: only its exact head proves it's this PR.
        if matching == nil, await fetchedHead(headRef, root: root) != pr.headSHA { throw notRemote }
        // Check out the head gh reported, not FETCH_HEAD, which a concurrent fetch can change.
        guard await resolves(pr.headSHA, root: root) else {
            throw ReviewGitError.gitFailed("Couldn't fetch this PR's head commit; refresh and try again")
        }

        let dir = worktreesDir.appendingPathComponent(pr.baseRepo.replacingOccurrences(of: "/", with: "-") + "-pr-\(pr.number)").path
        if FileManager.default.fileExists(atPath: dir) {
            guard let real = realPath(dir), trees.contains(where: { realPath($0.path) == real }) else {
                throw ReviewGitError.gitFailed("\(dir) isn't a worktree of this repository")
            }
            // Already at the head: reuse it as is, with any edits the agent made there.
            if await out(["rev-parse", "HEAD"], in: dir) != pr.headSHA {
                let status = await run(["status", "--porcelain"], in: dir)
                guard status.exitCode == 0 else { throw ReviewGitError.gitFailed(status.stderr) }
                guard status.stdout.isEmpty else { throw ReviewGitError.gitFailed("This PR's worktree has local changes") }
                let checkout = await run(["checkout", "--quiet", "--detach", pr.headSHA], in: dir)
                guard checkout.exitCode == 0 else { throw ReviewGitError.gitFailed(checkout.stderr) }
            }
        } else {
            try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
            let add = await run(["worktree", "add", "--quiet", "--detach", "--end-of-options", dir, pr.headSHA], in: root)
            guard add.exitCode == 0 else { throw ReviewGitError.gitFailed(add.stderr) }
        }
        return (dir, remote)
    }

    /// Removes a worktree Simul made; refuses anything outside `worktreesDir`, and one with
    /// local changes unless `force` (after the user confirmed).
    func removeSimulWorktree(_ path: String, root: String, worktreesDir: URL, force: Bool = false) async throws {
        let foreign = ReviewGitError.gitFailed("Not a Simul worktree: \(path)")
        let target: String
        if FileManager.default.fileExists(atPath: path) {
            guard let real = realPath(path), let dir = realPath(worktreesDir.path), real.hasPrefix(dir + "/") else { throw foreign }
            target = real
        } else {
            // Folder already deleted: git drops just its record. Git stores the resolved path.
            let dir = worktreesDir.standardized.path, lexical = URL(fileURLWithPath: path).standardized.path
            guard lexical.hasPrefix(dir + "/") else { throw foreign }
            target = (realPath(dir) ?? dir) + lexical.dropFirst(dir.count)
        }
        let remove = await run(["worktree", "remove"] + (force ? ["--force"] : []) + ["--end-of-options", target], in: root)
        guard remove.exitCode == 0 else {
            throw ReviewGitError.gitFailed(remove.stderr.contains("--force") ? "This PR's worktree has local changes" : remove.stderr)
        }
    }

    // MARK: - Helpers

    /// Fetch remotes as (name, "owner/name").
    func remotes(root: String) async -> [(name: String, slug: String)] {
        let r = await run(["remote", "-v"], in: root)
        return r.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count == 3, fields[2] == "(fetch)", let slug = Self.slug(remoteURL: String(fields[1])) else { return nil }
            return (String(fields[0]), slug)
        }
    }

    /// "owner/name" from https://host/o/n(.git), git@host:o/n(.git) or ssh://git@host/o/n(.git).
    static func slug(remoteURL: String) -> String? {
        var url = remoteURL
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        let parts = url.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count >= 3 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    /// gh's stdout; throws the install/login message when gh is missing or logged out.
    private func ghOutput(_ args: [String], root: String) async throws -> Data {
        guard let gh else { throw ReviewGitError.gitFailed(Self.ghUnavailable) }
        guard let r = await runGH(gh, args, root: root, seconds: 10) else {
            throw ReviewGitError.gitFailed("The GitHub CLI (gh) didn't answer in time")
        }
        guard r.exitCode == 0 else {
            let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines), lower = stderr.lowercased()
            if lower.contains("auth") || lower.contains("log in") || lower.contains("login") { throw ReviewGitError.gitFailed(Self.ghUnavailable) }
            throw ReviewGitError.gitFailed(stderr.isEmpty ? "gh \(args.prefix(2).joined(separator: " ")) failed (exit \(r.exitCode))" : stderr)
        }
        return Data(r.stdout.utf8)
    }

    /// The commit the last fetch got for `ref`, from FETCH_HEAD ("<sha>\t\t'<ref>' of <url>" per line).
    private func fetchedHead(_ ref: String, root: String) async -> String? {
        guard var path = await out(["rev-parse", "--git-path", "FETCH_HEAD"], in: root) else { return nil }
        if !path.hasPrefix("/") { path = root + "/" + path }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first { $0.contains("\t'\(ref)' of ") }
        return line?.split(separator: "\t", maxSplits: 1).first.map(String.init)
    }

    private func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
