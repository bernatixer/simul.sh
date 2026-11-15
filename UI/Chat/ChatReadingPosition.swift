import AppKit
import SwiftUI

/// Row positions in the native document, independent of SwiftUI's scroll layout.
@MainActor
final class ChatReadingPosition {
    var onLayout: (() -> Void)?
    private var markers: [String: WeakMarker] = [:]
    private var scheduled = false

    private struct WeakMarker { weak var view: NSView? }

    func register(_ view: NSView, id: String) {
        if markers[id]?.view !== view { markers[id] = WeakMarker(view: view); changed() }
    }

    func remove(_ view: NSView, id: String) {
        if markers[id]?.view === view { markers[id] = nil }
    }

    var firstVisibleID: String? {
        let visible = markers.compactMap { id, marker -> (String, CGFloat)? in
            guard let view = marker.view, view.window != nil,
                  let document = view.enclosingScrollView?.documentView else { return nil }
            let frame = view.convert(view.bounds, to: document)
            guard frame.height > 0, frame.maxY > document.visibleRect.minY + 1,
                  frame.minY < document.visibleRect.maxY else { return nil }
            return (id, document.isFlipped ? frame.minY : -frame.maxY)
        }
        return visible.min { $0.1 < $1.1 }?.0
    }

    func isVisible(_ id: String) -> Bool {
        guard let view = markers[id]?.view, view.window != nil,
              let document = view.enclosingScrollView?.documentView else { return false }
        let frame = view.convert(view.bounds, to: document)
        return frame.height > 0 && frame.intersects(document.visibleRect)
    }

    func changed() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.onLayout?()
        }
    }
}

struct ChatRowMarker: NSViewRepresentable {
    let id: String
    let reading: ChatReadingPosition
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.configure(id: id, reading: reading) }
    static func dismantleNSView(_ view: Marker, coordinator: ()) {
        view.reading?.remove(view, id: view.id)
    }

    final class Marker: NSView {
        var id = ""
        weak var reading: ChatReadingPosition?

        func configure(id: String, reading: ChatReadingPosition) {
            if self.id != id || self.reading !== reading {
                self.reading?.remove(self, id: self.id)
                self.id = id
                self.reading = reading
            }
            reading.register(self, id: id)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { reading?.remove(self, id: id) }
            else { reading?.register(self, id: id); reading?.changed() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameSize(_ size: NSSize) {
            let changed = frame.size != size
            super.setFrameSize(size)
            if changed { reading?.changed() }
        }

        override func setFrameOrigin(_ point: NSPoint) {
            let changed = frame.origin != point
            super.setFrameOrigin(point)
            if changed { reading?.changed() }
        }
    }
}
