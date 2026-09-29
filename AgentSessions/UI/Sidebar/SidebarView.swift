import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(
            get: { model.selectedSessionID },
            set: { id in
                if let id, let session = model.sessions.first(where: { $0.id == id }) {
                    model.select(session)
                }
            }
        )) {
            Section("Sessions") {
                ForEach(model.activeSessions) { session in
                    SessionRow(
                        session: session,
                        slot: slotNumber(for: session),
                        isRunning: model.isRunning(session)
                    )
                    .tag(session.id)
                    .contextMenu {
                        SessionContextMenu(session: session)
                    }
                }
                .onMove { source, destination in
                    moveInSidebar(from: source, to: destination)
                }
            }

            if !model.archivedSessions.isEmpty {
                Section("Archived") {
                    ForEach(model.archivedSessions) { session in
                        SessionRow(
                            session: session,
                            slot: nil,
                            isRunning: model.isRunning(session)
                        )
                        .tag(session.id)
                        .contextMenu {
                            SessionContextMenu(session: session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func slotNumber(for session: Session) -> Int? {
        let active = model.activeSessions
        guard let index = active.firstIndex(where: { $0.id == session.id }),
              index < 9 else { return nil }
        return index + 1
    }

    private func moveInSidebar(from source: IndexSet, to destination: Int) {
        let active = model.activeSessions
        guard let first = source.first else { return }
        guard first < active.count, destination - 1 < active.count else { return }
        let sourceID = active[first].id
        // Destination maps to the item currently at that slot (drop on target).
        let adjusted = destination > first ? destination - 1 : destination
        guard adjusted < active.count, adjusted != first else { return }
        model.reorder(from: sourceID, to: active[adjusted].id)
    }
}

/// Context menu actions shared by active and archived rows.
struct SessionContextMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Group {
            if !session.isArchived {
                Button("Rename…") { model.renaming = session.id }
                Section {
                    Button("Move Up") { model.move(session: session, offset: -1) }
                    Button("Move Down") { model.move(session: session, offset: 1) }
                }
            }
            if session.isArchived {
                Button("Unarchive") { model.setArchived(session, false) }
            } else {
                Button("Archive") { model.setArchived(session, true) }
            }
            Section {
                if model.isRunning(session) {
                    Button("Stop Session…", role: .destructive) {
                        Task { await model.stop(session) }
                    }
                }
                Button("Delete Metadata…", role: .destructive) {
                    model.pendingDelete = session.id
                }
            }
        }
    }
}
