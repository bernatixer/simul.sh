import Foundation

enum ChatMarkdown {
    static let cache = Cache()

    /// NSCache is thread-safe; cached blocks are immutable values.
    final class Cache: @unchecked Sendable {
        private final class Value {
            let blocks: [Block]
            init(_ blocks: [Block]) { self.blocks = blocks }
        }
        private let values: NSCache<NSString, Value> = {
            let cache = NSCache<NSString, Value>()
            cache.countLimit = 256
            cache.totalCostLimit = 16 * 1024 * 1024
            return cache
        }()
        func cached(_ text: String) -> [Block]? { values.object(forKey: text as NSString)?.blocks }
        func blocks(_ text: String) -> [Block] {
            if let cached = cached(text) { return cached }
            let parsed = ChatMarkdown.parse(text)
            values.setObject(Value(parsed), forKey: text as NSString, cost: text.utf8.count * 4)
            return parsed
        }
        func prewarm(_ entries: [ChatEntry]) {
            for case let .reply(_, text) in entries { _ = blocks(text) }
        }
    }

    struct Block: Identifiable, Equatable, Sendable {
        let id: Int
        let kind: PresentationIntent.Kind
        var text = AttributedString()
        var children: [Block] = []
        var task: Bool?
    }

    static func parse(_ source: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return source.isEmpty ? [] : [Block(id: 1, kind: .paragraph, text: AttributedString(source))]
        }
        var blocks: [Block] = []
        for (index, run) in parsed.runs.enumerated() {
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            // boffin: Kept link actions to web pages and email.
            if let link = text.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                text.link = nil
            }
            if let intent = run.presentationIntent {
                append(text, along: Array(intent.components.reversed())[...], to: &blocks)
            } else {
                // HTML has no block intent; keep it as selectable literal text.
                let id = -(run.markdownSourcePosition?.startLine ?? (index + 1))
                blocks.append(Block(id: id, kind: .paragraph, text: text))
            }
        }
        tasks(in: &blocks, sourceLines: source.split(separator: "\n", omittingEmptySubsequences: false))
        return blocks
    }

    private static func append(_ text: AttributedString, along path: ArraySlice<PresentationIntent.IntentType>,
                               to blocks: inout [Block]) {
        guard let component = path.first else { return }
        if blocks.last?.id != component.identity {
            blocks.append(Block(id: component.identity, kind: component.kind))
        }
        let last = blocks.count - 1
        if path.count == 1 {
            blocks[last].text.append(text)
        } else {
            append(text, along: path.dropFirst(), to: &blocks[last].children)
        }
    }

    private static func tasks(in blocks: inout [Block], sourceLines: [Substring]) {
        for index in blocks.indices {
            tasks(in: &blocks[index].children, sourceLines: sourceLines)
            guard case .listItem = blocks[index].kind,
                  let paragraph = blocks[index].children.first, paragraph.kind == .paragraph,
                  let position = paragraph.text.runs.first?.markdownSourcePosition,
                  sourceLines.indices.contains(position.startLine - 1) else { continue }
            let marker = Array(sourceLines[position.startLine - 1].utf8.dropFirst(position.startColumn - 1).prefix(4))
            guard marker.count >= 3, marker[0] == 91, marker[2] == 93,
                  [32, 88, 120].contains(marker[1]),
                  marker.count == 3 || marker[3] == 32 || marker[3] == 9 else { continue }
            blocks[index].task = marker[1] != 32
            var text = paragraph.text
            let count = text.characters.dropFirst(3).first?.isWhitespace == true ? 4 : 3
            let end = text.characters.index(text.startIndex, offsetBy: count)
            text.removeSubrange(text.startIndex..<end)
            blocks[index].children[0].text = text
        }
    }
}
