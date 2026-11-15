import ImageIO
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    let session: Session
    static let lightBackground = Theme.chatBackground

    var body: some View {
        Group {
            if let chat = app.chats.sessions[session.id] {
                ChatConversationView(session: session, chat: chat)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Self.lightBackground)
        .foregroundStyle(Theme.primaryText)
        .tint(Theme.chatAccent)
        .task(id: session.id) { await app.startChat(session) }
    }
}

private struct ChatConversationView: View {
    @Environment(AppModel.self) private var app
    let session: Session
    @Bindable var chat: ChatSessionModel
    @State private var visibleCount = 200
    @State private var reading = ChatReadingPosition()
    @State private var unread = 0
    @State private var restoring: String?
    @State private var loadingEarlier = false
    @State private var latestVisible = true

    init(session: Session, chat: ChatSessionModel) {
        self.session = session
        self.chat = chat
        let anchor = chat.state.followsLatest ? nil : chat.state.readingAnchor
        let index = anchor.flatMap { id in chat.state.conversation.entries.firstIndex(where: { $0.id == id }) }
        _visibleCount = State(initialValue: index.map { max(200, chat.state.conversation.entries.count - $0) } ?? 200)
        _restoring = State(initialValue: index == nil ? nil : anchor)
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            if !chat.state.requests.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(chat.state.requests) { request in
                            ChatRequestCard(request: request) { decision, answers in
                                app.chats.respond(request, id: session.id, decision: decision, answers: answers)
                            }
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: 808)
                        .frame(maxWidth: .infinity)
                }.frame(maxHeight: 280)
            }
            ChatComposer(session: session, chat: chat)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if chat.state.conversation.entries.count > visibleCount {
                        Button("Load earlier messages") {
                            guard !loadingEarlier else { return }
                            loadingEarlier = true
                            let first = chat.state.conversation.entries.suffix(visibleCount).first?.id
                            let entries = Array(chat.state.conversation.entries.suffix(visibleCount + 200))
                            Task {
                                defer { loadingEarlier = false }
                                await Task.detached(priority: .userInitiated) { ChatMarkdown.cache.prewarm(entries) }.value
                                visibleCount += 200
                                if let first { proxy.scrollTo(first, anchor: .top) }
                            }
                        }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText).padding(.top, 20).disabled(loadingEarlier)
                    }
                    ChatRows(
                        entries: Array(chat.state.conversation.entries.suffix(visibleCount)),
                        expanded: Binding(get: { chat.state.expanded }, set: { expanded in
                            app.chats.update(session.id) { $0.expanded = expanded }
                            app.chats.saveSoon(session.id)
                        }),
                        pending: chat.state.outbox.first(where: { $0.status == .sending })?.message.pieces,
                        activity: chat.state.isBusy ? .init(since: app.workingSince[session.id] ?? session.lastOpenedAt,
                                                           asking: chat.state.phase == .waiting) : nil,
                        attachments: chat.state.attachments, reading: reading
                    )
                    if chat.state.conversation.entries.isEmpty, !chat.state.isBusy {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30, weight: .ultraLight))
                                .foregroundStyle(Theme.mutedText)
                            Text("What would you like to work on?").font(.system(size: 20, weight: .medium))
                            Text("Your conversation stays with this session.").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                }
                .background(ChatScrollObserver { nearBottom, interaction in
                    if latestVisible != nearBottom { latestVisible = nearBottom }
                    if interaction == .scroll || interaction == .selection {
                        if restoring != nil { restoring = nil }
                        // boffin: pausing for text selection does not mean the latest message is offscreen.
                        app.chats.update(session.id) { $0.followsLatest = interaction == .scroll && nearBottom }
                        if !nearBottom { saveAnchor() }
                        if nearBottom { unread = 0 }
                    } else if restoring != nil {
                        restore(using: proxy)
                    } else if chat.state.followsLatest, !nearBottom {
                        proxy.scrollTo(ChatRows.bottomID, anchor: .bottom)
                    }
                })
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottom) {
                if !latestVisible, !chat.state.followsLatest {
                    Button {
                        app.chats.update(session.id) { $0.followsLatest = true; $0.readingAnchor = nil }
                        unread = 0
                        proxy.scrollTo(ChatRows.bottomID, anchor: .bottom)
                    } label: {
                        Label(unread > 0 ? "\(unread) new updates" : "Jump to latest", systemImage: "arrow.down")
                            .font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.chatBackground, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.chatBorder))
                    }.buttonStyle(.plain).padding(10)
                }
            }
            .onAppear {
                reading.onLayout = { if restoring != nil { restore(using: proxy) } }
                if let saved = restoring {
                    DispatchQueue.main.async { proxy.scrollTo(saved, anchor: .top) }
                } else { proxy.scrollTo(ChatRows.bottomID, anchor: .bottom) }
            }
            .onDisappear { saveAnchor(); reading.onLayout = nil }
            .onChange(of: chat.state.conversation.revision) {
                if chat.state.followsLatest { proxy.scrollTo(ChatRows.bottomID, anchor: .bottom) }
                else { unread += 1 }
            }
            .onChange(of: chat.state.outbox.count) {
                if chat.state.followsLatest { proxy.scrollTo(ChatRows.bottomID, anchor: .bottom) }
            }
        }
    }

    private func restore(using proxy: ScrollViewProxy) {
        guard let saved = restoring else { return }
        if reading.isVisible(saved) { restoring = nil }
        else { proxy.scrollTo(saved, anchor: .top) }
    }

    private func saveAnchor() {
        guard !chat.state.followsLatest, restoring == nil, let first = reading.firstVisibleID,
              chat.state.readingAnchor != first else { return }
        app.chats.update(session.id) { $0.readingAnchor = first }
        app.chats.saveSoon(session.id)
    }
}

struct ChatRows: View {
    let entries: [ChatEntry]
    @Binding var expanded: Set<String>
    var pending: [PromptPiece]?
    var activity: Activity?
    var attachments: [String: [URL]] = [:]
    var reading: ChatReadingPosition?
    static let bottomID = "chat-bottom"
    struct Activity: Equatable { let since: Date; let asking: Bool }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(entries) { entry in
                row(entry).id(entry.id).background {
                    if let reading { ChatRowMarker(id: entry.id, reading: reading).allowsHitTesting(false) }
                }
            }
            if let pending { PromptBubble(pending: pending).equatable().opacity(0.65) }
            if let activity {
                HStack(spacing: 8) {
                    Image(systemName: activity.asking ? "questionmark.bubble" : "ellipsis")
                    if activity.asking { Text("Waiting for your answer") }
                    else {
                        TimelineView(.periodic(from: activity.since, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(activity.since)))
                            Text("Working  \(seconds / 60 > 0 ? "\(seconds / 60)m " : "")\(seconds % 60)s").monospacedDigit()
                        }
                    }
                }.font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Color.clear.frame(height: 1).id(Self.bottomID)
        }
        .scrollTargetLayout()
        .frame(maxWidth: 760).padding(.horizontal, 24).padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func row(_ entry: ChatEntry) -> some View {
        switch entry {
        case let .prompt(id, text, images):
            PromptBubble(text: text, images: images.isEmpty
                         ? (attachments[id] ?? []).map(PromptImage.Source.file) : images.map(PromptImage.Source.data)).equatable()
        case let .reply(_, text):
            ChatMarkdownView(text: text).equatable().contextMenu { Button("Copy message") { copy(text) } }
        case let .tools(id, tools): ToolRun(tools: tools, open: binding(id), expanded: $expanded)
        case let .note(_, text):
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity)
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

private struct PromptBubble: View, Equatable {
    let text: String
    let images: [PromptImage.Source]
    init(text: String, images: [PromptImage.Source]) { self.text = text; self.images = images }
    init(pending: [PromptPiece]) {
        text = pending.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined()
        images = pending.compactMap { if case let .image(url) = $0 { .file(url) } else { nil } }
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 108))], alignment: .trailing, spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, source in PromptImage(source: source) }
                }.frame(maxWidth: 450)
            }
            if !text.isEmpty {
                Text(text).font(.system(size: 13.5)).lineSpacing(2).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.chatPrompt, in: RoundedRectangle(cornerRadius: 14))
                    .contextMenu { Button("Copy message") { copy(text) } }
            }
        }.frame(maxWidth: 590, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct PromptImage: View {
    enum Source: Hashable { case data(Data), file(URL) }
    let source: Source
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Color.primary.opacity(0.06).overlay { Image(systemName: "photo").foregroundStyle(Theme.mutedText) } }
        }
        .frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
        .task(id: source) {
            let source = source
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                switch source {
                case let .data(data):
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 176] as CFDictionary)
                case let .file(url): return ClipboardPaste.thumbnail(of: url, maxPixels: 176)
                }
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { image = NSImage(cgImage: decoded, size: .zero) }
        }.accessibilityLabel("Attached image")
        .contextMenu {
            if case let .file(url) = source { Button("Open image") { NSWorkspace.shared.open(url) } }
        }
    }
}

private struct ToolRun: View {
    let tools: [ChatTool]
    @Binding var open: Bool
    @Binding var expanded: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tools.count > 1 {
                Button { open.toggle() } label: {
                    Label("\(tools.count) tool calls", systemImage: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }.buttonStyle(.plain)
            }
            if open || tools.count == 1 {
                ForEach(tools) { tool in
                    ChatToolRow(tool: tool, open: Binding(get: { expanded.contains(tool.id) }, set: {
                        if $0 { expanded.insert(tool.id) } else { expanded.remove(tool.id) }
                    }))
                }
            }
        }
    }
}

private struct ChatToolRow: View {
    let tool: ChatTool
    @Binding var open: Bool
    @State private var showingOutput = false
    @State private var preview = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .medium))
                    Image(systemName: tool.isError ? "exclamationmark.circle" : tool.result == nil ? "ellipsis.circle" : "checkmark.circle")
                        .foregroundStyle(tool.isError ? Theme.errorText : Theme.secondaryText)
                    Text(tool.name).fontWeight(.medium)
                    Text(tool.summary).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if !tool.detail.isEmpty { outputText(String(tool.detail.prefix(4000))) }
                    if tool.result != nil {
                        Divider()
                        outputText(preview)
                        HStack {
                            Button("Open full output") { showingOutput = true }
                            Button("Copy output") { copy(tool.result ?? "") }
                        }.font(.system(size: 11)).buttonStyle(.link)
                    }
                }.padding(12).background(Theme.chatPrompt, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: tool.result) {
            let result = tool.result ?? ""
            let text = await Task.detached {
                result.utf8.count > 6500 ? String(result.prefix(3000)) + "\n\n…\n\n" + String(result.suffix(3000)) : result
            }.value
            if !Task.isCancelled, preview != text { preview = text }
        }
        .sheet(isPresented: $showingOutput) {
            VStack(spacing: 0) {
                HStack { Text(tool.summary.isEmpty ? tool.name : tool.summary).lineLimit(1); Spacer(); Button("Done") { showingOutput = false } }
                    .padding(14)
                Divider()
                ChatOutputView(text: tool.detail + "\n\n" + (tool.result ?? ""))
            }.frame(minWidth: 650, minHeight: 440)
        }
    }
    private func outputText(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true).foregroundStyle(tool.isError ? Theme.errorText : Theme.secondaryText)
        }
    }
}

struct ChatOutputView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = Theme.primaryLabel
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.usesFindPanel = true
        view.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
