import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: 180, ideal: 220, max: 320
                )
        } detail: {
            detail
        }
        .navigationTitle("Agent Sessions")
        .toolbar {
            ToolbarItem {
                Button {
                    model.showingNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New session (⌘N)")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.showingNewSession },
            set: { model.showingNewSession = $0 }
        )) {
            NewSessionView { title, directory, agent in
                model.createSession(
                    title: title,
                    workingDirectory: directory,
                    agent: agent
                )
            }
        }
        .modifier(RenameDialog())
        .modifier(DeleteDialog())
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.selectedSession {
            TerminalContainer(session: session)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            Label("No Session Selected", systemImage: "terminal")
        } description: {
            Text("Create a session with ⌘N or pick one from the sidebar.")
        } actions: {
            Button("New Session") { model.showingNewSession = true }
                .keyboardShortcut("n")
        }
    }
}

/// Rename alert driven by `model.renaming`.
private struct RenameDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var title = ""

    func body(content: Content) -> some View {
        content.alert(
            "Rename Session",
            isPresented: Binding(
                get: { model.renaming != nil },
                set: { if !$0 { model.renaming = nil } }
            )
        ) {
            TextField("Title", text: $title)
            Button("Rename") {
                if let id = model.renaming,
                   let session = model.sessions.first(where: { $0.id == id }) {
                    model.rename(session, to: title)
                }
                model.renaming = nil
            }
            Button("Cancel", role: .cancel) { model.renaming = nil }
        } message: {
            Text("This only changes the sidebar label.")
        }
        .onChange(of: model.renaming) { _, id in
            if let id, let session = model.sessions.first(where: { $0.id == id }) {
                title = session.title
            }
        }
    }
}

/// Delete-metadata confirmation driven by `model.pendingDelete`.
private struct DeleteDialog: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete session metadata?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Metadata Only", role: .destructive) {
                if let id = model.pendingDelete,
                   let session = model.sessions.first(where: { $0.id == id }) {
                    model.deleteMetadata(session)
                }
                model.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("The terminal process is kept if it is running. This only removes the app's session entry.")
        }
    }
}
