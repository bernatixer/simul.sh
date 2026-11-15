import AppKit
import SwiftUI

struct ChatComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorSchemeContrast) private var contrast
    let session: Session
    @Bindable var chat: ChatSessionModel
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var height: CGFloat = 36
    @State private var focusRequest = 0

    private var parts: Binding<[ComposerPart]> {
        Binding(get: { chat.state.draft }, set: { app.chats.setDraft($0, for: session.id) })
    }
    private var pieces: [PromptPiece] { ComposerPart.pieces(chat.state.draft) }
    private var images: [ComposerImage] { chat.state.draft.compactMap { if case let .image(image) = $0 { image } else { nil } } }
    private var canSend: Bool { app.chats.connected.contains(session.id) && ![.connecting, .disconnected].contains(chat.state.phase) && !pieces.isEmpty }
    private var imagesFolder: URL { Paths.applicationSupport.appendingPathComponent("chat/attachments/\(session.id.uuidString)", isDirectory: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectionStatus
            if let notice = chat.state.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(notice).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { app.chats.update(session.id) { $0.notice = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }.font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 6)
            }
            if !chat.state.outbox.isEmpty { queue }
            VStack(alignment: .leading, spacing: 10) {
                if !images.isEmpty { attachments }
                ComposerTextView(parts: parts, height: $height, placeholder: "Message \(app.agent(for: session)?.name ?? "agent")…",
                                 focusRequest: focusRequest, imagesFolder: imagesFolder, onSubmit: send)
                    .frame(height: height)
                HStack(spacing: 12) {
                    Button(action: attach) { Image(systemName: "paperclip").font(.system(size: 14)) }
                        .help("Add images or files").accessibilityLabel("Add images or files")
                    Spacer(minLength: 0)
                    runtimeInfo
                    if chat.state.isBusy {
                        Button { app.chats.interrupt(session.id) } label: {
                            Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 30, height: 30)
                                .background(Theme.chatPrompt, in: Circle())
                        }.disabled(chat.state.phase == .stopping).help("Stop current turn").accessibilityLabel("Stop")
                    }
                    Button(action: send) {
                        Image(systemName: chat.state.isBusy ? "text.badge.plus" : "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(canSend ? Color.white : Theme.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(canSend ? Theme.chatAccent : Theme.chatPrompt, in: Circle())
                    }.disabled(!canSend)
                        .help(chat.state.isBusy ? "Queue message  ↩" : "Send  ↩")
                        .accessibilityLabel(chat.state.isBusy ? "Queue message" : "Send")
                }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(contrast == .increased ? Theme.secondaryText : Theme.chatBorder))
            HStack(spacing: 5) {
                Text("↩ send · ⇧↩ new line")
                Spacer()
                Image(systemName: session.skipPermissions ? "shield.slash" : "shield")
                Text(session.skipPermissions ? "Full access" : "Asks for permission")
            }.font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 6)
        }
        .frame(maxWidth: 760).padding(.horizontal, 24).padding(.bottom, 14).padding(.top, 8)
        .frame(maxWidth: .infinity)
        .task(id: images.map(\.url)) { await loadThumbnails() }
    }

    private var runtimeInfo: some View {
        HStack(spacing: 6) {
            if let model = chat.state.modelLabel { Text(model) }
            if let effort = chat.state.effort, !effort.isEmpty {
                if chat.state.modelLabel != nil { Text("·") }
                Text("\(effort.capitalized) effort")
            }
        }.font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            .lineLimit(1).truncationMode(.middle).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var connectionStatus: some View {
        if app.hostCenter.hasHost(for: session.id) {
            Button("Continue in Chat") { Task { await app.startChat(session, takeOverTerminal: true) } }
                .disabled(app.workingSince[session.id] != nil || app.sessionProgress[session.id] != nil || app.starting.contains(session.id))
                .help("Closes the idle terminal and resumes this conversation in Chat")
        } else if chat.state.phase == .connecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
        } else if !session.isArchived, [.disconnected, .failed].contains(chat.state.phase) {
            Button("Reconnect") { app.reconnectChat(session) }.controlSize(.small)
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chat.state.queuePaused ? "Queue paused" : "Messages").fontWeight(.medium)
                Spacer()
                if chat.state.queuePaused {
                    Button("Resume queue") { app.chats.resumeQueue(session.id) }
                        .disabled(chat.state.isBusy || !app.chats.connected.contains(session.id) || chat.state.outbox.contains { $0.status == .uncertain || $0.status == .failed })
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.state.outbox) { pending in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(pending.message.pieces.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined())
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Text(label(pending.status)).foregroundStyle(Theme.secondaryText)
                                if pending.status != .sending {
                                    Button("Edit") { app.chats.returnToDraft(pending, for: session.id); focusRequest += 1 }
                                    Button { app.chats.removeQueued(pending, for: session.id) } label: { Image(systemName: "xmark") }
                                        .accessibilityLabel("Remove queued message")
                                }
                            }
                            if let error = pending.error { Text(error).foregroundStyle(Theme.warningText).textSelection(.enabled) }
                            if pending.status == .uncertain {
                                Text("Reconnect to check the conversation before sending this message again.").foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxHeight: 120)
        }.font(.system(size: 11)).padding(10)
            .background(Theme.chatPrompt, in: RoundedRectangle(cornerRadius: 10))
            .buttonStyle(.plain)
    }

    private func label(_ status: ChatPendingMessage.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .sending: "Sending"
        case .uncertain: "Unconfirmed"
        case .failed: "Not sent"
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    Group {
                        if let thumbnail = thumbnails[image.url] { Image(decorative: thumbnail, scale: 2).resizable().scaledToFill() }
                        else { Image(systemName: "photo").foregroundStyle(Theme.secondaryText) }
                    }
                    .frame(width: 52, height: 52).background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        Button { parts.wrappedValue.removeAll { $0 == .image(image) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 16, height: 16).background(.black.opacity(0.65), in: Circle())
                        }.buttonStyle(.plain).padding(3).accessibilityLabel("Remove \(image.name)")
                    }.help(image.name)
                }
            }
        }.padding(.top, 4)
    }

    private func send() {
        guard canSend else { return }
        Task { await app.chats.submitDraft(session.id) }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: session.workingDirectory)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let folder = imagesFolder
        Task {
            let added = await Task.detached(priority: .userInitiated) {
                urls.flatMap { url -> [ComposerPart] in
                    if ComposerTextView.imageTypes.contains(url.pathExtension.lowercased()),
                       let copy = ComposerTextView.localCopy(of: url, in: folder) {
                        return [.image(ComposerImage(url: copy, name: url.lastPathComponent)), .text(" ")]
                    }
                    return [.text(ClipboardPaste.shellEscaped(url.path) + " ")]
                }
            }.value
            parts.wrappedValue += added
            focusRequest += 1
        }
    }

    private func loadThumbnails() async {
        let images = images
        let valid = Set(images.map(\.url))
        thumbnails = thumbnails.filter { valid.contains($0.key) }
        for image in images where thumbnails[image.url] == nil {
            let url = image.url
            let thumbnail = await Task.detached(priority: .userInitiated) { ClipboardPaste.thumbnail(of: url, maxPixels: 104) }.value
            guard !Task.isCancelled else { return }
            if let thumbnail { thumbnails[url] = thumbnail }
        }
    }
}
