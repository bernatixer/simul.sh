import AppKit
import Foundation
@testable import SimulCore

@MainActor
func registerSupportTests() {
    test("relative age: compact buckets") {
        let m = 60.0, h = 3600.0, d = 86400.0
        expectEqual(RelativeAge.short(10), "now", "seconds")
        expectEqual(RelativeAge.short(5 * m), "5m", "minutes")
        expectEqual(RelativeAge.short(h), "1h", "hour")
        expectEqual(RelativeAge.short(4 * d), "4d", "days")
        expectEqual(RelativeAge.short(15 * d), "2w", "weeks")
        expectEqual(RelativeAge.short(125 * d), "4mo", "months")
        expectEqual(RelativeAge.short(800 * d), "2y", "years")
        expectEqual(RelativeAge.countdown(20), "1m", "countdown floor")
        expectEqual(RelativeAge.countdown(45 * m), "45m", "countdown minutes")
        expectEqual(RelativeAge.countdown(2 * h + 10 * m), "2h 10m", "countdown hours+minutes")
        expectEqual(RelativeAge.countdown(3 * h), "3h", "countdown whole hours")
        expectEqual(RelativeAge.countdown(3 * d + 4 * h + 5 * m), "3d 4h", "countdown days+hours")
    }

    test("clipboard paste: files, text, image, escaping") {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("simul-paste-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard(name: .init("simul-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        expectEqual(ClipboardPaste.shellEscaped("/a b/c(1)'s.png"), #"/a\ b/c\(1\)\'s.png"#, "escapes specials")

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/one file.png") as NSURL, URL(fileURLWithPath: "/tmp/two") as NSURL])
        let files = ClipboardPaste.text(from: board, savingImagesIn: folder)
        expectEqual(files.text, #"/tmp/one\ file.png /tmp/two"#, "copied files paste as escaped paths")
        expect(files.savedImage == nil, "files save nothing")

        board.clearContents()
        board.setString("hello", forType: .string)
        expectEqual(ClipboardPaste.text(from: board, savingImagesIn: folder).text, "hello", "text unchanged")

        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        board.clearContents()
        board.setData(image.tiffRepresentation!, forType: .tiff) // TIFF only, like some apps
        let pasted = ClipboardPaste.text(from: board, savingImagesIn: folder)
        expect(pasted.savedImage != nil, "image saved")
        if let saved = pasted.savedImage {
            expectEqual(pasted.text, ClipboardPaste.shellEscaped(saved.path), "pastes the saved path")
            expectEqual(saved.pathExtension, "png", "saved as PNG")
            let thumb = ClipboardPaste.thumbnail(of: saved, maxPixels: 20)
            expectEqual(thumb.map { max($0.width, $0.height) }, 20, "thumbnail capped at maxPixels")
        }

        board.clearContents()
        expectEqual(ClipboardPaste.text(from: board, savingImagesIn: folder).text, "", "empty clipboard")
    }

    test("image tokens: numbers and columns") {
        let line = "❯ what do you see: [Image #2] [Image #14]"
        expectEqual(ImageTokens.tokens(in: line).map(\.number), [2, 14], "both numbers")
        expectEqual(ImageTokens.tokens(in: line).first?.columns, 19...28, "columns of [Image #2]")
        expectEqual(ImageTokens.token(atColumn: 19, in: line)?.number, 2, "first column")
        expectEqual(ImageTokens.token(atColumn: 28, in: line)?.number, 2, "last column")
        expectEqual(ImageTokens.token(atColumn: 29, in: line)?.number, nil, "the gap")
        expectEqual(ImageTokens.token(atColumn: 31, in: line)?.number, 14, "second token")
        expectEqual(ImageTokens.tokens(in: "[Image #] [Image #x] [Image 3] [Image #5"), [], "malformed ignored")
        expectEqual(ImageTokens.numbers(in: "  └ [Image #2]\nnone\n[Image #4]"), [2, 4], "multi-line")
        expectEqual(ImageTokens.newNumber(before: [1, 2], after: [1, 2, 3]), 3, "next number")
        expectEqual(ImageTokens.newNumber(before: [1, 2, 3], after: [1, 2, 3, 1]), 1, "Codex restarts at #1")
        expectEqual(ImageTokens.newNumber(before: [1, 2], after: [2]), nil, "scrolled, nothing new")
    }

    test("shell words: quotes, escapes, whitespace") {
        expectEqual(ShellWords.split(""), [], "empty")
        expectEqual(ShellWords.split("  --model   opus "), ["--model", "opus"], "whitespace")
        expectEqual(ShellWords.split(#"--name "my agent" -c 'a b'"#), ["--name", "my agent", "-c", "a b"], "quotes group")
        expectEqual(ShellWords.split(#"a\ b "x\"y" ''"#), ["a b", #"x"y"#, ""], "escapes and empty quotes")
    }

    test("launch environment: inherited agent/terminal markers dropped") {
        expect(LaunchEnvironment.shouldKeep("HOME"), "HOME kept")
        expect(LaunchEnvironment.shouldKeep("LC_CTYPE"), "locale kept")
        expect(!LaunchEnvironment.shouldKeep("CLAUDE_CODE_CHILD_SESSION"), "claude child marker dropped")
        expect(!LaunchEnvironment.shouldKeep("CLAUDE_CODE_SESSION_ID"), "claude session id dropped")
        expect(!LaunchEnvironment.shouldKeep("TERM_PROGRAM"), "terminal identity dropped")
    }

    test("git info: branch, detached head, linked worktree") {
        let root = try temporaryDirectory()
        let repo = root.appendingPathComponent("repo")
        try write("ref: refs/heads/feature/x\n", to: repo.appendingPathComponent(".git/HEAD"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("sub/dir"), withIntermediateDirectories: true)
        expectEqual(GitInfo.read(directory: repo.appendingPathComponent("sub/dir").path),
                    GitInfo(branch: "feature/x", worktree: nil), "branch found from a subdirectory")

        let worktreeGitDir = repo.appendingPathComponent(".git/worktrees/wt1")
        try write("0123456789abcdef\n", to: worktreeGitDir.appendingPathComponent("HEAD"))
        let worktree = root.appendingPathComponent("wt1")
        try write("gitdir: \(worktreeGitDir.path)\n", to: worktree.appendingPathComponent(".git"))
        expectEqual(GitInfo.read(directory: worktree.path),
                    GitInfo(branch: "0123456", worktree: "wt1"), "worktree with detached head")

        expect(GitInfo.read(directory: "/") == nil, "no repo")
    }

    test("paths: legacy data folder moves once, never overwrites") {
        let base = try temporaryDirectory()
        let legacy = base.appendingPathComponent("AgentSessions")
        let current = base.appendingPathComponent("Simul")
        try write("old", to: legacy.appendingPathComponent("sessions.json"))

        let moved = current.appendingPathComponent("sessions.json")
        Paths.migrateLegacyData(from: legacy, to: current)
        expectEqual(try? String(contentsOf: moved, encoding: .utf8), "old", "data moved to the new folder")
        expect(!FileManager.default.fileExists(atPath: legacy.path), "legacy folder gone")

        try write("stale", to: legacy.appendingPathComponent("sessions.json"))
        Paths.migrateLegacyData(from: legacy, to: current)
        expectEqual(try? String(contentsOf: moved, encoding: .utf8), "old", "existing data never overwritten")
    }

    test("usage: claude cache parsing") {
        let dir = try temporaryDirectory()
        let claudeJSON = dir.appendingPathComponent("claude.json")
        try write("""
            {"cachedUsageUtilization": {"fetchedAtMs": 1000000, "utilization": {
              "five_hour": {"utilization": 12, "resets_at": null},
              "seven_day": {"utilization": 31, "resets_at": "2026-10-04T03:59:59.649894+00:00"}}}}
            """, to: claudeJSON)
        let claude = UsageLimits.claude(configFile: claudeJSON)
        expectEqual(claude?.windows.map(\.label), ["5h", "Week"], "claude windows")
        expectEqual(claude?.windows.map(\.percent), [12, 31], "claude percents")
        expect(claude?.windows[1].resetsAt != nil, "claude reset parsed (fractional seconds)")
        expectEqual(claude?.updatedAt, Date(timeIntervalSince1970: 1000), "claude fetched time")

    }

    test("usage: codex app-server live result") {
        let result: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1791658203],
            "secondary": ["usedPercent": 3.5, "windowDurationMins": 10080, "resetsAt": 1791658203],
        ]]
        let now = Date()
        let usage = UsageLimits.codexAppServer(result: result, fetchedAt: now)
        expectEqual(usage?.windows.map(\.label), ["5h", "Week"], "labels from window minutes")
        expectEqual(usage?.windows.map(\.percent), [12, 3.5], "percents")
        expectEqual(usage?.updatedAt, now, "stamped with fetch time")
        expect(UsageLimits.codexAppServer(result: [:], fetchedAt: now) == nil, "no rateLimits → nil")
    }

    test("conversations: claude transcript lookup by id") {
        let claudeDir = try temporaryDirectory()
        try write("{}\n", to: claudeDir.appendingPathComponent("projects/-Users-me-proj/abc.jsonl"))
        expect(AgentConversations.claudeTranscriptExists(id: "abc", claudeDir: claudeDir), "found")
        expect(!AgentConversations.claudeTranscriptExists(id: "other", claudeDir: claudeDir), "missing")
    }

    test("conversations: claude last reply for notifications") {
        let claudeDir = try temporaryDirectory()
        let lines = [
            #"{"type":"last-prompt","lastPrompt":"old prompt"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"old reply"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"fix the   failing\ntest"}"#,
            ###"{"type":"assistant","message":{"content":[{"type":"text","text":"## Done\n**Fixed** the `test`."}]}}"###,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#,
        ]
        try write(lines.joined(separator: "\n") + "\n", to: claudeDir.appendingPathComponent("projects/-p/abc.jsonl"))
        let reply = AgentConversations.claudeLastReply(id: "abc", claudeDir: claudeDir)
        expectEqual(reply, "Done Fixed the test.", "latest text reply, markdown stripped")

        let cut = AgentConversations.claudeLastReply(id: "abc", claudeDir: claudeDir, tailBytes: 150)
        expect(cut == nil || cut == "Done Fixed the test.", "partial first line ignored")

        expectEqual(AgentConversations.claudeLastReply(id: "nope", claudeDir: claudeDir), nil, "no transcript")
        expectEqual(AgentConversations.snippet(String(repeating: "a", count: 300), limit: 10), "aaaaaaaaa…", "truncated")
    }

    test("conversations: codex thread = first unclaimed in cwd since launch") {
        let codexDir = try temporaryDirectory()
        let db = codexDir.appendingPathComponent("state_5.sqlite").path
        let setup = """
            CREATE TABLE threads (id TEXT, cwd TEXT, created_at INTEGER, created_at_ms INTEGER,
                                  source TEXT, first_user_message TEXT);
            INSERT INTO threads VALUES ('old', '/p', 1, 1000, 'cli', 'hi');
            INSERT INTO threads VALUES ('other-dir', '/q', 5, 5000, 'cli', 'hi');
            INSERT INTO threads VALUES ('empty', '/p', 6, 6000, 'cli', '');
            INSERT INTO threads VALUES ('subagent', '/p', 6, 6500, '{"subagent":{}}', 'task');
            INSERT INTO threads VALUES ('claimed', '/p', 7, 7000, 'cli', 'hi');
            INSERT INTO threads VALUES ('mine', '/p', 8, 8000, 'cli', 'hi');
            """
        let created = await ProcessRunner.run("/usr/bin/sqlite3", arguments: [db, setup])
        expectEqual(created.exitCode, 0, "fixture db created")
        let id = await AgentConversations.codexThreadID(
            cwd: "/p", since: Date(timeIntervalSince1970: 2), excluding: ["claimed"], codexDir: codexDir)
        expectEqual(id, "mine", "picks the first unclaimed thread after launch")
        let none = await AgentConversations.codexThreadID(
            cwd: "/p", since: Date(timeIntervalSince1970: 9), excluding: [], codexDir: codexDir)
        expect(none == nil, "nothing after launch → nil (start fresh)")
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("as-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
