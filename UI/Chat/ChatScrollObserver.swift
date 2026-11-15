import AppKit
import SwiftUI

/// Measures the clip view; lazy row creation does not mean the user saw a row.
struct ChatScrollObserver: NSViewRepresentable {
    enum Interaction { case layout, scroll, selection }
    var changed: (Bool, Interaction) -> Void
    func makeNSView(context: Context) -> Probe { Probe(changed: changed) }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.changed = changed }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.stopObserving() }

    final class Probe: NSView {
        var changed: (Bool, Interaction) -> Void
        private var observers: [NSObjectProtocol] = []
        private weak var scroll: NSScrollView?
        private var scrolling = false
        private var mouseMonitor: Any?
        private var reportPending = false
        private var userMoved = false
        init(changed: @escaping (Bool, Interaction) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let scroll = enclosingScrollView else { return }
            self.scroll = scroll
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseDownInTranscript(event) }
                return event
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolling = true }
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(user: true); self?.scrolling = false }
            })
            observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(user: true) }
            })
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.report(user: self?.scrolling == true || NSApp.currentEvent?.type == .scrollWheel || NSApp.currentEvent?.type == .keyDown)
                }
            })
            scroll.contentView.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(user: false) }
            })
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(user: false) }
                })
            }
            report(user: false)
        }
        private func report(user: Bool) {
            userMoved = userMoved || user
            guard !reportPending else { return }
            reportPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportPending = false
                let user = self.userMoved
                self.userMoved = false
                guard self.scroll != nil else { return }
                self.changed(self.nearBottom, user ? .scroll : .layout)
            }
        }
        private var nearBottom: Bool {
            guard let scroll, let document = scroll.documentView else { return true }
            return document.bounds.maxY - scroll.contentView.bounds.maxY <= 40
        }
        func mouseDownInTranscript(_ event: NSEvent) {
            guard let scroll, event.window === scroll.window,
                  scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
            changed(nearBottom, .selection)
        }
        func stopObserving() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            scroll = nil
            scrolling = false
            userMoved = false
        }
    }
}
