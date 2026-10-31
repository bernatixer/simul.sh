import SwiftUI

/// The agent's change map, drawn from `ChangeMapLayout`: lanes as columns,
/// parts as cards coloured by state, edges with arrowheads routed through the
/// gutters between lanes, their labels in the gutters (all of them up to 12
/// edges, else only the focused part's). It scrolls sideways when wider than
/// the column. Hovering a part focuses it; otherwise `focus` does. Unfocused
/// parts and edges fade (nothing when there's no focus). Clicking a part
/// focuses it and goes to its anchor, or shows the lines around it for a
/// file the diff doesn't show.
struct ChangeMap: View {
    @Environment(\.reviewPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionID: Session.ID
    let overview: AgentOverview
    let focus: Set<String>
    /// The anchor still means what the agent meant: linked.
    let holds: (AgentOverview.Anchor) -> Bool
    /// Files the diff shows.
    let diffPaths: Set<String>
    let onPick: (String) -> Void
    let onJump: (AgentOverview.Anchor) -> Void
    /// The part whose lines are shown in a popover.
    @State private var previewing: String?
    @State private var hovered: String?

    private static let dim = 0.45
    /// Up to this many edges, every label shows.
    private static let allLabels = 12

    var body: some View {
        let layout = ChangeMapLayout(overview)
        let lit = hovered.map { [$0] } ?? focus
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                map(layout, lit: lit)
                ScrollView(.horizontal) { map(layout, lit: lit).padding(.bottom, 8) }
            }
            legend
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: lit)
    }

    private func isOn(_ part: String, _ lit: Set<String>) -> Bool { lit.isEmpty || lit.contains(part) }

    private func isOn(_ edge: AgentOverview.Edge, _ lit: Set<String>) -> Bool {
        lit.isEmpty || lit.contains(edge.from) || lit.contains(edge.to)
    }

    private func map(_ layout: ChangeMapLayout, lit: Set<String>) -> some View {
        let edges = overview.edges
        let labelled = edges.count <= Self.allLabels ? Set(edges.indices)
            : Set(edges.indices.filter { lit.contains(edges[$0].from) || lit.contains(edges[$0].to) })
        let parts = Dictionary(overview.parts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            ForEach(Array(overview.lanes.enumerated()), id: \.offset) { i, lane in
                let r = layout.lanes[i]
                RoundedRectangle(cornerRadius: 6).fill(palette.laneFill)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                Text(verbatim: lane.label.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .help(lane.label)
                    .frame(width: r.width - 16, alignment: .leading)
                    .position(x: r.midX, y: 17)
            }
            ForEach(layout.routes, id: \.edge) { route in
                let edge = edges[route.edge]
                ZStack {
                    EdgeLine(points: route.points)
                        .stroke(palette.mapEdge(edge.state),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round,
                                                   dash: edge.state == .untouched ? [4, 3] : []))
                    Arrowhead(points: route.points).fill(palette.mapEdge(edge.state))
                }
                .opacity(isOn(edge, lit) ? 1 : Self.dim)
                .allowsHitTesting(false)
            }
            ForEach(overview.parts.filter { layout.cards[$0.id] != nil }, id: \.id) { part in
                let r = layout.cards[part.id]!
                card(part, size: r.size)
                    .opacity(isOn(part.id, lit) ? 1 : Self.dim)
                    .position(x: r.midX, y: r.midY)
            }
            ForEach(layout.tags(labelled), id: \.edge) { tag in
                let edge = edges[tag.edge]
                Text(verbatim: tag.text)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: tag.frame.width, height: tag.frame.height)
                    .background(RoundedRectangle(cornerRadius: 3).fill(palette.panel))
                    .help(tag.text == tag.full ? "\(label(parts, edge.from)) → \(label(parts, edge.to))"
                                               : "\(tag.full): \(label(parts, edge.from)) → \(label(parts, edge.to))")
                    .opacity(isOn(edge, lit) ? 1 : Self.dim)
                    .position(x: tag.frame.midX, y: tag.frame.midY)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func label(_ parts: [String: AgentOverview.Part], _ id: String) -> String { parts[id]?.label ?? id }

    private func card(_ part: AgentOverview.Part, size: CGSize) -> some View {
        let linked = part.anchor.map(holds) ?? false
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button { open(part, linked: linked) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: part.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text)
                    .strikethrough(part.state == .removed)
                    // A long identifier has nowhere to wrap but mid-word: one line, shortened in the middle.
                    .lineLimit(part.label.contains(" ") ? 2 : 1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.85)
                if let note = part.note {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(shape.fill(palette.fill(part.state)))
            .overlay(shape.strokeBorder(palette.stroke(part.state),
                                        style: StrokeStyle(lineWidth: 1.2, dash: part.state == .untouched ? [4, 3] : [])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help(part, linked: linked))
        .onHover { inside in
            if inside { if hovered != part.id { hovered = part.id } } else if hovered == part.id { hovered = nil }
        }
        .popover(isPresented: Binding(get: { previewing == part.id },
                                      set: { if !$0, previewing == part.id { previewing = nil } }), arrowEdge: .bottom) {
            if let anchor = part.anchor { AnchorPreview(sessionID: sessionID, anchor: anchor) }
        }
    }

    private func open(_ part: AgentOverview.Part, linked: Bool) {
        onPick(part.id)
        guard let anchor = part.anchor, linked else { return }
        if diffPaths.contains(anchor.path) { onJump(anchor) } else { previewing = part.id }
    }

    private func help(_ part: AgentOverview.Part, linked: Bool) -> String {
        let what = "\(part.label) (\(part.state.rawValue))"
        guard let anchor = part.anchor else { return what }
        guard linked else { return "\(what): \(anchor.path) changed since the review" }
        return "\(what): \(diffPaths.contains(anchor.path) ? "go to" : "show the lines around") \(anchor.path):\(anchor.line)"
    }

    // MARK: - Legend

    private var legend: some View {
        let shown = AgentOverview.State.allCases.filter { s in overview.parts.contains { $0.state == s } }
        return HStack(spacing: 12) {
            ForEach(shown, id: \.self) { state in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.fill(state))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(palette.stroke(state), style: StrokeStyle(lineWidth: 1, dash: state == .untouched ? [2, 2] : [])))
                        .frame(width: 10, height: 10)
                    Text(state == .untouched ? "untouched, related" : state.rawValue)
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(palette.secondaryText)
    }
}

/// An edge's route with rounded corners, stopping short of the arrowhead.
private struct EdgeLine: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        var pts = points
        pts[pts.count - 1] = Arrowhead.base(points)
        path.move(to: pts[0])
        for i in 1..<pts.count - 1 {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let r = min(6, hypot(b.x - a.x, b.y - a.y) / 2, hypot(c.x - b.x, c.y - b.y) / 2)
            path.addArc(tangent1End: b, tangent2End: c, radius: r)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

/// A filled triangle on the route's end, pointing along its last segment.
private struct Arrowhead: Shape {
    let points: [CGPoint]
    static let length: CGFloat = 7

    /// Where the line stops: the arrowhead's base.
    static func base(_ points: [CGPoint]) -> CGPoint {
        let (a, b) = (points[points.count - 2], points[points.count - 1])
        let d = max(hypot(b.x - a.x, b.y - a.y), 0.001)
        let l = min(length, d)
        return CGPoint(x: b.x - (b.x - a.x) / d * l, y: b.y - (b.y - a.y) / d * l)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let tip = points[points.count - 1], base = Self.base(points)
        let d = max(hypot(tip.x - base.x, tip.y - base.y), 0.001)
        let (dx, dy) = ((tip.x - base.x) / d, (tip.y - base.y) / d)
        let w: CGFloat = 4
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
        path.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
        path.closeSubpath()
        return path
    }
}

/// The lines around an anchor in a file the diff doesn't show, the anchored one marked.
private struct AnchorPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reviewPalette) private var palette
    let sessionID: Session.ID
    let anchor: AgentOverview.Anchor
    @State private var lines: [NameUse]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: anchor.path)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            if let lines, lines.isEmpty {
                Text("No such line now").foregroundStyle(palette.secondaryText).padding(.horizontal, 12)
            }
            ForEach(lines ?? []) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: String(line.line))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 40, alignment: .trailing)
                    Text(verbatim: line.text)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 12)
                .padding(.vertical, 1)
                .background(line.line == anchor.line ? palette.nameMark : .clear)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 10)
        .frame(width: 520, alignment: .leading)
        .preferredColorScheme(palette.light ? .light : .dark)
        .task {
            let found = await model.reviews.lines(around: anchor.line, path: anchor.path, in: sessionID)
            if lines != found { lines = found }
        }
    }
}
