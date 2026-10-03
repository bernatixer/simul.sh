import AppKit
import Foundation
import Observation

/// Events a terminal surface can report about its session. Provider-neutral:
/// standard terminal protocols only (bell, OSC progress), never text
/// parsing.
enum SurfaceEvent {
    /// The program asked for the user: bell, desktop notification
    /// (OSC 9/777), or a finished shell command.
    case attention
    /// Terminal-reported progress (OSC 9;4); `percent` is nil when
    /// indeterminate, and `active == false` clears the indicator.
    case progress(active: Bool, percent: Int?)
    /// The program set the terminal title (OSC 0/2).
    case title(String)
}

/// Creates and retains terminal hosts so switching sessions keeps terminal
/// state (scrollback, selection, modes) alive while hidden. Observable so
/// views reading live-surface state update when terminals come and go.
@MainActor
@Observable
final class TerminalHostCenter {
    private var hosts: [Session.ID: GhosttyTerminalHost] = [:]

    func host(for session: Session) -> GhosttyTerminalHost {
        if let host = hosts[session.id] {
            return host
        }
        let host = GhosttyTerminalHost()
        hosts[session.id] = host
        return host
    }

    /// Hosts are only registered by attach (AppModel.attachTerminal) and
    /// removed on close, so presence means a live surface.
    func hasHost(for sessionID: Session.ID) -> Bool {
        hosts[sessionID] != nil
    }

    func closeHost(for sessionID: Session.ID) {
        hosts[sessionID]?.close()
        hosts[sessionID] = nil
    }
}
