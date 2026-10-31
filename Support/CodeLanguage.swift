import Foundation

/// Languages the review parses (symbols and highlights) with tree-sitter.
enum CodeLanguage: String, Sendable, CaseIterable {
    case python, javascript, typescript, tsx

    static func forPath(_ path: String) -> CodeLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py": .python
        case "js", "jsx", "mjs", "cjs": .javascript
        case "ts", "mts", "cts": .typescript
        case "tsx": .tsx
        default: nil
        }
    }
}

enum TokenKind: String, Sendable {
    case keyword, string, comment, number, function, type, constant, property, variable, `operator`, punctuation

    /// From a highlights.scm capture name, by its first part
    /// ("function.method" → function); nil for ones we don't colour.
    init?(capture: String) {
        let head = String(capture.prefix { $0 != "." })
        if head == "constructor" { self = .type; return }
        self.init(rawValue: head)
    }
}

struct HighlightSpan: Equatable, Sendable {
    let range: Range<Int>   // Character offsets within the line
    let kind: TokenKind
}

struct CodeSymbol: Equatable, Sendable {
    enum Kind: Sendable { case function, method, `class` }
    /// Qualified ("Class.method"; interfaces qualify too). A name repeated in
    /// one file (a property and its setter) gets "#2", "#3"… in source order.
    let name: String
    let kind: Kind
    let lines: ClosedRange<Int>   // 1-based, decorators included
    // Both hashes use Swift's per-process seed: compare within one run, never persist.
    let rawHash: Int              // hash of its exact text
    let shapeHash: Int            // hash of its tokens, without its own name
}

struct ParsedSource: Sendable {
    let symbols: [CodeSymbol]
    /// By 1-based line; outer spans come first, so inner ones paint over them.
    let highlights: [Int: [HighlightSpan]]
}
