import Foundation
@testable import SimulCore

@MainActor
func registerChatMarkdownTests() {
    test("chat markdown: headings and inline styles stay in their blocks") {
        let blocks = ChatMarkdown.parse("# Title\n\nA **bold** word, `code`, and [link](https://example.com).")
        guard blocks.count == 2 else { return expect(false, "heading and paragraph") }
        expectEqual(blocks[0].kind, .header(level: 1), "heading level")
        expectEqual(String(blocks[0].text.characters), "Title", "heading text")
        expectEqual(blocks[1].kind, .paragraph, "paragraph")
        let runs = blocks[1].text.runs
        expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold retained")
        expect(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "inline code retained")
        expect(runs.contains { $0.link == URL(string: "https://example.com") }, "web link retained")
    }

    test("chat markdown: task lists keep nesting and inline formatting") {
        let blocks = ChatMarkdown.parse("- [x] **Done**\n- [ ] Open\n  1. Nested\n\n> First\n>\n> Second")
        guard blocks.count == 2, blocks[0].children.count == 2 else {
            return expect(false, "list and quote")
        }
        let items = blocks[0].children
        expectEqual(blocks[0].kind, .unorderedList, "unordered list")
        expectEqual(items.map(\.task), [true, false], "task states")
        expectEqual(String(items[0].children[0].text.characters), "Done", "task marker removed")
        expect(items[0].children[0].text.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }, "formatting survives marker removal")
        expectEqual(items[1].children[1].kind, .orderedList, "nested list")
        expectEqual(blocks[1].kind, .blockQuote, "block quote")
        expectEqual(blocks[1].children.map { String($0.text.characters) }, ["First", "Second"], "quote paragraphs")
    }

    test("chat markdown: literal task markers are not checkboxes") {
        let blocks = ChatMarkdown.parse("- `[x]` code\n- \\[x] escaped\n- **[x]** bold")
        guard let list = blocks.first, list.children.count == 3 else { return expect(false, "three items") }
        expect(list.children.allSatisfy { $0.task == nil }, "only source task markers become checkboxes")
        expectEqual(list.children.map { String($0.children[0].text.characters) },
                    ["[x] code", "[x] escaped", "[x] bold"], "literal markers remain visible")
    }

    test("chat markdown: tables retain cell columns and alignment") {
        let blocks = ChatMarkdown.parse("| Name | Count |\n| :--- | ---: |\n| **A** | 2 |\n| | 3 |")
        guard let table = blocks.first, case let .table(columns) = table.kind,
              table.children.count == 3 else { return expect(false, "table with header and two rows") }
        expectEqual(columns.map(\.alignment), [.left, .right], "table alignment")
        expectEqual(table.children[0].kind, .tableHeaderRow, "header row")
        expectEqual(table.children[1].children.map { String($0.text.characters) }, ["A", "2"], "body cells")
        expectEqual(table.children[2].children[0].kind, .tableCell(columnIndex: 1), "empty cells keep later columns in place")
    }

    test("chat markdown: fences preserve code and stable prior blocks while streaming") {
        let prefix = "Before\n\n```swift\nlet value = 1"
        let partial = ChatMarkdown.parse(prefix)
        let complete = ChatMarkdown.parse(prefix + "\nprint(value)\n```\n\nAfter")
        guard partial.count == 2, complete.count == 3 else { return expect(false, "prose, code, then prose") }
        expectEqual(partial[0], complete[0], "completed prose stays unchanged")
        expectEqual(partial[1].id, complete[1].id, "streaming code keeps its identity")
        expectEqual(partial[1].kind, .codeBlock(languageHint: "swift"), "fence language")
        expectEqual(String(partial[1].text.characters), "let value = 1\n", "open fence is code")
        expectEqual(String(complete[1].text.characters), "let value = 1\nprint(value)\n", "code is not parsed as prose")
        let tildes = ChatMarkdown.parse("~~~~text\n``` is literal\n~~~~")
        expectEqual(tildes.first?.kind, .codeBlock(languageHint: "text"), "tilde fence")
        expectEqual(tildes.first.map { String($0.text.characters) }, "``` is literal\n", "other fence marker is literal code")
    }

    test("chat markdown: HTML stays literal and unsupported links lose their action") {
        let blocks = ChatMarkdown.parse("<script>alert('x')</script>\n\nText <b>literal</b> [bad](javascript:alert) [mail](mailto:a@example.com)")
        guard blocks.count == 2 else { return expect(false, "HTML and paragraph") }
        expectEqual(String(blocks[0].text.characters), "<script>alert('x')</script>\n", "raw HTML stays visible")
        expect(String(blocks[1].text.characters).contains("<b>literal</b>"), "inline HTML stays visible")
        expect(!blocks[1].text.runs.contains { $0.link?.scheme == "javascript" }, "unsupported scheme has no link action")
        expect(blocks[1].text.runs.contains { $0.link?.scheme == "mailto" }, "email links work")
        expect(ChatMarkdown.parse("").isEmpty, "empty text has no blocks")
    }
}
