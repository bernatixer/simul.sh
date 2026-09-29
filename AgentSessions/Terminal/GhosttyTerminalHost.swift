import AppKit
import Foundation

/// libghostty-backed terminal host. All Ghostty integration lives in
/// Terminal/ — nothing outside this folder imports Ghostty.
@MainActor
final class GhosttyTerminalHost: TerminalHost {
    private(set) var surfaceView: GhosttySurfaceView?

    var view: NSView? { surfaceView }

    var onChildExited: (() -> Void)?

    func attach(to spec: ProcessSpec) {
        // If a surface already exists for this spec, keep it — switching
        // sessions must not rebuild terminals.
        if let surfaceView, surfaceView.hasProcessExited() == false {
            return
        }
        close()

        let view = GhosttySurfaceView(spec: spec)
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
