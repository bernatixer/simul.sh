import Foundation
@testable import SimulCore

private func sym(_ name: String, _ lines: ClosedRange<Int>, raw: Int, shape: Int? = nil,
                 kind: CodeSymbol.Kind = .function) -> CodeSymbol {
    CodeSymbol(name: name, kind: kind, lines: lines, rawHash: raw, shapeHash: shape ?? raw)
}

@MainActor
func registerSymbolDiffTests() {
    test("symbols: changed vs formatting") {
        let old = [sym("a", 1...3, raw: 1), sym("b", 5...7, raw: 2, shape: 20)]
        let new = [sym("a", 1...3, raw: 10), sym("b", 5...7, raw: 3, shape: 20)]
        let r = SymbolDiff.compare(old: old, new: new, changedOld: [2, 6], changedNew: [2, 6])
        expectEqual(r, [
            SymbolChange(name: "a", kind: .changed, newLines: 1...3, oldLines: 1...3),
            SymbolChange(name: "b", kind: .formatting, newLines: 5...7, oldLines: 5...7),
        ], "changed then formatting")
    }

    test("symbols: class noise") {
        let old = [sym("C", 1...5, raw: 1, shape: 1, kind: .class), sym("C.m", 2...3, raw: 2, shape: 2, kind: .method)]
        let edited = [sym("C", 1...5, raw: 10, shape: 10, kind: .class), sym("C.m", 2...3, raw: 20, shape: 20, kind: .method)]
        expectEqual(SymbolDiff.compare(old: old, new: edited, changedOld: [2], changedNew: [2]),
                    [SymbolChange(name: "C.m", kind: .changed, newLines: 2...3, oldLines: 2...3)], "method edit: only the method")
        let attr = [sym("C", 1...5, raw: 10, shape: 10, kind: .class), old[1]]
        expectEqual(SymbolDiff.compare(old: old, new: attr, changedOld: [4], changedNew: [4]),
                    [SymbolChange(name: "C", kind: .changed, newLines: 1...5, oldLines: 1...5)], "class-level edit: the class")
        let renamed = [sym("D", 1...5, raw: 1, shape: 1, kind: .class), sym("D.m", 2...3, raw: 3, shape: 2, kind: .method)]
        expectEqual(SymbolDiff.compare(old: old, new: renamed, changedOld: [1], changedNew: [1]),
                    [SymbolChange(name: "D", kind: .renamed(from: "C"), newLines: 1...5, oldLines: 1...5)], "class rename: only the class")
    }

    test("symbols: rename") {
        let old = [sym("a", 1...2, raw: 1, shape: 9), sym("b", 4...5, raw: 2, shape: 9)]
        let new = [sym("x", 1...2, raw: 3, shape: 9), sym("y", 4...5, raw: 4, shape: 9)]
        let r = SymbolDiff.compare(old: old, new: new, changedOld: [1, 4], changedNew: [1, 4])
        expectEqual(r, [
            SymbolChange(name: "x", kind: .renamed(from: "a"), newLines: 1...2, oldLines: 1...2),
            SymbolChange(name: "y", kind: .renamed(from: "b"), newLines: 4...5, oldLines: 4...5),
        ], "paired in source order")
    }

    test("symbols: added and deleted") {
        let old = [sym("gone", 1...2, raw: 1)]
        let new = [sym("fresh", 3...4, raw: 2)]
        let r = SymbolDiff.compare(old: old, new: new, changedOld: [1], changedNew: [3])
        expectEqual(r, [
            SymbolChange(name: "fresh", kind: .added, newLines: 3...4, oldLines: nil),
            SymbolChange(name: "gone", kind: .deleted, newLines: nil, oldLines: 1...2),
        ], "added before deleted")
    }

    test("symbols: untouched symbols not reported") {
        let old = [sym("a", 1...3, raw: 1), sym("b", 5...7, raw: 2)]
        let new = [sym("a", 1...3, raw: 5), sym("b", 5...7, raw: 2)]
        expectEqual(SymbolDiff.compare(old: old, new: new, changedOld: [], changedNew: []), [], "no changed lines")
        let r = SymbolDiff.compare(old: old, new: new, changedOld: [6], changedNew: [6])
        expectEqual(r, [], "a differs but its lines are untouched; b is identical")
    }

    test("symbols: moved across files") {
        let old = ["a.py": [sym("f", 1...3, raw: 1, shape: 7)], "b.py": []]
        let new = ["a.py": [], "b.py": [sym("g", 2...4, raw: 2, shape: 7)]]
        let byPath = [
            "a.py": [SymbolChange(name: "f", kind: .deleted, newLines: nil, oldLines: 1...3)],
            "b.py": [SymbolChange(name: "g", kind: .added, newLines: 2...4, oldLines: nil)],
        ]
        let r = SymbolDiff.linkMoves(byPath, old: old, new: new)
        expectEqual(r["a.py"], [], "deleted entry removed")
        expectEqual(r["b.py"], [SymbolChange(name: "g", kind: .moved(from: "a.py"), newLines: 2...4, oldLines: 1...3)], "moved")
    }

    test("symbols: end to end with parser") {
        let parser = CodeParser(queries: repoQueries)
        let old = parser.parse("def f():\n    return 1\n\ndef g():\n    return 2\n", .python).symbols
        let new = parser.parse("def f():\n    return 9\n\ndef g():\n    return 2\n", .python).symbols
        let r = SymbolDiff.compare(old: old, new: new, changedOld: [2], changedNew: [2])
        expectEqual(r, [SymbolChange(name: "f", kind: .changed, newLines: 1...2, oldLines: 1...2)], "only f changed")
    }
}
