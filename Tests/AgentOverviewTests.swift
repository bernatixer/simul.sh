import Foundation
@testable import SimulCore

@MainActor
func registerAgentOverviewTests() {
    // x.py is in the diff (120 lines), lib.py isn't (50 lines).
    let counts = ["posthog/x.py": 120, "posthog/lib.py": 50]
    let example = #"""
    {"version":2,
     "summary":"Final misses now split by source: live ones alert, backfill ones fail quietly.",
     "map":{
       "lanes":[{"id":"wf","label":"Workflows"}],
       "parts":[{"id":"hydrate","lane":"wf","label":"hydrate_event_reference","note":"picks error class",
                 "state":"changed","path":"posthog/x.py","line":91},
                {"id":"live","lane":"wf","label":"live_ingest","state":"untouched","path":"posthog/lib.py","line":7}],
       "edges":[{"from":"live","to":"hydrate","state":"untouched","label":"retry ×3"}]},
     "concerns":[{"severity":"high","title":"Backfill misses go dark",
                  "why":"Nothing logs them now, so a broken lookup looks like expired rows.",
                  "at":[{"path":"posthog/x.py","line":99}],"parts":["hydrate"]}],
     "tour":[{"title":"One raise, two outcomes","text":"Read this first.","focus":["hydrate"],"path":"posthog/x.py","line":99}],
     "comments":[{"path":"posthog/x.py","line":12,"endLine":14,"body":"Log it."}],
     "extra":"ignored"}
    """#
    func root(_ s: String) -> [String: Any] {
        (try? AgentDrafts.parseFile(Data(s.utf8)))?.overview ?? [:]
    }
    func validate(_ s: String) -> Result<AgentOverview, AgentOverview.Invalid> {
        AgentOverview.validate(json: root(s), diffPaths: ["posthog/x.py"], lineCount: { counts[$0] })
    }
    func reasons(_ s: String) -> [String] {
        if case let .failure(r) = validate(s) { return r.reasons }
        return []
    }
    /// The example with `old` replaced by `new`.
    func edited(_ old: String, _ new: String) -> String {
        precondition(example.contains(old), old)
        return example.replacingOccurrences(of: old, with: new)
    }

    test("overview: parses the example") {
        guard case let .success(o) = validate(example) else { return expect(false, "valid") }
        expectEqual(o.summary.prefix(11), "Final misse", "summary")
        expectEqual(o.lanes, [.init(id: "wf", label: "Workflows")], "lanes")
        expectEqual(o.parts.map(\.id), ["hydrate", "live"], "parts")
        expectEqual(o.parts[0].anchor, .init(path: "posthog/x.py", line: 91), "part anchor")
        expectEqual(o.parts[1].anchor, .init(path: "posthog/lib.py", line: 7), "untouched part outside the diff")
        expectEqual(o.edges, [.init(from: "live", to: "hydrate", state: .untouched, label: "retry ×3")], "edges")
        expectEqual(o.concerns.map(\.severity), [.high], "concerns")
        expectEqual(o.tour.first?.focus, ["hydrate"], "tour")
        expectEqual(AgentOverview.anchorPaths(in: root(example)), ["posthog/x.py", "posthog/lib.py"], "paths to read")
        let entries = try AgentDrafts.parse(Data(example.utf8))
        expectEqual(entries.map(\.body), ["Log it."], "comments parse as in version 1")
    }

    test("overview: version 1 has none; version 2 needs a summary") {
        let v1 = try AgentDrafts.parseFile(Data(#"{"version":1,"comments":[],"summary":"x"}"#.utf8))
        expect(v1.overview == nil, "no overview in version 1")
        let v2 = try AgentDrafts.parseFile(Data(#"{"version":2,"summary":"Just this."}"#.utf8))
        expectEqual(v2.entries, [], "comments may be left out")
        expectEqual(reasons(#"{"version":2,"summary":"Just this."}"#), [], "map, concerns and tour are optional")
        expectEqual(reasons(#"{"version":2,"tour":[]}"#), ["summary: missing"], "summary required")
        let bare = try AgentDrafts.parseFile(Data(#"{"version":2,"comments":[]}"#.utf8))
        expect(bare.overview == nil, "nothing but comments: no overview, not a missing summary")
    }

    test("overview: unknown ids and duplicates rejected with the id") {
        expectEqual(reasons(edited(#""from":"live""#, #""from":"x""#)), [#"map.edges[0]: unknown part "x""#], "edge")
        expectEqual(reasons(edited(#""lane":"wf","label":"live_ingest""#, #""lane":"q","label":"live_ingest""#)),
                    [#"map.parts[1]: unknown lane "q""#, #"map.edges[0]: unknown part "live""#], "lane (and its edge)")
        expectEqual(reasons(edited(#""focus":["hydrate"]"#, #""focus":["hydrate","nope"]"#)), [#"tour[0]: unknown part "nope""#], "focus")
        expectEqual(reasons(edited(#""parts":["hydrate"]"#, #""parts":["gone"]"#)), [#"concerns[0]: unknown part "gone""#], "concern parts")
        expectEqual(reasons(edited(#""id":"live""#, #""id":"hydrate""#)), [#"map.parts[1]: duplicate id "hydrate""#,
                                                                              #"map.edges[0]: unknown part "live""#], "duplicate id")
    }

    test("overview: anchors outside the diff only for untouched parts") {
        expectEqual(reasons(edited(#""state":"untouched","path""#, #""state":"changed","path""#)),
                    [#"map.parts[1].path: "posthog/lib.py" is not a file in the diff"#], "changed part outside the diff")
        expectEqual(reasons(edited(#""at":[{"path":"posthog/x.py""#, #""at":[{"path":"posthog/lib.py""#)),
                    [#"concerns[0].at[0].path: "posthog/lib.py" is not a file in the diff"#], "concern outside the diff")
        expectEqual(reasons(edited(#""path":"posthog/lib.py""#, #""path":"posthog/nope.py""#)),
                    [#"map.parts[1].path: no file "posthog/nope.py""#], "untouched part, missing file")
        expectEqual(reasons(edited(#""path":"posthog/lib.py""#, #""path":"../etc/passwd""#)),
                    ["map.parts[1].path: must be a path relative to the source root"], "can't leave the root")
        expectEqual(reasons(edited(#""at":[{"path":"posthog/x.py","line":99}]"#, #""at":[{}]"#)),
                    [#"concerns[0].at[0]: needs "path" and "line""#], "a concern anchor needs both")
    }

    test("overview: reads outside the diff only for untouched parts, within limits") {
        expectEqual(AgentOverview.outsidePaths(in: root(example)), ["posthog/lib.py"], "untouched part")
        expectEqual(AgentOverview.outsidePaths(in: root(edited(#""state":"untouched","path""#, #""state":"changed","path""#))), [],
                    "changed parts aren't read outside the diff")
        let many = (1...25).map { #"{"id":"p\#($0)","lane":"wf","label":"P","state":"untouched","path":"f\#($0).py","line":1}"# }
        let over = root(#"{"version":2,"summary":"s","map":{"parts":[\#(many.joined(separator: ","))]}}"#)
        expectEqual(AgentOverview.outsidePaths(in: over), [], "over maxParts: nothing read")
        let four = (1...4).map { #"{"path":"a\#($0).py","line":1}"# }.joined(separator: ",")
        let at = root(#"{"version":2,"summary":"s","concerns":[{"severity":"low","title":"t","why":"w","at":[\#(four)]}]}"#)
        expectEqual(AgentOverview.anchorPaths(in: at), [], "over 3 anchors in a concern: none gathered")
    }

    test("overview: fileLines stays in the root, on small regular files") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("simul-lines-\(UUID().uuidString)").path
        let outside = dir + "-outside"
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "a\nb".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        try "secret".write(toFile: outside + "/s.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.txt", withDestinationPath: outside + "/s.txt")
        try FileManager.default.createSymbolicLink(atPath: dir + "/in.txt", withDestinationPath: dir + "/f.txt")
        let git = ReviewGit(git: "/usr/bin/git", gh: nil, environment: [:])
        func lines(_ path: String, maxBytes: Int = 2 << 20) async -> [String] { await git.fileLines(root: dir, path: path, maxBytes: maxBytes) }
        let plain = await lines("f.txt"), inside = await lines("in.txt"), out = await lines("link.txt")
        let folder = await lines("sub"), big = await lines("f.txt", maxBytes: 2)
        expectEqual(plain, ["a", "b"], "plain file")
        expectEqual(inside, ["a", "b"], "symlink inside the root")
        expectEqual(out, [], "symlink out of the root")
        expectEqual(folder, [], "a folder")
        expectEqual(big, [], "over the size cap")
    }

    test("overview: lines out of range rejected") {
        expectEqual(reasons(edited(#""line":91"#, #""line":121"#)), ["map.parts[0].line: 121 is past the end of posthog/x.py (120 lines)"], "past the end")
        expectEqual(reasons(edited(#""line":91"#, #""line":0"#)), ["map.parts[0].line: must be a line number"], "zero")
        expectEqual(reasons(edited(#""line":91"#, #""line":"91""#)), ["map.parts[0].line: must be a line number"], "string")
        expectEqual(reasons(edited(#""line":7"#, #""line":51"#)), ["map.parts[1].line: 51 is past the end of posthog/lib.py (50 lines)"], "outside file too")
    }

    test("overview: limits") {
        let long = String(repeating: "x", count: AgentOverview.maxSummary + 1)
        expectEqual(reasons(edited(#""summary":"Final misses now split by source: live ones alert, backfill ones fail quietly.""#, #""summary":"\#(long)""#)),
                    ["summary: over 280 characters"], "summary")
        expectEqual(reasons(edited(#""label":"retry ×3""#, #""label":"\#(String(repeating: "y", count: 25))""#)),
                    ["map.edges[0].label: over 24 characters"], "edge label")
        let lanes = (1...6).map { #"{"id":"l\#($0)","label":"L"}"# }.joined(separator: ",")
        expect(reasons(edited(#""lanes":[{"id":"wf","label":"Workflows"}]"#, #""lanes":[\#(lanes)]"#))
            .contains("map.lanes: at most 5 allowed, found 6"), "lanes")
        expectEqual(reasons(edited(#""lanes":[{"id":"wf","label":"Workflows"}]"#, #""lanes":[]"#)).first,
                    "map.lanes: needs at least one lane", "at least one lane")
        expectEqual(reasons(edited(#""lanes":[{"id":"wf","label":"Workflows"}]"#, #""lanes":[\#(lanes)]"#)),
                    ["map.lanes: at most 5 allowed, found 6"], "over the limit: no unknown-lane noise after it")
        let parts = (1...25).map { #"{"id":"p\#($0)","lane":"wf","label":"P","state":"changed"}"# }.joined(separator: ",")
        expectEqual(reasons(#"{"version":2,"summary":"s","map":{"lanes":[{"id":"wf","label":"W"}],"parts":[\#(parts)],"#
                            + #""edges":[{"from":"p1","to":"p2","state":"changed"}]},"tour":[{"title":"t","text":"x","focus":["p1"]}]}"#),
                    ["map.parts: at most 24 allowed, found 25"], "parts over the limit: edges and focus not checked against them")
        let four = Array(repeating: #"{"path":"posthog/x.py","line":1}"#, count: 4).joined(separator: ",")
        expectEqual(reasons(edited(#""at":[{"path":"posthog/x.py","line":99}]"#, #""at":[\#(four)]"#)),
                    ["concerns[0].at: at most 3 allowed, found 4"], "anchors per concern")
        let concerns = Array(repeating: #"{"severity":"low","title":"t","why":"w"}"#, count: 7).joined(separator: ",")
        expectEqual(reasons(#"{"version":2,"summary":"s","concerns":[\#(concerns)]}"#), ["concerns: at most 6 allowed, found 7"], "concerns")
        expectEqual(reasons(edited(#""severity":"high""#, #""severity":"urgent""#)),
                    ["concerns[0].severity: must be one of high, medium, low"], "severity")
    }

    // MARK: - Layers, risk, effort

    func layered(_ layers: String, deleted: Set<String> = []) -> Result<AgentOverview, AgentOverview.Invalid> {
        AgentOverview.validate(json: root(#"{"version":2,"summary":"s","layers":\#(layers)}"#),
                               diffPaths: ["a.swift", "b.swift", "c.swift"], deletedPaths: deleted, lineCount: { _ in 1 })
    }
    func layerReasons(_ layers: String, deleted: Set<String> = []) -> [String] {
        if case let .failure(r) = layered(layers, deleted: deleted) { return r.reasons }
        return []
    }

    test("overview: layers validate") {
        let two = #"[{"title":"Model","note":"Types first.","files":["b.swift"]},{"title":"UI","files":["a.swift","gone.swift"]}]"#
        guard case let .success(o) = layered(two, deleted: ["gone.swift"]) else { return expect(false, "valid") }
        expectEqual(o.layers, [.init(title: "Model", note: "Types first.", files: ["b.swift"]),
                               .init(title: "UI", note: nil, files: ["a.swift", "gone.swift"])], "parsed, deleted files allowed")
        expectEqual(layerReasons("[]"), [], "none is fine")
        expectEqual(layerReasons(#"[{"title":"Only","files":["a.swift"]}]"#), ["layers: needs at least 2 layers (or none)"], "one")
        let seven = Array(repeating: #"{"title":"T","files":["a.swift"]}"#, count: 7).joined(separator: ",")
        expectEqual(layerReasons("[\(seven)]"), ["layers: at most 6 allowed, found 7"], "seven")
        expectEqual(layerReasons(#"[{"title":"A","files":["a.swift"]},{"title":"B","files":["x.swift"]}]"#),
                    [#"layers[1].files: "x.swift" is not a file in the diff"#], "unknown path")
        expectEqual(layerReasons(#"[{"title":"A","files":["a.swift"]},{"title":"B","files":["b.swift","a.swift"]}]"#),
                    [#"layers[1].files: "a.swift" is already in layers[0]"#], "in two layers")
        expectEqual(layerReasons(#"[{"title":"A","files":[]},{"title":"\#(String(repeating: "t", count: 41))","files":["b.swift"]}]"#),
                    ["layers[0].files: must be a non-empty array of paths", "layers[1].title: over 40 characters"], "empty, long title")
        expectEqual(layerReasons(#"[{"title":"A","note":"\#(String(repeating: "n", count: 161))","files":["a.swift"]},{"title":"B","files":["b.swift"]}]"#),
                    ["layers[0].note: over 160 characters"], "long note")
    }

    test("overview: fileOrder puts layers first, the rest in Other") {
        guard case let .success(o) = layered(#"[{"title":"Model","files":["c.swift","gone.swift"]},{"title":"UI","files":["a.swift"]}]"#,
                                             deleted: ["gone.swift"]) else { return expect(false, "valid") }
        let order = o.fileOrder(diffPaths: ["a.swift", "b.swift", "c.swift", "d.swift"])
        expectEqual(order.map { $0.layer?.title }, ["Model", "UI", nil], "layers in order, then Other")
        expectEqual(order.map(\.paths), [["c.swift"], ["a.swift"], ["b.swift", "d.swift"]], "files no longer in the diff dropped; Other in diff order")
        expectEqual(o.fileOrder(diffPaths: ["a.swift"]).map { $0.layer?.title }, ["UI"], "empty layers and Other left out")
        let none = AgentOverview(summary: "s").fileOrder(diffPaths: ["b.swift", "a.swift"])
        expect(none.count == 1 && none[0].layer == nil && none[0].paths == ["b.swift", "a.swift"], "no layers: all Other")
    }

    test("overview: risk and effort") {
        @MainActor func r(_ extra: String) -> [String] {
            if case let .failure(i) = AgentOverview.validate(json: root(#"{"version":2,"summary":"s",\#(extra)}"#), diffPaths: [], lineCount: { _ in nil }) {
                return i.reasons
            }
            return []
        }
        guard case let .success(o) = AgentOverview.validate(json: root(#"{"version":2,"summary":"s","risk":{"level":"low","reason":"Docs."},"effort":5}"#),
                                                            diffPaths: [], lineCount: { _ in nil }) else { return expect(false, "valid") }
        expect(o.risk == .init(level: .low, reason: "Docs.") && o.effort == 5, "parsed")
        expectEqual(r(#""risk":{"level":"huge","reason":"x"}"#), ["risk.level: must be one of high, medium, low"], "level")
        expectEqual(r(#""risk":{"level":"low","reason":"\#(String(repeating: "r", count: 121))"}"#), ["risk.reason: over 120 characters"], "reason")
        expectEqual(r(#""risk":"low""#), ["risk: must be an object"], "shape")
        expectEqual(r(#""effort":0"#), ["effort: must be a whole number from 1 to 5"], "zero")
        expectEqual(r(#""effort":6"#), ["effort: must be a whole number from 1 to 5"], "six")
        expectEqual(r(#""effort":2.5"#), ["effort: must be a whole number from 1 to 5"], "fraction")
    }

    test("overview: re-review marks new concerns and resolved ones") {
        func concern(_ title: String, _ line: Int?) -> AgentOverview.Concern {
            .init(severity: .medium, title: title, why: "w", at: line.map { [.init(path: "a.swift", line: $0)] } ?? [], parts: [])
        }
        var old = AgentOverview(summary: "s")
        old.concerns = [concern("Cache never expires", 10), concern("Race on save", 20), concern("Gone now", 30), concern("Dismissed", 40)]
        old.dismissed = [3]
        var new = AgentOverview(summary: "s")
        new.concerns = [concern("cache  never expires!", 99), concern("Retitled race", 20), concern("Brand new", nil), concern("Other", 41)]
        let o = new.following(old)
        expectEqual(o.newConcerns, [2, 3], "title (normalised) or first anchor match; the rest are new")
        expect(o.isNew(2) && !o.isNew(0), "isNew")
        expectEqual(o.resolved.map(\.title), ["Gone now"], "open old concerns with no match; dismissed ones aren't resolved")
        expect(new.newConcerns == nil && !new.isNew(0), "first review: nothing marked")
        var again = AgentOverview(summary: "s")
        again.concerns = [concern("Fresh", nil), concern("dismissed", nil), concern("Race on save", 20)]
        expectEqual(again.following(old).dismissed, [1], "a dismissed concern raised again stays dismissed; open ones stay open")
        var s = SourceState()
        s.overview = o
        let decoded = try JSONDecoder().decode(SourceState.self, from: JSONEncoder().encode(s))
        expectEqual(decoded, s, "round-trips")
    }

    // MARK: - Store, staleness, Keep

    let snapshot = ReviewSnapshot(root: "/r", base: "main", point: "abc",
                                  files: [FileDiff(path: "posthog/x.py", oldPath: nil, status: .modified, isBinary: false, hunks: [])],
                                  hashes: ["posthog/x.py": "h1"])
    func imported() throws -> AgentOverview {
        guard case var .success(o) = validate(example) else { throw AgentDrafts.Problem(message: "invalid") }
        o.fingerprint = snapshot.fingerprint
        o.anchorHashes = Dictionary(uniqueKeysWithValues: AgentOverview.anchorPaths(in: root(example)).map { ($0, snapshot.anchorHash($0)) })
        return o
    }

    test("overview: old reviews.json loads; overview round-trips") {
        let old = #"{"sources":{"x":{"base":"main","viewed":{},"comments":[]}},"sourceChosen":true}"#
        let state = try JSONDecoder().decode(ReviewState.self, from: Data(old.utf8))
        expect(state.sources["x"] != nil && state.sources["x"]?.overview == nil, "loads, no overview")
        var s = SourceState()
        s.overview = try imported()
        s.overview?.dismissed = [0]
        let decoded = try JSONDecoder().decode(SourceState.self, from: JSONEncoder().encode(s))
        expectEqual(decoded, s, "round-trips")
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported())) as? [String: Any] ?? [:]
        for key in ["layers", "risk", "effort", "newConcerns", "resolved"] { saved[key] = nil }
        let older = try JSONDecoder().decode(AgentOverview.self, from: JSONSerialization.data(withJSONObject: saved))
        expect(older.layers.isEmpty && older.resolved.isEmpty && older.newConcerns == nil, "overview saved before layers loads")
        let broken = #"{"sources":{"x":{"viewed":{},"comments":[],"overview":{"summary":3}}}}"#
        let kept = try JSONDecoder().decode(ReviewState.self, from: Data(broken.utf8))
        expect(kept.sources["x"] != nil && kept.sources["x"]?.overview == nil, "undecodable overview dropped, state kept")
    }

    test("overview: stale when the snapshot changes; anchors hold while their file is the same") {
        let o = try imported()
        expect(!o.isStale(for: snapshot), "fresh")
        let otherFile = ReviewSnapshot(root: "/r", base: "main", point: "abc", files: snapshot.files,
                                       hashes: ["posthog/x.py": "h1", "y.py": "h9"])
        expect(o.isStale(for: otherFile), "another file changed: stale")
        expect(o.holds(.init(path: "posthog/x.py", line: 99), in: otherFile), "but x.py's anchors still hold")
        let edited = ReviewSnapshot(root: "/r", base: "main", point: "abc", files: snapshot.files, hashes: ["posthog/x.py": "h2"])
        expect(!o.holds(.init(path: "posthog/x.py", line: 99), in: edited), "x.py changed: unlinked")
        expect(o.keepAnchor(0, in: edited) == nil, "Keep disabled")
        expect(o.holds(.init(path: "posthog/lib.py", line: 7), in: edited), "outside file, same merge base")
        let moved = ReviewSnapshot(root: "/r", base: "main", point: "def", files: snapshot.files, hashes: snapshot.hashes)
        expect(o.isStale(for: moved) && !o.holds(.init(path: "posthog/lib.py", line: 7), in: moved), "new merge base")
    }

    test("overview: keepConcern adds one comment, once; dismiss") {
        var s = SourceState()
        s.overview = try imported()
        guard let anchor = s.overview?.keepAnchor(0, in: snapshot) else { return expect(false, "keepable") }
        expectEqual(anchor, .init(path: "posthog/x.py", line: 99), "first anchor in the diff")
        s.keepConcern(0, at: anchor, quote: "raise X")
        s.keepConcern(0, at: anchor, quote: "raise X")
        expectEqual(s.comments.count, 1, "one comment")
        expectEqual(s.comments.first?.text, "**Backfill misses go dark** — Nothing logs them now, so a broken lookup looks like expired rows.", "text")
        expect(s.comments.first.map { !$0.byAgent && $0.state == .queued && $0.quote == "raise X" } == true, "the user's, queued")
        expectEqual(s.overview?.dismissed, [0], "out of the list")
        expect(s.overview?.keepAnchor(0, in: snapshot) == nil, "no second Keep")
        var d = SourceState()
        d.overview = try imported()
        d.dismissConcern(0)
        d.dismissConcern(5)
        expectEqual(d.overview?.dismissed, [0], "dismissed; unknown index ignored")
        expectEqual(d.comments, [], "no comment")
    }

    test("overview: rejected file keeps the overview as written") {
        let (entries, json) = try AgentDrafts.parseFile(Data(example.utf8))
        let rejected = AgentDrafts.comments(entries, diffPaths: [], lines: { _ in [] }, existing: []).rejected
        let kept = try AgentDrafts.parseFile(AgentDrafts.file(keeping: rejected, overview: json))
        expectEqual(kept.entries, entries, "comments kept")
        expectEqual(AgentOverview.anchorPaths(in: kept.overview ?? [:]), ["posthog/x.py", "posthog/lib.py"], "overview kept")
        let v1 = try AgentDrafts.parseFile(AgentDrafts.file(keeping: rejected))
        expect(v1.overview == nil, "without it: version 1")
    }

    // MARK: - Return-if-empty

    test("prompt box: only Claude's empty box counts") {
        let rule = String(repeating: "─", count: 60)
        let empty = "● Done.\n\n\(rule)\n> \u{a0}\n\(rule)\n  ? for shortcuts\n\n\n"
        expect(PromptBox.isEmpty(empty), "empty box")
        expect(PromptBox.isEmpty("╭\(rule)╮\n│ >                │\n╰\(rule)╯\n  ? for shortcuts"), "boxed (older Claude)")
        expect(PromptBox.isEmpty("\(rule)\n❯ \n\(rule)\n  ⏵⏵ accept edits on\n[0] 0:claude*  tmux"), "❯, hints and a tmux bar")
        expect(!PromptBox.isEmpty("\(rule)\n> fix the tests\n\(rule)\n  ? for shortcuts"), "typed text")
        expect(!PromptBox.isEmpty("\(rule)\n> Try \"refactor x.py\"\n\(rule)"), "placeholder: can't tell, so no")
        expect(!PromptBox.isEmpty("\(rule)\n> first line\n  second\n\(rule)"), "two lines")
        expect(!PromptBox.isEmpty("\(rule)\n>\n\(rule)\nDo you want to proceed?\n\(rule)\n❯ 1. Yes\n\(rule)"), "a menu below")
        expect(!PromptBox.isEmpty("user@mac ~/code % \n"), "shell prompt")
        expect(!PromptBox.isEmpty("codex> \n"), "another agent")
        expect(!PromptBox.isEmpty(""), "nothing")
        expect(!PromptBox.isEmpty("\(rule)\n>\n\(rule)\n1\n2\n3\n4\n5"), "too much below the box")
    }

    test("prompt box: Return only onto the paste alone") {
        let rule = String(repeating: "─", count: 60)
        expect(PromptBox.holdsOnlyPaste("● Done.\n\(rule)\n> [Pasted text #1 +12 lines]\n\(rule)\n  ? for shortcuts"), "marker only")
        expect(PromptBox.holdsOnlyPaste("\(rule)\n❯ [Pasted text #3 +40 lines] \n\(rule)"), "❯, trailing space")
        expect(!PromptBox.holdsOnlyPaste("\(rule)\n> [Pasted text #1 +12 lines] also this\n\(rule)"), "marker + typed text")
        expect(!PromptBox.holdsOnlyPaste("\(rule)\n> x[Pasted text #1 +12 lines]\n\(rule)"), "typed before the marker")
        expect(!PromptBox.holdsOnlyPaste("\(rule)\n> please review\n\(rule)"), "plain short text")
        expect(!PromptBox.holdsOnlyPaste("\(rule)\n>\n\(rule)"), "empty: the paste didn't land")
        expect(!PromptBox.holdsOnlyPaste("\(rule)\n> [Pasted text #1 +12 lines]\n\(rule)\nDo you want to proceed?\n\(rule)\n❯ 1. Yes\n\(rule)"),
               "permission box")
        expect(!PromptBox.holdsOnlyPaste("\(rule)\nBash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n\(rule)"),
               "permission box in place of the input")
    }
}
