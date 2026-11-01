import Foundation
@testable import SimulCore

@MainActor
func registerWorkflowTests() {
    test("workflows: built-in templates are valid and round-trip through JSON") {
        for workflow in WorkflowTemplates.all {
            expectEqual(workflow.validate(), [], "\(workflow.id) is valid")
            let data = try JSONEncoder().encode(workflow)
            let decoded = try JSONDecoder().decode(Workflow.self, from: data)
            expectEqual(decoded, workflow, "\(workflow.id) round-trips")
        }
        expectEqual(Set(WorkflowTemplates.all.map(\.id)).count, WorkflowTemplates.all.count, "unique ids")
    }

    test("workflows: a hand-written file may leave out empty parts; problems name the stage") {
        let json = #"{"id":"mine","name":"Mine","loop":{"stages":[{"kind":"check","title":"Tests"},{"kind":"agent","title":"Go","prompt":"Do {nope}"}],"maxRounds":"2"}}"#
        let workflow = try JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
        expectEqual(workflow.before, [], "before defaults to empty")
        expectEqual(workflow.validate(), ["loop[0] Tests: command missing", "loop[1] Go: {nope} isn't an input"], "problems")
        let bad = Workflow(id: "a b", name: "", summary: "", loop: .init(stages: [], maxRounds: "0"))
        expectEqual(bad.validate(), ["id: use letters, digits, - and _ only", "name: missing", "no stages",
                                     "loop: no stages", "loop.maxRounds: a number of at least 1, or {input}"], "empty workflow")
        expect(WorkflowLibrary.describe(DecodingError.keyNotFound(Workflow.CodingKeys.name,
            .init(codingPath: [], debugDescription: ""))) == "name: missing", "decoding error in words")
    }

    test("workflows: filling in values, references and on/off") {
        expectEqual(WorkflowText.fill("Merge {pr} with {merge} {unknown} {", ["pr": "#3", "merge": "gh pr merge"]),
                    "Merge #3 with gh pr merge {unknown} {", "fill")
        expectEqual(WorkflowText.references("a {b} {c d} {e_1} {}"), ["b", "e_1"], "references")
        expect(WorkflowText.isOn("true") && WorkflowText.isOn("npm test") && WorkflowText.isOn("2"), "on")
        expect(!WorkflowText.isOn("0") && !WorkflowText.isOn(" false ") && !WorkflowText.isOn("") && !WorkflowText.isOn(nil), "off")
        expectEqual(WorkflowText.number("{n}", ["n": "4"]), 4, "number from an input")
    }

    test("workflows: positions walk before, loop, after") {
        let w = WorkflowTemplates.ship
        expectEqual(w.first(from: .before), StagePosition(part: .loop, index: 0), "no before: starts in the loop")
        expectEqual(w.allPositions.count, 11, "every stage")
        let run = WorkflowRun(workflow: w, sessionID: UUID(), folder: "/r", inputs: ["maxRounds": "4"])
        expectEqual(run.round, 1, "starting in the loop is round 1")
        expectEqual(run.maxRounds, 4, "max rounds from the input")
        expect(w.usesPullRequest && !WorkflowTemplates.reviewAndFix.usesPullRequest, "which need a PR")
    }

    test("ledger: reviews add, keep, verify and notice a finding coming back") {
        func item(_ title: String, _ path: String?, _ line: Int?, _ sev: Finding.Severity = .medium, id: String? = nil) -> ReviewerReport.Item {
            ReviewerReport.Item(id: id, severity: sev, title: title, detail: "", path: path, line: line)
        }
        // Round 1: two reviewers find the same thing near the same line, and one more.
        var m = FindingLedger.mergeReviews([], reports: [
            ("Claude", ReviewerReport(findings: [item("Retry swallows timeout errors", "a.py", 10, .high)], resolved: [])),
            ("Codex", ReviewerReport(findings: [item("Timeout errors are swallowed by retry", "a.py", 12),
                                                item("No test for empty input", nil, nil, .low)], resolved: [])),
        ], round: 1)
        expectEqual(m.findings.map(\.id), ["F1", "F2"], "duplicates merged")
        expectEqual(m.findings[0].sources, ["Claude", "Codex"], "both sources")
        expectEqual(m.findings[0].severity, .high, "highest severity kept")
        expectEqual(m.new, 2, "two new")

        // Fixed, then round 2: F1 confirmed fixed, F2 raised again by id.
        var f = FindingLedger.set(m.findings, ["F1", "F2"], status: .fixed)
        m = FindingLedger.mergeReviews(f, reports: [
            ("Claude", ReviewerReport(findings: [item("Still no test for empty input", nil, nil, .low, id: "F2")], resolved: ["F1"])),
        ], round: 2)
        expectEqual(m.findings.map(\.status), [.verified, .open], "F1 verified, F2 still open")
        expectEqual(m.findings[0].note, "Confirmed fixed by Claude", "who confirmed")
        expectEqual(m.findings[1].note, "Still there after the fix", "still there")
        expectEqual(m.still, 1, "one still there")

        // Round 3: F1's problem is back.
        f = m.findings
        m = FindingLedger.mergeReviews(f, reports: [("Codex", ReviewerReport(findings: [item("Retry swallows timeout errors again", "a.py", 11)], resolved: []))], round: 3)
        expectEqual(m.cameBack, ["F1"], "came back")
        expect(m.findings[0].cameBack && m.findings[0].status == .open, "reopened and marked")
        expectEqual(m.findings[1].status, .verified, "F2 not raised: verified")
        expectEqual(m.findings[1].note, "Not found again", "why verified")
    }

    test("ledger: two problems in one report stay two; common words don't make a match") {
        let items = [ReviewerReport.Item(id: nil, severity: .high, title: "Token is logged when the request fails", detail: "", path: "a.py", line: 10),
                     ReviewerReport.Item(id: nil, severity: .low, title: "Retry count is off by one", detail: "", path: "a.py", line: 11)]
        let m = FindingLedger.mergeReviews([], reports: [("Claude", ReviewerReport(findings: items, resolved: []))], round: 1)
        expectEqual(m.findings.count, 2, "both kept")
        expect(FindingLedger.titleSimilarity("Fails when the input is empty", "Leaks when the cache is full") == 0, "stopwords ignored")
    }

    test("ledger: a skipped finding stays skipped; no reports changes nothing") {
        let f = [Finding(id: "F1", key: nil, sources: ["Claude"], severity: .low, title: "Name is unclear", detail: "",
                         path: "a.py", line: 3, status: .skipped, raisedRound: 1, updatedRound: 1)]
        let m = FindingLedger.mergeReviews(f, reports: [("Claude", ReviewerReport(findings: [
            ReviewerReport.Item(id: nil, severity: .low, title: "Name is unclear", detail: "", path: "a.py", line: 3)], resolved: []))], round: 2)
        expectEqual(m.findings.map(\.status), [.skipped], "still skipped")
        expectEqual(FindingLedger.mergeReviews(f, reports: [], round: 2).findings, f, "no reports")
        expectEqual(FindingLedger.nextID(f), "F2", "next id")
    }

    test("ledger: with a reviewer missing, silence doesn't verify; outdated threads aren't resolved") {
        let f = [Finding(id: "F1", key: nil, sources: ["Codex"], severity: .high, title: "Leaks the token", detail: "",
                         path: "a.py", line: 9, status: .fixed, raisedRound: 1, updatedRound: 1)]
        let partial = FindingLedger.mergeReviews(f, reports: [("Claude", ReviewerReport(findings: [], resolved: []))], round: 2,
                                                 verifyUnmentioned: false)
        expectEqual(partial.findings[0].status, .fixed, "still to verify")
        let confirmed = FindingLedger.mergeReviews(f, reports: [("Claude", ReviewerReport(findings: [], resolved: ["F1"]))], round: 2,
                                                   verifyUnmentioned: false)
        expectEqual(confirmed.findings[0].status, .verified, "confirmed by id")
        let thread = ReviewThread(id: "T1", isResolved: false, isOutdated: false, path: "a.py", line: 3, author: "@ana",
                                  authorIsBot: false, body: "Why?", url: nil)
        var m = FindingLedger.mergeFeedback([], failing: [], threads: [thread], round: 1)
        var outdated = thread
        outdated.isOutdated = true
        m = FindingLedger.mergeFeedback(m.findings, failing: [], threads: [outdated], round: 2)
        expectEqual(m.findings.map(\.status), [.yours], "an outdated thread is still open")
        outdated.isResolved = true
        m = FindingLedger.mergeFeedback(m.findings, failing: [], threads: [outdated], round: 3)
        expectEqual(m.findings.map(\.status), [.verified], "resolved")
        let fresh = FindingLedger.mergeFeedback([], failing: [], threads: [ReviewThread(id: "T2", isResolved: false, isOutdated: true,
            path: nil, line: nil, author: "bot", authorIsBot: true, body: "x", url: nil)], round: 1)
        expectEqual(fresh.findings.count, 0, "a new outdated thread isn't added")
    }

    test("ledger: checks fail as one finding and pass as verified") {
        var f = FindingLedger.mergeCheck([], command: "npm test", passed: false, output: "1 failing", round: 1)
        expectEqual(f.map(\.title), ["`npm test` fails"], "one finding")
        expectEqual(f[0].severity, .high, "high")
        f = FindingLedger.mergeCheck(FindingLedger.set(f, ["F1"], status: .fixed), command: "npm test", passed: false, output: "2 failing", round: 1)
        expectEqual(f.count, 1, "same finding")
        expectEqual(f[0].status, .open, "open again")
        expectEqual(f[0].detail, "2 failing", "latest output")
        f = FindingLedger.mergeCheck(f, command: "npm test", passed: true, output: "", round: 2)
        expectEqual(f[0].status, .verified, "passes now")
    }

    test("ledger: PR feedback: CI and bot threads for the agent, people's for you") {
        let failing = [PullRequestStatus.Check(name: "lint", state: .failed, url: "https://ci/1")]
        let threads = [
            ReviewThread(id: "T1", isResolved: false, isOutdated: false, path: "a.py", line: 4, author: "lintbot[bot]",
                         authorIsBot: true, body: "**Unused import**\nRemove it.", url: "https://gh/t1"),
            ReviewThread(id: "T2", isResolved: false, isOutdated: false, path: nil, line: nil, author: "@ana",
                         authorIsBot: false, body: "Should this be behind a flag?", url: nil),
            ReviewThread(id: "T3", isResolved: true, isOutdated: false, path: nil, line: nil, author: "@bo",
                         authorIsBot: false, body: "nit", url: nil),
        ]
        var m = FindingLedger.mergeFeedback([], failing: failing, threads: threads, round: 1)
        expectEqual(m.findings.map(\.title), ["CI: lint fails", "Unused import", "Should this be behind a flag?"], "titles")
        expectEqual(m.findings.map(\.status), [.open, .open, .yours], "people's comments are yours")
        expectEqual(m.people, ["F3"], "new people comments")
        // Next push: lint passes, the bot thread is resolved.
        m = FindingLedger.mergeFeedback(FindingLedger.set(m.findings, ["F1", "F2"], status: .fixed), failing: [],
                                        threads: [threads[1]], round: 2)
        expectEqual(m.findings.map(\.status), [.verified, .verified, .yours], "verified")
        expectEqual(m.people, [], "nothing new")
    }

    test("ledger: selecting what to fix and what blocks") {
        let f = [("F1", Finding.Severity.high, Finding.Status.open), ("F2", .low, .open), ("F3", .medium, .verified), ("F4", .medium, .yours)]
            .map { Finding(id: $0.0, key: nil, sources: [], severity: $0.1, title: $0.0, detail: "", status: $0.2, raisedRound: 1, updatedRound: 1) }
        let s = FindingLedger.select(f, atLeast: .medium)
        expectEqual(s.auto, ["F1"], "fixed without asking")
        expectEqual(s.lower, ["F2"], "asked about")
        expectEqual(FindingLedger.blocking(f, atLeast: .medium).map(\.id), ["F1"], "blocking")
    }

    test("reports: reviewer files are read leniently and safely") {
        let json = #"{"findings":[{"severity":"HIGH","title":" Bad ","detail":"x","path":"./src/a.py","line":"7"},{"title":""},{"title":"Up","path":"../etc/passwd"},{"title":"Odd","severity":"urgent"}],"resolved":["F1",2]}"#
        let r = try ReviewerReport.parse(Data(json.utf8))
        expectEqual(r.findings.map(\.title), ["Bad", "Up", "Odd"], "untitled dropped")
        expectEqual(r.findings[0].severity, .high, "severity, any case")
        expectEqual(r.findings[0].path, "src/a.py", "./ stripped")
        expectEqual(r.findings[0].line, 7, "line as text")
        expectEqual(r.findings[1].path, nil, "outside path dropped")
        expectEqual(r.findings[2].severity, .medium, "unknown severity is medium")
        expectEqual(r.resolved, ["F1"], "resolved ids")
        await expectThrows("not an object") { _ = try ReviewerReport.parse(Data("[]".utf8)) }
        await expectThrows("no findings list") { _ = try ReviewerReport.parse(Data(#"{"resolved":[]}"#.utf8)) }
        let verify = try VerifyReport.parse(Data(#"{"status":"problem","summary":"500s"}"#.utf8))
        expectEqual(verify, VerifyReport(ok: false, summary: "500s"), "verify")
        await expectThrows("verify status") { _ = try VerifyReport.parse(Data(#"{"status":"maybe"}"#.utf8)) }
    }

    test("github: PR status from gh, checks in every state") {
        let json = #"""
        {"number":12,"url":"https://github.com/octo/widgets/pull/12","state":"OPEN","isDraft":true,"headRefOid":"abc","baseRefName":"main",
         "reviewDecision":"REVIEW_REQUIRED","mergeCommit":null,"statusCheckRollup":[
          {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci/t"},
          {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":""},
          {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"},
          {"__typename":"StatusContext","context":"deploy","state":"SUCCESS","targetUrl":"https://d"}]}
        """#
        let s = try PullRequestStatus.decode(ghJSON: Data(json.utf8))
        expectEqual(s.checks.map(\.state), [.failed, .pending, .skipped, .passed], "states, re-runs once")
        expect(!s.checksFinished, "lint still running")
        expectEqual(s.failing.map(\.name), ["test"], "failing")
        expect(!s.approved, "review required")
        expectEqual(s.repo, "octo/widgets", "repo from url")
        expectEqual(s.baseRef, "main", "base")
        var t = s
        t.reviewDecision = nil
        expect(t.approved, "nothing requires approval")
    }

    test("github: review threads from GraphQL") {
        let json = #"""
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
          {"id":"T1","isResolved":false,"isOutdated":false,"path":"a.py","line":3,"comments":{"nodes":[{"body":"Fix","url":"u","author":{"login":"ana","__typename":"User"}}]}},
          {"id":"T2","isResolved":false,"isOutdated":true,"path":null,"line":null,"comments":{"nodes":[{"body":"Hm","url":"v","author":{"login":"lint","__typename":"Bot"}}]}},
          {"id":"T3","isResolved":false,"isOutdated":false,"comments":{"nodes":[]}}]}}}}}
        """#
        let t = try ReviewThread.decode(graphQL: Data(json.utf8))
        expectEqual(t.map(\.author), ["@ana", "lint"], "authors; empty thread dropped")
        expectEqual(t.map(\.authorIsBot), [false, true], "bots")
        expect(t[1].isOutdated, "outdated")
        await expectThrows("API error") { _ = try ReviewThread.decode(graphQL: Data(#"{"errors":[]}"#.utf8)) }
    }

    test("fix guard: notices weakened tests") {
        let diff = """
            diff --git a/src/app.py b/src/app.py
            +x = 1
            diff --git a/tests/test_app.py b/tests/test_app.py
            -    assert x == 1
            -    assert y == 2
            +    assert x
            +@pytest.mark.skip
            diff --git a/web/button.test.ts b/web/button.test.ts
            deleted file mode 100644
            -expect(a).toBe(1)
            """
        let r = FixGuard.check(diff: diff)
        expectEqual(r.files, ["src/app.py", "tests/test_app.py", "web/button.test.ts"], "files")
        expectEqual(r.testWarnings, ["skips or focuses tests in tests/test_app.py", "removes 1 assertion in tests/test_app.py",
                                     "deletes web/button.test.ts", "removes 1 assertion in web/button.test.ts"], "warnings")
        expect(FixGuard.isTest("Tests/WorkflowTests.swift") && !FixGuard.isTest("src/contest.py"), "test paths")
    }

    test("prompts: the fix prompt lists findings with places and the rules") {
        let f = Finding(id: "F2", key: nil, sources: ["CI"], severity: .high, title: "CI: lint fails", detail: "line one\nline two",
                        path: "a.py", line: 3, url: "https://ci", raisedRound: 1, updatedRound: 1)
        let text = WorkflowPrompt.fix([f], folder: "/r")
        expect(text.contains("1. F2 [high] CI: lint fails (a.py:3)\n   line one\n   line two\n   https://ci"), "item")
        expect(text.contains("Never delete, skip or weaken a test"), "rule")
        let review = WorkflowPrompt.review(what: "the change", folder: "/r", point: "abc", since: "def", previous: [f],
                                           instructions: " Be brief ", file: "/tmp/r.json")
        expect(review.contains("`git diff def`") && review.contains("- F2 [high] CI: lint fails (a.py:3)") && review.contains("\n\nBe brief"), "review prompt")
        let untrusted = WorkflowPrompt.review(what: "pull request #4", folder: "/wt", point: "abc", since: "def", previous: [],
                                              instructions: nil, file: "/r.json", diffs: .init(change: "/d.diff", since: "/s.diff"))
        expect(untrusted.contains("`/d.diff`") && untrusted.contains("`/s.diff`") && untrusted.contains("don't run commands")
               && !untrusted.contains("git diff"), "untrusted: diffs from files, no commands")
    }

    test("tools: a command's leftover child doesn't hold it up; a slow one times out") {
        let tools = WorkflowTools(shell: "/bin/zsh", gh: nil, environment: [:])
        let started = Date()
        let quick = await tools.runShell("(sleep 20 &); echo hi; echo oops >&2; exit 3", in: "/tmp", timeout: 10)
        expect(Date().timeIntervalSince(started) < 5, "didn't wait for the background child")
        expectEqual(quick.exitCode, 3, "exit code")
        expectEqual(quick.output, "hi\noops", "stdout and stderr together")
        let slow = await tools.runShell("sleep 20", in: "/tmp", timeout: 1)
        expect(slow.timedOut && Date().timeIntervalSince(started) < 10, "timed out")
    }

    test("runs: a run round-trips through the store") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RunStore(fileURL: dir.appendingPathComponent("runs.json"), backupURL: dir.appendingPathComponent("runs.json.prev"))
        var run = WorkflowRun(workflow: WorkflowTemplates.reviewAndFix, sessionID: UUID(), folder: "/r", inputs: ["checks": "make"])
        run.log("Started")
        run.ask = Ask(kind: .confirm, title: "Go?", detail: "", actions: [.continue, .stop])
        store.save([run])
        store.save([run])
        let loaded = store.load()
        expectEqual(loaded.count, 1, "one run")
        expectEqual(loaded.first?.workflow, run.workflow, "workflow")
        expectEqual(loaded.first?.ask, run.ask, "ask")
        expectEqual(loaded.first?.events.map(\.text), ["Started"], "events")
        let library = dir.appendingPathComponent("workflows")
        // An older file without later fields still loads.
        let old = #"{"version":1,"runs":[{"id":"\#(UUID().uuidString)","sessionID":"\#(UUID().uuidString)","workflow":{"id":"x","name":"X","loop":{"stages":[{"kind":"fix","title":"Fix"}],"maxRounds":"2"}},"findings":[{"id":"F1","title":"t"}],"stage":{"reviewers":[{"agentID":"claude","sessionID":"\#(UUID().uuidString)"}]}}]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("runs.json"))
        let lenient = store.load()
        expectEqual(lenient.first?.findings.first?.severity, .medium, "missing fields take defaults")
        expectEqual(lenient.first?.stage.reviewers.first?.state, .failed, "a reviewer of unknown state isn't waited on")
        let saved = try WorkflowLibrary.save(WorkflowTemplates.ship, to: library)
        expectEqual(saved.lastPathComponent, "ship-change.json", "saved by id")
        let entries = WorkflowLibrary.load(from: library)
        expectEqual(entries.first?.problems, ["id ship-change is a built-in workflow's; give it another"], "built-in id taken")
        var mine = WorkflowTemplates.reviewAndFix
        mine.id = "mine"
        _ = try WorkflowLibrary.save(mine, to: library)
        let second = try WorkflowLibrary.save(mine, to: library)
        expectEqual(second.lastPathComponent, "mine-2.json", "a second copy gets its own file")
        expectEqual(WorkflowLibrary.load(from: library).compactMap(\.workflow?.id).sorted(), ["mine", "mine-2", "ship-change"], "and its own id")
        // Editing: saved over its file; a new id renames it, never over another.
        var edited = mine
        edited.name = "Mine, edited"
        let same = try WorkflowLibrary.write(edited, replacing: library.appendingPathComponent("mine.json"), to: library)
        expectEqual(same.lastPathComponent, "mine.json", "same file")
        edited.id = "renamed"
        let renamed = try WorkflowLibrary.write(edited, replacing: same, to: library)
        expectEqual(renamed.lastPathComponent, "renamed.json", "renamed")
        expect(!FileManager.default.fileExists(atPath: same.path), "old file gone")
        edited.id = "mine-2"
        await expectThrows("won't overwrite another") { _ = try WorkflowLibrary.write(edited, replacing: renamed, to: library) }
    }
}
