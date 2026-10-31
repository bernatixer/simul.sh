import Foundation
@testable import SimulCore

@MainActor
func registerAgentDraftsTests() {
    let files: [String: [String]] = ["a.swift": ["one", "two", "three", ""], "b.py": ["x"]]
    func lines(_ path: String) -> [String] { files[path] ?? [] }
    func json(_ s: String) -> Data { Data(s.utf8) }
    func found(_ s: String, existing: [ReviewComment] = []) throws -> (comments: [ReviewComment], rejected: [AgentDrafts.Rejected]) {
        AgentDrafts.comments(try AgentDrafts.parse(json(s)), diffPaths: ["a.swift", "b.py"], lines: lines, existing: existing)
    }
    func comments(_ s: String, existing: [ReviewComment] = []) throws -> [ReviewComment] {
        try found(s, existing: existing).comments
    }

    test("drafts: parse valid") {
        let c = try comments(#"{"version":1,"comments":[{"path":"a.swift","line":2,"endLine":3,"body":"Rename"},{"path":"b.py","line":1,"body":"Typo"}]}"#)
        expectEqual(c.count, 2, "two comments")
        expectEqual(c.map(\.path), ["a.swift", "b.py"], "paths")
        expectEqual(c.map(\.line), [2, 1], "lines")
        expectEqual(c.map(\.endLine), [3, 1], "endLine defaults to line")
        expectEqual(c.map(\.quote), ["two", "x"], "quote is the line's text")
        expectEqual(c.map(\.text), ["Rename", "Typo"], "bodies")
        expect(c.allSatisfy { $0.byAgent && $0.state == .queued && !$0.isOutdated }, "queued, by agent")
    }

    test("drafts: rejects bad version / missing fields") {
        await expectThrows("version 3") { _ = try AgentDrafts.parse(json(#"{"version":3,"comments":[]}"#)) }
        await expectThrows("version 1 without comments") { _ = try AgentDrafts.parse(json(#"{"version":1}"#)) }
        await expectThrows("no version") { _ = try AgentDrafts.parse(json(#"{"comments":[]}"#)) }
        await expectThrows("no comments array") { _ = try AgentDrafts.parse(json(#"{"version":1,"comments":{}}"#)) }
        let c = try comments(#"{"version":1,"comments":[{"line":1,"body":"no path"},{"path":"a.swift","body":"no line"},{"path":"a.swift","line":1},{"path":"a.swift","line":1,"body":"  "},{"path":"a.swift","line":0,"body":"zero"},{"path":"a.swift","line":2,"endLine":1,"body":"backwards"},"junk",{"path":"a.swift","line":1,"body":"ok"}]}"#)
        expectEqual(c.map(\.text), ["ok"], "invalid entries skipped one by one")
    }

    test("drafts: malformed JSON rejected whole") {
        do {
            _ = try AgentDrafts.parse(json(#"{"version":1,"comments":[{"path":"a.swift""#))
            expect(false, "should throw")
        } catch let problem as AgentDrafts.Problem {
            expectEqual(problem.message, "it isn't valid JSON", "message")
        }
    }

    test("drafts: drops lines outside the file") {
        let c = try comments(#"{"version":1,"comments":[{"path":"a.swift","line":3,"body":"last"},{"path":"a.swift","line":4,"body":"past the end (trailing newline)"},{"path":"a.swift","line":2,"endLine":9,"body":"range past the end"},{"path":"c.swift","line":1,"body":"not in the diff"}]}"#)
        expectEqual(c.map(\.text), ["last"], "only the line inside the file")
    }

    test("drafts: no duplicate import") {
        let text = #"{"version":1,"comments":[{"path":"a.swift","line":1,"body":"Same"},{"path":"a.swift","line":1,"body":"Same"},{"path":"a.swift","line":1,"endLine":2,"body":"Same"}]}"#
        let first = try comments(text)
        expectEqual(first.count, 2, "repeat in the file skipped; another range kept")
        let again = try comments(text, existing: first)
        expectEqual(again, [], "all already imported")
    }

    test("drafts: a new review replaces the agent's drafts not kept") {
        let first = try comments(#"{"version":1,"comments":[{"path":"a.swift","line":1,"body":"Old"},{"path":"a.swift","line":2,"body":"Kept"}]}"#)
        var kept = first[1]
        kept.byAgent = false
        let mine = ReviewComment(id: UUID(), path: "b.py", line: 1, endLine: 1, quote: "x", text: "Mine",
                                 state: .queued, isOutdated: false, createdAt: Date())
        let existing = [first[0], kept, mine]
        let again = try AgentDrafts.parse(json(#"{"version":1,"comments":[{"path":"a.swift","line":1,"body":"Old"},{"path":"a.swift","line":3,"body":"New"}]}"#))
        let replaced = AgentDrafts.imported(again, into: existing, replacing: true, diffPaths: ["a.swift", "b.py"], lines: lines).comments
        expectEqual(replaced.map(\.text), ["Kept", "Mine", "Old", "New"], "old draft replaced (a repeat comes back once); kept and mine stay")
        expect(!replaced.contains { $0.id == first[0].id }, "the old draft itself is gone")
        let added = AgentDrafts.imported(again, into: existing, replacing: false, diffPaths: ["a.swift", "b.py"], lines: lines).comments
        expectEqual(added.map(\.text), ["Old", "Kept", "Mine", "New"], "a fix adds to the drafts")
        let none = try AgentDrafts.parse(json(#"{"version":1,"comments":[{"path":"c.swift","line":1,"body":"elsewhere"}]}"#))
        let unchanged = AgentDrafts.imported(none, into: existing, replacing: true, diffPaths: ["a.swift", "b.py"], lines: lines)
        expectEqual(unchanged.comments, existing, "nothing valid in: the drafts stay")
        expectEqual(unchanged.rejected.count, 1, "and the bad one is rejected")
    }

    test("drafts: file per session and source") {
        let id = UUID()
        let a = AgentDrafts.file(session: id, source: .sessionFolder)
        expectEqual(a, AgentDrafts.file(session: id, source: .sessionFolder), "stable")
        expect(a != AgentDrafts.file(session: id, source: .folder("/x")), "differs by source")
        expect(a.lastPathComponent.hasPrefix(id.uuidString + "-"), "named by session")
        expectEqual(a.deletingLastPathComponent().lastPathComponent, "drafts", "in drafts/")
    }

    test("drafts: wrong types and paths outside the diff skipped") {
        let c = try comments(#"{"version":1,"comments":[{"path":"a.swift","line":"3","body":"string line"},{"path":"a.swift","line":1,"endLine":"2","body":"string endLine"},{"path":"../x","line":1,"body":"up"},{"path":"/abs/a.swift","line":1,"body":"absolute"},{"path":"./a.swift","line":1,"body":"dot"},{"path":"a.swift","line":1,"body":"ok"}]}"#)
        expectEqual(c.map(\.text), ["ok"], "only the valid one")
    }

    test("drafts: rejected entries kept with reasons") {
        let r = try found(#"{"version":1,"comments":[{"path":"a.swift","line":1,"body":"ok"},{"path":"a.swift","line":9,"body":"far","extra":true},{"path":"c.swift","line":1,"body":"elsewhere"},7]}"#)
        expectEqual(r.comments.map(\.text), ["ok"], "valid one imported")
        expectEqual(r.rejected.map(\.reason), ["a.swift:9: the file has 3 lines", "c.swift:1: not a file in the diff",
                                               "comment 4: \"path\" is missing"], "reasons")
        // Written back as the agent wrote them, and it parses again to the same entries.
        let kept = try AgentDrafts.parse(AgentDrafts.file(keeping: r.rejected))
        expectEqual(kept, r.rejected.map(\.entry), "kept round-trips")
        expectEqual(kept[0].raw, #"{"body":"far","extra":true,"line":9,"path":"a.swift"}"#, "unknown keys kept")
    }

    test("drafts: all valid, nothing kept") {
        let r = try found(#"{"version":1,"comments":[{"path":"a.swift","line":1,"body":"ok"},{"path":"a.swift","line":1,"body":"ok"}]}"#)
        expectEqual(r.comments.count, 1, "imported (repeat skipped)")
        expectEqual(r.rejected, [], "nothing rejected: a duplicate isn't")
    }

    test("drafts: long bodies rejected") {
        let long = String(repeating: "x", count: AgentDrafts.maxBody + 1)
        let fits = String(repeating: "y", count: AgentDrafts.maxBody)
        let r = try found(#"{"version":1,"comments":[{"path":"a.swift","line":1,"body":"\#(long)"},{"path":"a.swift","line":2,"body":"\#(fits)"}]}"#)
        expectEqual(r.comments.map(\.line), [2], "the one that fits is imported")
        expectEqual(r.rejected.count, 1, "the long one is rejected")
        expect(r.rejected.first?.reason.contains("over 600 characters") == true, "says why")
    }

    test("drafts: a deleted session's files are removed") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gone = UUID(), kept = UUID()
        for name in ["\(gone.uuidString)-a.json", "\(gone.uuidString)-b.json", "\(kept.uuidString)-a.json"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        AgentDrafts.removeFiles(session: gone, in: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        expectEqual(left, ["\(kept.uuidString)-a.json"], "only the other session's left")
    }
}
