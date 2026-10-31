import Foundation

/// Where the change map draws everything. Lanes are columns in the agent's
/// order; within a lane, parts are ordered to cross fewer edges (barycenter
/// sweeps, ties by file order). Edges leave a card's side, run through the
/// gutters between lanes (crossing a lane only between its cards) and end on
/// the other card's facing side; within a lane they loop through the gutter
/// beside it (the last lane's on its left). Labels sit in the gutter on their
/// edge, pushed apart. Card sizes are estimated from text length, so it's
/// pure: the same overview always lays out the same.
struct ChangeMapLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        var cardWidth: CGFloat = 180
        var lanePad: CGFloat = 8
        var gutter: CGFloat = 128
        var spacing: CGFloat = 16
        /// Lane title and the room below it.
        var header: CGFloat = 32
        var padX: CGFloat = 10, padY: CGFloat = 8
        /// Average glyph widths, on the generous side (a card a bit tall beats a
        /// clipped label): 12 pt medium labels, 11 pt notes, 10 pt edge labels.
        var labelChar: CGFloat = 6.9, noteChar: CGFloat = 6.2, tagChar: CGFloat = 5.3
        var labelLine: CGFloat = 15, noteLine: CGFloat = 14, tagHeight: CGFloat = 16

        var laneWidth: CGFloat { cardWidth + 2 * lanePad }
        /// Edge labels are cut to this many characters (… included).
        var tagChars: Int { min(22, Int((gutter - 12) / tagChar)) }

        func cardHeight(label: String, note: String?) -> CGFloat {
            let text = cardWidth - 2 * padX
            var h = 2 * padY + CGFloat(ChangeMapLayout.lines(label, chars: Int(text / labelChar), max: 2)) * labelLine
            if let note { h += 2 + CGFloat(ChangeMapLayout.lines(note, chars: Int(text / noteChar), max: 2)) * noteLine }
            return h
        }
    }

    struct Route: Equatable, Sendable {
        /// Index in the overview's edges.
        var edge: Int
        /// Axis-aligned polyline from the source's side to the target's (the arrow's end).
        var points: [CGPoint]
    }

    struct Tag: Equatable, Sendable {
        var edge: Int
        /// Cut to `Metrics.tagChars`; `full` is the whole label, for the tooltip.
        var text: String
        var full: String
        var frame: CGRect
    }

    let metrics: Metrics
    /// Per overview lane: its column, the map's full height.
    private(set) var lanes: [CGRect] = []
    private(set) var cards: [String: CGRect] = [:]
    /// Part ids per lane, top to bottom.
    private(set) var order: [[String]] = []
    private(set) var routes: [Route] = []
    private(set) var size: CGSize = .zero
    /// Each labelled edge's label: its gutter and the y it wants.
    private var spots: [Spot] = []
    private struct Spot: Equatable, Sendable {
        var edge: Int, gutter: Int, y: CGFloat, label: String
    }

    init(_ overview: AgentOverview, metrics: Metrics = Metrics()) {
        self.metrics = metrics
        let m = metrics, n = overview.lanes.count
        guard n > 0 else { return }
        var laneOf: [String: Int] = [:]
        for (i, lane) in overview.lanes.enumerated() where laneOf[lane.id] == nil { laneOf[lane.id] = i }
        let parts = overview.parts.filter { laneOf[$0.lane] != nil }
        var partLane: [String: Int] = [:]
        for p in parts { partLane[p.id] = laneOf[p.lane] }
        let edges = overview.edges.enumerated().filter { partLane[$1.from] != nil && partLane[$1.to] != nil }

        var initial = Array(repeating: [String](), count: n)
        for p in parts { initial[partLane[p.id]!].append(p.id) }
        order = Self.ordered(initial, links: edges.map { ($1.from, $1.to) }, laneOf: partLane)

        let step = m.laneWidth + m.gutter
        let byID = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var bottom = m.header
        for (i, ids) in order.enumerated() {
            var y = m.header
            for id in ids {
                let h = m.cardHeight(label: byID[id]!.label, note: byID[id]!.note)
                cards[id] = CGRect(x: CGFloat(i) * step + m.lanePad, y: y, width: m.cardWidth, height: h)
                y += h + m.spacing
            }
            bottom = max(bottom, y - m.spacing)
        }
        func gutterX(_ g: Int) -> CGFloat { CGFloat(g) * step + m.laneWidth }

        // Which side each end leaves from, and the gutters it runs through.
        struct Plan { var edge: Int, from: String, to: String, out: Bool, into: Bool, gutters: [Int] }
        let plans = edges.map { i, e -> Plan in
            let a = partLane[e.from]!, b = partLane[e.to]!
            if a < b { return Plan(edge: i, from: e.from, to: e.to, out: true, into: false, gutters: Array(a..<b)) }
            if a > b { return Plan(edge: i, from: e.from, to: e.to, out: false, into: true, gutters: Array((b..<a).reversed())) }
            let right = !(a == n - 1 && n > 1)
            return Plan(edge: i, from: e.from, to: e.to, out: right, into: right, gutters: [right ? a : a - 1])
        }

        // Ports: a card side's ends spread down it, ordered by the other end's height.
        var ports: [String: [(plan: Int, end: Bool, other: CGFloat)]] = [:]
        for (k, p) in plans.enumerated() {
            ports[p.from + (p.out ? ">" : "<"), default: []].append((k, false, cards[p.to]!.midY))
            ports[p.to + (p.into ? ">" : "<"), default: []].append((k, true, cards[p.from]!.midY))
        }
        var portY: [Int: [Bool: CGFloat]] = [:]
        for (key, list) in ports {
            let rect = cards[String(key.dropLast())]!
            let sorted = list.sorted { ($0.other, $0.plan, $0.end ? 1 : 0) < ($1.other, $1.plan, $1.end ? 1 : 0) }
            for (j, port) in sorted.enumerated() {
                portY[port.plan, default: [:]][port.end] = rect.minY + rect.height * CGFloat(j + 1) / CGFloat(sorted.count + 1)
            }
        }

        // Heights: start, one per lane crossed (between its cards), end.
        let ys: [[CGFloat]] = plans.enumerated().map { k, p in
            let y1 = portY[k]![false]!, y2 = portY[k]![true]!
            let crossed = p.gutters.dropFirst().map { g in p.out ? g : g + 1 }
            return [y1] + crossed.map { crossing(lane: $0, near: (y1 + y2) / 2) } + [y2]
        }

        // Tracks: vertical runs in a gutter share an x only when they don't overlap.
        var trackX: [Int: [Int: CGFloat]] = [:]
        var runs: [Int: [(plan: Int, k: Int, lo: CGFloat, hi: CGFloat)]] = [:]
        for (k, p) in plans.enumerated() {
            for (j, g) in p.gutters.enumerated() {
                runs[g, default: []].append((k, j, min(ys[k][j], ys[k][j + 1]), max(ys[k][j], ys[k][j + 1])))
            }
        }
        for (g, list) in runs {
            var ends: [CGFloat] = [], track: [(plan: Int, k: Int, t: Int)] = []
            for r in list.sorted(by: { ($0.lo, $0.hi, $0.plan, $0.k) < ($1.lo, $1.hi, $1.plan, $1.k) }) {
                let t = ends.firstIndex { $0 + 6 < r.lo } ?? ends.count
                if t == ends.count { ends.append(r.hi) } else { ends[t] = r.hi }
                track.append((r.plan, r.k, t))
            }
            let inset: CGFloat = 14, width = (m.gutter - 2 * inset) / CGFloat(ends.count)
            for r in track { trackX[r.plan, default: [:]][r.k] = gutterX(g) + inset + (CGFloat(r.t) + 0.5) * width }
        }

        for (k, p) in plans.enumerated() {
            let from = cards[p.from]!, to = cards[p.to]!
            var points = [CGPoint(x: p.out ? from.maxX : from.minX, y: ys[k][0])]
            for j in p.gutters.indices {
                let x = trackX[k]![j]!
                points += [CGPoint(x: x, y: ys[k][j]), CGPoint(x: x, y: ys[k][j + 1])]
            }
            points.append(CGPoint(x: p.into ? to.maxX : to.minX, y: ys[k].last!))
            routes.append(Route(edge: p.edge, points: points.enumerated().filter { $0 == 0 || $1 != points[$0 - 1] }.map(\.1)))
            if let label = overview.edges[p.edge].label {
                spots.append(Spot(edge: p.edge, gutter: p.gutters[0], y: (ys[k][0] + ys[k][1]) / 2, label: label))
            }
        }

        let margin = n == 1 && plans.contains { $0.gutters == [0] } ? m.gutter : 0
        let low = max(bottom, ys.flatMap { $0 }.max() ?? 0, tags(Set(spots.map(\.edge))).map(\.frame.maxY).max() ?? 0)
        size = CGSize(width: CGFloat(n) * m.laneWidth + CGFloat(n - 1) * m.gutter + margin, height: low + m.lanePad)
        lanes = (0..<n).map { CGRect(x: CGFloat($0) * step, y: 0, width: m.laneWidth, height: size.height) }
    }

    /// Where an edge crosses `lane`: the gap between two of its cards (or below
    /// the last) nearest `y`.
    private func crossing(lane: Int, near y: CGFloat) -> CGFloat {
        let rects = order[lane].compactMap { cards[$0] }
        guard let last = rects.last else { return max(y, metrics.header) }
        let gaps = zip(rects, rects.dropFirst()).map { ($0.maxY + $1.minY) / 2 } + [last.maxY + metrics.spacing]
        return gaps.min { abs($0 - y) < abs($1 - y) }!
    }

    /// The labels of `shown` edges (overview indices), centred in their gutter
    /// near their edge, pushed down where they'd overlap.
    func tags(_ shown: Set<Int>) -> [Tag] {
        let m = metrics
        var out: [Tag] = []
        for g in Set(spots.map(\.gutter)).sorted() {
            var floor = -CGFloat.infinity
            for s in spots.filter({ $0.gutter == g && shown.contains($0.edge) }).sorted(by: { ($0.y, $0.edge) < ($1.y, $1.edge) }) {
                let text = s.label.count > m.tagChars ? String(s.label.prefix(m.tagChars - 1)) + "…" : s.label
                let w = min(CGFloat(text.count) * m.tagChar + 10, m.gutter - 8)
                let y = max(s.y - m.tagHeight / 2, floor)
                let x = CGFloat(g) * (m.laneWidth + m.gutter) + m.laneWidth + (m.gutter - w) / 2
                out.append(Tag(edge: s.edge, text: text, full: s.label, frame: CGRect(x: x, y: y, width: w, height: m.tagHeight)))
                floor = y + m.tagHeight + 2
            }
        }
        return out
    }

    // MARK: - Ordering

    /// Each lane's parts reordered by barycenter sweeps (left to right, then
    /// back), keeping whichever order crosses least; ties keep file order.
    static func ordered(_ initial: [[String]], links: [(String, String)], laneOf: [String: Int]) -> [[String]] {
        var neighbours: [String: [String]] = [:]
        for (a, b) in links where laneOf[a] != laneOf[b] {
            neighbours[a, default: []].append(b)
            neighbours[b, default: []].append(a)
        }
        let fileIndex = Dictionary(initial.flatMap { $0 }.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var order = initial, best = initial, least = crossings(initial, links: links, laneOf: laneOf)
        let n = initial.count
        guard n > 1 else { return initial }
        for pass in 0..<4 {
            let down = pass % 2 == 0
            for lane in down ? Array(1..<n) : Array((0..<n - 1).reversed()) {
                var pos: [String: Int] = [:]
                for ids in order { for (i, id) in ids.enumerated() { pos[id] = i } }
                func bary(_ id: String) -> Double {
                    let near = (neighbours[id] ?? []).filter { down ? laneOf[$0]! < lane : laneOf[$0]! > lane }
                    guard !near.isEmpty else { return Double(pos[id]!) }
                    return Double(near.map { pos[$0]! }.reduce(0, +)) / Double(near.count)
                }
                order[lane] = order[lane].map { ($0, bary($0)) }
                    .sorted { ($0.1, fileIndex[$0.0]!) < ($1.1, fileIndex[$1.0]!) }.map(\.0)
            }
            let c = crossings(order, links: links, laneOf: laneOf)
            if c < least { least = c; best = order }
        }
        return best
    }

    /// Pairs of edges between the same two lanes whose ends are in opposite orders.
    static func crossings(_ order: [[String]], links: [(String, String)], laneOf: [String: Int]) -> Int {
        var pos: [String: Int] = [:]
        for ids in order { for (i, id) in ids.enumerated() { pos[id] = i } }
        let spans = links.compactMap { a, b -> (lanes: [Int], ends: (Int, Int))? in
            guard let la = laneOf[a], let lb = laneOf[b], la != lb, let pa = pos[a], let pb = pos[b] else { return nil }
            return la < lb ? ([la, lb], (pa, pb)) : ([lb, la], (pb, pa))
        }
        var count = 0
        for i in spans.indices {
            for j in spans.indices where j > i && spans[i].lanes == spans[j].lanes {
                if (spans[i].ends.0 - spans[j].ends.0) * (spans[i].ends.1 - spans[j].ends.1) < 0 { count += 1 }
            }
        }
        return count
    }

    /// Lines `text` wraps to at `chars` per line (greedy by word, long words
    /// broken), at most `max`.
    static func lines(_ text: String, chars: Int, max limit: Int) -> Int {
        let chars = max(chars, 1)
        var lines = 1, used = 0
        for word in text.split(separator: " ") {
            let n = word.count
            if used > 0, used + 1 + n <= chars { used += 1 + n; continue }
            if used > 0 { lines += 1 }
            lines += (n - 1) / chars
            used = (n - 1) % chars + 1
        }
        return min(lines, limit)
    }
}
