import Foundation
@testable import SimulCore

@MainActor
func registerChangeMapLayoutTests() {
    typealias O = AgentOverview
    func part(_ id: String, _ lane: String, _ label: String = "part", note: String? = nil) -> O.Part {
        O.Part(id: id, lane: lane, label: label, note: note, state: .changed, anchor: nil)
    }
    func edge(_ from: String, _ to: String, _ label: String? = nil) -> O.Edge {
        O.Edge(from: from, to: to, state: .changed, label: label)
    }
    // The screenshot's shape: 4 lanes, 9 parts, long labels, edges both ways,
    // skipping lanes and within a lane.
    var big = O(summary: "s")
    big.lanes = ["wf", "api", "store", "tests"].map { O.Lane(id: $0, label: $0) }
    big.parts = [
        part("load", "wf", "load_order", note: "picks the error class"),
        part("checkout", "wf", "checkout_api"),
        part("nightly", "wf", "nightly_import", note: "now fails quietly"),
        part("ref", "api", "EventReference"),
        part("flag", "api", "is_retryable_lookup_failure", note: "new flag on the error"),
        part("rows", "store", "expired rows lookup"),
        part("alert", "store", "alerting"),
        part("t1", "tests", "test_load_order_reference_fails_quietly"),
        part("t2", "tests", "test_nightly_import"),
    ]
    big.edges = [
        edge("checkout", "load", "retry ×3"), edge("load", "ref", "reference + flag"), edge("load", "flag"),
        edge("flag", "alert", "is_retryable_lookup_failure"), edge("ref", "rows", "lookup"), edge("nightly", "rows"),
        edge("t1", "load", "asserts via"), edge("t2", "nightly", "report?"), edge("alert", "t1"), edge("rows", "rows", "self"),
        edge("t1", "t2", "same lane"), edge("load", "alert", "skips a lane"),
    ]

    /// Segments of every route, as (start, end).
    func segments(_ l: ChangeMapLayout) -> [(CGPoint, CGPoint, Int)] {
        l.routes.flatMap { r in zip(r.points, r.points.dropFirst()).map { ($0, $1, r.edge) } }
    }
    /// An axis-aligned segment's bounding box, a hair thick.
    func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -0.1, dy: -0.1)
    }

    test("map layout: edges never pass through a card, and are axis-aligned") {
        let l = ChangeMapLayout(big)
        expectEqual(l.routes.count, big.edges.count, "every edge routed")
        for (a, b, e) in segments(l) {
            expect(a.x == b.x || a.y == b.y, "edge \(e): axis-aligned")
            for (id, card) in l.cards where card.insetBy(dx: 1, dy: 1).intersects(box(a, b)) {
                expect(false, "edge \(e) passes through \(id)")
            }
        }
        for r in l.routes {
            let e = big.edges[r.edge], first = r.points.first!, last = r.points.last!
            let from = l.cards[e.from]!, to = l.cards[e.to]!
            expect(first.x == from.minX || first.x == from.maxX, "edge \(r.edge) starts on its source's side")
            expect(last.x == to.minX || last.x == to.maxX, "edge \(r.edge) ends on its target's side")
            expect((from.minY...from.maxY).contains(first.y) && (to.minY...to.maxY).contains(last.y), "edge \(r.edge): ports on the cards")
        }
    }

    test("map layout: cards don't overlap, lanes are columns in order, the map holds everything") {
        let l = ChangeMapLayout(big)
        let cards = Array(l.cards.values)
        for i in cards.indices { for j in cards.indices where j > i { expect(!cards[i].intersects(cards[j]), "cards overlap") } }
        for (i, ids) in l.order.enumerated() {
            for id in ids { expect(l.lanes[i].contains(l.cards[id]!), "\(id) in its lane") }
            for (a, b) in zip(ids, ids.dropFirst()) { expect(l.cards[b]!.minY - l.cards[a]!.maxY >= 14, "spacing") }
        }
        expectEqual(Set(l.order.flatMap { $0 }), Set(big.parts.map(\.id)), "every part placed once")
        expect(l.lanes.map(\.minX) == l.lanes.map(\.minX).sorted(), "lanes left to right")
        let bounds = CGRect(origin: .zero, size: l.size)
        expect(l.tags(Set(big.edges.indices)).allSatisfy { bounds.contains($0.frame) }, "labels inside")
        expect(segments(l).allSatisfy { bounds.contains($0.0) && bounds.contains($0.1) }, "edges inside")
        expect(l.cards["t1"]!.height > l.cards["checkout"]!.height, "a long label wraps to two lines")
    }

    test("map layout: labels in gutters, never overlapping each other or a card, cut with …") {
        var crowded = big
        // Many labelled edges between the same two cards: they all want the same spot.
        crowded.edges += (0..<6).map { edge("load", "ref", "label \($0)") }
        let l = ChangeMapLayout(crowded)
        let tags = l.tags(Set(crowded.edges.indices))
        expectEqual(tags.count, crowded.edges.filter { $0.label != nil }.count, "every label placed")
        for i in tags.indices {
            for j in tags.indices where j > i { expect(!tags[i].frame.intersects(tags[j].frame), "labels \(tags[i].text) and \(tags[j].text) overlap") }
            for card in l.cards.values { expect(!tags[i].frame.intersects(card), "label \(tags[i].text) over a card") }
        }
        let cut = tags.first { $0.full == "is_retryable_lookup_failure" }!
        expect(cut.text.count <= 22 && cut.text.hasSuffix("…"), "cut: \(cut.text)")
        expectEqual(tags.first { $0.full == "retry ×3" }?.text, "retry ×3", "short label whole")
        expectEqual(l.tags([1]).map(\.edge), [1], "only the edges asked for")
    }

    test("map layout: barycenter ordering uncrosses edges") {
        // a1→b2, a2→b1 cross in file order; one sweep fixes it.
        var x = O(summary: "s")
        x.lanes = [O.Lane(id: "a", label: "A"), O.Lane(id: "b", label: "B")]
        x.parts = [part("a1", "a"), part("a2", "a"), part("b1", "b"), part("b2", "b")]
        x.edges = [edge("a1", "b2"), edge("a2", "b1")]
        let laneOf = ["a1": 0, "a2": 0, "b1": 1, "b2": 1], links = x.edges.map { ($0.from, $0.to) }
        expectEqual(ChangeMapLayout.crossings([["a1", "a2"], ["b1", "b2"]], links: links, laneOf: laneOf), 1, "file order crosses")
        let l = ChangeMapLayout(x)
        expectEqual(l.order, [["a1", "a2"], ["b2", "b1"]], "reordered")
        expectEqual(ChangeMapLayout.crossings(l.order, links: links, laneOf: laneOf), 0, "no crossings")
        // Nothing to gain: file order kept.
        x.edges = [edge("a1", "b1"), edge("a2", "b2")]
        expectEqual(ChangeMapLayout(x).order, [["a1", "a2"], ["b1", "b2"]], "file order when already uncrossed")
        let bigLaneOf = Dictionary(uniqueKeysWithValues: big.parts.map { p in (p.id, big.lanes.firstIndex { $0.id == p.lane }!) })
        let bigLinks = big.edges.map { ($0.from, $0.to) }
        let before = ChangeMapLayout.crossings(big.lanes.map { lane in big.parts.filter { $0.lane == lane.id }.map(\.id) }, links: bigLinks, laneOf: bigLaneOf)
        expect(ChangeMapLayout.crossings(ChangeMapLayout(big).order, links: bigLinks, laneOf: bigLaneOf) <= before, "never worse than file order")
    }

    test("map layout: deterministic, and edge cases") {
        expectEqual(ChangeMapLayout(big), ChangeMapLayout(big), "same overview, same layout")
        expectEqual(ChangeMapLayout(big).tags([0, 1, 3]), ChangeMapLayout(big).tags([0, 1, 3]), "same labels")
        expectEqual(ChangeMapLayout(O(summary: "s")).size, .zero, "no lanes: nothing")
        var one = O(summary: "s")
        one.lanes = [O.Lane(id: "a", label: "A")]
        one.parts = [part("p", "a"), part("q", "a")]
        one.edges = [edge("p", "q", "loop"), edge("p", "p")]
        let l = ChangeMapLayout(one)
        expect(l.size.width > l.lanes[0].maxX, "one lane's loops get a margin")
        expect(l.routes.allSatisfy { $0.points.dropFirst().dropLast().allSatisfy { $0.x > l.lanes[0].maxX } }, "loops outside the lane")
        expectEqual(ChangeMapLayout.lines("aaaa bbbb cccc", chars: 9, max: 5), 2, "wraps by word")
        expectEqual(ChangeMapLayout.lines(String(repeating: "x", count: 30), chars: 10, max: 5), 3, "long word broken")
        expectEqual(ChangeMapLayout.lines(String(repeating: "x", count: 90), chars: 10, max: 2), 2, "capped")
    }
}
