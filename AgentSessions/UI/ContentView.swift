import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 250)
                .frame(maxHeight: .infinity)
                .background(SidebarBackground())
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 520)
        .modifier(DeleteDialog())
        .modifier(CloseDialog())
    }

    @ViewBuilder
    private var detail: some View {
        if model.isDraftSelected {
            SessionSetupView()
        } else if let session = model.selectedSession {
            TerminalContainer(session: session)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("No Session Selected")
                .font(.title3)
            Text("Create a session with ⌘N or ⌘T, or pick one from the sidebar.")
                .foregroundStyle(.secondary)
            Button("New Session") { model.createDraft() }
                .keyboardShortcut("n")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native sidebar material behind the session list.
struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// ⌘W on an agent session: confirm before terminating.
private struct CloseDialog: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Close this session?",
            isPresented: Binding(
                get: { model.pendingClose != nil },
                set: { if !$0 { model.pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Session", role: .destructive) {
                if let id = model.pendingClose,
                   let session = model.sessions.first(where: { $0.id == id }) {
                    Task { await model.closeSession(session) }
                }
                model.pendingClose = nil
            }
            Button("Cancel", role: .cancel) { model.pendingClose = nil }
        } message: {
            Text("The running agent will terminate and the session will be archived. Its conversation is kept by the agent itself.")
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
