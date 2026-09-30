import AppKit
import Foundation

/// The narrow interface the rest of the app sees for a terminal.
/// Implementations must keep terminal state alive across UI switches.
@MainActor
protocol TerminalHost: AnyObject {
    /// The NSView that presents the terminal (hosted by SwiftUI).
    var view: NSView? { get }

    /// Attaches the terminal to a process (creating the surface on first
    /// attach). Re-attaching replaces the previous surface.
    func attach(to spec: ProcessSpec)

    /// Makes the terminal the focused input target.
    func focus()

    /// Destroys the terminal surface. Metadata is unaffected.
    func close()
}

/// Creates and retains terminal hosts so switching sessions keeps terminal
/// state (scrollback, selection, modes) alive while hidden.
@MainActor
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

    func closeHost(for sessionID: Session.ID) {
        hosts[sessionID]?.close()
        hosts[sessionID] = nil
    }

    func hasHost(for sessionID: Session.ID) -> Bool {
        hosts[sessionID] != nil && hosts[sessionID]?.view != nil
    }

    func closeAll() {
        hosts.values.forEach { $0.close() }
        hosts.removeAll()
    }
}
