import Foundation
@testable import SimulCore

@MainActor
func registerReviewSourcesTests() {
    let git = "/usr/bin/git"
    let reviewGit = ReviewGit(git: git, gh: nil, environment: [:])
    @discardableResult
    func sh(_ dir: String, _ args: String...) async -> String {
        await ProcessRunner.run(git, arguments: ["-c", "commit.gpgsign=false", "-c", "user.name=T", "-c", "user.email=t@example.com"] + args,
                                workingDirectory: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func makeTempDir() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simul-pr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
    }
    func write(_ path: String, _ text: String) { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    /// `<tmp>/<repo>.git` bare repo with main, plus a commit pushed as refs/pull/1/head; returns its sha.
    func makeRemote(_ tmp: String, _ repo: String, file: String) async -> (url: String, sha: String) {
        let src = tmp + "/src-" + repo.replacingOccurrences(of: "/", with: "-")
        try? FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        await sh(src, "init", "-q", "-b", "main")
        write(src + "/a.txt", "one\n"); await sh(src, "add", "."); await sh(src, "commit", "-qm", "init")
        let bare = tmp + "/" + repo + ".git"
        try? FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
        await sh(bare, "init", "-q", "--bare")
        await sh(src, "push", "-q", bare, "main")
        write(src + "/" + file, "pr\n"); await sh(src, "add", "."); await sh(src, "commit", "-qm", "pr")
        await sh(src, "push", "-q", bare, "HEAD:refs/pull/1/head")
        return (bare, await sh(src, "rev-parse", "HEAD"))
    }
    func pr(_ repo: String, sha: String, head: String = "feature", cross: Bool = false) -> PullRequest {
        PullRequest(number: 1, title: "T", author: "me", headRef: head, baseRef: "main", headSHA: sha,
                    baseRepo: repo, url: "https://github.com/\(repo)/pull/1", isCrossRepository: cross)
    }
    func expectFailure(_ message: String, _ body: () async throws -> Void) async {
        await expectThrows(message) {
            do { try await body() }
            catch { expectEqual((error as? ReviewGitError), .gitFailed(message), "message: \(error)"); throw error }
        }
    }
    let dirty = "This PR's worktree has local changes"
    /// A clone of a fresh `me/proj` remote; returns (tmp, root, worktreesDir, pr head sha).
    func setUp() async -> (tmp: String, root: String, dir: URL, sha: String) {
        let tmp = makeTempDir()
        let origin = await makeRemote(tmp, "me/proj", file: "b.txt")
        await sh(tmp, "clone", "-q", origin.url, tmp + "/root")
        return (tmp, tmp + "/root", URL(fileURLWithPath: tmp + "/simul-worktrees"), origin.sha)
    }

    test("worktrees: porcelain parse") {
        let text = "worktree /r\0HEAD aaa\0branch refs/heads/main\0\0worktree /w/x y\0HEAD bbb\0detached\0\0"
        expectEqual(Worktree.parse(porcelainZ: text), [
            Worktree(path: "/r", branch: "main", head: "aaa", isMain: true),
            Worktree(path: "/w/x y", branch: nil, head: "bbb", isMain: false),
        ], "main + detached with a space")
        expectEqual(Worktree.parse(porcelainZ: "worktree /b.git\0bare\0\0"), [], "bare skipped")
        let (tmp, root, _, _) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        await sh(root, "worktree", "add", "-q", "-b", "side", tmp + "/side")
        let list = await reviewGit.worktrees(root: root)
        expectEqual(list.map(\.path), [root, tmp + "/side"], "real repo paths")
        expectEqual(list.map(\.branch), ["main", "side"], "real repo branches")
    }

    test("pr: parse input forms") {
        for (input, n) in [("123", 123), ("#123", 123), (" #7\n", 7), ("https://github.com/o/n/pull/123", 123),
                           ("https://github.com/o/n/pull/123/files", 123)] {
            expectEqual(PullRequest.number(from: input), n, input)
        }
        for input in ["", "#", "abc", "-1", "0", "--help", "https://github.com/o/n/issues/3", "https://github.com/o/n"] {
            expectEqual(PullRequest.number(from: input), nil, "rejects \(input)")
        }
        let json = #"{"number":123,"title":"Fix it","author":{"login":"ana"},"headRefName":"fix","baseRefName":"main","headRefOid":"abc","url":"https://github.com/PostHog/posthog/pull/123","isCrossRepository":true}"#
        let decoded = try PullRequest.decode(ghJSON: Data(json.utf8))
        expectEqual(decoded,
                    PullRequest(number: 123, title: "Fix it", author: "ana", headRef: "fix", baseRef: "main", headSHA: "abc",
                                baseRepo: "PostHog/posthog", url: "https://github.com/PostHog/posthog/pull/123",
                                isCrossRepository: true), "gh JSON")
        await expectThrows("bad JSON") { _ = try PullRequest.decodeList(ghJSON: Data("{}".utf8)) }
        let list = try PullRequest.decodeList(ghJSON: Data("[\(json)]".utf8))
        expectEqual(list.map(\.number), [123], "gh list JSON")
        for url in ["https://github.com/o/n.git", "git@github.com:o/n.git", "ssh://git@github.com/o/n", "https://github.com/o/n/"] {
            expectEqual(ReviewGit.slug(remoteURL: url), "o/n", url)
        }
        await expectThrows("no gh") {
            do { _ = try await reviewGit.pullRequests(root: "/") }
            catch { expectEqual(error as? ReviewGitError, .gitFailed(ReviewGit.ghUnavailable), "gh message"); throw error }
        }
    }

    test("pr: creates a detached worktree") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let path = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        expectEqual(path, dir.path + "/me-proj-pr-1", "named after repo and number")
        let head = await sh(path, "rev-parse", "HEAD"), symbolic = await sh(path, "symbolic-ref", "-q", "HEAD")
        let branches = await sh(root, "branch", "--list")
        expectEqual(head, sha, "at the PR head")
        expectEqual(symbolic, "", "detached")
        expectEqual(branches, "* main", "no local branch created")
    }

    test("pr: reuses a worktree on the head branch") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        await sh(root, "fetch", "-q", "origin", "refs/pull/1/head")
        await sh(root, "worktree", "add", "-q", "-b", "feature", tmp + "/mine", sha)
        write(tmp + "/mine/more.txt", "x\n"); await sh(tmp + "/mine", "add", "."); await sh(tmp + "/mine", "commit", "-qm", "more")
        write(tmp + "/mine/dirty.txt", "x\n")
        let path = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        expectEqual(path, tmp + "/mine", "the user's worktree, ahead of the PR head")
        expect(!FileManager.default.fileExists(atPath: dir.path), "nothing created")
        expect(FileManager.default.fileExists(atPath: tmp + "/mine/dirty.txt"), "left untouched")
    }

    test("pr: skips a head-branch worktree without the PR head") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        await sh(root, "worktree", "add", "-q", "-b", "feature", tmp + "/mine")   // at main, behind the PR
        let before = await sh(tmp + "/mine", "rev-parse", "HEAD")
        let path = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        expectEqual(path, dir.path + "/me-proj-pr-1", "simul worktree instead")
        let after = await sh(tmp + "/mine", "rev-parse", "HEAD")
        expectEqual(after, before, "user's worktree untouched")
    }

    test("pr: never reuses a user worktree for a fork PR") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // The user's main already contains the PR head, but the fork's `main` is a different branch.
        await sh(root, "fetch", "-q", "origin", "refs/pull/1/head")
        await sh(root, "merge", "-q", "--ff-only", sha)
        let fork = try await reviewGit.prepare(pr("me/proj", sha: sha, head: "main", cross: true), root: root, worktreesDir: dir).path
        expectEqual(fork, dir.path + "/me-proj-pr-1", "fork PR: simul worktree")
        let same = try await reviewGit.prepare(pr("me/proj", sha: sha, head: "main"), root: root, worktreesDir: dir).path
        expectEqual(same, root, "same-repo PR: the user's main")
    }

    test("pr: fetches from the remote matching the base repo") {
        let (tmp, root, dir, originSHA) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let upstream = await makeRemote(tmp, "acme/proj", file: "c.txt")
        await sh(root, "remote", "add", "upstream", upstream.url)
        let (path, remote) = try await reviewGit.prepare(pr("ACME/Proj", sha: upstream.sha), root: root, worktreesDir: dir)
        expectEqual(path, dir.path + "/ACME-Proj-pr-1", "named after the base repo")
        expectEqual(remote, "upstream", "remote used")
        let head = await sh(path, "rev-parse", "HEAD")
        expectEqual(head, upstream.sha, "upstream's PR head, not origin's")
        expect(upstream.sha != originSHA, "remotes differ")
    }

    test("pr: fetches the base, so a stale one adds no other files") {
        let (tmp, root, dir, _) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // After root's clone, main moves on (z.txt) and the PR is rebased onto it (c.txt).
        let src = tmp + "/src-me-proj", bare = tmp + "/me/proj.git"
        await sh(src, "reset", "-q", "--hard", "HEAD~1")
        write(src + "/z.txt", "z\n"); await sh(src, "add", "."); await sh(src, "commit", "-qm", "main moves")
        await sh(src, "push", "-q", "-f", bare, "main")
        write(src + "/c.txt", "c\n"); await sh(src, "add", "."); await sh(src, "commit", "-qm", "pr")
        await sh(src, "push", "-q", "-f", bare, "HEAD:refs/pull/1/head")
        let sha = await sh(src, "rev-parse", "HEAD")
        let (path, remote) = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir)
        expectEqual(remote, "origin", "remote used")
        let snapshot = try await reviewGit.snapshot(folder: path, baseOverride: "\(remote)/main")
        expectEqual(snapshot.files.map(\.path), ["c.txt"], "only the PR's files")
    }

    test("pr: origin fallback must have the PR head") {
        let (tmp, root, dir, originSHA) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let other = await makeRemote(tmp, "acme/proj", file: "c.txt")   // not a remote of root
        await expectFailure("This PR is in acme/proj, which isn't a remote of this folder") {
            _ = try await reviewGit.prepare(pr("acme/proj", sha: other.sha), root: root, worktreesDir: dir).path
        }
        expect(!FileManager.default.fileExists(atPath: dir.path), "nothing created")
        let path = try await reviewGit.prepare(pr("old/name", sha: originSHA), root: root, worktreesDir: dir).path
        let head = await sh(path, "rev-parse", "HEAD")
        expectEqual(head, originSHA, "origin's PR when its head matches")
    }

    test("pr: refuses to update a dirty simul worktree") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let path = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        // Move the PR head on the remote.
        let src = tmp + "/src-me-proj"
        write(src + "/b.txt", "pr2\n"); await sh(src, "commit", "-qam", "more")
        await sh(src, "push", "-q", "-f", tmp + "/me/proj.git", "HEAD:refs/pull/1/head")
        let newSHA = await sh(src, "rev-parse", "HEAD")
        _ = try await reviewGit.prepare(pr("me/proj", sha: newSHA), root: root, worktreesDir: dir).path
        let head = await sh(path, "rev-parse", "HEAD")
        expectEqual(head, newSHA, "clean worktree moved to the new head")
        write(path + "/b.txt", "local\n")
        let same = try await reviewGit.prepare(pr("me/proj", sha: newSHA), root: root, worktreesDir: dir).path
        expectEqual(same, path, "a dirty worktree already at the head still loads")
        write(src + "/b.txt", "pr3\n"); await sh(src, "commit", "-qam", "again")
        await sh(src, "push", "-q", "-f", tmp + "/me/proj.git", "HEAD:refs/pull/1/head")
        let thirdSHA = await sh(src, "rev-parse", "HEAD")
        await expectFailure(dirty) { _ = try await reviewGit.prepare(pr("me/proj", sha: thirdSHA), root: root, worktreesDir: dir).path }
        let kept = try String(contentsOfFile: path + "/b.txt", encoding: .utf8)
        expectEqual(kept, "local\n", "local change kept")
    }

    test("pr: an existing folder must be a worktree") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: dir.path + "/me-proj-pr-1", withIntermediateDirectories: true)
        await expectThrows("plain folder") { _ = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path }
    }

    test("pr: remove refuses foreign paths") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        await sh(root, "worktree", "add", "-q", "-b", "side", tmp + "/side")
        let path = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        for foreign in [tmp + "/side", dir.path + "/../side", root, dir.path, tmp + "/gone"] {
            await expectThrows("refuses \(foreign)") {
                try await reviewGit.removeSimulWorktree(foreign, root: root, worktreesDir: dir, force: true)
            }
        }
        expect(FileManager.default.fileExists(atPath: tmp + "/side"), "foreign worktree kept")
        try await reviewGit.removeSimulWorktree(path, root: root, worktreesDir: dir)
        expect(!FileManager.default.fileExists(atPath: path), "simul worktree removed")
        let left = await reviewGit.worktrees(root: root)
        expectEqual(left.map(\.path), [root, tmp + "/side"], "pruned from the list")
    }

    test("pr: remove keeps local changes unless forced") {
        let (tmp, root, dir, sha) = await setUp()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let path = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        write(path + "/new.txt", "x\n")
        await expectFailure(dirty) { try await reviewGit.removeSimulWorktree(path, root: root, worktreesDir: dir) }
        expect(FileManager.default.fileExists(atPath: path + "/new.txt"), "edits kept")
        try await reviewGit.removeSimulWorktree(path, root: root, worktreesDir: dir, force: true)
        expect(!FileManager.default.fileExists(atPath: path), "forced removal")

        let again = try await reviewGit.prepare(pr("me/proj", sha: sha), root: root, worktreesDir: dir).path
        await sh(root, "worktree", "add", "-q", "-b", "side", tmp + "/side")
        try FileManager.default.removeItem(atPath: again)   // both deleted behind git's back
        try FileManager.default.removeItem(atPath: tmp + "/side")
        try await reviewGit.removeSimulWorktree(again, root: root, worktreesDir: dir)
        let left = await reviewGit.worktrees(root: root)
        expectEqual(left.map(\.path), [root, tmp + "/side"], "only the simul entry dropped; the user's stale one stays")
    }
}
