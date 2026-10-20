import AppKit
import Foundation

/// Recognizes double-clicks without delaying the first click's action.
struct ClickTracker {
    private var last: (target: UUID, time: TimeInterval)?

    mutating func isDoubleClick(
        on target: UUID,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime,
        interval: TimeInterval = NSEvent.doubleClickInterval
    ) -> Bool {
        if let last, last.target == target, time - last.time < interval {
            self.last = nil
            return true
        }
        last = (target, time)
        return false
    }
}
