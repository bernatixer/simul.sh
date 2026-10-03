import AppKit
import SwiftUI

/// Hosts the libghostty terminal surfaces and shows placeholders when there
/// is nothing to attach to.
///
/// All live surfaces stay in a ZStack and switching only flips opacity —
/// views never leave the window, so switching is instant and terminal state
/// (scrollback, selection, modes) is preserved.
struct TerminalContainer: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        ZStack {
            ForEach(model.liveSessions) { liveSession in
                TerminalSurface(
                    host: model.hostCenter.host(for: liveSession),
                    isActive: liveSession.id == session.id
                )
                    .opacity(liveSession.id == session.id ? 1 : 0)
                    .allowsHitTesting(liveSession.id == session.id)
            }
        }
        .overlay {
            if !hasLiveSurface {
                placeholder
            }
        }
        .overlay {
            // Covers the blank moment between spawning and the agent drawing.
            if hasLiveSurface, model.starting.contains(session.id) {
                StartingView(session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.starting.contains(session.id))
        .background(Theme.background)
        .onAppear(perform: ensureSurface)
        .onChange(of: session.id) { _, _ in
            ensureSurface()
        }
    }

    private var hasLiveSurface: Bool {
        model.hostCenter.hasHost(for: session.id)
    }

    /// Only spawn/attach when there is no surface yet — never on plain
    /// switches. Archived sessions start explicitly via their Start button.
    private func ensureSurface() {
        guard !session.isArchived, !hasLiveSurface, !model.isLaunching(session) else { return }
        Task { await model.launch(session) }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = model.launchErrors[session.id] {
            launchError(error)
        } else if model.isLaunching(session) {
            StartingView(session: session)
        } else {
            VStack(spacing: 12) {
                Image(systemName: session.isArchived ? "archivebox" : "power")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(session.isArchived ? "Archived Session" : "Session is stopped")
                    .font(.headline)
                Text(verbatim: session.workingDirectory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button(session.isArchived ? "Unarchive and Start" : "Start") {
                    if session.isArchived { model.setArchived(session, false) }
                    Task { await model.launch(session) }
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding()
        }
    }

    private func launchError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Could not start session", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button("Retry") {
                Task { await model.launch(session) }
            }
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Loading screen: the agent's own logo as animated dot-matrix pixel art
/// (the knight for shells/unknown agents), its name, and the directory.
private struct StartingView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let agent = model.agent(for: session)
        VStack(spacing: 18) {
            DotMatrix(source: logo, columns: 40)
                .frame(width: 132, height: 132)
            VStack(spacing: 4) {
                Text("Starting \(agent?.name ?? "session")")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(verbatim: (session.workingDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var logo: DotMatrix.Source {
        guard let image = ProviderIcon.image(for: session.agentID, darkBackground: true) else {
            return .orbit
        }
        return .image(image, key: session.agentID)
    }
}

/// NSViewRepresentable wrapper around the Ghostty surface view. Only the
/// active surface renders, and it takes focus only when it becomes active —
/// not on every SwiftUI update (that would steal focus from e.g. rename).
private struct TerminalSurface: NSViewRepresentable {
    let host: GhosttyTerminalHost
    let isActive: Bool

    final class Coordinator {
        var wasActive = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let view = host.view else { return NSView() }
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? GhosttySurfaceView)?.setVisible(isActive)
        if isActive, !context.coordinator.wasActive {
            // Deferred: on first update the view is not in a window yet.
            let host = host
            DispatchQueue.main.async { host.focus() }
        }
        context.coordinator.wasActive = isActive
    }
}
