import Foundation
@testable import SimulCore

@MainActor
func registerAnalysisTests() {
    func del(_ o: Int, _ text: String) -> DiffLine { DiffLine(kind: .removed, oldNumber: o, newNumber: nil, text: text) }
    func add(_ n: Int, _ text: String) -> DiffLine { DiffLine(kind: .added, oldNumber: nil, newNumber: n, text: text) }
    func ctx(_ o: Int, _ n: Int) -> DiffLine { DiffLine(kind: .context, oldNumber: o, newNumber: n, text: "ctx \(o)") }
    func file(_ path: String, _ hunks: [[DiffLine]]) -> FileDiff {
        FileDiff(path: path, oldPath: nil, status: .modified, isBinary: false,
                 hunks: hunks.map { DiffHunk(header: "@@", lines: $0) })
    }
    func refs(_ path: String, _ hunk: Int, _ range: ClosedRange<Int>) -> [LineRef] {
        range.map { LineRef(path: path, hunk: hunk, index: $0) }
    }
    let body = ["def load(path):", "with open(path) as f:", "data = f.read()", "parse(data)", "return data", "log(data)"]

    test("moves: block across files") {
        let a = file("a.py", [body.prefix(5).enumerated().map { del(10 + $0, "    " + $1) }])
        let b = file("b.py", [body.prefix(5).enumerated().map { add(20 + $0, $1) }])
        let r = ReviewAnalysis.analyze([a, b])
        expectEqual(r.moves, [MoveBlock(removed: refs("a.py", 0, 0...4), added: refs("b.py", 0, 0...4))], "one block")
        expectEqual(r.notes[LineRef(path: "a.py", hunk: 0, index: 2)], .movedTo(path: "b.py", line: 20), "moved to")
        expectEqual(r.notes[LineRef(path: "b.py", hunk: 0, index: 4)], .movedFrom(path: "a.py", line: 10), "moved from")
        expectEqual(r.formattingLines, 0, "not formatting")
        expectEqual(r.quietHunks, ["a.py#0", "b.py#0"], "both hunks are noise")
    }

    test("moves: within a file") {
        let f = file("x.py", [[ctx(4, 4)] + body.prefix(4).enumerated().map { del(5 + $0, $1) } + [ctx(9, 5)],
                              [ctx(40, 36)] + body.prefix(4).enumerated().map { add(37 + $0, $1) }])
        let r = ReviewAnalysis.analyze([f])
        expectEqual(r.moves, [MoveBlock(removed: refs("x.py", 0, 1...4), added: refs("x.py", 1, 1...4))], "one block")
        expectEqual(r.notes[LineRef(path: "x.py", hunk: 1, index: 1)], .movedFrom(path: "x.py", line: 5), "moved from")
        expectEqual(r.notes[LineRef(path: "x.py", hunk: 0, index: 1)], .movedTo(path: "x.py", line: 37), "moved to")
    }

    test("moves: ignores short and trivial blocks") {
        let short = ReviewAnalysis.analyze([file("a.py", [[del(1, body[0]), del(2, body[1])]]),
                                            file("b.py", [[add(1, body[0]), add(2, body[1])]])])
        expectEqual(short, DiffAnalysis(), "two lines is too short")
        let closers = ["}", ")", "}", ")"]
        let trivial = ReviewAnalysis.analyze([file("a.js", [closers.enumerated().map { del(1 + $0, $1) }]),
                                              file("b.js", [closers.enumerated().map { add(1 + $0, $1) }])])
        expectEqual(trivial, DiffAnalysis(), "closers alone never move")
    }

    test("moves: moved block with an inner edit") {
        var edited = body
        edited[2] = "data = f.read().strip()"
        let a = file("a.py", [body.enumerated().map { del(1 + $0, $1) }])
        let b = file("b.py", [edited.enumerated().map { add(1 + $0, $1) }])
        let r = ReviewAnalysis.analyze([a, b])
        expectEqual(r.moves, [MoveBlock(removed: refs("a.py", 0, 3...5), added: refs("b.py", 0, 3...5))], "lines 4-6")
        expectEqual(r.notes[LineRef(path: "b.py", hunk: 0, index: 3)], .movedFrom(path: "a.py", line: 4), "from line 4")
        for i in 0...2 {
            expect(r.notes[LineRef(path: "a.py", hunk: 0, index: i)] == nil, "removed line \(i + 1) unnoted")
            expect(r.notes[LineRef(path: "b.py", hunk: 0, index: i)] == nil, "added line \(i + 1) unnoted")
        }
        expectEqual(r.quietHunks, [], "edited line is real")
    }

    test("formatting: whitespace-only pair") {
        let f = file("f.swift", [[ctx(1, 1), del(2, "let x  =  1"), del(3, "foo()"), add(2, "let x = 1"), add(3, "bar()")]])
        let r = ReviewAnalysis.analyze([f])
        expectEqual(r.notes[LineRef(path: "f.swift", hunk: 0, index: 1)], .formatting, "removed side")
        expectEqual(r.notes[LineRef(path: "f.swift", hunk: 0, index: 3)], .formatting, "added side")
        expect(r.notes[LineRef(path: "f.swift", hunk: 0, index: 2)] == nil, "real change unnoted")
        expectEqual(r.formattingLines, 1, "one pair")
        expectEqual(r.quietHunks, [], "hunk has a real change")
        expectEqual(r.moves, [], "no moves")
    }

    test("formatting: quiet hunk") {
        // A block re-indented in place is formatting, not a move onto itself.
        let block = Array(body.prefix(3))
        let f = file("f.py", [
            block.enumerated().map { del(1 + $0, $1) } + block.enumerated().map { add(1 + $0, "    " + $1) },
            [del(20, "a = 1"), add(20, "a = 2")],
        ])
        let r = ReviewAnalysis.analyze([f])
        expectEqual(r.moves, [], "not a move")
        expectEqual(r.formattingLines, 3, "three pairs")
        expectEqual(r.quietHunks, ["f.py#0"], "only the re-indent hunk is quiet")
    }

    test("analysis: skips huge files") {
        let filler = (0..<1500).map { ctx(100 + $0, 100 + $0) }
        let a = file("a.py", [body.prefix(5).enumerated().map { del(1 + $0, $1) } + [del(6, "x  = 1"), add(1, "x = 1")] + filler])
        let b = file("b.py", [body.prefix(5).enumerated().map { add(1 + $0, $1) }])
        expectEqual(ReviewAnalysis.analyze([a, b]), DiffAnalysis(), "nothing from a huge file")
    }

    test("rows: moved run folds, split pairs the rest") {
        let h = DiffHunk(header: "@@", lines: [ctx(1, 1), del(2, "a"), del(3, "m1"), del(4, "m2"), del(5, "m3"), add(2, "b")])
        let to = LineNote.movedTo(path: "b.py", line: 9)
        let note: (Int) -> LineNote? = { (2...4).contains($0) ? to : nil }
        let run = MovedRun(start: 2, count: 3, note: to)
        expectEqual(h.rows(split: false, note: note) { _ in false }, [.line(0), .line(1), .moved(run), .line(5)], "unified")
        expectEqual(h.rows(split: true, note: note) { _ in false },
                    [.pair(left: 0, right: 0), .pair(left: 1, right: nil), .moved(run), .pair(left: nil, right: 5)], "split")
        expectEqual(h.rows(split: true, note: note) { _ in true },
                    [.pair(left: 0, right: 0), .pair(left: 1, right: nil), .moved(run),
                     .pair(left: 2, right: nil), .pair(left: 3, right: nil), .pair(left: 4, right: nil),
                     .pair(left: nil, right: 5)], "open run")
        let plain = h.rows(split: true, note: { _ in nil }) { _ in false }
        expectEqual(plain, [.pair(left: 0, right: 0), .pair(left: 1, right: 5), .pair(left: 2, right: nil),
                            .pair(left: 3, right: nil), .pair(left: 4, right: nil)], "no notes: GitHub pairing")
        expectEqual(Set(plain.map(\.id)).count, plain.count, "unique ids")
    }

    test("formatting: pairs skip moved lines") {
        // [A (moved), B] vs [B′]: split rows fold A, so B sits beside B′.
        let a = file("a.py", [body.prefix(3).enumerated().map { del(1 + $0, $1) } + [del(4, "x  =  1"), add(1, "x = 1")]])
        let b = file("b.py", [body.prefix(3).enumerated().map { add(1 + $0, $1) }])
        let r = ReviewAnalysis.analyze([a, b])
        expectEqual(r.moves.count, 1, "A moved")
        expectEqual(r.notes[LineRef(path: "a.py", hunk: 0, index: 3)], .formatting, "B")
        expectEqual(r.notes[LineRef(path: "a.py", hunk: 0, index: 4)], .formatting, "B′")
        expectEqual(r.formattingLines, 1, "one pair")
        expectEqual(r.quietHunks, ["a.py#0", "b.py#0"], "moves and whitespace only")
    }

    test("analysis: summary") {
        let f = file("f.swift", [[del(1, "let x  =  1"), del(2, "foo()"), add(1, "let x = 1"), add(2, "bar()")]])
        let r = ReviewAnalysis.analyze([f])
        expectEqual(r.summary([f]), "2 lines changed · 1 whitespace", "zero parts left out")
        expectEqual(DiffAnalysis().summary([]), "", "nothing")
    }
}
