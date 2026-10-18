import SwiftUI

/// Boxed sidebar: each session is a card with attention/progress feedback;
/// archived sessions live behind a footer button (popover), out of the way.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var renameFocused: Bool
    @State private var renameText = ""
    @State private var lastTap: (Session.ID, Date)?
    /// Live drag-to-reorder: which card, where it was grabbed, where its top
    /// is. GestureState resets itself even when a drag is cancelled (focus
    /// loss, a menu opening), so a card can't stay stuck mid-air.
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.2)))
    private var drag: CardDrag?
    @State private var cardHeights: [Session.ID: CGFloat] = [:]
    /// A card dragged out of its folder: which, and how far it moved.
    @GestureState private var folderCardDrag: (id: Session.ID, dy: CGFloat)?
    /// The card or folder a dragged card will join if released now.
    @State private var dropTarget: Session.ID?
    @State private var showArchived = false
    @AppStorage(Preferences.Key.showDetails) private var showDetails = true
    @AppStorage(Preferences.Key.showLimits) private var showLimits = true
    @State private var archiveHovered = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let items = sidebarItems()
                    let top = items.map(\.first)
                    let slots = Dictionary(uniqueKeysWithValues:
                        model.slotSessions.prefix(9).enumerated().map { ($1.id, $0 + 1) })
                    if items.isEmpty {
                        EmptySessions { model.createDraft() }
                    }
                    VStack(spacing: Self.cardSpacing) {
                        ForEach(items) { item in
                            let session = item.first
                            let dragged = drag?.id == session.id
                            let holdsDragged = item.sessions.contains { $0.id == folderCardDrag?.id }
                            Group {
                                if let folder = item.folder {
                                    folderView(folder, item.sessions, slots: slots)
                                } else {
                                    sessionCard(session, slot: slots[session.id])
                                        .gesture(reorderGesture(for: session))
                                }
                            }
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CardHeightsKey.self, value: [session.id: proxy.size.height])
                            })
                            .overlay {
                                if dropTarget == session.id {
                                    RoundedRectangle(cornerRadius: item.folder == nil ? 8 : 10)
                                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .scaleEffect(dragged ? 1.02 : 1)
                            .shadow(color: .black.opacity(dragged ? 0.35 : 0), radius: 10, y: 4)
                            .offset(y: dragOffset(for: session, in: top))
                            .zIndex(dragged || holdsDragged ? 1 : 0)
                            // The dragged card tracks the pointer exactly;
                            // only its neighbors animate out of the way.
                            .transaction { if dragged { $0.animation = nil } }
                        }
                    }
                    .coordinateSpace(name: "cards")
                    .onPreferenceChange(CardHeightsKey.self) { heights in
                        MainActor.assumeIsolated { cardHeights = heights }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
                // Clicking empty sidebar space ends a rename (cards and
                // buttons sit on top and handle their own clicks).
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { commitPendingRename() }
                }
            }

            if !model.sleepingSessions.isEmpty {
                SleepingSection(model: model)
            }

            if showLimits, !model.usage.isEmpty {
                UsageSection(usage: model.usage)
            }

            if !model.archivedSessions.isEmpty {
                archiveFooter
            }
        }
        .padding(.bottom, 10)
        // The + lives in the title bar now; starting a new session still
        // saves an open rename.
        .onChange(of: showLimits) { _, shown in
            if shown { model.refreshLiveUsage() }
        }
        .onChange(of: model.draft?.id) { _, id in
            if id != nil { commitPendingRename() }
        }
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

    // MARK: - Archive (footer button → popover)

    /// One quiet row at the bottom; the list opens beside the sidebar so it
    /// never pushes active sessions around.
    private var archiveFooter: some View {
        let viewingArchived = model.selectedSession?.isArchived == true && !model.isDraftSelected
        return Button {
            commitPendingRename()
            showArchived.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.system(size: 11))
                Text("Archive")
                    .font(.system(size: 12))
                Spacer()
                Text("\(model.archivedSessions.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .foregroundStyle(viewingArchived ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(showArchived || viewingArchived ? 0.10 : archiveHovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { archiveHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .popover(isPresented: $showArchived, arrowEdge: .trailing) {
            ArchivePopover(model: model) { showArchived = false }
        }
    }

    // MARK: - Folders

    /// One sidebar entry: a lone card, or a folder of cards. Keyed (and
    /// dragged, measured) by its first session.
    private struct SidebarItem: Identifiable {
        let folder: UUID?
        let sessions: [Session]
        var first: Session { sessions[0] }
        var id: Session.ID { first.id }
    }

    private func sidebarItems() -> [SidebarItem] {
        let active = model.activeSessions
        let folders = Session.shownFolders(in: active)
        var items: [SidebarItem] = []
        for session in Session.sidebarOrder(active) {
            let folder = session.folderID.flatMap { folders.contains($0) ? $0 : nil }
            if let folder, let last = items.last, last.folder == folder {
                items[items.count - 1] = SidebarItem(folder: folder, sessions: last.sessions + [session])
            } else {
                items.append(SidebarItem(folder: folder, sessions: [session]))
            }
        }
        return items
    }

    /// Sessions started together (⇧⌘N), boxed under the first one's title.
    /// Cards inside keep their order; the folder moves as one.
    private func folderView(_ folder: UUID, _ sessions: [Session], slots: [Session.ID: Int]) -> some View {
        let collapsed = model.collapsedFolders.contains(folder)
        return VStack(spacing: Self.cardSpacing) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(sessions[0].title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if sessions.contains(where: { model.attentionIDs.contains($0.id) }), collapsed {
                    UnreadBadge()
                }
                Text("\(sessions.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) {
                    if collapsed { model.collapsedFolders.remove(folder) } else { model.collapsedFolders.insert(folder) }
                }
            }
            .gesture(reorderGesture(for: sessions[0]))
            .help(collapsed ? "Show sessions" : "Hide sessions")

            if !collapsed {
                ForEach(sessions) { session in
                    let dragged = folderCardDrag?.id == session.id
                    sessionCard(session, slot: slots[session.id])
                        .scaleEffect(dragged ? 1.02 : 1)
                        .shadow(color: .black.opacity(dragged ? 0.35 : 0), radius: 10, y: 4)
                        .offset(y: dragged ? folderCardDrag?.dy ?? 0 : 0)
                        .zIndex(dragged ? 1 : 0)
                        .gesture(folderCardGesture(for: session, folder: sessions[0].id))
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Cards

    /// Card: ⌘-number, agent tile, title and folder · branch; while the
    /// agent works, a pixel loader and elapsed time sit vertically centered
    /// on the right.
    private func sessionCard(_ session: Session, slot: Int?) -> some View {
        let selected = model.selectedSessionID == session.id && !model.isDraftSelected
        let attention = model.attentionIDs.contains(session.id)
        let working = model.isRunning(session) && model.isWorking(session.id)

        return HStack(alignment: .center, spacing: 8) {
            Text(verbatim: slot.map(String.init) ?? "")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(selected ? 0.45 : 0.28))
                .frame(width: 6, alignment: .leading)

            agentIcon(for: session)
                .frame(width: 18, height: 18)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.10 : 0.06)))
                // Working: a streak of light circles the tile, the app's
                // orbit idea; easy to spot at a glance on a dark card.
                .overlay {
                    if working || model.isLaunching(session) { OrbitingBorder() }
                }
                .overlay(alignment: .topTrailing) {
                    if attention { UnreadBadge().offset(x: 3, y: -3) }
                }

            VStack(alignment: .leading, spacing: 2) {
                titleView(for: session, selected: selected)
                    .fontWeight(attention ? .semibold : .regular)
                    .frame(height: 17)
                if showDetails {
                    details(for: session)
                }
            }

            Spacer(minLength: 4)

            if working, let since = model.workingSince[session.id] {
                ElapsedText(since: since)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(cardBackground(selected: selected, attention: attention))
        .animation(.easeOut(duration: 0.25), value: attention)
        .onTapGesture { tap(session) }
        .contextMenu {
            SessionContextMenu(session: session)
        }
    }

    /// Instant single-click select with manual double-click detection —
    /// combining .onTapGesture and .onTapGesture(count: 2) makes SwiftUI
    /// wait for the double-tap timeout before selecting (felt slow).
    private func tap(_ session: Session) {
        // A click anywhere else in the sidebar saves an open rename.
        if model.renaming != nil {
            commitPendingRename()
            lastTap = nil
        }
        model.select(session)
        if let (id, date) = lastTap,
           id == session.id,
           Date().timeIntervalSince(date) < 0.35 {
            lastTap = nil
            beginRename(session)
        } else {
            lastTap = (session.id, Date())
        }
    }

    /// Folder and branch on one line (worktree tag when it is one).
    private func details(for session: Session) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: (session.workingDirectory as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.head) // keep the folder name visible
                .layoutPriority(1)
            if let git = model.gitInfo[session.id] {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5))
                    Text(verbatim: git.branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let worktree = git.worktree {
                    Text("wt")
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .help("Linked git worktree “\(worktree)”")
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    /// Unread sessions get a soft accent wash instead of a loud border.
    @ViewBuilder
    private func cardBackground(selected: Bool, attention: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(attention ? 0.10 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        attention
                            ? Color.accentColor.opacity(0.35)
                            : (selected ? Color.white.opacity(0.18) : Color.white.opacity(0.07)),
                        lineWidth: 1
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
            // Same font and position as the title, in a subtle accent-bordered
            // field. Return commits, Escape cancels, clicking away commits.
            TextField("Title", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($renameFocused)
                .onSubmit { commitRename(session) }
                .onExitCommand { model.renaming = nil }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, model.renaming == session.id {
                        commitRename(session)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
                )
                .padding(.horizontal, -4) // text stays where the title was
        } else {
            Text(session.title)
                .font(.system(size: 12.5))
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

    /// Saves whatever is in the rename field, if a rename is open.
    private func commitPendingRename() {
        guard let id = model.renaming,
              let session = model.sessions.first(where: { $0.id == id }) else { return }
        commitRename(session)
    }

    // MARK: - Drag to reorder

    private static let cardSpacing: CGFloat = 4

    private struct CardDrag {
        let id: Session.ID
        /// Pointer distance from the card's top when grabbed.
        let grab: CGFloat
        /// The dragged card's top, in the "cards" coordinate space.
        var top: CGFloat
    }

    private func height(_ id: Session.ID) -> CGFloat {
        cardHeights[id] ?? 52
    }

    /// Where a card's slot starts, from measured heights in the given order.
    /// Computed rather than read from frames, so it is never a layout pass
    /// behind during a fast drag.
    private func slotTop(_ index: Int, in order: [Session]) -> CGFloat {
        order.prefix(index).reduce(0) { $0 + height($1.id) + Self.cardSpacing }
    }

    private func dragOffset(for session: Session, in order: [Session]) -> CGFloat {
        guard let drag, drag.id == session.id,
              let index = order.firstIndex(where: { $0.id == session.id }) else { return 0 }
        return drag.top - slotTop(index, in: order)
    }

    private func reorderGesture(for session: Session) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("cards"))
            .updating($drag) { value, state, _ in
                if state == nil {
                    let order = sidebarItems().map(\.first)
                    let index = order.firstIndex(where: { $0.id == session.id }) ?? 0
                    state = CardDrag(id: session.id, grab: value.startLocation.y - slotTop(index, in: order), top: 0)
                }
                let grab = state?.grab ?? 0
                state?.top = value.location.y - grab
            }
            .onChanged { value in
                if model.renaming != nil { commitPendingRename() } // a drag saves an open rename
                var order = sidebarItems().map(\.first)
                guard var index = order.firstIndex(where: { $0.id == session.id }) else { return }
                let y = value.location.y
                // A lone card held over the middle of another card or folder
                // joins it on release; nearer the edges it reorders.
                let lone = session.folderID.map { Session.shownFolders(in: model.activeSessions).contains($0) } != true
                let target = lone ? joinTarget(at: y, in: order, excluding: session.id) : nil
                if target != dropTarget { dropTarget = target }
                guard target == nil else { return }
                let reach: CGFloat = lone ? 0.75 : 0.5

                while index + 1 < order.count,
                      y > slotTop(index + 1, in: order) + height(order[index + 1].id) * reach {
                    let below = order[index + 1].id
                    withAnimation(.snappy(duration: 0.18)) {
                        model.reorder(from: session.id, to: below, persist: false)
                    }
                    order = sidebarItems().map(\.first)
                    index += 1
                }
                while index > 0,
                      y < slotTop(index - 1, in: order) + height(order[index - 1].id) * (1 - reach) {
                    let above = order[index - 1].id
                    withAnimation(.snappy(duration: 0.18)) {
                        model.reorder(from: session.id, to: above, persist: false)
                    }
                    order = sidebarItems().map(\.first)
                    index -= 1
                }
            }
            .onEnded { _ in
                if let target = dropTarget {
                    dropTarget = nil
                    withAnimation(.snappy(duration: 0.2)) { model.join(session.id, with: target) }
                } else {
                    model.saveOrder()
                }
            }
    }

    /// The card or folder whose middle half is under `y`, other than `excluding`.
    private func joinTarget(at y: CGFloat, in order: [Session], excluding: Session.ID) -> Session.ID? {
        for (index, item) in order.enumerated() where item.id != excluding {
            let top = slotTop(index, in: order), h = height(item.id)
            if y > top + h * 0.25, y < top + h * 0.75 { return item.id }
        }
        return nil
    }

    /// A card inside a folder: released outside the folder it leaves it
    /// (above or below), over another card or folder it joins that one.
    private func folderCardGesture(for session: Session, folder: Session.ID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("cards"))
            .updating($folderCardDrag) { value, state, _ in
                state = (session.id, value.translation.height)
            }
            .onChanged { value in
                if model.renaming != nil { commitPendingRename() }
                let target = joinTarget(at: value.location.y, in: sidebarItems().map(\.first), excluding: folder)
                if target != dropTarget { dropTarget = target }
            }
            .onEnded { value in
                let order = sidebarItems().map(\.first)
                let y = value.location.y
                dropTarget = nil
                withAnimation(.snappy(duration: 0.2)) {
                    if let target = joinTarget(at: y, in: order, excluding: folder) {
                        model.join(session.id, with: target)
                    } else if let index = order.firstIndex(where: { $0.id == folder }) {
                        let top = slotTop(index, in: order)
                        if y < top || y > top + height(folder) {
                            model.leaveFolder(session.id, above: y < top)
                        }
                    }
                }
            }
    }

}

private struct CardHeightsKey: PreferenceKey {
    static let defaultValue: [Session.ID: CGFloat] = [:]
    static func reduce(value: inout [Session.ID: CGFloat], nextValue: () -> [Session.ID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Shown when there are no sessions: one big, obvious way to start.
private struct EmptySessions: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                DotMatrix(source: .orbit, columns: 24, shimmer: hovering ? 0.6 : 0)
                    .frame(width: 44, height: 44)
                    .opacity(hovering ? 1 : 0.7)
                Text("New Session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text("⌘N")
                    .font(.system(size: 10.5, weight: .medium).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(hovering ? 0.25 : 0.14),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .padding(.top, 4)
    }
}

/// "Something new here" — the macOS unread idiom (Mail's blue dot), pinned
/// to the agent icon like an app badge.
private struct UnreadBadge: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1.5))
            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            .transition(.scale.combined(with: .opacity))
    }
}

/// Archived sessions, newest first, with how long ago each was archived.
private struct ArchivePopover: View {
    let model: AppModel
    let dismiss: () -> Void
    @State private var hovered: Session.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Archive")
                    .font(.headline)
                Spacer()
                Text("\(model.archivedSessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.archivedSessions) { session in
                        row(session)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 320)
        .environment(model)
    }

    private func row(_ session: Session) -> some View {
        let selected = model.selectedSessionID == session.id
        return HStack(spacing: 10) {
            Group {
                if let logo = ProviderIcon.image(for: session.agentID, darkBackground: true) {
                    Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: (session.workingDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            TimelineView(.everyMinute) { context in
                Text(RelativeAge.short(context.date.timeIntervalSince(model.archivedDate(session))))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .help("Archived \(model.archivedDate(session).formatted(date: .abbreviated, time: .shortened))")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(selected ? 0.12 : hovered == session.id ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? session.id : (hovered == session.id ? nil : hovered) }
        .onTapGesture {
            model.select(session)
            dismiss()
        }
        .contextMenu { SessionContextMenu(session: session) }
    }
}

/// Sleeping sessions, most recent first, with how long each has slept.
/// Selecting one wakes it. The header collapses the list.
private struct SleepingSection: View {
    let model: AppModel
    @AppStorage("sidebar.sleepingCollapsed") private var collapsed = false
    @State private var hovered: Session.ID?

    var body: some View {
        let sleeping = model.sleepingSessions
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Sleeping")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sleeping.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show sleeping sessions" : "Hide sleeping sessions")

            if !collapsed {
                ForEach(sleeping) { session in
                    row(session)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 8) {
            Group {
                if let logo = ProviderIcon.image(for: session.agentID, darkBackground: true) {
                    Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 12, height: 12)
            .opacity(0.6)
            Text(session.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let slept = session.sleptAt {
                TimelineView(.everyMinute) { context in
                    Text(RelativeAge.short(context.date.timeIntervalSince(slept)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .help("Asleep since \(slept.formatted(date: .abbreviated, time: .shortened)); select to wake")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovered == session.id ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? session.id : (hovered == session.id ? nil : hovered) }
        .onTapGesture { model.select(session) }
        .contextMenu { SessionContextMenu(session: session) }
    }
}

/// Plan limits, one row per agent (its windows side by side). The header
/// collapses it to a one-line summary. Hover for reset time and data age.
private struct UsageSection: View {
    let usage: [AgentUsage]
    @AppStorage("sidebar.limitsCollapsed") private var collapsed = false
    /// Hovered window ("claude.5h"): its percent turns into a reset countdown.
    @State private var hovered: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Limits")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if collapsed { summary }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show limits" : "Hide limits")

                if !collapsed {
                    ForEach(usage, id: \.agentID) { agent in
                        row(agent, now: context.date)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    /// Collapsed: each agent's logo and its most-used window.
    private var summary: some View {
        HStack(spacing: 8) {
            ForEach(usage, id: \.agentID) { agent in
                HStack(spacing: 3) {
                    logo(agent.agentID)
                    Text("\(Int((agent.windows.map(\.percent).max() ?? 0).rounded()))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ agent: AgentUsage, now: Date) -> some View {
        // Agents refresh these caches on their own schedule (Claude: mostly
        // on /usage). Old numbers are dimmed and labeled, never passed off as live.
        // Codex logs fresh numbers every turn, so old data there just means
        // no recent Codex use; Claude's cache genuinely goes stale.
        let age = agent.updatedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let stale = age > (agent.agentID == "claude" ? 15 * 60 : 86_400)
        return HStack(spacing: 8) {
            logo(agent.agentID)
                .overlay(alignment: .bottomTrailing) {
                    if stale {
                        Circle().fill(Color.orange).frame(width: 4, height: 4).offset(x: 2, y: 2)
                    }
                }
            ForEach(Array(agent.windows.enumerated()), id: \.offset) { _, window in
                let key = "\(agent.agentID).\(window.label)"
                let showReset = hovered == key && window.resetsAt.map { $0 > now } == true
                // Fixed layout: on hover the bar's space shows the reset
                // countdown, so nothing shifts or wraps.
                HStack(spacing: 4) {
                    Text(window.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    ZStack {
                        UsageBar(percent: window.percent)
                            .opacity(showReset ? 0 : 1)
                        if showReset, let reset = window.resetsAt {
                            Text("↻ \(RelativeAge.countdown(reset.timeIntervalSince(now)))")
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    Text("\(Int(window.percent.rounded()))%")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
                .help(tooltip(agent: agent, window: window, now: now))
            }
        }
        .opacity(stale ? 0.55 : 1)
    }

    private func logo(_ agentID: String) -> some View {
        Group {
            if let image = ProviderIcon.image(for: agentID, darkBackground: true) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }
        .frame(width: 12, height: 12)
    }

    private func tooltip(agent: AgentUsage, window: UsageWindow, now: Date) -> String {
        var parts = ["\(agent.agentID == "claude" ? "Claude" : "Codex") · \(window.label) limit · \(Int(window.percent.rounded()))% used"]
        if let reset = window.resetsAt, reset > now {
            let when = Calendar.current.isDate(reset, inSameDayAs: now)
                ? reset.formatted(date: .omitted, time: .shortened)
                : reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            parts.append("resets \(when) (in \(RelativeAge.countdown(reset.timeIntervalSince(now))))")
        } else if window.resetsAt == nil {
            parts.append("no active window")
        }
        if let updated = agent.updatedAt {
            let age = now.timeIntervalSince(updated)
            parts.append("updated \(RelativeAge.short(age)) ago")
        }
        return parts.joined(separator: " · ")
    }
}

private struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: 4)
    }

    private var color: Color {
        switch percent {
        case ..<70: Color.white.opacity(0.45)
        case ..<90: Color.orange
        default: Color.red
        }
    }
}

/// Working indicator: a short streak of accent light travelling around
/// the agent tile's border over a faint lit outline. Reduced motion: the
/// outline alone.
private struct OrbitingBorder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let period = 1.6
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                if !reduceMotion {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            AngularGradient(
                                stops: [
                                    .init(color: .accentColor.opacity(0), location: 0),
                                    .init(color: .accentColor.opacity(0), location: 0.6),
                                    .init(color: .accentColor, location: 0.97),
                                    .init(color: .accentColor.opacity(0), location: 1),
                                ],
                                center: .center,
                                angle: .degrees(phase * 360)),
                            lineWidth: 2)
                        .shadow(color: .accentColor.opacity(0.6), radius: 3)
                }
            }
        }
        .allowsHitTesting(false)
        .help("Working")
    }
}

/// "42s", "3m", "1h" since the agent started its turn.
private struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = context.date.timeIntervalSince(since)
            Text(seconds < 60 ? "\(max(0, Int(seconds)))s" : RelativeAge.short(seconds))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
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
                if session.sleptAt == nil {
                    Button("Sleep") { model.sleep(session) }
                } else {
                    Button("Wake") { model.select(session) }
                }
                Button("Archive") { model.requestArchive(session) }
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
