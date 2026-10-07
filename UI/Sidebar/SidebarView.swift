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
    @State private var showArchived = false
    @AppStorage(Preferences.Key.showDetails) private var showDetails = true
    @AppStorage(Preferences.Key.showLimits) private var showLimits = true
    @State private var archiveHovered = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let active = model.activeSessions
                    if active.isEmpty {
                        EmptySessions { model.createDraft() }
                    }
                    VStack(spacing: Self.cardSpacing) {
                        ForEach(Array(active.enumerated()), id: \.element.id) { index, session in
                            let dragged = drag?.id == session.id
                            sessionCard(session, slot: index < 9 ? index + 1 : nil)
                                .background(GeometryReader { proxy in
                                    Color.clear.preference(key: CardHeightsKey.self, value: [session.id: proxy.size.height])
                                })
                                .scaleEffect(dragged ? 1.02 : 1)
                                .shadow(color: .black.opacity(dragged ? 0.35 : 0), radius: 10, y: 4)
                                .offset(y: dragOffset(for: session, in: active))
                                .zIndex(dragged ? 1 : 0)
                                // The dragged card tracks the pointer exactly;
                                // only its neighbors animate out of the way.
                                .transaction { if dragged { $0.animation = nil } }
                                .gesture(reorderGesture(for: session))
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

    // MARK: - Cards

    /// Card: ⌘-number, agent tile, title and folder · branch; while the
    /// agent works, a pixel loader and elapsed time sit vertically centered
    /// on the right.
    private func sessionCard(_ session: Session, slot: Int?) -> some View {
        let selected = model.selectedSessionID == session.id && !model.isDraftSelected
        let attention = model.attentionIDs.contains(session.id)
        let working = model.isRunning(session) && model.sessionProgress[session.id] != nil

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
                    let order = model.activeSessions
                    let index = order.firstIndex(where: { $0.id == session.id }) ?? 0
                    state = CardDrag(id: session.id, grab: value.startLocation.y - slotTop(index, in: order), top: 0)
                }
                let grab = state?.grab ?? 0
                state?.top = value.location.y - grab
            }
            .onChanged { value in
                if model.renaming != nil { commitPendingRename() } // a drag saves an open rename
                var order = model.activeSessions
                guard var index = order.firstIndex(where: { $0.id == session.id }),
                      let grab = drag?.grab else { return }
                let top = value.location.y - grab
                let draggedHeight = height(session.id)

                // Swap with a neighbor once the dragged card covers half of it.
                while index + 1 < order.count,
                      top + draggedHeight > slotTop(index, in: order) + draggedHeight + Self.cardSpacing
                        + height(order[index + 1].id) / 2 {
                    let below = order[index + 1].id
                    withAnimation(.snappy(duration: 0.18)) {
                        model.reorder(from: session.id, to: below, persist: false)
                    }
                    order = model.activeSessions
                    index += 1
                }
                while index > 0,
                      top < slotTop(index - 1, in: order) + height(order[index - 1].id) / 2 {
                    let above = order[index - 1].id
                    withAnimation(.snappy(duration: 0.18)) {
                        model.reorder(from: session.id, to: above, persist: false)
                    }
                    order = model.activeSessions
                    index -= 1
                }
            }
            .onEnded { _ in
                model.saveOrder()
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
