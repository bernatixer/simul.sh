import CTreeSitter
import Foundation

@MainActor
func registerTreeSitterTests() {
    test("tree-sitter: parses each language") {
        let cases: [(String, OpaquePointer?, String, String)] = [
            ("python", tree_sitter_python(), "def f(x): return x\n", "module"),
            ("javascript", tree_sitter_javascript(), "const f = (x) => x;\n", "program"),
            ("typescript", tree_sitter_typescript(), "const f = (x: number): number => x;\n", "program"),
            ("tsx", tree_sitter_tsx(), "const a = <div>{x}</div>;\n", "program"),
        ]
        for (name, language, source, rootType) in cases {
            guard let parser = ts_parser_new() else { expect(false, "\(name): parser"); continue }
            defer { ts_parser_delete(parser) }
            expect(ts_parser_set_language(parser, language), "\(name): language ABI accepted")
            let tree = source.withCString { ts_parser_parse_string(parser, nil, $0, UInt32(strlen($0))) }
            guard let tree else { expect(false, "\(name): parse"); continue }
            defer { ts_tree_delete(tree) }
            let root = ts_tree_root_node(tree)
            expectEqual(String(cString: ts_node_type(root)), rootType, "\(name): root node type")
            expect(!ts_node_has_error(root), "\(name): no syntax errors")
        }
    }
}
