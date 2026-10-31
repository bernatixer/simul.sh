import Foundation
@testable import SimulCore

/// The app bundle's layout (<lang>/*.scm, as build-app.sh copies them),
/// made of links to the repo's vendored query folders.
let repoQueries: URL = {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("simul-queries-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for lang in ["python", "javascript", "typescript"] {
        try? FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(lang),
            withDestinationURL: repo.appendingPathComponent("Vendor/tree-sitter/\(lang)/queries"))
    }
    return dir
}()

@MainActor
func registerCodeParserTests() {
    test("parser: languages by extension") {
        expectEqual(CodeLanguage.forPath("a/b.py"), .python, "py")
        expectEqual(CodeLanguage.forPath("x.mjs"), .javascript, "mjs")
        expectEqual(CodeLanguage.forPath("x.jsx"), .javascript, "jsx")
        expectEqual(CodeLanguage.forPath("x.cts"), .typescript, "cts")
        expectEqual(CodeLanguage.forPath("X.TSX"), .tsx, "tsx, any case")
        expectEqual(CodeLanguage.forPath("Makefile"), nil, "unsupported")
    }

    test("parser: python symbols") {
        let source = """
        class Greeter:
            def hello(self):
                return "hi"

            def bye(self):
                return "bye"

        def main():
            Greeter().hello()

        """
        let symbols = CodeParser(queries: repoQueries).parse(source, .python).symbols
        expectEqual(symbols.map(\.name), ["Greeter", "Greeter.hello", "Greeter.bye", "main"], "names")
        expectEqual(symbols.map(\.kind), [.class, .method, .method, .function], "kinds")
        expectEqual(symbols.map(\.lines), [1...6, 2...3, 5...6, 8...9], "line ranges")
    }

    test("parser: ts symbols") {
        let source = """
        export class Store {
          load(id: string): number {
            return 1;
          }
        }
        function helper(x: number) { return x; }
        const arrow = (y: number) => y;

        """
        for language in [CodeLanguage.typescript, .tsx] {
            let symbols = CodeParser(queries: repoQueries).parse(source, language).symbols
            expectEqual(symbols.map(\.name), ["Store", "Store.load", "helper", "arrow"], "\(language) names")
            expectEqual(symbols.map(\.kind), [.class, .method, .function, .function], "\(language) kinds")
            expectEqual(symbols.map(\.lines), [1...5, 2...4, 6...6, 7...7], "\(language) lines")
        }
    }

    test("parser: unique symbol names") {
        let parser = CodeParser(queries: repoQueries)
        let ts = """
        function f(a: string): void;
        function f(a: number): void;
        function f(a: any) { return a; }
        interface Shape { area(): number; }
        class K { m(a: string): void; m(a: any) {} }

        """
        let tsSymbols = parser.parse(ts, .typescript).symbols
        expectEqual(tsSymbols.map(\.name), ["f", "Shape.area", "K", "K.m"], "overloads once, interface member qualified")
        expectEqual(tsSymbols.first?.lines, 3...3, "f is the implementation")
        let py = """
        class C:
            @property
            def x(self):
                return self._x

            @x.setter
            def x(self, value):
                self._x = value

        """
        let pySymbols = parser.parse(py, .python).symbols
        expectEqual(pySymbols.map(\.name), ["C", "C.x", "C.x#2"], "property and setter")
        expectEqual(pySymbols.map(\.lines), [1...8, 2...4, 6...8], "decorators included")
    }

    test("parser: decorator edits change rawHash") {
        let parser = CodeParser(queries: repoQueries)
        let a = parser.parse("@cache\ndef f():\n    return 1\n", .python).symbols
        let b = parser.parse("@lru_cache\ndef f():\n    return 1\n", .python).symbols
        expectEqual(a.map(\.name), ["f"], "one symbol")
        expect(a.first?.rawHash != b.first?.rawHash, "decorator is part of the text")
    }

    test("parser: broken source") {
        let parser = CodeParser(queries: repoQueries)
        let broken = parser.parse("def f(:\n    pass\n\nclass C:\n    def m(self): pass\n", .python)
        expect(broken.symbols.contains { $0.name == "C" }, "symbols after an error still found")
        expect(parser.parse("", .typescript).symbols.isEmpty, "empty source")
        expect(parser.parse("}}}{{{ ((( \"", .javascript).symbols.isEmpty, "garbage")
        let missing = CodeParser(queries: URL(fileURLWithPath: "/nonexistent")).parse("def f(): pass\n", .python)
        expect(missing.symbols.isEmpty && missing.highlights.isEmpty, "missing queries: nothing, no crash")
    }

    test("highlights: python keywords and strings") {
        let parsed = CodeParser(queries: repoQueries).parse("def f():\n    return 'x'  # done\n", .python)
        let line1 = parsed.highlights[1] ?? []
        let line2 = parsed.highlights[2] ?? []
        expect(line1.contains(HighlightSpan(range: 0..<3, kind: .keyword)), "def is a keyword")
        expect(line1.contains(HighlightSpan(range: 4..<5, kind: .function)), "f is a function")
        expect(line2.contains(HighlightSpan(range: 4..<10, kind: .keyword)), "return is a keyword")
        expect(line2.contains(HighlightSpan(range: 11..<14, kind: .string)), "'x' is a string")
        expect(line2.contains(HighlightSpan(range: 16..<22, kind: .comment)), "comment")
        let upper = CodeParser(queries: repoQueries).parse("MAX = 1\n", .python).highlights[1] ?? []
        expect(upper.contains(HighlightSpan(range: 0..<3, kind: .constant)), "#match? picks constants")
        expect(!upper.contains(HighlightSpan(range: 0..<3, kind: .variable)), "the later pattern wins")
        let call = CodeParser(queries: repoQueries).parse("obj.run()\nobj.name\n", .python).highlights
        expect((call[1] ?? []).contains(HighlightSpan(range: 4..<7, kind: .function)), "method call is a function")
        expect((call[2] ?? []).contains(HighlightSpan(range: 4..<8, kind: .property)), "attribute is a property")
    }

    test("highlights: multi-line spans split per line") {
        let parsed = CodeParser(queries: repoQueries).parse("/* a\n   bc */\nlet x = 1;\n", .typescript)
        expect((parsed.highlights[1] ?? []).contains(HighlightSpan(range: 0..<4, kind: .comment)), "first line")
        expect((parsed.highlights[2] ?? []).contains(HighlightSpan(range: 0..<8, kind: .comment)), "second line")
        expect((parsed.highlights[3] ?? []).contains(HighlightSpan(range: 0..<3, kind: .keyword)), "let (TS on JS)")
    }

    test("highlights: utf8 columns") {
        let parsed = CodeParser(queries: repoQueries).parse("s = \"héllo\" # ñ\n", .python)
        let spans = parsed.highlights[1] ?? []
        expect(spans.contains(HighlightSpan(range: 4..<11, kind: .string)), "string in Character offsets")
        expect(spans.contains(HighlightSpan(range: 12..<15, kind: .comment)), "comment after non-ASCII")
    }

    test("parser: shapeHash ignores rename and whitespace") {
        let parser = CodeParser(queries: repoQueries)
        let a = parser.parse("def total(xs):\n    return sum(xs) + 1\n", .python).symbols
        let b = parser.parse("class K:\n  def amount(xs):\n        return sum( xs )+1\n", .python).symbols
        let c = parser.parse("def total(xs):\n    return sum(xs) + 2\n", .python).symbols
        guard a.count == 1, b.count == 2, c.count == 1 else { expect(false, "symbol counts"); return }
        expectEqual(a[0].shapeHash, b[1].shapeHash, "same shape")
        expect(a[0].rawHash != b[1].rawHash, "different raw text")
        expect(a[0].shapeHash != c[0].shapeHash, "body change changes shape")
        expectEqual(a[0].rawHash, parser.parse("def total(xs):\n    return sum(xs) + 1\n", .python).symbols[0].rawHash, "stable")
    }
}
