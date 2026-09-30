import SwiftUI

/// Boxed sidebar: each session is a card (room for future loading states),
/// attention/progress feedback on the card, archived sessions in a
/// collapsible section pinned to the bottom (collapsed by default).
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var renameFocused: Bool
    @State private var renameText = ""
    @AppStorage("sidebar.archivedCollapsed") private var archivedCollapsed = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    topHeader

                    if let draft = model.draft {
                        draftCard
                    }

                    ForEach(model.activeSessions) { session in
                        sessionCard(session)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            if !model.archivedSessions.isEmpty {
                archivedSection
            }
        }
        .padding(.bottom, 10)
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

    // MARK: - Header (beside the traffic lights, no gap above)

    private var topHeader: some View {
        HStack(spacing: 6) {
            Text("Sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 56) // clear the traffic lights
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
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(height: 30)
    }

    // MARK: - Archived (collapsible, pinned to the bottom)

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.horizontal, 12)
            Button {
                archivedCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(archivedCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Text("Archived")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(model.archivedSessions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !archivedCollapsed {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.archivedSessions) { session in
                        sessionCard(session)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Cards

    private func sessionCard(_ session: Session) -> some View {
        let selected = model.selectedSessionID == session.id && !model.isDraftSelected
        let attention = model.attentionIDs.contains(session.id)
        let running = model.isRunning(session)
        let dimmed = session.isArchived

        return HStack(spacing: 7) {
            Text(verbatim: slotLabel(for: session) ?? " ")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(selected ? Color.white.opacity(0.55) : Color.secondary)
                .frame(width: 11, alignment: .trailing)

            agentIcon(for: session)
                .frame(width: 15, height: 15)

            titleView(for: session, selected: selected)

            if let progress = model.sessionProgress[session.id], running {
                Text(progress.label)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tint)
            }

            Spacer(minLength: 2)

            if attention {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 6, height: 6)
                    .shadow(color: .yellow.opacity(0.8), radius: 3)
            } else if model.isLaunching(session) {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
        .background(cardBackground(selected: selected, attention: attention))
        .opacity(dimmed ? 0.55 : 1)
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

    @ViewBuilder
    private func cardBackground(selected: Bool, attention: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(
                selected
                    ? Color.white.opacity(0.14)
                    : Color.white.opacity(0.05)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        attention
                            ? Color.yellow.opacity(0.7)
                            : (selected ? Color.white.opacity(0.18) : Color.white.opacity(0.07)),
                        lineWidth: 1
                    )
            )
    }

    private var draftCard: some View {
        HStack(spacing: 7) {
            Text(" ")
                .font(.system(size: 9.5))
                .frame(width: 11)
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)
            Text("New Session")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3]))
                )
        )
    }

    @ViewBuilder
    private func agentIcon(for session: Session) -> some View {
        if let logo = ProviderIcon.image(for: session.agentID, darkBackground: true) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
