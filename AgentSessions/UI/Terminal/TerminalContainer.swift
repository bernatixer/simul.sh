import AppKit
import SwiftUI

/// Hosts the libghostty terminal surfaces and shows placeholders when there
/// is nothing to attach to.
///
/// All live surfaces stay in a ZStack and switching only flips opacity —
/// views never leave the window, so switching is instant and terminal state
/// (scrollback, selection, modes) is preserved (plan §6).
struct TerminalContainer: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        ZStack {
            ForEach(model.liveSessions) { liveSession in
                TerminalSurface(host: model.hostCenter.host(for: liveSession))
                    .opacity(liveSession.id == session.id ? 1 : 0)
                    .allowsHitTesting(liveSession.id == session.id)
            }
        }
        .overlay {
            if !hasLiveSurface {
                placeholder
            }
        }
        .background(.black)
        .onAppear(perform: ensureSurface)
        .onChange(of: session.id) { _, _ in
            ensureSurface()
        }
    }

    private var hasLiveSurface: Bool {
        model.hostCenter.host(for: session).view != nil
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
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Starting \(model.agent(for: session).map { $0.name } ?? "session")…")
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding()
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
                Button("Start \(model.agent(for: session).map { " (\($0.name))" } ?? "")") {
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

/// NSViewRepresentable wrapper around the Ghostty surface view.
private struct TerminalSurface: NSViewRepresentable {
    let host: GhosttyTerminalHost

    func makeNSView(context: Context) -> NSView {
        guard let view = host.view else { return NSView() }
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        host.focus()
    }
}
