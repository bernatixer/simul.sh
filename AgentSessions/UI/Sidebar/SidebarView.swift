import SwiftUI

/// Flat, Xcode-style sidebar: square full-width selection rows, inline
/// rename, drag-to-reorder, and the new-session "+" in the section header.
/// Built on ScrollView (not List) so no system row/section chrome or
/// context menus appear.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var renameFocused: Bool
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(title: "Sessions") {
                    Button {
                        model.createDraft()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New session (⌘N)")
                    .padding(.trailing, 8)
                }

                if let draft = model.draft {
                    draftRow(draft)
                }

                ForEach(model.activeSessions) { session in
                    sessionRow(session)
                }

                if !model.archivedSessions.isEmpty {
                    header(title: "Archived")
                    ForEach(model.archivedSessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 30) // clear the overlaid traffic lights (hidden titlebar)
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

    private func header<Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            Spacer()
            trailing()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Rows

    private func sessionRow(_ session: Session) -> some View {
        let selected = model.selectedSessionID == session.id && !model.isDraftSelected
        let running = model.isRunning(session)

        return HStack(spacing: 8) {
            if let slot = slotNumber(for: session) {
                Text(verbatim: "\(slot)")
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.6) : Color.secondary)
                    .frame(width: 18, alignment: .trailing)
            } else {
                Color.clear.frame(width: 18)
            }

            Image(systemName: agentIcon(for: session))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                .imageScale(.small)
                .frame(width: 16)

            titleView(for: session, selected: selected)

            Spacer(minLength: 4)

            Circle()
                .fill(running
                    ? (selected ? Color.white : Color.green)
                    : (selected ? Color.white.opacity(0.4) : Color.secondary.opacity(0.35)))
                .frame(width: 7, height: 7)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 5)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: 8) {
            Color.clear.frame(width: 18)
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 16)
            Text("New Session")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(0.08))
    }

    @ViewBuilder
    private func titleView(for session: Session, selected: Bool) -> some View {
        if model.renaming == session.id {
            TextField("Title", text: $renameText)
                .textFieldStyle(.plain)
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

    private func slotNumber(for session: Session) -> Int? {
        let active = model.activeSessions
        guard let index = active.firstIndex(where: { $0.id == session.id }),
              index < 9 else { return nil }
        return index + 1
    }

    private func agentIcon(for session: Session) -> String {
        switch session.agentID {
        case "claude": return "sparkles"
        case "codex": return "circle.hexagongrid"
        case "opencode": return "chevron.left.forwardslash.slash.chevron.right"
        default: return "terminal"
        }
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
