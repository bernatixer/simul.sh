import SwiftUI

/// Flat sidebar: square full-width selection rows, inline rename,
/// drag-to-reorder, provider logos, and the new-session "+" at the top.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var renameFocused: Bool
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(title: "Sessions")

                if let draft = model.draft {
                    draftRow(draft)
                }

                ForEach(model.activeSessions) { session in
                    sessionRow(session)
                }

                if !model.archivedSessions.isEmpty {
                    Text("Archived")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(model.archivedSessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 34) // clear the overlaid traffic lights
        .onChange(of: model.renaming) { _, id in
            if let id,
               let session = model.sessions.first(where: { $0.id == id }) {
                renameText = session.title
                renameFocused = true
            } else {
                renameFocused = false
            }
        }
    }

    // MARK: - Sections

    private func header(title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.createDraft()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New session (⌘N)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    // MARK: - Rows

    private func sessionRow(_ session: Session) -> some View {
        let selected = model.selectedSessionID == session.id && !model.isDraftSelected
        let running = model.isRunning(session)

        return HStack(spacing: 6) {
            Text(verbatim: slotLabel(for: session) ?? " ")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(selected ? Color.white.opacity(0.55) : Color.secondary)
                .frame(width: 12, alignment: .trailing)

            agentIcon(for: session, selected: selected)
                .frame(width: 15, height: 15)

            titleView(for: session, selected: selected)

            Spacer(minLength: 2)

            Circle()
                .fill(running
                    ? (selected ? Color.white : Color.green)
                    : (selected ? Color.white.opacity(0.35) : Color.secondary.opacity(0.3)))
                .frame(width: 6, height: 6)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 4)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            selected
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear
        )
        .draggable(session.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first,
                  let id = UUID(uuidString: first),
                  id != session.id else { return false }
            model.reorder(from: id, to: session.id)
            return true
        }
        .onTapGesture { model.select(session) }
        .onTapGesture(count: 2) { beginRename(session) }
        .contextMenu {
            SessionContextMenu(session: session)
        }
    }

    private func draftRow(_ draft: Session) -> some View {
        HStack(spacing: 6) {
            Text(" ")
                .font(.system(size: 9.5))
                .frame(width: 12)
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)
            Text("New Session")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
        }
        .padding(.vertical, 4)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(0.08))
    }

    @ViewBuilder
    private func agentIcon(for session: Session, selected: Bool) -> some View {
        if let logo = ProviderIcon.image(for: session.agentID, darkBackground: true) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: session.agentID == AgentDefinition.shellID ? "terminal" : "terminal")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
    }

    @ViewBuilder
    private func titleView(for session: Session, selected: Bool) -> some View {
        if model.renaming == session.id {
            TextField("Title", text: $renameText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($renameFocused)
                .onSubmit { commitRename(session) }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, model.renaming == session.id {
                        commitRename(session)
                    }
                }
                .padding(.horizontal, 3)
                .background(Color(nsColor: .controlBackgroundColor))
        } else {
            Text(session.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
    }

    // MARK: - Rename

    private func beginRename(_ session: Session) {
        renameText = session.title
        model.renaming = session.id
    }

    private func commitRename(_ session: Session) {
        model.rename(session, to: renameText)
        model.renaming = nil
    }

    // MARK: - Helpers

    private func slotLabel(for session: Session) -> String? {
        let active = model.activeSessions
        guard let index = active.firstIndex(where: { $0.id == session.id }),
              index < 9 else { return nil }
        return "\(index + 1)"
    }
}

/// Context menu actions shared by active and archived rows.
struct SessionContextMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Group {
            Button("Rename") { model.renaming = session.id }

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
