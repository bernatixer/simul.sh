import SwiftUI

/// Menu-bar commands and keyboard shortcuts (plan §12).
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()

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
