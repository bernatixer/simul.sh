import SwiftUI

struct ChatMarkdownView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
    let text: String
    @State private var blocks: [ChatMarkdown.Block] = []

    init(text: String) {
        self.text = text
        _blocks = State(initialValue: ChatMarkdown.cache.cached(text) ?? [])
    }

    var body: some View {
        Group {
            if blocks.isEmpty, !text.isEmpty { Text(text).frame(maxWidth: .infinity, alignment: .leading) }
            else { ChatMarkdownBlocks(blocks: blocks) }
        }
            .font(.system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: text) {
                let source = text
                if let cached = ChatMarkdown.cache.cached(source) {
                    if blocks != cached { blocks = cached }
                    return
                }
                let parsing = Task.detached(priority: .userInitiated) {
                    Task.isCancelled ? [] : ChatMarkdown.cache.blocks(source)
                }
                let fresh = await withTaskCancellationHandler {
                    await parsing.value
                } onCancel: {
                    parsing.cancel()
                }
                // boffin: Keep the visible blocks until the current revision is fully parsed.
                guard !Task.isCancelled else { return }
                if blocks != fresh { blocks = fresh }
            }
    }
}

private struct ChatMarkdownBlocks: View {
    let blocks: [ChatMarkdown.Block]
    var spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in ChatMarkdownBlock(block: block).equatable() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMarkdownBlock: View, Equatable {
    let block: ChatMarkdown.Block

    var body: some View {
        switch block.kind {
        case let .header(level):
            Text(block.text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case let .codeBlock(language):
            ChatMarkdownCode(text: String(block.text.characters), language: language)
        case .orderedList:
            list(ordered: true)
        case .unorderedList:
            list(ordered: false)
        case .blockQuote:
            ChatMarkdownBlocks(blocks: block.children, spacing: 8)
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.2)).frame(width: 3)
                }
        case let .table(columns):
            ChatMarkdownTable(rows: block.children, columns: columns)
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        default:
            if block.children.isEmpty {
                Text(block.text).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ChatMarkdownBlocks(blocks: block.children)
            }
        }
    }

    private func list(ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(block.children) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if let checked = item.task {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .accessibilityLabel(checked ? "Completed" : "Incomplete")
                        } else if ordered, case let .listItem(ordinal) = item.kind {
                            Text("\(ordinal).").monospacedDigit()
                        } else {
                            Text("•")
                        }
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minWidth: 18, alignment: .trailing)
                    ChatMarkdownBlocks(blocks: item.children, spacing: 6)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 25
        case 2: 21
        case 3: 18
        case 4: 16
        default: 14
        }
    }
}

private struct ChatMarkdownCode: View {
    let text: String
    let language: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language ?? "Code")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.chatPrompt)
            Theme.chatBorder.frame(height: 1)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Theme.chatPrompt)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chatBorder))
    }
}

private struct ChatMarkdownTable: View {
    let rows: [ChatMarkdown.Block]
    let columns: [PresentationIntent.TableColumn]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows) { row in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { index in
                            let cell = row.children.first { $0.kind == .tableCell(columnIndex: index) }
                            Text(cell?.text ?? AttributedString())
                                .font(.system(size: 13, weight: row.kind == .tableHeaderRow ? .semibold : .regular))
                                .frame(minWidth: 70, maxWidth: 280, alignment: alignment(columns[index].alignment))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(row.kind == .tableHeaderRow ? Theme.chatPrompt : .clear)
                                .overlay(alignment: .bottom) { Theme.chatBorder.frame(height: 1) }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chatBorder))
        }
    }

    private func alignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}
