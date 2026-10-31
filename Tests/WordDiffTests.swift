import Foundation
@testable import SimulCore

@MainActor
func registerWordDiffTests() {
    func marked(_ s: String, _ ranges: [Range<Int>]?) -> [String] {
        let c = Array(s)
        return (ranges ?? []).map { String(c[$0]) }
    }

    test("words: one changed word on each side") {
        let old = "let total = price * count", new = "let total = cost * count"
        let r = WordDiff.changes(old: old, new: new)
        expectEqual(marked(old, r?.old), ["price"], "old side")
        expectEqual(marked(new, r?.new), ["cost"], "new side")
    }

    test("words: changes split by whitespace merge, by other tokens don't") {
        let old = "call(alpha beta, gamma)", new = "call(one two, gamma)"
        let r = WordDiff.changes(old: old, new: new)
        expectEqual(marked(old, r?.old), ["alpha beta"], "merged across the space")
        expectEqual(marked(new, r?.new), ["one two"], "merged across the space")
        let o2 = "f(a, b, c, d, e)", n2 = "f(x, b, c, d, y)"
        let r2 = WordDiff.changes(old: o2, new: n2)
        expectEqual(marked(o2, r2?.old), ["a", "e"], "apart")
    }

    test("words: an insertion marks only the new side") {
        let old = "foo(bar)", new = "foo(bar, baz)"
        let r = WordDiff.changes(old: old, new: new)
        expectEqual(r?.old ?? [0..<1], [], "nothing removed")
        expectEqual(marked(new, r?.new), [", baz"], "the added part")
    }

    test("words: too different, too long, identical, trailing CR") {
        expect(WordDiff.changes(old: "import os", new: "return value + 1") == nil, "too different")
        let indent = String(repeating: " ", count: 16)
        expect(WordDiff.changes(old: indent + "import os", new: indent + "return value + 1") == nil,
               "shared indentation doesn't make lines alike")
        let long = String(repeating: "a ", count: 300)
        expect(WordDiff.changes(old: long, new: long + "b") == nil, "too long")
        expect(WordDiff.changes(old: "same line", new: "same line") == nil, "nothing changed")
        expect(WordDiff.changes(old: "same line\r", new: "same line") == nil, "a trailing CR is ignored")
        let r = WordDiff.changes(old: "x = 1\r", new: "x = 2")
        expectEqual(r?.old, [4..<5], "offsets before the CR")
    }
}
