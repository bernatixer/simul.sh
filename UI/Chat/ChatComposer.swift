import AppKit
import SwiftUI

/// The message box under the chat. Sends by typing into the session's
/// terminal (AppModel.sendPrompt), so Claude gets what typing in Agent
/// would give it: text and images in the order written, each image as an
/// attachment. The model, effort and permission mode come from the
/// transcript; they're shown, not chosen.
struct ChatComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let session: Session
    let conversation: ChatConversation?
    /// A message went out: shown right away, Return follows a moment later.
    var onSent: ([PromptPiece]) -> Void = { _ in }
    /// Return wasn't pressed after all; the message stays typed in Agent.
    var onUnsent: () -> Void = {}

    @State private var parts: [ComposerPart] = []
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var notice: String?
    @State private var height: CGFloat = 36
    @State private var focusRequest = 0

    var body: some View {
        let running = app.hostCenter.hasHost(for: session.id)
        let asking = app.waitingIDs.contains(session.id)
        let busy = app.isBusy(session.id)
        let canSend = running && !busy && !pieces.isEmpty
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .leading, spacing: 10) {
                if !images.isEmpty { attachments }
                ComposerTextView(
                    parts: $parts, height: $height, placeholder: "Ask anything",
                    focusRequest: focusRequest, imagesFolder: imagesFolder, onSubmit: send
                )
                .frame(height: height)
                HStack(spacing: 14) {
                    Button(action: attach) {
                        Image(systemName: "paperclip").font(.system(size: 14))
                    }
                    .foregroundStyle(.secondary)
                    .help("Add images or files")
                    .accessibilityLabel("Add images or files")
                    Spacer()
                    if let model = conversation?.model { modelLabel(model) }
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(canSend ? (scheme == .light ? Color.white : .black) : .secondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.primary.opacity(canSend ? 0.85 : 0.08)))
                    }
                    .disabled(!canSend)
                    .help(busy ? "Claude is working" : "Send  ↩")
                    .accessibilityLabel("Send")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(scheme == .light ? Color.white : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(scheme == .light ? 0.05 : 0), radius: 8, y: 2)

            HStack(spacing: 5) {
                if !running {
                    status("This session isn't running.", action: "Show Agent")
                } else if asking {
                    status("Claude is asking you something.", action: "Answer in Agent")
                } else if let notice {
                    Text(notice).foregroundStyle(.orange)
                }
                Spacer()
                let mode = permission
                Image(systemName: mode.icon)
                Text(mode.label)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .onAppear {
            if let draft = app.chatDrafts[session.id] {
                parts = draft.filter {
                    if case let .image(image) = $0 { return FileManager.default.fileExists(atPath: image.url.path) }
                    return true
                }
            }
            focusRequest += 1
        }
        .onChange(of: parts) {
            if notice != nil { notice = nil }
            app.chatDrafts[session.id] = parts.isEmpty ? nil : parts
            loadThumbnails()
        }
    }

    // MARK: - Pieces

    private var images: [ComposerImage] {
        parts.compactMap { if case let .image(image) = $0 { image } else { nil } }
    }

    /// What gets sent: the parts with the outer whitespace trimmed.
    private var pieces: [PromptPiece] {
        var pieces: [PromptPiece] = parts.map {
            switch $0 {
            case let .text(text): .text(text)
            case let .image(image): .image(image.url)
            }
        }
        if case let .text(text)? = pieces.first { pieces[0] = .text(String(text.drop(while: \.isWhitespace))) }
        if case let .text(text)? = pieces.last {
            pieces[pieces.count - 1] = .text(String(text.reversed().drop(while: \.isWhitespace).reversed()))
        }
        return pieces.filter { $0 != .text("") }
    }

    private var attachments: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                Group {
                    if let thumbnail = thumbnails[image.url] {
                        Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 52)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                .overlay(alignment: .topTrailing) {
                    Button { remove(image) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.black.opacity(0.65)))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .accessibilityLabel("Remove \(image.name)")
                }
                .help(image.name)
            }
        }
        .padding(.top, 4)
    }

    private func modelLabel(_ name: String) -> some View {
        HStack(spacing: 5) {
            if let icon = ProviderIcon.image(for: session.agentID, darkBackground: scheme == .dark) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(name).foregroundStyle(.primary)
            if let effort = conversation?.effort { Text(effort).foregroundStyle(.secondary) }
        }
        .font(.system(size: 12.5))
    }

    private func status(_ text: String, action: String) -> some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(.orange)
            Button(action) { app.toggleChat(session) }
                .buttonStyle(.link)
        }
    }

    /// The live mode from the transcript (Shift-Tab changes it), else the
    /// launch setting.
    private var permission: (label: String, icon: String) {
        switch conversation?.permissionMode {
        case "bypassPermissions": return ("Full access", "shield.slash")
        case "auto": return ("Auto mode", "shield.lefthalf.filled")
        case "acceptEdits": return ("Accepts edits", "pencil")
        case "plan": return ("Plan mode", "list.bullet")
        case "default": return ("Asks for permission", "shield")
        default: return session.skipPermissions ? ("Full access", "shield.slash") : ("Asks for permission", "shield")
        }
    }

    // MARK: - Actions

    private var imagesFolder: URL {
        Paths.pastedImages.appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    private func send() {
        let pieces = pieces
        guard !pieces.isEmpty, app.hostCenter.hasHost(for: session.id), !app.isBusy(session.id) else { return }
        // A path to a missing image makes Claude Code send the box as it is.
        let missing = images.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        if !missing.isEmpty {
            missing.forEach(remove)
            notice = "An image was no longer there and was removed; add it again"
            return
        }
        let delivery = app.sendPrompt(pieces, to: session.id) { sent in
            if !sent {
                onUnsent()
                notice = "Typed into Agent but not sent; check it there"
            }
        }
        switch delivery {
        case .submitted:
            parts = []
            onSent(pieces)
        case .pasted:
            parts = []
            notice = "Typed into Agent; press Return there to send"
        case .notReady:
            notice = "Claude's input box isn't empty or isn't showing; check Agent"
        case .failed:
            notice = "The session isn't running"
        }
    }

    /// × on a thumbnail: its token goes from the text too.
    private func remove(_ image: ComposerImage) {
        parts = Self.merged(parts.filter { $0 != .image(image) })
    }

    /// The paperclip: images go in as tokens at the end, other files as paths.
    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: session.workingDirectory)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var added: [ComposerPart] = []
        if case let .text(text)? = parts.last, !text.hasSuffix(" "), !text.hasSuffix("\n") { added.append(.text(" ")) }
        for url in panel.urls {
            if ComposerTextView.imageTypes.contains(url.pathExtension.lowercased()),
               let copy = ComposerTextView.localCopy(of: url, in: imagesFolder) {
                added += [.image(ComposerImage(url: copy, name: url.lastPathComponent)), .text(" ")]
            } else {
                added.append(.text(ClipboardPaste.shellEscaped(url.path) + " "))
            }
        }
        parts = Self.merged(parts + added)
        focusRequest += 1
    }

    /// Adjacent text runs joined, as the text view reports them.
    private static func merged(_ parts: [ComposerPart]) -> [ComposerPart] {
        parts.reduce(into: []) { result, part in
            if case let .text(next) = part, case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(part)
            }
        }
    }

    /// Thumbnails for the row above the text, decoded once each, off the main thread.
    private func loadThumbnails() {
        for image in images where thumbnails[image.url] == nil {
            let url = image.url
            Task {
                let thumbnail = await Task.detached(priority: .userInitiated) {
                    ClipboardPaste.thumbnail(of: url, maxPixels: 104)
                }.value
                if let thumbnail, thumbnails[url] == nil { thumbnails[url] = thumbnail }
            }
        }
    }
}
