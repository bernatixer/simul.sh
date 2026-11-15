import AppKit
import Foundation
import SwiftUI

/// Lets an agent drive a test copy without screen-recording or accessibility
/// permissions: with `SIMUL_DEV_HOOKS=1`, SIGUSR1 runs the commands in
/// `<data dir>/devcmd` (one per line) and appends results to `<data dir>/devlog`.
///   select <title>   select the session with that title
///   review           toggle the selected session's review
///   chat             toggle Agent | Chat
///   paste            send Edit ▸ Paste to the key view (reads the clipboard)
///   compose <text>   type text into the key text view; backspace deletes back one character; submit presses Return there
///   responder        log the key view and whether it would take the clipboard's types (reads, never writes, the clipboard)
///   chatrender <name> [entries] [light] [working]  draw the selected Claude session's last entries and message box offscreen
///   snap <name>      save the main window as <data dir>/<name>.png
///   scroll <steps>   scroll the review by 80 pt per step (negative: up), logging ms per step
///   top              scroll the review back to its top
///   size <w> <h>     resize the main window
///   pr <owner/repo> <n>  review that pull request in the selected session
///   folder <path>    review that folder in the selected session (a PR's worktree when
///                    fetching can't run, e.g. a locked screen's SSH agent refuses)
///   base <ref>       compare against that ref
///   session <agent> <path> [skip]  start a session (skipping permission prompts) of that agent in that folder, and select it
///   press <down|up|return> [session title]  press a key in the selected (or named) session's terminal
///   type <text>      paste text (\\n for newlines) into the selected session
///   screen [session title]  log the selected (or named) session's screen text
///   window           host the app in a window of its own when none shows (a locked
///                    screen opens no SwiftUI windows), starting the model once
/// ponytail: dev-only signal hook, no UI; replace with UI tests if we ever get Xcode.
@MainActor
enum DevHooks {
    private static var source: DispatchSourceSignal?
    private static var window: NSWindow?

    static func install(model: AppModel) {
        guard ProcessInfo.processInfo.environment["SIMUL_DEV_HOOKS"] == "1", source == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { Task { await run(model: model) } } }
        s.resume()
        source = s
    }

    private static func run(model: AppModel) async {
        let dir = Paths.applicationSupport
        let commands = (try? String(contentsOf: dir.appendingPathComponent("devcmd"), encoding: .utf8)) ?? ""
        // Timings shouldn't depend on whether the copy is in front: no App Nap meanwhile.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "dev hooks")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        for line in commands.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let verb = words.first else { continue }
            let rest = words.dropFirst().joined(separator: " ")
            switch verb {
            case "select":
                if let session = model.sessions.last(where: { $0.title == rest }) { model.select(session) }
            case "sidebarstate":
                for session in Session.sidebarOrder(model.activeSessions) {
                    log("row: \(session.title), folder=\(session.workingDirectory), origin=\(session.titleOrigin.rawValue)")
                }
            case "namingcheck":
                let unnamed = Session(title: "", workingDirectory: "/tmp", agentID: "codex")
                let named = Session(title: "Keep my name", workingDirectory: "/tmp", agentID: "claude")
                let ids: Set<UUID> = [unnamed.id, named.id]
                let order = model.sessions.map(\.id)
                model.sessions.append(contentsOf: [unnamed, named])
                defer {
                    model.sessions.removeAll { ids.contains($0.id) }
                    for id in ids { model.chats.forget(id) }
                    model.saveSessions()
                }
                var passed = true
                for session in [unnamed, named] {
                    await model.chats.prepare(session.id)
                    let entries: [ChatEntry] = [.prompt(id: "sidebar-check", text: "Improve the sidebar")]
                    model.chats.update(session.id) { $0.apply(.history(entries)) }
                    model.chatEvent(session.id, .history(entries))
                }
                passed = passed && model.sessions.first(where: { $0.id == unnamed.id })?.title == "Improve the sidebar"
                passed = passed && model.sessions.first(where: { $0.id == named.id })?.title == "Keep my name"
                if let session = model.sessions.first(where: { $0.id == unnamed.id }) {
                    model.rename(session, to: session.title)
                    model.chats.update(session.id) { $0.apply(.titleChanged("Late provider title")) }
                    model.chatEvent(session.id, .titleChanged("Late provider title"))
                    passed = passed && model.sessions.first(where: { $0.id == session.id })?.title == "Improve the sidebar"
                }
                passed = passed && model.sessions.filter { !ids.contains($0.id) }.map(\.id) == order
                log("naming integration: \(passed ? "passed" : "FAILED")")
            case "chat":
                if let session = model.selectedSession { model.toggleChat(session) }
            case "chatfixture":
                var session = Session(title: "Chat preview", workingDirectory: "/tmp", agentID: "codex", sortOrder: 0)
                session.isArchived = true // A fixture never launches a provider.
                model.sessions.append(session)
                await model.chats.prepare(session.id)
                var entries: [ChatEntry] = []
                if words.contains("large") {
                    for index in 0..<1000 {
                        entries.append(.prompt(id: "p\(index)", text: "Check change \(index)"))
                        entries.append(.reply(id: "r\(index)", text: "### Change \(index)\n\nA reply with **bold text**, a [link](https://simul.sh), and `inline code`.\n\n- First item\n- Second item"))
                    }
                }
                entries += [.prompt(id: "preview-prompt", text: "Review the chat changes and show the results."),
                            .tools(id: "preview-tools", [ChatTool(id: "preview-tool", name: "Run", summary: "swift run SimulTests", detail: "swift run SimulTests", result: "All tests passed.")]),
                            .reply(id: "preview-answer", text: "### Chat changes\n\nThe new view keeps your place while the agent works.\n\n- [x] Claude and Codex\n- [x] Saved drafts\n- [ ] Release\n\n> Queued messages wait for a completed turn.\n\n| Check | Result |\n|:--|--:|\n| Protocol tests | Passed |\n| Idle CPU | Measuring |\n\n```swift\nlet message = ChatOutgoingMessage(pieces: [.text(\"Hello\")])\n```\n")]
                let previewEntries = entries
                await Task.detached(priority: .userInitiated) { ChatMarkdown.cache.prewarm(Array(previewEntries.suffix(200))) }.value
                model.chats.update(session.id) { state in
                    state.conversation.entries = entries
                    state.conversation.revision += 1
                    state.phase = .idle
                    state.models = [.init(id: "fixture", name: "Codex", efforts: ["low", "medium", "high"])]
                    state.selectedModel = "fixture"
                    if words.contains("question") {
                        state.requests = [.init(id: "preview-question", title: "Codex has a question", questions: [.init(id: "format", prompt: "Which layout should I use?", options: [.init(label: "Compact", description: "Keep related messages together"), .init(label: "Comfortable", description: "Use more space between messages")])])]
                    }
                    if words.contains("images") {
                        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP8z8DwnwEIGBkZGRgYGAA/AgP/0z5cgQAAAABJRU5ErkJggg==")!
                        state.conversation.entries.append(.prompt(id: "preview-images", text: "Nine attachments", images: Array(repeating: image, count: 9)))
                    }
                }
                model.showingChat = true
                model.select(session)
            case "chattick":
                if let id = model.selectedSessionID {
                    model.chats.update(id) { $0.apply(.text(id: "preview-answer", delta: "\nAnother streaming update.")) }
                }
            case "chatclick":
                if let window = mainWindow, let root = window.contentView {
                    func click(_ view: NSView) {
                        if let probe = view as? ChatScrollObserver.Probe, let scroll = probe.enclosingScrollView,
                           let event = NSEvent.mouseEvent(with: .leftMouseDown,
                               location: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                            probe.mouseDownInTranscript(event)
                        }
                        view.subviews.forEach(click)
                    }
                    click(root)
                }
            case "chatsend":
                if let id = model.selectedSessionID {
                    model.chats.setDraft([.text(rest)], for: id)
                    await model.chats.submitDraft(id)
                }
            case "chatstop":
                if let id = model.selectedSessionID { model.chats.interrupt(id) }
            case "chatconnect":
                if let session = model.selectedSession { await model.startChat(session, takeOverTerminal: true) }
            case "chatreconnect":
                if let session = model.selectedSession { model.reconnectChat(session) }
            case "chatstate":
                if let id = model.selectedSessionID, let state = model.chats.sessions[id]?.state {
                    log("chat: \(state.phase), follow=\(state.followsLatest), anchor=\(state.readingAnchor ?? "nil"), rows=\(state.conversation.entries.count), draft=\(state.draft.count)")
                    log("window: light=\(model.chatAppearance), appearance=\(mainWindow?.appearance?.name.rawValue ?? "nil"), titleHeight=\(model.titleBar.height)")
                }
            case "compose":
                (mainWindow?.firstResponder as? NSTextView)?.insertText(rest, replacementRange: NSRange(location: NSNotFound, length: 0))
            case "submit":
                (mainWindow?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case "backspace":
                (mainWindow?.firstResponder as? NSTextView)?.deleteBackward(nil)
            case "paste":
                log("paste: \(NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) ? "handled" : "no taker")")
            case "responder":
                let responder = mainWindow?.firstResponder
                let types = NSPasteboard.general.types ?? []
                var line = "responder: \(responder.map { String(describing: type(of: $0)) } ?? "none"); clipboard: \(types.map(\.rawValue))"
                if let textView = responder as? NSTextView, let storage = textView.textStorage {
                    let parts = ComposerTextView.parts(of: storage).map { part -> String in
                        switch part {
                        case let .text(text): return "text(\(text.debugDescription))"
                        case let .image(image): return "image(\(image.name))"
                        }
                    }
                    line += "; parts: \(parts)"
                    line += "; text view reads: \(textView.readablePasteboardTypes.filter(types.contains).map(\.rawValue))"
                    if let paste = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
                        .first(where: { $0.action == #selector(NSText.paste(_:)) }) {
                        line += "; Paste enabled: \(textView.validateUserInterfaceItem(paste))"
                    }
                }
                log(line)
            case "review":
                if let session = model.selectedSession { model.reviews.toggle(session) }
            case "snap":
                snap(to: dir.appendingPathComponent("\(rest).png"))
            case "layout":
                if let window = mainWindow {
                    log("window id=\(window.windowNumber), main=\(window === AppDelegate.mainWindow), appearance=\(window.appearance?.name.rawValue ?? "nil"), effective=\(window.effectiveAppearance.name.rawValue)")
                    var count = 0
                    func describe(_ view: NSView) {
                        if view is NSScrollView || view is NSHostingView<ContentView> {
                            log("view: \(type(of: view)), frame=\(view.frame), hidden=\(view.isHidden), appearance=\(view.effectiveAppearance.name.rawValue)")
                        }
                        count += 1
                        view.subviews.forEach(describe)
                    }
                    if let root = window.contentView { describe(root) }
                    log("views: \(count)")
                }
            case "sidebarrender":
                let renderer = ImageRenderer(content: SidebarView().frame(width: 250, height: 700)
                    .background(Theme.sidebar).environment(\.colorScheme, .light).environment(model))
                renderer.scale = 2
                if let image = renderer.cgImage {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("sidebar-light.png"))
                }
            case "scroll":
                await scroll(steps: Int(rest) ?? 50)
            case "top":
                await scroll(steps: 0)
            case "size":
                if words.count == 3, let w = Double(words[1]), let h = Double(words[2]), let window = mainWindow {
                    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: w, height: h)), display: true)
                }
            case "pr":
                if words.count == 3, let n = Int(words[2]), let id = model.selectedSessionID {
                    model.reviews.setSource(id, .pullRequest(repo: words[1], number: n))
                }
            case "folder":
                if let id = model.selectedSessionID { model.reviews.setSource(id, .folder(rest)) }
            case "base":
                if let id = model.selectedSessionID { model.reviews.setBase(id, rest.isEmpty ? nil : rest) }
            case "window":
                guard mainWindow == nil else { break }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.appearance = NSAppearance(named: .darkAqua)
                w.contentView = NSHostingView(rootView: ContentView().environment(model))
                w.orderFront(nil)
                window = w
                model.start()
                try? await Task.sleep(for: .seconds(2))
            case "session":
                guard words.count >= 3 else { break }
                let session = Session(title: URL(fileURLWithPath: words[2]).lastPathComponent, workingDirectory: words[2],
                                      agentID: words[1], sortOrder: (model.sessions.map(\.sortOrder).max() ?? 0) + 1,
                                      skipPermissions: words.count > 3 && words[3] == "skip")
                model.sessions.append(session)
                model.saveSessions()
                model.select(session)
                await model.launch(session)
                log("session: \(session.id)")
            case "type":
                if let session = model.selectedSession, model.hostCenter.hasHost(for: session.id) {
                    model.hostCenter.host(for: session).sendText(rest.replacingOccurrences(of: "\\n", with: "\n"))
                }
            case "press", "screen":
                let named = words.count > (verb == "press" ? 2 : 1) ? words.dropFirst(verb == "press" ? 2 : 1).joined(separator: " ") : nil
                guard let session = named.map({ n in model.sessions.last { $0.title == n } }) ?? model.selectedSession,
                      model.hostCenter.hasHost(for: session.id), let view = model.hostCenter.host(for: session).surfaceView else { log("\(verb): no terminal"); break }
                if verb == "screen" { log(view.screenText()); break }
                switch words.count > 1 ? words[1] : "" {
                case "down": view.pressKey(0x7D)
                case "up": view.pressKey(0x7E)
                case "return": view.pressReturn()
                default: log("press: down, up or return")
                }
            case "chatrender":
                // Unscrolled, so ImageRenderer can draw it; the last tool run and its first call opened.
                guard let id = model.selectedSession.flatMap(model.claudeTranscriptID),
                      let session = model.selectedSession,
                      let conversation = await ChatTranscripts.shared.conversation(id: id) else { log("chatrender: no transcript"); break }
                let shown = Array(conversation.entries.suffix(words.count > 2 ? Int(words[2]) ?? 14 : 14))
                let light = words.contains("light")
                var open: Set<String> = []
                if case let .tools(runID, tools)? = shown.last(where: { if case .tools = $0 { return true } else { return false } }) {
                    open = [runID, tools[0].id]
                }
                let view = VStack(spacing: 0) {
                    ChatRows(entries: shown, expanded: .constant(open),
                             activity: words.contains("working") ? .init(since: Date().addingTimeInterval(-12), asking: false) : nil)
                    ChatComposer(session: session, chat: ChatSessionModel(ChatState(conversation: conversation)))
                }
                .frame(width: 1000)
                .background(light ? ChatView.lightBackground : Theme.background)
                .environment(\.colorScheme, light ? .light : .dark)
                .environment(model)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.cgImage {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("\(words[1]).png"))
                    log("chatrender: \(words[1]).png")
                }
            case "wait":
                try? await Task.sleep(for: .seconds(Double(rest) ?? 1))
            default:
                // The review's own commands (ReviewPanel, ReviewDiffView): filter, layers, overview, jump, expand,
                // key <j k n p v c ? ⌥↓ ⌥↑ esc>, range, say, suggest, queue.
                NotificationCenter.default.post(name: .simulDevCommand, object: String(line))
                try? await Task.sleep(for: .milliseconds(300))
                log("posted: \(line)")
            }
        }
        log("done")
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }.max { $0.frame.width < $1.frame.width } ?? window
    }

    private static func snap(to url: URL) {
        // A window macOS isn't showing (locked screen) gets no display updates: lay out and draw first.
        mainWindow?.contentView?.layoutSubtreeIfNeeded()
        mainWindow?.displayIfNeeded()
        guard let view = mainWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return log("snap: no window")
        }
        // In the view's own (dark) appearance: otherwise scroll views draw light backgrounds.
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("snap: \(url.lastPathComponent)")
    }

    /// The tallest scroll view in the window that isn't a terminal: the review's file list.
    private static func scroll(steps: Int) async {
        guard let root = mainWindow?.contentView else { return log("scroll: no window") }
        var views: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { views.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let scroll = views.max(by: { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }) else {
            var count = 0
            func all(_ v: NSView) { count += 1; v.subviews.forEach(all) }
            all(root)
            return log("scroll: no scroll view (\(count) views, visible \(root.window?.isVisible ?? false), occluded \(!(root.window?.occlusionState.contains(.visible) ?? false)))")
        }
        guard steps != 0 else {
            scroll.contentView.scroll(to: .zero)
            return scroll.reflectScrolledClipView(scroll.contentView)
        }
        var times: [Double] = []
        for _ in 0..<abs(steps) {
            let start = CACurrentMediaTime()
            var origin = scroll.contentView.bounds.origin
            origin.y = max(0, min(origin.y + (steps > 0 ? 80 : -80),
                                  max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let sorted = times.sorted()
        let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let screen = root.window?.screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))" } ?? "?"
        log(String(format: "scroll %d steps: median %.1f ms, p90 %.1f ms, max %.1f ms, over 16ms: %d (%@%@)",
                   steps, p(0.5), p(0.9), sorted.last ?? 0, times.filter { $0 > 16 }.count,
                   screen, NSApp.isActive ? ", active" : ""))
        log("  slow steps: " + times.indices.filter { times[$0] > 16 }.map { String(format: "%d (%.0f)", $0, times[$0]) }.joined(separator: ", "))
    }

    private static func log(_ message: String) {
        let url = Paths.applicationSupport.appendingPathComponent("devlog")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((message + "\n").utf8))
            try? handle.close()
        }
    }
}

extension Notification.Name {
    /// A DevHooks command for the views (only posted with SIMUL_DEV_HOOKS=1).
    static let simulDevCommand = Notification.Name("sh.simul.devCommand")
}
