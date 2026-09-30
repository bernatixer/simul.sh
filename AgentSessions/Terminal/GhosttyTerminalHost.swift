import AppKit
import Foundation

/// libghostty-backed terminal host. All Ghostty integration lives in
/// Terminal/ — nothing outside this folder imports Ghostty.
@MainActor
final class GhosttyTerminalHost: TerminalHost {
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

    func close() {
        surfaceView?.onChildExited = nil
        surfaceView?.removeFromSuperview()
        surfaceView?.requestClose()
        surfaceView = nil
    }
}
