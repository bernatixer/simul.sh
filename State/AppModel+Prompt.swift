import AppKit
import Foundation

/// Types prompts into a session for Chat and developer commands.
extension AppModel {
    enum PromptDelivery: Equatable {
        /// Typed in and Return pressed.
        case submitted
        /// Typed in; Return is left to the user.
        case pasted
        /// Claude isn't showing its input box (a question, a dialog, text
        /// typed in it): nothing was typed; try again later.
        case notReady
        /// No terminal to type into.
        case failed
    }

    /// Working, starting, launching, or asking the user something.
    func isBusy(_ id: Session.ID) -> Bool {
        isWorking(id) || starting.contains(id) || waitingIDs.contains(id)
            || sessions.first(where: { $0.id == id }).map(isLaunching) == true
    }

    /// Types text and images into the session, one paste each. Presses Return
    /// only when safe: Claude between turns with an empty input box that then holds just the
    /// prompt (PromptBox), Codex when it's idle. Other agents get the paste only.
    /// `submitted` hears whether Return was pressed, when it was due.
    /// ponytail: Codex's input box isn't read, so anything typed there goes out with the prompt.
    func sendPrompt(_ pieces: [PromptPiece], to id: Session.ID,
                    submitted: (@MainActor (Bool) -> Void)? = nil) -> PromptDelivery {
        guard let session = sessions.first(where: { $0.id == id }), hostCenter.hasHost(for: id) else { return .failed }
        let host = hostCenter.host(for: session)
        let claude = session.agentID == "claude"
        // A paste into a dialog (say "trust this folder?") could answer it: wait for the box.
        // Text in the box nobody typed since the last turn is Claude's own suggestion.
        if claude {
            let screen = host.surfaceView?.screenText() ?? ""
            let typed = typedAt[id].map { $0 > (turnEndedAt[id] ?? session.lastLaunchedAt ?? .distantPast) } ?? false
            guard PromptBox.isEmptyOrHint(screen) || (PromptBox.hasBox(screen) && !typed) else { return .notReady }
        }
        let canSubmit = !isBusy(id) && (claude || session.agentID == "codex")
        let pastes = pieces.compactMap { piece -> (text: String, image: Bool)? in
            switch piece {
            case let .text(text): return text.isEmpty ? nil : (text, false)
            case let .image(url): return (ClipboardPaste.shellEscaped(url.path), true)
            }
        }
        guard let first = pastes.first, host.sendText(first.text) else { return .failed }
        Task { [weak host] in
            var images = 0
            for (index, paste) in pastes.enumerated() {
                if index > 0, host?.sendText(paste.text) != true { return }
                guard paste.image else { continue }
                images += 1
                // An image path becomes "[Image #N]" a moment after its paste,
                // unless more text lands first: wait for it.
                if claude {
                    guard await Self.waitForImages(images, on: host) else {
                        if canSubmit { submitted?(false) }
                        return
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            guard canSubmit else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard let view = host?.surfaceView, !claude || PromptBox.holds(pieces, view.screenText()) else {
                submitted?(false)
                return
            }
            view.pressReturn()
            submitted?(true)
        }
        return canSubmit ? .submitted : .pasted
    }

    /// Waits up to 3 s for Claude's box to show `count` pasted images.
    private static func waitForImages(_ count: Int, on host: GhosttyTerminalHost?) async -> Bool {
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let view = host?.surfaceView else { return false }
            if PromptBox.imagesShown(view.screenText()) == count { return true }
        }
        return false
    }
}
