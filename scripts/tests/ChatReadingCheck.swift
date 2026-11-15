import AppKit

@main
struct ChatReadingCheck {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 320, height: 1000))
        scroll.documentView = document
        window.contentView = scroll
        let reading = ChatReadingPosition()
        let first = ChatRowMarker.Marker(frame: NSRect(x: 0, y: 20, width: 300, height: 100))
        let second = ChatRowMarker.Marker(frame: NSRect(x: 0, y: 300, width: 300, height: 100))
        first.configure(id: "first", reading: reading)
        second.configure(id: "second", reading: reading)
        document.addSubview(first)
        document.addSubview(second)
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        precondition(reading.firstVisibleID == "first", "the actual viewport selects its first visible row")
        precondition(reading.isVisible("first"), "visible rows can finish restoration")
        precondition(!reading.isVisible("second"), "offscreen rows cannot finish restoration")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 260))
        precondition(reading.firstVisibleID == "second", "scrolling changes the anchor without SwiftUI geometry")
        precondition(!reading.isVisible("first"), "the previous row has left the viewport")
        precondition(first.hitTest(NSPoint(x: 1, y: 1)) == nil, "measurement never takes clicks or text selection")
        let replacement = ChatRowMarker.Marker(frame: second.frame)
        replacement.configure(id: "second", reading: reading)
        document.addSubview(replacement)
        reading.remove(second, id: "second")
        precondition(reading.firstVisibleID == "second", "old-view teardown cannot remove its replacement")
        replacement.removeFromSuperview()
        precondition(reading.firstVisibleID == nil, "detached markers are ignored")
        var reports: [(Bool, ChatScrollObserver.Interaction)] = []
        let probe = ChatScrollObserver.Probe { reports.append(($0, $1)) }
        document.addSubview(probe)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 760))
        let location = scroll.convert(NSPoint(x: 160, y: 120), to: nil)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        probe.mouseDownInTranscript(click)
        precondition(!reports.isEmpty, "the native transcript mouse handler receives the event")
        precondition(reports.last?.0 == true, "clicking at the bottom must not claim that the latest message is offscreen")
        precondition(reports.last?.1 == .selection, "text selection pauses following independently of viewport position")
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(reports.last?.0 == false && reports.last?.1 == .scroll, "scrolling up reports that the latest message is offscreen")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 760))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(reports.last?.0 == true && reports.last?.1 == .layout, "jumping to latest updates visibility without pretending the user scrolled")
        document.setFrameSize(NSSize(width: 320, height: 100))
        probe.mouseDownInTranscript(click)
        precondition(reports.last?.0 == true, "a short conversation is always at the bottom")
        probe.stopObserving()
        let count = reports.count
        probe.mouseDownInTranscript(click)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(reports.count == count, "teardown stops mouse and queued layout callbacks")
        window.close()
        print("Chat reading position: 15 checks passed")
    }

    private final class Document: NSView { override var isFlipped: Bool { true } }
}
