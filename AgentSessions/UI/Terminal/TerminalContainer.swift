import AppKit
import SwiftUI

/// Hosts the libghostty terminal NSView for a session and shows a
/// placeholder when there is nothing to attach to.
struct TerminalContainer: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(spacing: 0) {
            let host = model.hostCenter.host(for: session)
            if host.view != nil {
                TerminalSurface(host: host)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onAppear {
            // Auto-attach on first appearance when the backend is running.
            if model.isRunning(session) || model.launchErrors[session.id] == nil {
                Task { await model.launch(session) }
            }
        }
        .id(session.id)
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = model.launchErrors[session.id] {
            launchError(error)
        } else if model.isRunning(session) {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Session is running")
                    .font(.headline)
                Button("Attach") {
                    Task { await model.launch(session) }
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Session is stopped")
                    .font(.headline)
                Text(verbatim: session.workingDirectory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Start \(model.agent(for: session).map { "(\($0.name))" } ?? "")") {
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
