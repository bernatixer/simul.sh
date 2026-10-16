import AppKit
import SwiftUI

/// The menu bar item: Simul's mark, and how many sessions are waiting for
/// you. Its menu lists what's waiting and what's working.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let waiting = MenuBarSessions.waiting(in: model).count
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image)
            if waiting > 0 {
                Text("\(waiting)")
            }
        }
        .accessibilityLabel(waiting > 0 ? "Simul, \(waiting) waiting" : "Simul")
    }
}

struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = MenuBarSessions.waiting(in: model)
        let working = MenuBarSessions.working(in: model)

        if !waiting.isEmpty {
            Section("Waiting for you") {
                ForEach(waiting) { session in
                    Button(session.title) { show(session) }
                }
            }
        }
        if !working.isEmpty {
            Section("Working") {
                ForEach(working) { session in
                    Button("\(session.title) · \(startedAt(session))") { show(session) }
                }
            }
        }
        if waiting.isEmpty, working.isEmpty {
            Text(model.activeSessions.isEmpty ? "No sessions" : "Nothing running")
        }

        Divider()
        Button("New Session") {
            bringToFront()
            model.createDraft()
        }
        Button("Open Simul") { bringToFront() }
        Divider()
        Button("Quit Simul") { NSApp.terminate(nil) }
    }

    private func show(_ session: Session) {
        bringToFront()
        model.select(session)
    }

    /// Activates Simul and shows its window, reopening it if it was closed.
    private func bringToFront() {
        NSApp.activate()
        if let window = AppDelegate.mainWindow, window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    /// A start time, not elapsed: menu items are built once and don't tick,
    /// so "6s" would sit there stale.
    private func startedAt(_ session: Session) -> String {
        guard let since = model.workingSince[session.id] else { return "working" }
        return "since \(since.formatted(date: .omitted, time: .shortened))"
    }
}

enum MenuBarSessions {
    @MainActor static func waiting(in model: AppModel) -> [Session] {
        model.activeSessions.filter { model.attentionIDs.contains($0.id) }
    }

    @MainActor static func working(in model: AppModel) -> [Session] {
        model.activeSessions.filter { model.isWorking($0.id) && !model.attentionIDs.contains($0.id) }
    }
}

/// Simul's orbit mark as an 18pt template image: a center dot and a ring
/// of eight, so it follows the menu bar's light/dark appearance.
enum MenuBarIcon {
    @MainActor static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            NSBezierPath(ovalIn: CGRect(x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2)).fill()
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                let point = CGPoint(x: center.x + 6.6 * cos(angle), y: center.y + 6.6 * sin(angle))
                NSBezierPath(ovalIn: CGRect(x: point.x - 1.35, y: point.y - 1.35, width: 2.7, height: 2.7)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
