import CTreeSitter
import Foundation

/// Parses source with tree-sitter into symbols (tags.scm) and per-line
/// highlights (highlights.scm). `queries` holds <lang>/tags.scm and
/// <lang>/highlights.scm, as build-app.sh copies them; TypeScript and TSX
/// use JavaScript's queries followed by TypeScript's. Queries compile once
/// per language. Not thread-safe: used from one serial queue.
final class CodeParser: @unchecked Sendable {
    private let queries: URL
    private let parser: OpaquePointer = ts_parser_new()
    private var compiled: [CodeLanguage: (tags: Query?, highlights: Query?)] = [:]

    init(queries: URL) { self.queries = queries }
    deinit { ts_parser_delete(parser) }

    func parse(_ source: String, _ language: CodeLanguage) -> ParsedSource {
        let empty = ParsedSource(symbols: [], highlights: [:])
        let (tags, highlights) = queries(for: language)
        let bytes = Array(source.utf8)
        guard tags != nil || highlights != nil, !bytes.isEmpty,
              ts_parser_set_language(parser, language.grammar) else { return empty }
        let tree = bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                ts_parser_parse_string(parser, nil, $0.baseAddress, UInt32($0.count))
            }
        }
        guard let tree else { return empty }
        defer { ts_tree_delete(tree) }
        let text = SourceText(bytes: bytes)
        let root = ts_tree_root_node(tree)
        return ParsedSource(
            symbols: tags.map { symbols(root, $0, text) } ?? [],
            highlights: highlights.map { self.highlights(root, $0, text) } ?? [:])
    }

    /// Compiles every language's queries now instead of on first use.
    func prepare() {
        for language in CodeLanguage.allCases { _ = queries(for: language) }
    }

    private func queries(for language: CodeLanguage) -> (tags: Query?, highlights: Query?) {
        if let done = compiled[language] { return done }
        let folders = switch language {
        case .python: ["python"]
        case .javascript: ["javascript"]
        case .typescript, .tsx: ["javascript", "typescript"]
        }
        func load(_ file: String) -> Query? {
            let source = folders.compactMap {
                try? String(contentsOf: queries.appendingPathComponent("\($0)/\(file)"), encoding: .utf8)
            }.joined(separator: "\n")
            return source.isEmpty ? nil : Query(language.grammar, source, "\(language.rawValue) \(file)")
        }
        let result = (load("tags.scm"), load("highlights.scm"))
        compiled[language] = result
        return result
    }

    private func symbols(_ root: TSNode, _ tags: Query, _ text: SourceText) -> [CodeSymbol] {
        // kind nil: a scope that qualifies names but isn't a symbol (interfaces).
        struct Def { let name: String; let kind: CodeSymbol.Kind?; let node: TSNode; let nameNode: TSNode }
        var defs: [Def] = []
        tags.forEachMatch(root, text) { _, captures in
            var nameNode: TSNode?, def: (TSNode, CodeSymbol.Kind?)?
            for capture in captures {
                switch tags.captureNames[Int(capture.index)] {
                case "name": nameNode = capture.node
                case "definition.function": def = (capture.node, .function)
                case "definition.method": def = (capture.node, .method)
                case "definition.class": def = (capture.node, .class)
                case "definition.interface": def = (capture.node, nil)
                default: break
                }
            }
            guard let nameNode, let def else { return }
            var node = def.0
            let kind = def.1
            // Bodiless overload signatures would repeat the implementation's name.
            let type = String(cString: ts_node_type(node))
            if type == "function_signature" { return }
            let parent = ts_node_parent(node)
            if type == "method_signature", String(cString: ts_node_type(parent)) == "class_body" { return }
            // Python decorators belong to the definition they decorate.
            if String(cString: ts_node_type(parent)) == "decorated_definition" { node = parent }
            guard !defs.contains(where: { ts_node_eq($0.node, node) }) else { return }
            defs.append(Def(name: text[nameNode], kind: kind, node: node, nameNode: nameNode))
        }
        // Outer definitions first, so a stack holds each one's enclosing chain.
        defs.sort { (ts_node_start_byte($0.node), ts_node_end_byte($1.node))
            < (ts_node_start_byte($1.node), ts_node_end_byte($0.node)) }
        var enclosing: [(name: String, kind: CodeSymbol.Kind?, end: UInt32)] = []
        var seen: [String: Int] = [:]
        return defs.compactMap { def in
            let end = ts_node_end_byte(def.node)
            while let last = enclosing.last, last.end < end { enclosing.removeLast() }
            let kind: CodeSymbol.Kind? = def.kind == .function && enclosing.last?.kind == .class ? .method : def.kind
            var name = (enclosing.map(\.name) + [def.name]).joined(separator: ".")
            enclosing.append((name: def.name, kind: kind, end: end))
            guard let kind else { return nil }
            // Repeated names (a property and its setter) get "#2", "#3"… in source order.
            seen[name, default: 0] += 1
            if let count = seen[name], count > 1 { name += "#\(count)" }
            let first = ts_node_start_point(def.node), last = ts_node_end_point(def.node)
            // A node ending at a line's column 0 ends on the line before.
            let lastLine = last.column == 0 && last.row > first.row ? last.row : last.row + 1
            return CodeSymbol(
                name: name, kind: kind, lines: Int(first.row) + 1...Int(lastLine),
                rawHash: text[def.node].hashValue,
                shapeHash: shapeHash(def.node, without: def.nameNode, text))
        }
    }

    /// Hash of the node's leaf tokens: whitespace between them and the
    /// definition's own name don't count.
    private func shapeHash(_ node: TSNode, without name: TSNode, _ text: SourceText) -> Int {
        var hasher = Hasher()
        var cursor = ts_tree_cursor_new(node)
        defer { ts_tree_cursor_delete(&cursor) }
        walk: while true {
            let current = ts_tree_cursor_current_node(&cursor)
            if ts_node_child_count(current) == 0, !ts_node_eq(current, name) {
                hasher.combine(text[current])
            }
            if ts_tree_cursor_goto_first_child(&cursor) { continue }
            while !ts_tree_cursor_goto_next_sibling(&cursor) {
                if !ts_tree_cursor_goto_parent(&cursor) { break walk }
            }
        }
        return hasher.finalize()
    }

    private func highlights(_ root: TSNode, _ query: Query, _ text: SourceText) -> [Int: [HighlightSpan]] {
        // Per node, the latest pattern wins (the queries go generic → specific),
        // except that a call or definition's function beats property/variable:
        // Python's `(attribute attribute: …) @property` comes after its method calls.
        func wins(_ new: TokenKind, _ pattern: Int, over old: (pattern: Int, kind: TokenKind)) -> Bool {
            let plain: Set<TokenKind> = [.property, .variable]
            if old.kind == .function, plain.contains(new) { return false }
            if new == .function, plain.contains(old.kind) { return true }
            return pattern >= old.pattern
        }
        var best: [Range<UInt32>: (pattern: Int, kind: TokenKind, start: TSPoint, end: TSPoint)] = [:]
        query.forEachMatch(root, text) { pattern, captures in
            for capture in captures {
                guard let kind = TokenKind(capture: query.captureNames[Int(capture.index)]) else { continue }
                let range = ts_node_start_byte(capture.node)..<ts_node_end_byte(capture.node)
                if range.isEmpty { continue }
                if let old = best[range], !wins(kind, pattern, over: (old.pattern, old.kind)) { continue }
                best[range] = (pattern, kind, ts_node_start_point(capture.node), ts_node_end_point(capture.node))
            }
        }
        var lines: [Int: [HighlightSpan]] = [:]
        for span in best.values {
            for row in Int(span.start.row)...Int(span.end.row) where row < text.lineCount {
                let from = row == Int(span.start.row) ? Int(span.start.column) : 0
                let to = row == Int(span.end.row) ? Int(span.end.column) : text.lineLength(row)
                let range = text.character(row, from)..<text.character(row, to)
                if !range.isEmpty { lines[row + 1, default: []].append(HighlightSpan(range: range, kind: span.kind)) }
            }
        }
        return lines.mapValues { $0.sorted { ($0.range.lowerBound, $1.range.upperBound) < ($1.range.lowerBound, $0.range.upperBound) } }
    }
}

private extension CodeLanguage {
    var grammar: OpaquePointer? {
        switch self {
        case .python: tree_sitter_python()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        }
    }
}

/// UTF-8 source with its line starts, for node text and byte → Character columns.
private final class SourceText {
    let bytes: [UInt8]
    private var lineStarts = [0]
    private var nonASCIILines = Set<Int>()
    private var columnTables: [Int: [Int]] = [:]   // byte offset → Character offset

    init(bytes: [UInt8]) {
        self.bytes = bytes
        for (index, byte) in bytes.enumerated() {
            if byte == 0x0A { lineStarts.append(index + 1) }
            else if byte >= 0x80 { nonASCIILines.insert(lineStarts.count - 1) }
        }
    }

    var lineCount: Int { lineStarts.count }

    func lineLength(_ row: Int) -> Int {
        (row + 1 < lineStarts.count ? lineStarts[row + 1] - 1 : bytes.count) - lineStarts[row]
    }

    subscript(node: TSNode) -> String {
        let start = Int(ts_node_start_byte(node)), end = min(Int(ts_node_end_byte(node)), bytes.count)
        return start < end ? String(decoding: bytes[start..<end], as: UTF8.self) : ""
    }

    func character(_ row: Int, _ byteColumn: Int) -> Int {
        guard nonASCIILines.contains(row) else { return byteColumn }
        if columnTables[row] == nil {
            let start = lineStarts[row]
            let line = String(decoding: bytes[start..<start + lineLength(row)], as: UTF8.self)
            var table: [Int] = []
            for (offset, character) in line.enumerated() {
                table += Array(repeating: offset, count: character.utf8.count)
            }
            columnTables[row] = table + [line.count]
        }
        let table = columnTables[row]!
        return table[min(byteColumn, table.count - 1)]
    }
}

/// A compiled query plus its text predicates, parsed once. Supports #eq?,
/// #not-eq?, #match?, #not-match?, #any-of?, #not-any-of?; other predicates
/// (#is-not? local) and directives (#strip!, #select-adjacent!) are ignored.
private final class Query {
    let query: OpaquePointer
    let captureNames: [String]
    private let predicates: [[Predicate]]   // by pattern index

    init?(_ language: OpaquePointer?, _ source: String, _ label: String) {
        var errorOffset: UInt32 = 0, error = TSQueryErrorNone
        let compiled = source.withCString {
            ts_query_new(language, $0, UInt32(source.utf8.count), &errorOffset, &error)
        }
        guard let compiled else {
            Log.app.error("\(label, privacy: .public) query error \(error.rawValue) at \(errorOffset)")
            return nil
        }
        query = compiled
        captureNames = (0..<ts_query_capture_count(compiled)).map { id in
            var length: UInt32 = 0
            let name = ts_query_capture_name_for_id(compiled, id, &length)
            return String(decoding: UnsafeRawBufferPointer(start: name, count: Int(length)), as: UTF8.self)
        }
        predicates = (0..<ts_query_pattern_count(compiled)).map { Predicate.all(compiled, pattern: $0) }
    }

    deinit { ts_query_delete(query) }

    /// Calls `body` with each match whose predicates hold.
    func forEachMatch(_ node: TSNode, _ text: SourceText, _ body: (Int, UnsafeBufferPointer<TSQueryCapture>) -> Void) {
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_exec(cursor, query, node)
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            let pattern = Int(match.pattern_index)
            if predicates[pattern].allSatisfy({ $0.holds(captures, text) }) { body(pattern, captures) }
        }
    }
}

private struct Predicate {
    enum Argument { case capture(UInt32), string(String) }
    let name: String
    let capture: UInt32
    let arguments: [Argument]
    let regex: NSRegularExpression?

    static func all(_ query: OpaquePointer, pattern: UInt32) -> [Predicate] {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, pattern, &count) else { return [] }
        func string(_ id: UInt32) -> String {
            var length: UInt32 = 0
            let value = ts_query_string_value_for_id(query, id, &length)
            return String(decoding: UnsafeRawBufferPointer(start: value, count: Int(length)), as: UTF8.self)
        }
        var result: [Predicate] = [], current: [Argument] = []
        for step in UnsafeBufferPointer(start: steps, count: Int(count)) {
            switch step.type {
            case TSQueryPredicateStepTypeCapture: current.append(.capture(step.value_id))
            case TSQueryPredicateStepTypeString: current.append(.string(string(step.value_id)))
            default:
                // Done: the first argument is the predicate's name.
                if case .string(let name)? = current.first, case .capture(let capture)? = current.dropFirst().first,
                   ["eq?", "not-eq?", "match?", "not-match?", "any-of?", "not-any-of?"].contains(name) {
                    var regex: NSRegularExpression?
                    if name.hasSuffix("match?"), case .string(let pattern)? = current.last {
                        regex = try? NSRegularExpression(pattern: pattern)
                        if regex == nil { Log.app.error("query regex doesn't compile: \(pattern, privacy: .public)") }
                    }
                    result.append(Predicate(name: name, capture: capture, arguments: Array(current.dropFirst(2)), regex: regex))
                }
                current = []
            }
        }
        return result
    }

    func holds(_ captures: UnsafeBufferPointer<TSQueryCapture>, _ text: SourceText) -> Bool {
        func value(_ argument: Argument) -> String? {
            switch argument {
            case .string(let string): string
            case .capture(let id): captures.first { $0.index == id }.map { text[$0.node] }
            }
        }
        let negated = name.hasPrefix("not-")
        return captures.filter { $0.index == capture }.allSatisfy { captured in
            let string = text[captured.node]
            let found = switch name {
            case "eq?", "not-eq?": arguments.first.flatMap(value) == string
            case "match?", "not-match?":
                regex?.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
            default: arguments.contains { value($0) == string }
            }
            return found != negated
        }
    }
}
