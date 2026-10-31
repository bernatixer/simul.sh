import SwiftUI

/// The agent's overview above the files (layout B): a bar it collapses to,
/// the one-line summary, the change map beside the concerns, and the tour.
/// Hovering a concern, picking a part or stepping the tour focuses the map;
/// until then nothing is dimmed.
struct OverviewPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reviewPalette) private var palette
    let session: Session
    let snapshot: ReviewSnapshot
    let overview: AgentOverview
    /// The pane's height cap: the details scroll inside past it. Collapsed, it's the bar's.
    let maxHeight: CGFloat
    let onJump: (AgentOverview.Anchor) -> Void
    /// "Ask again" when out of date; nil without a terminal.
    let onAskAgain: (() -> Void)?
    @State private var collapsed = false
    @State private var step = 0
    /// The user stepped the tour: only then does its step focus the map.
    @State private var touring = false
    /// The concern under the pointer, and the part last clicked.
    @State private var hovered: Int?
    @State private var picked: String?
    /// The details' own height, so the pane shrinks to them when short, and the bar's and
    /// tour's, so the details get what's left of maxHeight.
    @State private var detailsHeight: CGFloat?
    @State private var chrome: [String: CGFloat] = [:]
    @FocusState private var tourFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        // No frame on the pane itself: a max-height frame takes all it's offered, so the
        // pane would stay tall collapsed. The scroll view alone is capped.
        VStack(spacing: 0) {
            bar.measured("bar", in: $chrome)
            if !collapsed {
                Rectangle().fill(palette.cardBorder).frame(height: 1)
                ScrollView {
                    details.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if detailsHeight != h { detailsHeight = h }
                    }
                }
                .frame(maxHeight: min(detailsHeight ?? .infinity, max(maxHeight - chromeHeight, 80)))
                if !overview.tour.isEmpty {
                    Rectangle().fill(palette.cardBorder).frame(height: 1)
                    tourBar(min(step, overview.tour.count - 1)).measured("tour", in: $chrome)
                }
            }
        }
        .background(palette.panel)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 1))
        // Another overview came in: its tour from the start.
        .onChange(of: overview.tour) {
            if step != 0 { step = 0 }
            if touring { touring = false }
            if picked != nil { picked = nil }
        }
        .onChange(of: overview.concerns) { if hovered != nil { hovered = nil } }
        // Hidden on Agent: ← and → mustn't step a tour that isn't on screen.
        .onChange(of: model.reviews.isShowing(session.id)) { if tourFocused { tourFocused = false } }
    }

    private var stale: Bool { overview.isStale(for: snapshot) }

    /// The bar, the tour and their dividers.
    private var chromeHeight: CGFloat {
        (chrome["bar"] ?? 0) + (overview.tour.isEmpty ? 1 : 2 + (chrome["tour"] ?? 0))
    }

    private var openConcerns: [AgentOverview.Concern] {
        overview.concerns.indices.filter { !overview.dismissed.contains($0) }.map { overview.concerns[$0] }
    }

    /// The map's focus: the hovered concern's parts, else the picked part, else the tour
    /// step's once the user stepped; empty (nothing dimmed) before any of these.
    private var focus: Set<String> {
        if let hovered, overview.concerns.indices.contains(hovered), !overview.dismissed.contains(hovered) { return Set(overview.concerns[hovered].parts) }
        if let picked { return [picked] }
        guard touring, !overview.tour.isEmpty else { return [] }
        return Set(overview.tour[min(step, overview.tour.count - 1)].focus)
    }

    // MARK: - Bar

    /// "Overview · 1 high · 1 medium · Out of date — Ask again · Tour 3 steps"; the chevron collapses the pane to it.
    private var bar: some View {
        HStack(spacing: 10) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 10)
                    Text("Overview").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand" : "Collapse")
            // The verdict: risk and effort, as Copilot's and CodeRabbit's reviews give them.
            if let risk = overview.risk {
                SeverityChip(text: "\(risk.level.rawValue.capitalized) risk", severity: risk.level)
                    .help(risk.reason)
            }
            if let effort = overview.effort {
                PrimerLabel(text: "Effort \(effort)/5", color: palette.secondaryText, border: palette.cardBorder)
                    .help("How hard it is to review, 1 (quick) to 5 (hard)")
            }
            let open = openConcerns
            ForEach(AgentOverview.Severity.allCases, id: \.self) { severity in
                let n = open.filter { $0.severity == severity }.count
                if n > 0 { SeverityChip(text: "\(n) \(severity.rawValue)", severity: severity) }
            }
            if let reason = overview.risk?.reason {
                Text(verbatim: reason).foregroundStyle(palette.secondaryText).truncationMode(.tail).help(reason)
                    .layoutPriority(-1)
            }
            if stale {
                HStack(spacing: 4) {
                    Text("Out of date —").foregroundStyle(palette.severityText(.medium))
                    Button("Ask again") { onAskAgain?() }
                        .buttonStyle(.plain)
                        .foregroundStyle(onAskAgain == nil ? palette.secondaryText : palette.link)
                        .disabled(onAskAgain == nil)
                        .help(onAskAgain == nil ? "Start the session to ask" : "Ask the agent to review the changes as they are now")
                }
            }
            Spacer(minLength: 8)
            if !overview.tour.isEmpty {
                Text("Tour \(overview.tour.count) step\(overview.tour.count == 1 ? "" : "s")")
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(palette.laneFill)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            // The concerns beside the map (capped, so the map gets most) while
            // its lanes fit, else above it: they're what needs reading first.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    map
                    concerns.frame(minWidth: 240, idealWidth: 240, maxWidth: 420, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    concerns
                    map
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var map: some View {
        if !overview.lanes.isEmpty {
            ChangeMap(sessionID: session.id, overview: overview, focus: focus,
                      holds: { model.reviews.overviewAnchorHolds(session.id, $0) },
                      diffPaths: Set(snapshot.files.filter { $0.status != .deleted }.map(\.path)),
                      onPick: { if picked != $0 { picked = $0 } }, onJump: onJump)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Change map")
        }
    }

    private var concerns: some View {
        ConcernList(sessionID: session.id, overview: overview, hovered: $hovered, onJump: onJump)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Concerns")
    }

    /// The summary, full width, then what the map holds on the same line (" · 2 changed · 1 added").
    private var summary: some View {
        let counts = AgentOverview.State.allCases.compactMap { state in
            let n = overview.parts.filter { $0.state == state }.count
            return n == 0 ? nil : " · \(n) \(state.rawValue)"
        }.joined()
        return (Text(verbatim: overview.summary).font(.system(size: 14)).foregroundStyle(palette.text)
            + Text(verbatim: counts).font(.system(size: 12)).foregroundStyle(palette.secondaryText))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: - Tour

    /// "Step 2 / 3 · title · text ‹ ›"; ← and → step while it has focus.
    private func tourBar(_ i: Int) -> some View {
        let s = overview.tour[i]
        return HStack(spacing: 10) {
            Text("Step \(i + 1) / \(overview.tour.count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.link)
                .fixedSize()
            (Text(verbatim: s.title).fontWeight(.semibold).foregroundStyle(palette.text)
                + Text(verbatim: " · ").foregroundStyle(palette.secondaryText)
                + Text(verbatim: s.text).foregroundStyle(palette.secondaryText))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(s.text)
            HStack(spacing: 4) {
                arrow("chevron.left", "Previous step  ←") { go(-1) }
                    .accessibilityLabel("Previous step")
                arrow("chevron.right", "Next step  →") { go(1) }
                    .accessibilityLabel("Next step")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.linkFill)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()  // ← and → work once clicked, without the bar looking selected
        .focused($tourFocused)
        .onTapGesture { tourFocused = true }
        .onKeyPress(.leftArrow) {
            go(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            go(1)
            return .handled
        }
    }

    private func arrow(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.simul(.quiet))
        .help(help)
    }

    /// The previous or next step (wrapping): the map focuses on it and the diff goes to its anchor.
    private func go(_ delta: Int) {
        let n = overview.tour.count
        guard n > 0 else { return }
        let next = ((min(step, n - 1) + delta) % n + n) % n
        if step != next { step = next }
        if !touring { touring = true }
        if picked != nil { picked = nil }
        if !tourFocused { tourFocused = true }
        if let anchor = overview.tour[next].anchor, model.reviews.overviewAnchorHolds(session.id, anchor) { onJump(anchor) }
    }
}

private extension View {
    /// Writes the view's height into `heights[key]` when it changes.
    func measured(_ key: String, in heights: Binding<[String: CGFloat]>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if heights.wrappedValue[key] != h { heights.wrappedValue[key] = h }
        }
    }
}
