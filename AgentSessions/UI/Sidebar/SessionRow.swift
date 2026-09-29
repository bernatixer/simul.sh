import SwiftUI

/// Sidebar row: shortcut number, title, agent, running state.
/// Only information that can be known reliably (plan §11).
struct SessionRow: View {
    let session: Session
    let slot: Int?
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let slot {
                Text(verbatim: "\(slot)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .trailing)
            } else {
                Circle()
                    .fill(.clear)
                    .frame(width: 8)
            }

            Image(systemName: agentIcon)
                .foregroundStyle(.secondary)
                .imageScale(.small)

            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .help(isRunning ? "Running" : "Stopped")
        }
        .padding(.vertical, 1)
    }

    private var agentIcon: String {
        switch session.agentID {
        case "claude": return "sparkles"
        case "codex": return "circle.hexagongrid"
        case "opencode": return "chevron.left.forwardslash.slash.chevron.right"
        default: return "terminal"
        }
    }
}
