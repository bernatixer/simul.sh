import AppKit
import SwiftUI

/// Menu-bar commands and keyboard shortcuts.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Simul") {
                let credits = NSMutableAttributedString(
                    string: "All your coding agents, in one place.\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                credits.append(NSAttributedString(
                    string: "simul.sh",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://simul.sh")!]))
                let centered = NSMutableParagraphStyle()
                centered.alignment = .center
                credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
        }

        // File: one window, so "New Window" becomes "New Session" (⌘N).
        CommandGroup(replacing: .newItem) {
            Button { model.createDraft() } label: {
                Label("New Session", systemImage: "plus")
            }
            .keyboardShortcut("n")
            Button { model.createDraft() } label: {
                Label("New Session", systemImage: "plus")
            }
            .keyboardShortcut("t")
        }

        CommandGroup(replacing: .sidebar) {
            Button { model.sidebarVisible.toggle() } label: {
                Label(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("b")
        }

        CommandMenu("Session") {
            // Your sessions by name, ⌘1 … ⌘9 (only the ones that exist).
            let active = Array(model.activeSessions.prefix(9))
            if active.isEmpty {
                Text("No Sessions")
            }
            ForEach(Array(active.enumerated()), id: \.element.id) { index, session in
                Button(session.title) { model.select(session) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }

            if let session = model.selectedSession, !model.isDraftSelected {
                Divider()

                Button { model.renaming = session.id } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button { model.toggleArchived(session) } label: {
                    Label(session.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button { Task { await model.stop(session) } } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .disabled(!model.isRunning(session))
            }
        }
    }
}
