import ImageIO
import SwiftUI

/// A Claude session's conversation as a chat: your prompts as bubbles,
/// replies as plain text, tool calls folded into one line per run, and a
/// message box that types into the session's terminal. It reads Claude's
/// transcript (ChatTranscripts reads only what was appended): on opening,
/// when a turn starts or ends, and twice a second while Claude works.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    /// Shared with the review: one Light / Dark for both.
    @AppStorage(Preferences.Key.reviewLight) private var light = false
    @State private var conversation: ChatConversation?
    @State private var loaded = false
    @State private var expanded: Set<String> = []
    /// The end of the conversation is on screen: new rows scroll into view.
    /// Scrolled up to read, they don't.
    @State private var atBottom = true
    /// What you just sent from the box, shown until the transcript has it:
    /// Claude Code writes it only after its submit hooks have run.
    @State private var pending: Pending?

    static let lightBackground = Color(white: 0.985)

    private struct Pending: Equatable {
        let pieces: [PromptPiece]
        let sentAt: Date
        /// The transcript's prompt count when it was sent.
        let prompts: Int
    }

    private struct Reload: Equatable {
        let transcriptID: String?
        let turnStarted: Date?
        let sentAt: Date?
    }

    var body: some View {
        let transcriptID = model.claudeTranscriptID(session)
        let turnStarted = model.workingSince[session.id]
        let since = turnStarted ?? pending?.sentAt
        // Once the transcript records the turn's end, stop: Simul's own
        // turn-end check trails it by a few seconds.
        let active = since != nil && (pending != nil || conversation?.turnOpen != false)
        VStack(spacing: 0) {
            messages(activeSince: active ? since : nil)
            ChatComposer(session: session, conversation: conversation) { pieces in
                pending = Pending(pieces: pieces, sentAt: Date(), prompts: conversation?.prompts ?? 0)
            } onUnsent: {
                pending = nil
            }
        }
        .background(light ? Self.lightBackground : Theme.background)
        .environment(\.colorScheme, light ? .light : .dark)
        .overlay(alignment: .topTrailing) {
            Button { light.toggle() } label: {
                Image(systemName: light ? "moon" : "sun.max")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(light ? "Dark (Chat and Review)" : "Light (Chat and Review)")
            .accessibilityLabel(light ? "Dark colours" : "Light colours")
            .padding(10)
        }
        .task(id: Reload(transcriptID: transcriptID, turnStarted: turnStarted, sentAt: pending?.sentAt)) {
            guard let transcriptID else { return }
            await load(transcriptID)
            // Polls only mid-turn (or just sent): idle, nothing runs.
            while turnStarted != nil || pending != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                await load(transcriptID)
                // Sent, but it never reached the transcript and no turn started.
                if turnStarted == nil, let sent = pending?.sentAt, Date().timeIntervalSince(sent) > 20 { pending = nil }
            }
        }
    }

    private func load(_ transcriptID: String) async {
        let fresh = await ChatTranscripts.shared.conversation(id: transcriptID)
        if fresh?.revision != conversation?.revision || (fresh == nil) != (conversation == nil) { conversation = fresh }
        if let pending, (fresh?.prompts ?? 0) > pending.prompts { self.pending = nil }
        if !loaded { loaded = true }
    }

    @ViewBuilder
    private func messages(activeSince: Date?) -> some View {
        let entries = conversation?.entries ?? []
        if !entries.isEmpty || activeSince != nil || pending != nil {
            ScrollViewReader { proxy in
                ScrollView {
                    ChatRows(entries: entries, expanded: $expanded, pending: pending?.pieces,
                             activity: activeSince.map { .init(since: $0, asking: model.waitingIDs.contains(session.id)) }) { visible in
                        if atBottom != visible { atBottom = visible }
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: conversation?.revision) {
                    if atBottom { proxy.scrollTo(ChatRows.bottomID, anchor: .bottom) }
                }
                .onChange(of: activeSince) {
                    if atBottom { proxy.scrollTo(ChatRows.bottomID, anchor: .bottom) }
                }
                .onChange(of: pending) {
                    // Your own message: always into view.
                    if pending != nil { proxy.scrollTo(ChatRows.bottomID, anchor: .bottom) }
                }
            }
        } else {
            Group {
                if loaded {
                    Text(conversation == nil ? "No conversation yet" : "No messages yet").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The conversation's rows in a centred column; ChatView scrolls them.
struct ChatRows: View {
    let entries: [ChatEntry]
    @Binding var expanded: Set<String>
    /// Just sent from the box, not in the transcript yet.
    var pending: [PromptPiece]?
    /// Claude is on a turn (or was just sent one): a row under the last entry.
    var activity: Activity?
    /// Whether the end of the list is on screen (lazily laid out, so it
    /// comes and goes with scrolling).
    var bottomVisible: (Bool) -> Void = { _ in }

    static let bottomID = "chat-bottom"

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { entry in row(entry).id(entry.id) }
            if let pending { PromptBubble(pending: pending) }
            if let activity { ActivityRow(activity: activity) }
            Color.clear.frame(height: 1).id(Self.bottomID)
                .onAppear { bottomVisible(true) }
                .onDisappear { bottomVisible(false) }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ entry: ChatEntry) -> some View {
        switch entry {
        case let .prompt(_, text, images):
            PromptBubble(text: text, images: images.map(PromptImage.Source.data))
        case let .reply(_, text):
            MarkdownText(text: text)
        case let .tools(id, tools):
            ToolRun(tools: tools, open: binding(id), expanded: $expanded)
        case let .note(_, text):
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }
}


extension ChatRows {
    struct Activity: Equatable {
        let since: Date
        /// Mid-turn but waiting on you (a question, a permission prompt).
        let asking: Bool
    }
}

/// "Working  12s" under the last entry while Claude is on a turn; the time
/// ticks only while it shows.
private struct ActivityRow: View {
    let activity: ChatRows.Activity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.asking ? "questionmark.bubble" : "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !activity.asking && !reduceMotion)
                .frame(width: 16)
            if activity.asking {
                Text("Waiting for your answer in Agent")
            } else {
                TimelineView(.periodic(from: activity.since, by: 1)) { context in
                    Text("Working") + Text("  " + Self.elapsed(context.date.timeIntervalSince(activity.since)))
                        .foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}

/// Your message: images above, text in a bubble, on the right.
private struct PromptBubble: View {
    let text: String
    let images: [PromptImage.Source]

    init(text: String, images: [PromptImage.Source]) {
        self.text = text
        self.images = images
    }

    /// A message as sent from the box, before the transcript has it.
    init(pending: [PromptPiece]) {
        var text = ""
        var images: [PromptImage.Source] = []
        for piece in pending {
            switch piece {
            case let .text(part): text += part
            case let .image(url): images.append(.file(url))
            }
        }
        self.init(text: text.trimmingCharacters(in: .whitespacesAndNewlines), images: images)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, source in PromptImage(source: source) }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.09)))
            }
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// An image you sent, as a thumbnail; decoded once, off the main thread.
private struct PromptImage: View {
    enum Source: Hashable {
        /// A transcript's thumbnail (JPEG).
        case data(Data)
        /// The box's copy, before the transcript has it.
        case file(URL)
    }

    let source: Source
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .task(id: source) {
            let source = source
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                switch source {
                case let .data(data):
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(image, 0, nil)
                case let .file(url):
                    return ClipboardPaste.thumbnail(of: url, maxPixels: 192)
                }
            }.value
            if let decoded { image = NSImage(cgImage: decoded, size: .zero) }
        }
        .accessibilityLabel("Image")
    }
}

/// A run of tool calls: one line ("3 tool calls · Read, Ran"), each call
/// its own line when opened, its input and output when that is opened.
private struct ToolRun: View {
    let tools: [ChatTool]
    @Binding var open: Bool
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tools.count == 1 {
                call(tools[0])
            } else {
                Disclosure(open: $open, failed: tools.contains(where: \.isError)) {
                    Text("\(tools.count) tool calls").foregroundStyle(.primary)
                    + Text("  " + verbs).foregroundStyle(.secondary)
                }
                if open {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tools) { call($0) }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    private var verbs: String {
        var seen: [String] = []
        for tool in tools where !seen.contains(Self.verb(tool.name)) { seen.append(Self.verb(tool.name)) }
        return seen.joined(separator: ", ")
    }

    @ViewBuilder
    private func call(_ tool: ChatTool) -> some View {
        let open = Binding(
            get: { expanded.contains(tool.id) },
            set: { if $0 { expanded.insert(tool.id) } else { expanded.remove(tool.id) } }
        )
        Disclosure(open: open, failed: tool.isError) {
            Text(Self.verb(tool.name)).foregroundStyle(.primary)
            + Text("  " + tool.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
        if open.wrappedValue {
            VStack(alignment: .leading, spacing: 0) {
                CodeBlock(text: tool.detail)
                if let result = tool.result, !result.isEmpty {
                    Divider().opacity(0.4)
                    CodeBlock(text: result, color: tool.isError ? .red.opacity(0.85) : .secondary)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.leading, 14)
        }
    }

    /// What Claude Code's own UI calls each tool.
    static func verb(_ name: String) -> String {
        switch name {
        case "Bash": return "Ran"
        case "Read": return "Read"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edited"
        case "Write": return "Wrote"
        case "Grep", "Glob": return "Searched"
        case "WebFetch": return "Fetched"
        case "WebSearch": return "Searched the web"
        case "Agent", "Task": return "Agent"
        case "TodoWrite": return "Updated todos"
        default:
            return name.hasPrefix("mcp__") ? name.split(separator: "__").last.map(String.init) ?? name : name
        }
    }
}

/// A chevron and a one-line label that opens and closes.
private struct Disclosure<Label: View>: View {
    @Binding var open: Bool
    let failed: Bool
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                label()
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if failed {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            .opacity(hovering ? 1 : 0.8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct CodeBlock: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}

/// Inline markdown (bold, code, links) with fenced code as blocks and
/// headings in bold; lists and tables stay as written.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parts(text).enumerated()), id: \.offset) { _, part in
                if part.code {
                    CodeBlock(text: part.text)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                } else {
                    Text(Self.inline(part.text))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Prose and ``` fenced code, in order.
    static func parts(_ text: String) -> [(code: Bool, text: String)] {
        var parts: [(code: Bool, text: String)] = []
        var lines: [Substring] = []
        var inCode = false
        func flush() {
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { parts.append((inCode, joined)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return parts
    }

    static func inline(_ prose: String) -> AttributedString {
        let headed = prose.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let heading = line.drop { $0 == "#" }
            return heading.count < line.count && heading.hasPrefix(" ")
                ? "**\(heading.trimmingCharacters(in: .whitespaces))**" : String(line)
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: headed, options: options)) ?? AttributedString(prose)
    }
}
