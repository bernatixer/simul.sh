import Foundation
@testable import SimulCore

@MainActor
func registerGitHubReviewTests() {
    func ctx(_ o: Int, _ n: Int) -> DiffLine { DiffLine(kind: .context, oldNumber: o, newNumber: n, text: "c") }
    func add(_ n: Int) -> DiffLine { DiffLine(kind: .added, oldNumber: nil, newNumber: n, text: "+") }
    func del(_ o: Int) -> DiffLine { DiffLine(kind: .removed, oldNumber: o, newNumber: nil, text: "-") }
    // a.swift: new lines 1-4 in one hunk, 20-21 in another.
    let diff = [FileDiff(path: "a.swift", oldPath: nil, status: .modified, isBinary: false, hunks: [
        DiffHunk(header: "@@", lines: [ctx(1, 1), del(2), add(2), add(3), ctx(3, 4)]),
        DiffHunk(header: "@@", lines: [ctx(19, 20), add(21)]),
    ])]
    func comment(_ line: Int, _ end: Int? = nil, _ text: String = "fix", path: String = "a.swift", outdated: Bool = false) -> ReviewComment {
        ReviewComment(id: UUID(), path: path, line: line, endLine: end ?? line, quote: "q", text: text,
                      state: .queued, isOutdated: outdated, createdAt: Date())
    }
    func payload(_ comments: [ReviewComment], summary: String = "", outsideIntoSummary: Bool = true) -> (payload: GitHubReviewPayload, outside: [ReviewComment]) {
        GitHubReview.payload(event: .comment, summary: summary, comments: comments, diff: diff,
                             headSHA: "abc", outsideIntoSummary: outsideIntoSummary)
    }

    test("github review: inline vs outside") {
        let inside = [comment(2), comment(4), comment(21)]
        let outside = [comment(10), comment(1, path: "b.swift"), comment(4, 20)]  // not in a hunk, file not in diff, range over a gap
        let r = payload(inside + outside)
        expectEqual(r.payload.comments.map(\.line), [2, 4, 21], "inline lines")
        expectEqual(r.outside.map(\.id), outside.map(\.id), "outside ones, in order")
        expectEqual(r.payload.commit_id, "abc", "commit")
        expectEqual(r.payload.comments.first?.side, "RIGHT", "new side")
    }

    test("github review: ranges use start_line") {
        let r = payload([comment(1, 3), comment(2)])
        let range = r.payload.comments[0], single = r.payload.comments[1]
        expectEqual(range.start_line, 1, "start")
        expectEqual(range.line, 3, "end")
        expectEqual(range.start_side, "RIGHT", "start side")
        expectEqual(single.start_line, nil, "single: no start_line")
        expectEqual(single.start_side, nil, "single: no start_side")
    }

    test("github review: outside-diff comments go to summary") {
        let r = payload([comment(2, nil, "inline"), comment(10, nil, "line one\nline two"), comment(10, 12, "range")], summary: "Looks good")
        expectEqual(r.payload.body, "Looks good\n\nOther comments:\n- `a.swift:10` line one\n  line two\n- `a.swift:10-12` range", "body")
        expectEqual(r.payload.comments.map(\.body), ["inline"], "inline body is the text, no quote")
        expectEqual(payload([comment(10)], summary: "S", outsideIntoSummary: false).payload.body, "S", "off: summary only")
        expectEqual(payload([comment(10, nil, "x")]).payload.body, "Other comments:\n- `a.swift:10` x", "no summary")
        expectEqual(payload([comment(2)], summary: "S").payload.body, "S", "nothing outside")
    }

    test("github review: outdated goes outside") {
        let r = payload([comment(2, outdated: true)])
        expect(r.payload.comments.isEmpty, "not inline")
        expectEqual(r.outside.count, 1, "outside")
    }

    test("github review: payload JSON shape") {
        let r = GitHubReview.payload(event: .requestChanges, summary: "S", comments: [comment(1, 3), comment(2)], diff: diff,
                                     headSHA: "abc", outsideIntoSummary: true)
        let data = try JSONEncoder().encode(r.payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        expectEqual(Set(json.keys), ["commit_id", "event", "body", "comments"], "top-level keys")
        expectEqual(json["event"] as? String, "REQUEST_CHANGES", "event")
        let comments = json["comments"] as? [[String: Any]] ?? []
        expectEqual(comments.count, 2, "two comments")
        expectEqual(Set(comments.first?.keys ?? [:].keys), ["path", "line", "side", "start_line", "start_side", "body"], "range keys")
        expectEqual(Set(comments.last?.keys ?? [:].keys), ["path", "line", "side", "body"], "single-line keys")
    }

    test("github review: error message from gh") {
        let body = #"{"message":"Unprocessable Entity","errors":["Line could not be resolved"],"status":"422"}"#
        expectEqual(GitHubReview.errorMessage(stdout: body, stderr: "gh: Unprocessable Entity (HTTP 422)", exitCode: 1),
                    "Unprocessable Entity: Line could not be resolved", "JSON message and errors")
        expectEqual(GitHubReview.errorMessage(stdout: "", stderr: "boom\n", exitCode: 1), "boom", "stderr")
        expectEqual(GitHubReview.errorMessage(stdout: "", stderr: "", exitCode: 4), "gh api failed (exit 4)", "exit code")
    }

    test("github review: snapshot must match the PR head") {
        let git = "/usr/bin/git", review = ReviewGit(git: git, gh: nil, environment: [:])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simul-head-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dir = realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        @discardableResult
        func sh(_ args: String...) async -> String {
            await ProcessRunner.run(git, arguments: ["-c", "commit.gpgsign=false", "-c", "user.name=T", "-c", "user.email=t@example.com"] + args,
                                    workingDirectory: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ name: String, _ text: String) throws { try text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        try write("a.txt", "one\n")
        await sh("init", "-q", "-b", "main"); await sh("add", "."); await sh("commit", "-qm", "base")
        let base = await sh("rev-parse", "HEAD")
        try write("a.txt", "one\ntwo\n")
        await sh("commit", "-qam", "pr")
        let head = await sh("rev-parse", "HEAD")
        func check() async throws -> (ReviewSnapshot, Set<String>?) {
            let snap = try await review.snapshot(folder: dir, baseOverride: base)
            let objects = try await review.objects(at: head, paths: snap.files.map(\.path), root: dir)
            return (snap, GitHubReview.localOnly(snap, head: objects))
        }

        let (_, clean) = try await check()
        expectEqual(clean, [], "at head: fine")
        let headLines = await review.lines(at: head, path: "a.txt", root: dir)
        expectEqual(headLines, ["one", "two", ""], "head blob lines")
        let missing = await review.lines(at: head, path: "nope.txt", root: dir)
        expectEqual(missing, nil, "no file at head")

        // Edited and refreshed, then reverted without a refresh: the stored snapshot is stale.
        try write("a.txt", "one\nTWO\n")
        let stale = try await review.snapshot(folder: dir, baseOverride: base)
        try write("a.txt", "one\ntwo\n")
        let objects = try await review.objects(at: head, paths: stale.files.map(\.path), root: dir)
        expectEqual(GitHubReview.localOnly(stale, head: objects), nil, "stale snapshot blocked")

        // An untracked file is in the diff but not at the head: its comment goes outside.
        try write("new.txt", "x\n")
        let (snap, local) = try await check()
        expectEqual(local, ["new.txt"], "local-only path")
        let c = ReviewComment(id: UUID(), path: "new.txt", line: 1, endLine: 1, quote: "x", text: "hm",
                              state: .queued, isOutdated: false, createdAt: Date())
        let r = GitHubReview.payload(event: .comment, summary: "", comments: [c],
                                     diff: snap.files.filter { !(local ?? []).contains($0.path) },
                                     headSHA: head, outsideIntoSummary: true)
        expect(r.payload.comments.isEmpty, "not inline")
        expectEqual(r.outside.map(\.id), [c.id], "outside")
    }

    test("github review: ls-tree parsing") {
        let text = "100644 blob aaa\ta.txt\u{0}160000 commit bbb\tsub\u{0}100644 blob ccc\tdir/with space.txt\u{0}"
        expectEqual(GitHubReview.parseLsTree(text), ["a.txt": "aaa", "sub": "bbb", "dir/with space.txt": "ccc"], "entries")
    }

    test("github review: inline only where the quote is on its line at the head") {
        let head = ["let a = 1\r", "let b = 2", "let c = 3"]
        func c(_ line: Int, _ end: Int, _ quote: String) -> ReviewComment {
            ReviewComment(id: UUID(), path: "a.swift", line: line, endLine: end, quote: quote, text: "t",
                          state: .queued, isOutdated: false, createdAt: Date())
        }
        expect(GitHubReview.matchesHead(c(2, 2, "let b = 2"), headLines: head), "matching: inline")
        expect(GitHubReview.matchesHead(c(1, 1, "let a = 1"), headLines: head), "trailing \\r ignored")
        expect(!GitHubReview.matchesHead(c(2, 2, "let x = 9"), headLines: head), "quote not at its line: outside")
        expect(!GitHubReview.matchesHead(c(2, 4, "let b = 2"), headLines: head), "range past EOF: outside")
        expect(!GitHubReview.matchesHead(c(1, 1, "let a = 1"), headLines: nil), "no file at head: outside")
        // In the payload: a moved line stays out of the inline comments.
        let diff = [FileDiff(path: "a.swift", oldPath: nil, status: .added, isBinary: false, hunks: [DiffHunk(header: "@@", lines:
            (1...3).map { DiffLine(kind: .added, oldNumber: nil, newNumber: $0, text: head[$0 - 1]) })])]
        let good = c(2, 2, "let b = 2"), moved = c(3, 3, "let b = 2")
        let r = GitHubReview.payload(event: .comment, summary: "", comments: [good, moved], diff: diff, headSHA: "h",
                                     outsideIntoSummary: true, headLines: ["a.swift": head])
        expectEqual(r.payload.comments.map(\.line), [2], "only the matching one inline")
        expectEqual(r.outside.map(\.id), [moved.id], "the other outside")
        expectEqual(GitHubReview.notMatchingHead(r.outside, diff: diff),
                    "1 comment no longer matches the PR head — refresh, or tick Add to summary", "demoted by the head: says so")
        expectEqual(GitHubReview.notMatchingHead([c(9, 9, "x")], diff: diff), nil, "outside the diff anyway: fine")
    }
}
