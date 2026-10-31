import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .padding(.top, model.titleBar.height) // below the title-bar strip
                    .frame(width: 250)
                    .frame(maxHeight: .infinity)
                    .background(Theme.sidebar)
                    .transition(.move(edge: .leading))
                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1)
            }
            detail
                // The title-bar buttons sit over the sidebar, so with it
                // shown the terminal can start at the top (below the notch
                // band in full screen). Sidebar hidden: the traffic lights
                // and buttons overlay this side, so keep the full strip.
                .padding(.top, model.sidebarVisible ? model.titleBar.topInset : model.titleBar.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .animation(.easeOut(duration: 0.2), value: model.sidebarVisible)
        .overlay(alignment: .topLeading) {
            // Title-bar strip: [traffic lights] [sidebar] [settings] … [+]
            ZStack(alignment: .leading) {
                if model.sidebarVisible {
                    NewSessionButton()
                        .frame(width: 250 - 8, alignment: .trailing) // at the sidebar's right edge
                }
                TitleBarButtons()
                    .padding(.leading, model.titleBar.leading)
            }
            .frame(height: model.titleBar.height - model.titleBar.topInset)
            .padding(.top, model.titleBar.topInset)
        }
        // Draw under the transparent title bar instead of leaving a strip.
        .ignoresSafeArea()
        .background(MainWindowMarker())
        .frame(minWidth: 900, minHeight: 520)
        .modifier(DeleteDialog())
        .modifier(CloseDialog())
    }

    @ViewBuilder
    private var detail: some View {
        if model.isDraftSelected {
            SessionSetupView()
        } else if let session = model.selectedSession {
            // Review covers the terminal, which stays mounted underneath
            // (its surfaces must never leave the window). Once opened, the
            // review stays mounted too, hidden on Agent, so it keeps drafts,
            // scroll and toggles.
            let reviewing = model.reviews.isShowing(session.id)
            ZStack {
                TerminalContainer(session: session)
                    .opacity(reviewing ? 0 : 1)
                    .allowsHitTesting(!reviewing)
                if model.reviews.openFor == session.id {
                    ReviewPanel(session: session)
                        .id(session.id)
                        .opacity(reviewing ? 1 : 0)
                        .allowsHitTesting(reviewing)
                }
            }
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
            Text("Create a session with ⌘N, or pick one from the sidebar.")
                .foregroundStyle(.secondary)
            Button("New Session") { model.createDraft() }
                .keyboardShortcut("n")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Registers the window this view lives in as Simul's main window, so only
/// that one gets the custom chrome (see AppDelegate.configureMainWindow).
private struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { AppDelegate.configureMainWindow(window) }
        }
    }
}

/// Small buttons beside the traffic lights.
private struct TitleBarButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            TitleBarButton(systemImage: "sidebar.left", help: "Toggle sidebar  ⌘B") {
                model.sidebarVisible.toggle()
            }
            if let session = model.selectedSession, !model.isDraftSelected {
                ModeSwitch(session: session)
            }
            SettingsLink {
                TitleBarIcon(systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings  ⌘,")
        }
    }
}

/// Agent | Review: what the detail area shows for the session.
private struct ModeSwitch: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let reviewing = model.reviews.isShowing(session.id)
        HStack(spacing: 0) {
            segment("Agent", on: !reviewing)
            segment("Review", on: reviewing)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .help("Agent / Review  ⇧⌘R")
    }

    private func segment(_ title: String, on: Bool) -> some View {
        Button { if !on { model.reviews.toggle(session) } } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(on ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NewSessionButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TitleBarButton(systemImage: "plus", help: "New session  ⌘N") {
            model.createDraft()
        }
    }
}

private struct TitleBarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { TitleBarIcon(systemImage: systemImage) }
            .buttonStyle(.plain)
            .help(help)
    }
}

private struct TitleBarIcon: View {
    let systemImage: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: 28, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
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
                    model.closeSession(session)
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
