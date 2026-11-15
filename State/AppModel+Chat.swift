import AppKit
import Foundation

extension AppModel {
    var chatAppearance: Bool {
        guard !isDraftSelected, let session = selectedSession else { return false }
        return showsChat(session) && !reviews.isShowing(session.id)
    }

    func chooseChat(_ session: Session, showing: Bool) {
        guard supportsChat(session) else { return }
        if showing {
            if !showingChat { showingChat = true }
            Task { await startChat(session) }
        } else {
            Task {
                if chats.sessions[session.id]?.state.isBusy == true {
                    chats.update(session.id) { $0.notice = "Stop the current turn before opening Agent." }
                    return
                }
                let pid = chats.close(session.id)
                guard await waitForChatExit(pid) else {
                    chats.update(session.id) { $0.notice = "The Chat process is still closing. Try opening Agent again." }
                    return
                }
                if showingChat { showingChat = false }
                await launch(session)
            }
        }
    }

    func startChat(_ original: Session, takeOverTerminal: Bool = false) async {
        let id = original.id
        guard !launching.contains(id) else { return }
        launching.insert(id)
        let token = UUID()
        launchGeneration[id] = token
        defer {
            if launching.contains(id) { launching.remove(id) }
            if launchGeneration[id] == token, !showsChat(original) { Task { await launch(original) } }
        }
        await chats.prepare(id)
        guard !Task.isCancelled, launchGeneration[id] == token, showsChat(original), !original.isArchived, !chats.connected.contains(id),
              let agent = agent(for: original), supportsChat(original) else { return }
        if hostCenter.hasHost(for: id) {
            guard takeOverTerminal else {
                chats.update(id) { $0.notice = "Continue this conversation in Chat when Agent is idle." }
                return
            }
            guard sessionProgress[id] == nil, workingSince[id] == nil, !waitingIDs.contains(id), !starting.contains(id) else {
                chats.update(id) { $0.notice = "Agent is still working. Finish the turn before switching to Chat." }
                return
            }
            if agent.resume == .codex, original.agentSessionID == nil {
                discoverCodexThread(id)
                chats.update(id) { $0.notice = "The Codex conversation ID is not available yet. Finish a turn in Agent before switching." }
                return
            }
            if agent.resume == .claude,
               !PromptBox.isEmptyOrHint(hostCenter.host(for: original).surfaceView?.screenText() ?? "") {
                chats.update(id) { $0.notice = "Send or clear the text in Agent before switching to Chat." }
                return
            }
            let pid = hostCenter.host(for: original).processID
            // boffin: close the current owner and confirm its exit before resuming the same conversation.
            closeTerminal(id, invalidatingLaunch: false)
            guard await waitForChatExit(pid) else {
                chats.update(id) { $0.notice = "Agent is still closing. Try connecting Chat again." }
                return
            }
        }
        await resolver.bootstrap()
        guard let executable = await resolver.resolve(command: agent.executable) else {
            chats.update(id) { $0.phase = .failed; $0.notice = "Could not find \(agent.executable) in your shell." }
            return
        }
        guard launchGeneration[id] == token, showsChat(original),
              let session = sessions.first(where: { $0.id == id }), !session.isArchived, session.sleptAt == nil else { return }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(resolver.shellPathEnvironment) { _, shell in shell }
        environment.merge(agent.environment) { _, agent in agent }
        var conversationID = session.agentSessionID ?? chats.sessions[id]?.state.conversationID
        if agent.resume == .claude, let existing = conversationID {
            let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? AgentConversations.defaultClaudeDir
            let exists = await Task.detached { AgentConversations.claudeTranscriptExists(id: existing, claudeDir: directory) }.value
            // A terminal may allocate an ID before its first turn creates a transcript.
            if !exists, chats.sessions[id]?.state.conversation.entries.isEmpty == true { conversationID = nil }
        }
        let configuration = ChatAgentConfiguration(
            executable: executable, arguments: agent.arguments, environment: environment,
            workingDirectory: session.workingDirectory, conversationID: conversationID,
            sessionID: id, skipPermissions: session.skipPermissions
        )
        guard launchGeneration[id] == token, showsChat(session), !hostCenter.hasHost(for: id) else { return }
        await chats.connect(session, configuration: configuration)
    }

    func waitForChatExit(_ pid: Int32?) async -> Bool {
        guard let pid, pid > 0 else { return true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while kill(pid, 0) == 0 {
            if ContinuousClock.now >= deadline { return false }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        return true
    }

    func reconnectChat(_ session: Session) {
        Task {
            let pid = chats.close(session.id)
            guard await waitForChatExit(pid) else { return }
            await startChat(session)
        }
    }

    func chatEvent(_ id: UUID, _ event: ChatAgentEvent) {
        switch event {
        case .ready, .history, .accepted, .titleChanged: updateConversationName(id)
        default: break
        }
        switch event {
        case let .ready(conversationID, _):
            if let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].agentSessionID != conversationID {
                sessions[index].agentSessionID = conversationID
                sessions[index].lastLaunchedAt = Date()
                saveSessions()
            }
        case .started:
            if sessionProgress[id] == nil { sessionProgress[id] = .indeterminate }
            if workingSince[id] == nil { workingSince[id] = Date() }
            if waitingIDs.contains(id) { waitingIDs.remove(id) }
            if attentionIDs.contains(id) { attentionIDs.remove(id) }
        case let .request(request):
            if request.isBlocking, !waitingIDs.contains(id) { waitingIDs.insert(id) }
            flagAttention(id, message: request.title, fallback: "Needs your attention")
        case .requestResolved:
            if chats.sessions[id]?.state.requests.contains(where: \.isBlocking) == false, waitingIDs.contains(id) { waitingIDs.remove(id) }
        case let .finished(outcome, error):
            if sessionProgress[id] != nil { sessionProgress.removeValue(forKey: id) }
            if workingSince[id] != nil { workingSince.removeValue(forKey: id) }
            if waitingIDs.contains(id) { waitingIDs.remove(id) }
            reviews.turnEnded(id)
            flagAttention(id, message: error, fallback: outcome == .completed ? "Finished, waiting for you" : "Turn stopped")
        case .disconnected:
            if sessionProgress[id] != nil { sessionProgress.removeValue(forKey: id) }
            if workingSince[id] != nil { workingSince.removeValue(forKey: id) }
            if waitingIDs.contains(id) { waitingIDs.remove(id) }
        default: break
        }
    }
}
