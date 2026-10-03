import AppKit
import SwiftUI

/// Menu-bar commands and keyboard shortcuts.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Simul") {
                let credits = NSMutableAttributedString(
                    string: "One player, many boards.\nTerminals by Ghostty.\n",
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

        CommandGroup(replacing: .sidebar) {
            Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.sidebarVisible.toggle()
            }
            .keyboardShortcut("b")
        }

        CommandMenu("Session") {
            Button("New Session…") {
                model.createDraft()
            }
            .keyboardShortcut("n")

            Button("New Session…") {
                model.createDraft()
            }
            .keyboardShortcut("t")

            if let session = model.selectedSession {
                Divider()

                Button("Rename") {
                    model.renaming = session.id
                }

                Button(session.isArchived ? "Unarchive" : "Archive") {
                    model.toggleArchived(session)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("Stop Session…") {
                    Task { await model.stop(session) }
                }

                Divider()
            }

            // ⌘1 … ⌘9 jump straight to a session.
            ForEach(1...9, id: \.self) { slot in
                Button("Switch to Session \(slot)") {
                    model.selectSlot(slot)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")))
                .disabled(slot > model.activeSessions.count)
            }
        }
    }
}
