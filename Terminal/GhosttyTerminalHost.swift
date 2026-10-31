import AppKit
import Foundation

/// libghostty-backed terminal host. All Ghostty integration lives in
/// Terminal/ — nothing outside this folder imports Ghostty.
@MainActor
final class GhosttyTerminalHost {
    private(set) var surfaceView: GhosttySurfaceView?

    var view: NSView? { surfaceView }

    /// The session this host presents; forwarded to the surface so
    /// app-level events (bell, progress) can be attributed.
    var sessionID: Session.ID? {
        didSet { surfaceView?.sessionID = sessionID }
    }

    var onEvent: ((Session.ID, SurfaceEvent) -> Void)?

    var onChildExited: (() -> Void)?

    func attach(to spec: ProcessSpec) {
        // If a surface already exists for this spec, keep it — switching
        // sessions must not rebuild terminals.
        if let surfaceView, surfaceView.hasProcessExited() == false {
            return
        }
        close()

        let view = GhosttySurfaceView(spec: spec)
        view.sessionID = sessionID
        view.onEvent = { [weak self] id, event in
            self?.onEvent?(id, event)
        }
        view.onChildExited = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onChildExited?()
                }
            }
        }
        surfaceView = view
    }

    func focus() {
        guard let surfaceView else { return }
        surfaceView.window?.makeFirstResponder(surfaceView)
    }

    /// Gives up the keyboard if the terminal has it (e.g. hidden under the review).
    func unfocus() {
        guard let surfaceView, let window = surfaceView.window, window.firstResponder === surfaceView else { return }
        window.makeFirstResponder(nil)
    }

    /// Pastes `text` into the terminal without submitting it. False if
    /// there is no terminal to paste into.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        surfaceView?.sendText(text) ?? false
    }

    /// Pastes `text`, and presses Return only if Claude Code's input box was
    /// empty before the paste and holds just the paste a moment later
    /// (PromptBox); otherwise it waits like sendText. `claude`: the session
    /// runs Claude Code and isn't mid-turn (others never get Return).
    @discardableResult
    func sendText(_ text: String, submitIfEmpty claude: Bool) -> Bool {
        let submit = claude && PromptBox.isEmpty(surfaceView?.screenText() ?? "")
        guard sendText(text) else { return false }
        guard submit else { return true }
        // A moment later, so the agent has taken in the paste before the Return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                // Keys typed or a prompt shown meanwhile: leave it to the user.
                guard let view = self?.surfaceView, PromptBox.holdsOnlyPaste(view.screenText()) else { return }
                view.pressReturn()
            }
        }
        return true
    }

    /// Destroys the terminal surface (terminating its process). Metadata is
    /// unaffected.
    func close() {
        surfaceView?.onChildExited = nil
        surfaceView?.onEvent = nil
        surfaceView?.removeFromSuperview()
        surfaceView?.destroy()
        surfaceView = nil
    }
}
