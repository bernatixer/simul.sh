import Foundation
@testable import SimulCore

@MainActor
func registerReviewTests() {
    test("diff parser: modified file") {
        let diff = """
        diff --git a/Sources/app.swift b/Sources/app.swift
        index 83db48f..bf2a5c1 100644
        --- a/Sources/app.swift
        +++ b/Sources/app.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let x = 1
        +let x = 2
        +let y = 3
         print(x)
        \\ No newline at end of file

        """
        let files = UnifiedDiff.parse(diff)
        expectEqual(files.count, 1, "one file")
        let f = files[0]
        expectEqual(f.path, "Sources/app.swift", "path")
        expectEqual(f.status, .modified, "status")
        expectEqual(f.hunks.count, 1, "one hunk")
        expectEqual(f.hunks[0].header, "@@ -1,3 +1,4 @@", "header")
        let l = f.hunks[0].lines
        expectEqual(l.count, 5, "five lines (marker skipped)")
        expectEqual(l[1], DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "let x = 1"), "removed is old-side")
        expectEqual(l[2], DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "let x = 2"), "added is new-side")
        expectEqual(l[3].newNumber, 3, "second added")
        expectEqual(l[4], DiffLine(kind: .context, oldNumber: 3, newNumber: 4, text: "print(x)"), "context has both")
    }

    func ctx(_ o: Int, _ n: Int) -> DiffLine { DiffLine(kind: .context, oldNumber: o, newNumber: n, text: "c\(o)") }
    func del(_ o: Int) -> DiffLine { DiffLine(kind: .removed, oldNumber: o, newNumber: nil, text: "-\(o)") }
    func add(_ n: Int) -> DiffLine { DiffLine(kind: .added, oldNumber: nil, newNumber: n, text: "+\(n)") }

    test("split rows: pairs removed/added runs") {
        let rows = DiffHunk(header: "@@", lines: [del(1), del(2), add(1), add(2)]).splitRows
        expectEqual(rows, [SplitRow(left: del(1), right: add(1)), SplitRow(left: del(2), right: add(2))], "paired")
    }

    test("split rows: unequal runs pad with nil") {
        let more = DiffHunk(header: "@@", lines: [del(1), del(2), del(3), add(1)]).splitRows
        expectEqual(more, [SplitRow(left: del(1), right: add(1)), SplitRow(left: del(2), right: nil),
                           SplitRow(left: del(3), right: nil)], "more removed")
        let fewer = DiffHunk(header: "@@", lines: [del(1), add(1), add(2)]).splitRows
        expectEqual(fewer, [SplitRow(left: del(1), right: add(1)), SplitRow(left: nil, right: add(2))], "more added")
    }

    test("split rows: context on both sides") {
        let rows = DiffHunk(header: "@@", lines: [ctx(1, 1), del(2), add(2), ctx(3, 3)]).splitRows
        expectEqual(rows, [SplitRow(left: ctx(1, 1), right: ctx(1, 1)), SplitRow(left: del(2), right: add(2)),
                           SplitRow(left: ctx(3, 3), right: ctx(3, 3))], "context mirrored")
    }

    test("split rows: pure add and pure delete") {
        let adds = DiffHunk(header: "@@", lines: [ctx(1, 1), add(2), add(3)]).splitRows
        expectEqual(adds.map(\.left), [ctx(1, 1), nil, nil], "adds: left empty")
        expectEqual(adds.map(\.right), [ctx(1, 1), add(2), add(3)], "adds: right")
        let dels = DiffHunk(header: "@@", lines: [del(1), del(2), ctx(3, 1)]).splitRows
        expectEqual(dels.map(\.right), [nil, nil, ctx(3, 1)], "deletes: right empty")
        // Added then removed: two runs, not paired backwards.
        let flipped = DiffHunk(header: "@@", lines: [add(1), del(1)]).splitRows
        expectEqual(flipped, [SplitRow(left: nil, right: add(1)), SplitRow(left: del(1), right: nil)], "add then delete")
    }

    test("diff stat squares") {
        expect(FileDiff.squares(added: 0, removed: 0) == (0, 0), "nothing changed")
        expect(FileDiff.squares(added: 2, removed: 1) == (2, 1), "small file: one per line")
        expect(FileDiff.squares(added: 90, removed: 10) == (5, 0), "mostly added")
        expect(FileDiff.squares(added: 30, removed: 70) == (2, 3), "scaled to five")
        expect(FileDiff.squares(added: 0, removed: 400) == (0, 5), "all removed")
    }

    test("diff parser: rename, delete, binary, spaces") {
        let diff = """
        diff --git a/a/x.py b/b/y.py
        similarity index 90%
        rename from a/x.py
        rename to b/y.py
        index 1111111..2222222 100644
        --- a/a/x.py
        +++ b/b/y.py
        @@ -1 +1 @@
        -old
        +new
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 3333333..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/img.png b/img.png
        index 4444444..5555555 100644
        Binary files a/img.png and b/img.png differ
        diff --git a/docs/my file.md b/docs/my file.md
        index 6666666..7777777 100644
        --- a/docs/my file.md\t
        +++ b/docs/my file.md\t
        @@ -1 +1 @@
        --- not a header
        +++ not a header
        diff --git a/docs/only mode.md b/docs/only mode.md
        old mode 100644
        new mode 100755
        diff --git "a/q\\"t\\tab\\303\\251.txt" "b/q\\"t\\tab\\303\\251.txt"
        index 8888888..9999999 100644
        --- "a/q\\"t\\tab\\303\\251.txt"
        +++ "b/q\\"t\\tab\\303\\251.txt"
        @@ -1 +1 @@
        -a
        +b

        """.replacingOccurrences(of: "\\t\n", with: "\t\n")
        let f = UnifiedDiff.parse(diff)
        expectEqual(f.count, 6, "six files")
        expectEqual(f[0].status, .renamed, "renamed")
        expectEqual(f[0].oldPath, "a/x.py", "old path")
        expectEqual(f[0].path, "b/y.py", "new path")
        expectEqual(f[1].status, .deleted, "deleted")
        expectEqual(f[1].path, "gone.txt", "deleted path is old path")
        expectEqual(f[2].isBinary, true, "binary")
        expectEqual(f[2].status, .modified, "binary modified")
        expectEqual(f[2].path, "img.png", "binary path from diff --git line")
        expectEqual(f[3].path, "docs/my file.md", "tab and spaces handled")
        expectEqual(f[3].hunks[0].lines.count, 2, "---/+++ inside a hunk are content")
        expectEqual(f[4].path, "docs/only mode.md", "mode-only path with spaces")
        expectEqual(f[5].path, "q\"t\tabé.txt", "C-quoted path unquoted")
    }

    test("diff parser: new file") {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hi

        """
        let f = UnifiedDiff.parse(diff)
        expectEqual(f.count, 1, "one file")
        expectEqual(f[0].status, .added, "added")
        expectEqual(f[0].path, "new.txt", "path")
        expectEqual(f[0].hunks[0].lines[0].newNumber, 1, "numbering from 1")
    }

    test("diff parser: line count") {
        let diff = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         a
        -b
        +c
        @@ -10,2 +10,4 @@
         d
        +e
        +f
         g
        """
        let f = UnifiedDiff.parse(diff)
        expectEqual(f[0].hunks.count, 2, "two hunks")
        expectEqual(f[0].lineCount, 7, "3 + 4 lines")
        expectEqual(f[0].hunks[1].lines[0].oldNumber, 10, "second hunk numbering")
    }

    test("diff parser: CRLF lines") {
        let diff = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,3 @@\n one\r\n-two\r\n+three\r\n+four\r\n"
        let f = UnifiedDiff.parse(diff)
        expectEqual(f[0].lineCount, 4, "each CRLF line is its own DiffLine")
        expectEqual(f[0].hunks[0].lines[2], DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "three\r"), "CR kept in content")
        expectEqual(f[0].hunks[0].lines[3].newNumber, 3, "numbering continues")
    }

    func comment(_ path: String, _ line: Int, _ end: Int, _ quote: String, _ text: String) -> ReviewComment {
        ReviewComment(id: UUID(), path: path, line: line, endLine: end, quote: quote, text: text,
                      state: .queued, isOutdated: false, createdAt: Date())
    }

    test("anchoring: unchanged") {
        var lines = Array(repeating: "x", count: 10)
        lines[4] = "foo()"
        let r = ReviewAnchoring.reanchor([comment("a", 5, 5, "foo()", "t")], path: "a", lines: lines)
        expectEqual(r[0].line, 5, "same line")
        expect(!r[0].isOutdated, "not outdated")
    }

    test("anchoring: moved line") {
        var lines = Array(repeating: "x", count: 40)
        lines[8] = "foo()"
        lines[29] = "foo()"
        let r = ReviewAnchoring.reanchor([comment("a", 5, 7, "foo()", "t")], path: "a", lines: lines)
        expectEqual(r[0].line, 9, "nearest")
        expectEqual(r[0].endLine, 11, "end shifts with start")
        expect(!r[0].isOutdated, "not outdated")
    }

    test("anchoring: trailing \\r ignored") {
        let r = ReviewAnchoring.reanchor([comment("a", 2, 2, "foo()\r", "t"), comment("a", 1, 1, "bar()", "t")],
                                         path: "a", lines: ["bar()\r", "foo()"])
        expect(!r[0].isOutdated && r[0].line == 2, "quote's \\r ignored")
        expect(!r[1].isOutdated && r[1].line == 1, "line's \\r ignored")
    }

    test("state: a session never reviewed is on the session folder") {
        expect(ReviewState.isCurrent(nil, .sessionFolder), "no state: session folder is current")
        expect(!ReviewState.isCurrent(nil, .folder("/x")), "no state: another folder isn't")
        var chosen = ReviewState()
        chosen.source = .folder("/x")
        expect(ReviewState.isCurrent(chosen, .folder("/x")), "chosen source is current")
        expect(!ReviewState.isCurrent(chosen, .sessionFolder), "switched away")
    }

    test("anchoring: outdated") {
        let r = ReviewAnchoring.reanchor([comment("a", 5, 5, "foo()", "t")], path: "a", lines: ["x", "y"])
        expect(r[0].isOutdated, "outdated")
        expectEqual(r[0].line, 5, "line kept")
    }

    test("prompt: format") {
        let cs = [
            comment("api/views.py", 12, 12, "def handler(request):", "Rename this to handle_request."),
            comment("web/app.js", 40, 42, "fetch(url)", "Add error handling."),
        ]
        expectEqual(ReviewPrompt.text(for: cs, root: "/repo"), """
        Review comments on your changes (paths relative to /repo):

        1. api/views.py:12
           > def handler(request):
           Rename this to handle_request.

        2. web/app.js:40-42
           > fetch(url)
           Add error handling.
        """, "prompt text")
    }

    test("prompt: another source names it and its folder") {
        let cs = [comment("a.swift", 3, 3, "let x = 1", "Why?")]
        expectEqual(ReviewPrompt.text(for: cs, root: "/wt/pr-7", source: "PR #7"), """
        Review comments on PR #7 (files in /wt/pr-7):

        1. a.swift:3
           > let x = 1
           Why?
        """, "prompt text")
        let wts = [Worktree(path: "/r/feat", branch: "feat", head: "h", isMain: false),
                   Worktree(path: "/r/detached", branch: nil, head: "h", isMain: false)]
        expectEqual(ReviewSource.pullRequest(repo: "o/n", number: 7).promptName(worktrees: []), "PR #7", "PR")
        expectEqual(ReviewSource.folder("/r/feat").promptName(worktrees: wts), "the feat worktree", "worktree")
        expectEqual(ReviewSource.folder("/r/detached").promptName(worktrees: wts), "detached", "detached: folder name")
        expectEqual(ReviewSource.folder("/elsewhere/proj").promptName(worktrees: wts), "proj", "folder name")
    }

    test("state: source chosen") {
        let d = JSONDecoder()
        let before = try d.decode(ReviewState.self, from: Data("{\"source\": {\"sessionFolder\": {}}}".utf8))
        expect(!before.sourceChosen, "session folder before the flag: not chosen")
        let legacy = try d.decode(ReviewState.self, from: Data("{\"folder\": \"/x\"}".utf8))
        expect(legacy.sourceChosen, "legacy folder: chosen")
        var s = ReviewState()
        s.sourceChosen = true
        let again = try d.decode(ReviewState.self, from: JSONEncoder().encode(s))
        expectEqual(again, s, "round-trips")
    }

    test("review state: decodes without optional fields") {
        let s = try JSONDecoder().decode(ReviewState.self, from: Data("{}".utf8))
        expectEqual(s, ReviewState(), "empty state")
    }

    test("state: migrates old format to session-folder source") {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let comment = """
        {"id": "\(UUID().uuidString)", "path": "a.swift", "line": 3, "endLine": 3, "quote": "q",
         "text": "t", "state": "queued", "createdAt": "2026-01-01T00:00:00Z"}
        """
        let old = try decoder.decode(ReviewState.self, from: Data("""
        {"base": "main", "viewed": {"a.swift": {"hash": "abc", "viewedAt": "2026-01-01T00:00:00Z"}},
         "comments": [\(comment)]}
        """.utf8))
        expectEqual(old.source, .sessionFolder, "session folder selected")
        expectEqual(Array(old.sources.keys), ["session"], "one source")
        expectEqual(old.current.base, "main", "base kept")
        expectEqual(old.current.viewed["a.swift"]?.hash, "abc", "viewed kept")
        expectEqual(old.current.comments.map(\.text), ["t"], "comments kept")

        let withFolder = try decoder.decode(ReviewState.self, from: Data("""
        {"folder": "/tmp/x", "base": "dev"}
        """.utf8))
        expectEqual(withFolder.source, .folder("/tmp/x"), "folder selected")
        expectEqual(withFolder.sources["folder:/tmp/x"]?.base, "dev", "state under the folder's key")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode(ReviewState.self, from: encoder.encode(old))
        expectEqual(again, old, "new format round-trips")
    }

    test("state: per-source isolation") {
        var s = ReviewState()
        s.current.base = "main"
        s.current.comments.append(comment("a", 1, 1, "x", "session note"))
        s.source = .folder("/tmp/other")
        expectEqual(s.current, SourceState(), "other source starts empty")
        s.current.viewed["b"] = ViewedMark(hash: "h", viewedAt: Date())
        s.source = .sessionFolder
        expectEqual(s.current.base, "main", "session base kept")
        expectEqual(s.current.comments.map(\.text), ["session note"], "session comments kept")
        expect(s.current.viewed.isEmpty, "other source's viewed not here")
        var t = s
        t.source = .pullRequest(repo: "o/n", number: 1)
        t.current = t.current  // reading an empty source and writing it back
        t.source = .sessionFolder
        expectEqual(t, s, "untouched source adds nothing")
        t[.folder("/tmp/other")].viewed = [:]
        expectEqual(t.sources["folder:/tmp/other"], nil, "emptied source removed")
        expectEqual(t.current.base, "main", "subscript leaves the selected source alone")
    }

    test("source: keys round-trip") {
        let sources: [ReviewSource] = [.sessionFolder, .folder("/a/b"), .pullRequest(repo: "owner/name", number: 12)]
        expectEqual(sources.map(\.key), ["session", "folder:/a/b", "pr:owner/name#12"], "keys")
        let decoded = try JSONDecoder().decode([ReviewSource].self, from: JSONEncoder().encode(sources))
        expectEqual(decoded, sources, "codable round trip")
        expectEqual(decoded.map(\.key), sources.map(\.key), "same keys after decoding")
    }

    test("comment: decodes without byAgent/posted") {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        {"id": "\(UUID().uuidString)", "path": "a", "line": 1, "endLine": 1, "quote": "q",
         "text": "t", "state": "sent", "createdAt": "2026-01-01T00:00:00Z"}
        """
        let c = try decoder.decode(ReviewComment.self, from: Data(json.utf8))
        expect(!c.byAgent, "byAgent defaults to false")
        expectEqual(c.state, .sent, "state kept")
        var posted = c
        posted.state = .posted
        posted.byAgent = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try decoder.decode(ReviewComment.self, from: encoder.encode(posted))
        expectEqual(back, posted, "posted + byAgent round-trip")
    }

    // Real repos in temp dirs, like the tmux tests use real tmux.
    let git = "/usr/bin/git"
    func sh(_ dir: String, _ args: String...) async -> String {
        await ProcessRunner.run(git, arguments: ["-c", "commit.gpgsign=false"] + args, workingDirectory: dir).stdout
    }
    func makeTempDir() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simul-git-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
    func write(_ dir: String, _ name: String, _ text: String) {
        try? text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }
    /// main with a.txt + b.txt committed; branch `feature` adds c.txt (committed), edits a.txt (unstaged), adds d.txt (untracked).
    func makeRepo() async -> String {
        let dir = makeTempDir()
        _ = await sh(dir, "init", "-b", "main")
        _ = await sh(dir, "config", "user.name", "T")
        _ = await sh(dir, "config", "user.email", "t@example.com")
        write(dir, "a.txt", "one\n"); write(dir, "b.txt", "bee\n")
        _ = await sh(dir, "add", ".")
        _ = await sh(dir, "commit", "-m", "init")
        _ = await sh(dir, "checkout", "-b", "feature")
        write(dir, "c.txt", "see\n")
        _ = await sh(dir, "add", "c.txt")
        _ = await sh(dir, "commit", "-m", "c")
        write(dir, "a.txt", "one\ntwo\n")
        write(dir, "d.txt", "dee\n")
        return dir
    }
    let reviewGit = ReviewGit(git: git, gh: nil, environment: [:])

    test("git: not a repository") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        await expectThrows("plain folder") {
            do { _ = try await reviewGit.snapshot(folder: dir, baseOverride: nil) }
            catch { expectEqual(error as? ReviewGitError, .notARepository(dir), "error"); throw error }
        }
    }

    test("git: base fallback without remote") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: nil)
        expectEqual(snap.base, "main", "falls back to main")
        expectEqual(Set(snap.files.map(\.path)), ["a.txt", "c.txt", "d.txt"], "committed, unstaged, untracked")
        let staged = await sh(dir, "diff", "--cached", "--name-only")
        let status = await sh(dir, "status", "--porcelain")
        expectEqual(staged, "", "real index untouched")
        expect(status.contains("?? d.txt"), "untracked stays untracked")
    }

    test("git: override base") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: "HEAD")
        expectEqual(snap.base, "HEAD", "override shown")
        expectEqual(Set(snap.files.map(\.path)), ["a.txt", "d.txt"], "only uncommitted work")
    }

    test("git: hashes") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.removeItem(atPath: dir + "/b.txt")
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: nil)
        let expected = await sh(dir, "hash-object", "a.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(snap.hashes["a.txt"] ?? "", expected, "hash of working copy")
        expectEqual(snap.hashes["b.txt"] ?? "", "deleted", "deleted file")
        let content = try Data(contentsOf: URL(fileURLWithPath: dir + "/a.txt"))
        expectEqual(ReviewGit.blobID(content), expected, "blobID matches git's (expanders check reads against it)")
    }

    test("git: prefix config does not change paths") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = await sh(dir, "config", "diff.mnemonicPrefix", "true")
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: nil)
        expectEqual(Set(snap.files.map(\.path)), ["a.txt", "c.txt", "d.txt"], "repo-relative paths")
    }

    test("git: option-like base override is rejected") {
        let dir = await makeRepo()
        let out = dir + "-out"
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: out) }
        await expectThrows("option as base") {
            _ = try await reviewGit.snapshot(folder: dir, baseOverride: "--output=" + out)
        }
        expect(!FileManager.default.fileExists(atPath: out), "no file written")
        await expectThrows("unknown ref") {
            _ = try await reviewGit.snapshot(folder: dir, baseOverride: "nope")
        }
    }

    test("git: non-UTF-8 diff is still listed") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("caf\u{e9}\n".data(using: .isoLatin1)!).write(to: URL(fileURLWithPath: dir + "/a.txt"))
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: "HEAD")
        expect(snap.files.map(\.path).contains("a.txt"), "Latin-1 file listed")
    }

    test("git: unhashable path keeps other hashes") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let nested = dir + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        _ = await sh(nested, "init")
        write(nested, "x.txt", "x\n")
        _ = await sh(nested, "add", ".")
        _ = await sh(nested, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-m", "x")
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: nil)
        let expected = await sh(dir, "hash-object", "a.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(snap.hashes["a.txt"] ?? "", expected, "normal file still hashed")
    }

    test("git: dirty submodule gets a submodule hash") {
        let dir = await makeRepo()
        let sub = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: sub) }
        _ = await sh(sub, "init", "-b", "main")
        write(sub, "x.txt", "x\n")
        _ = await sh(sub, "add", ".")
        _ = await sh(sub, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-m", "x")
        _ = await sh(dir, "-c", "protocol.file.allow=always", "submodule", "add", sub, "sub")
        _ = await sh(dir, "commit", "-m", "sub")
        write(dir + "/sub", "x.txt", "changed\n")
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: "HEAD")
        let hash = snap.hashes["sub"] ?? ""
        expect(hash.hasPrefix("submodule:"), "submodule hash, got \(hash)")
        expect(hash.hasSuffix("-dirty"), "dirty submodule")
    }

    test("git: unborn branch diffs against the empty tree") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = await sh(dir, "init", "-b", "main")
        write(dir, "new.txt", "new\n")
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: nil)
        expectEqual(snap.files.map(\.path), ["new.txt"], "untracked file listed")
        expectEqual(snap.base, "HEAD", "base shown")
    }

    test("word offsets: whole words only") {
        expectEqual("bee(beehive, a_bee, bee)".wordOffsets(of: "bee"), [0..<3, 20..<23], "standalone matches")
        expectEqual("$bee bee$ ébee".wordOffsets(of: "bee"), [1..<4, 5..<8, 11..<14], "ASCII word chars only, like git grep -w")
    }

    test("git: grep uses excludes changed lines") {
        let dir = await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        write(dir, "b.txt", "bee\nuse(bee)\nbeehive\n")
        write(dir, "x:y.txt", "a bee here\n")
        write(dir, "z.txt", "bee\r\nbee\r\n")
        _ = await sh(dir, "add", "x:y.txt", "z.txt")
        write(dir, "a.txt", "one\ntwo bee\n")
        _ = await sh(dir, "add", "b.txt", "a.txt")
        _ = await sh(dir, "commit", "-m", "bees")
        write(dir, "a.txt", "bee one\ntwo bee\n")  // line 1 is changed against HEAD
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: "HEAD")
        let (uses, more) = await reviewGit.uses(of: "bee", root: snap.root, files: snap.files)
        expect(!more, "all listed")
        expectEqual(uses.map(\.id), ["a.txt:2", "b.txt:1", "b.txt:2", "x:y.txt:1", "z.txt:1", "z.txt:2"],
                    "whole words, changed line skipped")
        expectEqual(uses.first { $0.path == "x:y.txt" }?.text, "a bee here", "text after a path with ':'")
        expectEqual(uses.last?.text, "bee", "CRLF lines split")
        let capped = await reviewGit.uses(of: "bee", root: snap.root, files: snap.files, limit: 2)
        expectEqual(capped.uses.map(\.id), ["a.txt:2", "b.txt:1"], "first two")
        expect(capped.more, "more past the limit")
        let none = await reviewGit.uses(of: "nothing", root: snap.root, files: snap.files)
        expectEqual(none.uses, [], "no matches")
    }

    test("git: file at point uses old path") {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = await sh(dir, "init", "-b", "main")
        _ = await sh(dir, "config", "user.name", "T")
        _ = await sh(dir, "config", "user.email", "t@example.com")
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        write(dir, "old.txt", old)
        _ = await sh(dir, "add", ".")
        _ = await sh(dir, "commit", "-m", "init")
        let point = await sh(dir, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await sh(dir, "checkout", "-b", "feature")
        _ = await sh(dir, "mv", "old.txt", "new.txt")
        write(dir, "new.txt", old + "line 21\n")
        _ = await sh(dir, "commit", "-am", "rename")
        let snap = try await reviewGit.snapshot(folder: dir, baseOverride: nil)
        let file = snap.files.first { $0.path == "new.txt" }
        expectEqual(file?.status, .renamed, "rename detected")
        expectEqual(file?.oldPath, "old.txt", "old path")
        expectEqual(snap.point, point, "point is the merge-base")
        let text = await reviewGit.file(at: snap.point, path: file?.oldPath ?? "", root: snap.root)
        expectEqual(text, old, "old content at the old path")
        let missing = await reviewGit.file(at: snap.point, path: "new.txt", root: snap.root)
        expectEqual(missing, nil, "new path not at point")
    }

    func tempStore() throws -> (ReviewStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ReviewStore(fileURL: dir.appendingPathComponent("reviews.json"),
                            backupURL: dir.appendingPathComponent("reviews.json.prev"),
                            snapshots: dir.appendingPathComponent("reviews")), dir)
    }

    test("review store: round trip") {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        expectEqual(store.load(), [:], "missing file is empty")
        var state = ReviewState()
        state.source = .folder("/tmp/x")
        state.current.viewed["a.swift"] = ViewedMark(hash: "abc", viewedAt: Date(timeIntervalSince1970: 1_000))
        let id = UUID()
        store.save([id: state])
        expectEqual(store.load(), [id: state], "state survives")
        try Data("{\"version\": 9, \"reviews\": {}}".utf8).write(to: dir.appendingPathComponent("reviews.json"))
        expectEqual(store.load(), [:], "unknown version is empty")
    }

    test("review store: duplicate and invalid keys do not crash") {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        let json = """
        {"version": 1, "reviews": {"\(id.uppercased())": {}, "\(id.lowercased())": {}, "not-a-uuid": {}}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("reviews.json"))
        expectEqual(store.load(), [UUID(uuidString: id)!: ReviewState()], "one entry, invalid key dropped")
    }

    test("review store: corrupt falls back to prev") {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        var state = ReviewState()
        state.current.base = "main"
        store.save([id: ReviewState()])
        store.save([id: state])
        try Data("not json".utf8).write(to: dir.appendingPathComponent("reviews.json"))
        expectEqual(store.load(), [id: ReviewState()], "previous copy recovered")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("reviews.json.prev"))
        expectEqual(store.load(), [:], "both corrupt is empty")
    }

    test("review store: snapshot keep/prune") {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("work.txt")
        try Data("one".utf8).write(to: src)
        let h1 = String(repeating: "a", count: 40), h2 = String(repeating: "b", count: 40)
        let kept = store.keepViewedContent(of: src, hash: h1)
        expect(kept != nil, "copied")
        try Data("two".utf8).write(to: src)
        _ = store.keepViewedContent(of: src, hash: h1)
        let text = try String(contentsOf: store.viewedContent(hash: h1)!, encoding: .utf8)
        expectEqual(text, "one", "not overwritten")
        _ = store.keepViewedContent(of: src, hash: h2)
        expect(store.keepViewedContent(of: src, hash: "../x") == nil, "path-like hash rejected")
        expect(store.keepViewedContent(of: dir.appendingPathComponent("gone"), hash: String(repeating: "c", count: 40)) == nil,
               "missing source")
        expect(store.viewedContent(hash: "nope") == nil, "unknown hash")
        store.pruneSnapshots(keeping: [h2])
        expect(store.viewedContent(hash: h1) == nil, "pruned")
        expect(store.viewedContent(hash: h2) != nil, "kept")
    }
}
