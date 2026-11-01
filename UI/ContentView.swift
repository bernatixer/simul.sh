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
                // With the sidebar shown the buttons must stop short of the +;
                // the Agent | Review switch drops its labels when they don't fit.
                ViewThatFits(in: .horizontal) {
                    TitleBarButtons(compact: false)
                    TitleBarButtons(compact: true)
                }
                .frame(
                    maxWidth: model.sidebarVisible ? max(0, 250 - 8 - 28 - 6 - model.titleBar.leading) : nil,
                    alignment: .leading
                )
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
            // Runs cover both the same way.
            let runs = model.workflows.showing
            let reviewing = model.reviews.isShowing(session.id) && !runs
            ZStack {
                TerminalContainer(session: session)
                    .opacity(reviewing || runs ? 0 : 1)
                    .allowsHitTesting(!reviewing && !runs)
                if model.reviews.openFor == session.id {
                    ReviewPanel(session: session)
                        .id(session.id)
                        .opacity(reviewing ? 1 : 0)
                        .allowsHitTesting(reviewing)
                }
                if runs {
                    RunsView().background(Theme.background)
                }
            }
        } else if model.workflows.showing {
            RunsView()
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
    let compact: Bool

    var body: some View {
        HStack(spacing: 2) {
            TitleBarButton(systemImage: "sidebar.left", help: "Toggle sidebar  ⌘B") {
                model.sidebarVisible.toggle()
            }
            if let session = model.selectedSession, !model.isDraftSelected {
                ModeSwitch(session: session, compact: compact)
            } else {
                RunsButton()
            }
            SettingsLink {
                TitleBarIcon(systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings  ⌘,")
        }
    }
}

/// Agent | Review | Runs: what the detail area shows for the session.
private struct ModeSwitch: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Icons instead of labels, for a narrow title bar.
    let compact: Bool

    enum Mode { case agent, review, runs }

    var body: some View {
        let runs = model.workflows.showing
        let reviewing = model.reviews.isShowing(session.id)
        HStack(spacing: 0) {
            segment("Agent", icon: "terminal", .agent, on: !reviewing && !runs)
            segment("Review", icon: "plus.forwardslash.minus", .review, on: reviewing && !runs)
            segment("Runs", icon: "arrow.triangle.2.circlepath", .runs, on: runs)
                .overlay(alignment: .topTrailing) { NeedsYouCount().offset(x: 4, y: -5) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        .help("Agent / Review  ⇧⌘R · Runs  ⌥⌘R")
    }

    private func segment(_ title: String, icon: String, _ mode: Mode, on: Bool) -> some View {
        Button {
            guard !on else { return }
            if mode == .runs { return model.showRuns() }
            if model.workflows.showing { model.workflows.showing = false }
            if (mode == .review) != model.reviews.isShowing(session.id) { model.reviews.toggle(session) }
        } label: {
            Group {
                if compact { Image(systemName: icon) } else { Text(title) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(on ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Purple: how many runs, on any session, need you.
private struct NeedsYouCount: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.workflows.needingYou.count
        if waiting > 0 {
            Text("\(waiting)")
                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 13, minHeight: 13)
                .background(Circle().fill(RunColors.you))
                .allowsHitTesting(false)
        }
    }
}

/// Opens the Runs view; a purple count when runs need you.
private struct RunsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.workflows.needingYou.count
        let showing = model.workflows.showing
        TitleBarButton(systemImage: "arrow.triangle.2.circlepath",
                       help: waiting > 0 ? "Runs: \(waiting) need you  ⌥⌘R" : "Runs  ⌥⌘R") {
            if showing { model.workflows.showing = false } else { model.showRuns() }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(showing ? 0.12 : 0)))
        .overlay(alignment: .topTrailing) { NeedsYouCount().offset(x: 2, y: -2) }
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
