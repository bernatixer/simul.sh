import CryptoKit
import Foundation

/// The shape of a change, from the agent's review file (version 2): a
/// one-line summary, a map of the parts it touches, design-level concerns
/// and a short tour. Validated whole: any problem rejects all of it.
struct AgentOverview: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable, CaseIterable { case added, changed, removed, untouched }
    enum Severity: String, Codable, Sendable, CaseIterable { case high, medium, low }

    /// A line of a file relative to the source root (new side).
    struct Anchor: Codable, Hashable, Sendable {
        var path: String
        var line: Int
    }

    struct Lane: Codable, Equatable, Sendable {
        var id: String
        var label: String
    }

    struct Part: Codable, Equatable, Sendable {
        var id: String
        var lane: String
        var label: String
        var note: String?
        var state: State
        var anchor: Anchor?
    }

    struct Edge: Codable, Equatable, Sendable {
        var from: String
        var to: String
        var state: State
        var label: String?
    }

    struct Concern: Codable, Equatable, Sendable {
        var severity: Severity
        var title: String
        var why: String
        var at: [Anchor]
        /// Part ids it's about (focused on the map).
        var parts: [String]
    }

    struct Step: Codable, Equatable, Sendable {
        var title: String
        var text: String
        var focus: [String]
        var anchor: Anchor?
    }

    /// Files grouped by purpose, in reading order (each path in at most one).
    struct Layer: Codable, Equatable, Sendable {
        var title: String
        var note: String?
        var files: [String]
    }

    struct Risk: Codable, Equatable, Sendable {
        var level: Severity
        var reason: String
    }

    var summary: String
    var lanes: [Lane] = []
    var parts: [Part] = []
    var edges: [Edge] = []
    var concerns: [Concern] = []
    var tour: [Step] = []
    var layers: [Layer] = []
    var risk: Risk?
    /// How hard it is to review, 1–5.
    var effort: Int?
    /// The snapshot it was made for (`ReviewSnapshot.fingerprint`); set by the importer.
    var fingerprint = ""
    /// Each anchored file's `ReviewSnapshot.anchorHash` then: its anchors hold while it's the same.
    var anchorHashes: [String: String] = [:]
    /// Concerns (by index) the user kept or dismissed.
    var dismissed: Set<Int> = []
    /// Concerns (by index) no concern of the overview it replaced matches;
    /// nil when it replaced none (a first review: no "New" or "Still open").
    var newConcerns: Set<Int>?
    /// The replaced overview's open concerns this one no longer raises.
    var resolved: [Concern] = []

    func isNew(_ index: Int) -> Bool { newConcerns?.contains(index) == true }

    /// The diff's files (in diff order) in reading order: each layer with its
    /// files still in the diff, then the rest under a nil layer ("Other").
    /// No layers: one nil group with every file.
    func fileOrder(diffPaths: [String]) -> [(layer: Layer?, paths: [String])] {
        let inDiff = Set(diffPaths)
        let groups: [(layer: Layer?, paths: [String])] = layers.map { ($0, $0.files.filter(inDiff.contains)) }.filter { !$0.1.isEmpty }
        let listed = Set(layers.flatMap(\.files))
        let other = diffPaths.filter { !listed.contains($0) }
        return other.isEmpty ? groups : groups + [(nil, other)]
    }

    /// This overview replacing `old`: which concerns are new, which stay dismissed (raised
    /// again after the user kept or dismissed them), and old open concerns gone from it. A concern matches one with the same title
    /// (ignoring case, spacing and punctuation) or the same first anchor.
    func following(_ old: AgentOverview) -> AgentOverview {
        func key(_ title: String) -> String {
            title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        func matches(_ a: Concern, _ b: Concern) -> Bool {
            key(a.title) == key(b.title) || (a.at.first != nil && a.at.first == b.at.first)
        }
        var o = self
        o.newConcerns = Set(concerns.indices.filter { i in !old.concerns.contains { matches($0, concerns[i]) } })
        o.dismissed = Set(concerns.indices.filter { i in old.dismissed.contains { old.concerns.indices.contains($0) && matches(old.concerns[$0], concerns[i]) } })
        o.resolved = old.concerns.indices.filter { !old.dismissed.contains($0) }.map { old.concerns[$0] }
            .filter { c in !concerns.contains { matches($0, c) } }
        return o
    }

    /// Made for another snapshot: the pane says "Out of date — Ask again".
    func isStale(for snapshot: ReviewSnapshot) -> Bool { fingerprint != snapshot.fingerprint }

    /// The anchor's file hasn't changed since: the line still means what the agent meant.
    func holds(_ anchor: Anchor, in snapshot: ReviewSnapshot) -> Bool {
        anchorHashes[anchor.path] == snapshot.anchorHash(anchor.path)
    }

    /// Where Keep comments: the concern's first anchor that holds on a file
    /// in the diff. nil: Keep is disabled ("Not on a changed line").
    func keepAnchor(_ index: Int, in snapshot: ReviewSnapshot) -> Anchor? {
        guard concerns.indices.contains(index), !dismissed.contains(index) else { return nil }
        let paths = Set(snapshot.files.filter { $0.status != .deleted }.map(\.path))
        return concerns[index].at.first { paths.contains($0.path) && holds($0, in: snapshot) }
    }
}

extension AgentOverview {
    /// Fields added later decode as absent from overviews saved before them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        lanes = try c.decode([Lane].self, forKey: .lanes)
        parts = try c.decode([Part].self, forKey: .parts)
        edges = try c.decode([Edge].self, forKey: .edges)
        concerns = try c.decode([Concern].self, forKey: .concerns)
        tour = try c.decode([Step].self, forKey: .tour)
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        risk = try c.decodeIfPresent(Risk.self, forKey: .risk)
        effort = try c.decodeIfPresent(Int.self, forKey: .effort)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        anchorHashes = try c.decode([String: String].self, forKey: .anchorHashes)
        dismissed = try c.decode(Set<Int>.self, forKey: .dismissed)
        newConcerns = try c.decodeIfPresent(Set<Int>.self, forKey: .newConcerns)
        resolved = try c.decodeIfPresent([Concern].self, forKey: .resolved) ?? []
    }
}

extension SourceState {
    /// Keep: concern `index` becomes the user's queued comment at `anchor`
    /// ("**title** — why", quoting `quote`) and leaves the list. Once only.
    mutating func keepConcern(_ index: Int, at anchor: AgentOverview.Anchor, quote: String, now: Date = Date()) {
        guard var o = overview, o.concerns.indices.contains(index), !o.dismissed.contains(index) else { return }
        let c = o.concerns[index]
        o.dismissed.insert(index)
        overview = o
        comments.append(ReviewComment(id: UUID(), path: anchor.path, line: anchor.line, endLine: anchor.line, quote: quote,
                                      text: "**\(c.title)** — \(c.why)", state: .queued, isOutdated: false, createdAt: now))
    }

    mutating func dismissConcern(_ index: Int) {
        guard overview?.concerns.indices.contains(index) == true, overview?.dismissed.contains(index) == false else { return }
        overview?.dismissed.insert(index)
    }
}

extension ReviewSnapshot {
    /// `fingerprint`: changes whenever the diff could, with another merge base or any file's content.
    static func fingerprint(point: String, hashes: [String: String]) -> String {
        let text = point + "\n" + hashes.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// What `path`'s content is now: its hash in the diff, else the merge base's (not in the diff = unchanged since it).
    func anchorHash(_ path: String) -> String { hashes[path] ?? "@" + point }
}

// MARK: - Validation

extension AgentOverview {
    static let maxLanes = 5, maxParts = 24, maxEdges = 40, maxConcerns = 6, maxAt = 3, maxSteps = 8
    static let maxSummary = 280, maxLabel = 40, maxEdgeLabel = 24, maxTitle = 70, maxText = 240
    static let maxLayers = 6, maxLayerNote = 160, maxReason = 120

    struct Invalid: Error, Equatable {
        let reasons: [String]
    }

    /// The overview in a version 2 file's root object, or every reason it
    /// isn't valid (each prefixed by its JSON path). `lineCount` gives a
    /// file's line count, nil if there is no such file; fingerprint and
    /// anchorHashes are left for the importer. Layers may also list `deletedPaths`.
    static func validate(json: [String: Any], diffPaths: Set<String>, deletedPaths: Set<String> = [],
                         lineCount: (String) -> Int?) -> Result<AgentOverview, Invalid> {
        withoutActuallyEscaping(lineCount) { lineCount in
            var v = Validator(diffPaths: diffPaths, deletedPaths: deletedPaths, lineCount: lineCount)
            let overview = v.overview(json)
            return v.reasons.isEmpty ? .success(overview) : .failure(Invalid(reasons: v.reasons))
        }
    }

    /// Every anchor path in a version 2 root object (plain relative paths
    /// only), from arrays within their limits: the validator skips the rest.
    static func anchorPaths(in json: [String: Any]) -> Set<String> {
        let objects = parts(json) + capped(json["tour"], maxSteps)
            + capped(json["concerns"], maxConcerns).flatMap { capped(($0 as? [String: Any])?["at"], maxAt) }
        return Set(objects.compactMap { ($0 as? [String: Any])?["path"] as? String }.filter(isPlainPath))
    }

    /// The only paths outside the diff worth reading: untouched parts' anchors (at most maxParts).
    static func outsidePaths(in json: [String: Any]) -> Set<String> {
        let untouched = parts(json).compactMap { $0 as? [String: Any] }.filter { $0["state"] as? String == State.untouched.rawValue }
        return Set(untouched.compactMap { $0["path"] as? String }.filter(isPlainPath))
    }

    private static func parts(_ json: [String: Any]) -> [Any] {
        capped((json["map"] as? [String: Any])?["parts"], maxParts)
    }

    /// The array, or none if it's over `max` (the validator rejects it).
    private static func capped(_ value: Any?, _ max: Int) -> [Any] {
        let array = value as? [Any] ?? []
        return array.count <= max ? array : []
    }

    /// Relative, without "", "." or ".." parts: it can't leave the source root.
    static func isPlainPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

private struct Validator {
    typealias O = AgentOverview
    let diffPaths: Set<String>
    let deletedPaths: Set<String>
    let lineCount: (String) -> Int?
    var reasons: [String] = []
    /// Arrays dropped for being over their limit (JSON paths).
    var overLimit: Set<String> = []

    /// The ids references may use; nil (don't check) when their array was over its limit, already reported.
    func known(_ path: String, _ ids: [String]) -> Set<String>? { overLimit.contains(path) ? nil : Set(ids) }

    mutating func overview(_ root: [String: Any]) -> O {
        var o = O(summary: text(root, "summary", at: "", max: O.maxSummary) ?? "")
        if let value = root["map"] {
            if let map = value as? [String: Any] {
                o.lanes = lanes(map)
                o.parts = parts(map, lanes: known("map.lanes", o.lanes.map(\.id)))
                o.edges = edges(map, parts: known("map.parts", o.parts.map(\.id)))
            } else {
                fail("map", "must be an object")
            }
        }
        let partIDs = known("map.parts", o.parts.map(\.id))
        o.concerns = items(root, "concerns", at: "", max: O.maxConcerns).compactMap { at, c in
            let severity: O.Severity? = choice(c, "severity", at: at)
            let title = text(c, "title", at: at, max: O.maxTitle), why = text(c, "why", at: at, max: O.maxText)
            let anchors = items(c, "at", at: at, max: O.maxAt).map { anchor($1, at: $0, outside: false, required: true) }
            let parts = ids(c, "parts", at: at, known: partIDs)
            guard let severity, let title, let why, !anchors.contains(where: { $0 == nil }) else { return nil }
            return O.Concern(severity: severity, title: title, why: why, at: anchors.compactMap { $0 }, parts: parts)
        }
        o.tour = items(root, "tour", at: "", max: O.maxSteps).compactMap { at, s in
            let title = text(s, "title", at: at, max: O.maxTitle), body = text(s, "text", at: at, max: O.maxText)
            let focus = ids(s, "focus", at: at, known: partIDs)
            let anchor = anchor(s, at: at, outside: false)
            guard let title, let body else { return nil }
            return O.Step(title: title, text: body, focus: focus, anchor: anchor)
        }
        o.layers = layers(root)
        if let value = root["risk"] {
            if let r = value as? [String: Any] {
                let level: O.Severity? = choice(r, "level", at: "risk")
                let reason = text(r, "reason", at: "risk", max: O.maxReason)
                if let level, let reason { o.risk = O.Risk(level: level, reason: reason) }
            } else {
                fail("risk", "must be an object")
            }
        }
        if let value = root["effort"] {
            if let effort = value as? Int, (1...5).contains(effort) { o.effort = effort } else { fail("effort", "must be a whole number from 1 to 5") }
        }
        return o
    }

    mutating func layers(_ root: [String: Any]) -> [O.Layer] {
        let found = items(root, "layers", at: "", max: O.maxLayers)
        if found.count == 1 { fail("layers", "needs at least 2 layers (or none)") }
        var placed: [String: String] = [:]  // path: the layer that has it
        return found.compactMap { at, l in
            let title = text(l, "title", at: at, max: O.maxLabel)
            let note = text(l, "note", at: at, max: O.maxLayerNote, optional: true)
            guard let files = l["files"] as? [String], !files.isEmpty else {
                fail(join(at, "files"), "must be a non-empty array of paths")
                return nil
            }
            var ok = true
            for path in files {
                if !diffPaths.contains(path) && !deletedPaths.contains(path) {
                    fail(join(at, "files"), "\"\(path)\" is not a file in the diff")
                    ok = false
                } else if let other = placed[path] {
                    fail(join(at, "files"), "\"\(path)\" is already in \(other)")
                    ok = false
                } else {
                    placed[path] = at
                }
            }
            guard let title, ok else { return nil }
            return O.Layer(title: title, note: note, files: files)
        }
    }

    mutating func lanes(_ map: [String: Any]) -> [O.Lane] {
        let found = items(map, "lanes", at: "map", max: O.maxLanes)
        if (map["lanes"] as? [Any])?.isEmpty ?? (map["lanes"] == nil) { fail("map.lanes", "needs at least one lane") }
        var seen: Set<String> = []
        return found.compactMap { at, l in
            guard let id = id(l, at: at, seen: &seen), let label = text(l, "label", at: at, max: O.maxLabel) else { return nil }
            return O.Lane(id: id, label: label)
        }
    }

    mutating func parts(_ map: [String: Any], lanes: Set<String>?) -> [O.Part] {
        var seen: Set<String> = []
        return items(map, "parts", at: "map", max: O.maxParts).compactMap { at, p in
            let id = id(p, at: at, seen: &seen)
            let lane = ids(p, "lane", at: at, known: lanes, one: true).first
            let label = text(p, "label", at: at, max: O.maxLabel)
            let note = text(p, "note", at: at, max: O.maxLabel, optional: true)
            let state: O.State? = choice(p, "state", at: at)
            let anchor = anchor(p, at: at, outside: state == .untouched)
            guard let id, let lane, let label, let state else { return nil }
            return O.Part(id: id, lane: lane, label: label, note: note, state: state, anchor: anchor)
        }
    }

    mutating func edges(_ map: [String: Any], parts: Set<String>?) -> [O.Edge] {
        items(map, "edges", at: "map", max: O.maxEdges).compactMap { at, e in
            let from = ids(e, "from", at: at, known: parts, one: true).first
            let to = ids(e, "to", at: at, known: parts, one: true).first
            let state: O.State? = choice(e, "state", at: at)
            let label = text(e, "label", at: at, max: O.maxEdgeLabel, optional: true)
            guard let from, let to, let state else { return nil }
            return O.Edge(from: from, to: to, state: state, label: label)
        }
    }

    // MARK: Fields

    mutating func fail(_ at: String, _ why: String) { reasons.append("\(at): \(why)") }

    func join(_ at: String, _ key: String) -> String { at.isEmpty ? key : "\(at).\(key)" }

    /// A trimmed, non-empty string of at most `max` characters.
    mutating func text(_ o: [String: Any], _ key: String, at: String, max: Int, optional: Bool = false) -> String? {
        guard let value = o[key] else {
            if !optional { fail(join(at, key), "missing") }
            return nil
        }
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            fail(join(at, key), "must be a non-empty string")
            return nil
        }
        guard s.count <= max else {
            fail(join(at, key), "over \(max) characters")
            return nil
        }
        return s
    }

    mutating func choice<E: RawRepresentable & CaseIterable>(_ o: [String: Any], _ key: String, at: String) -> E? where E.RawValue == String {
        if let value = (o[key] as? String).flatMap(E.init(rawValue:)) { return value }
        fail(join(at, key), "must be one of " + E.allCases.map(\.rawValue).joined(separator: ", "))
        return nil
    }

    /// The array's objects with their JSON paths; absent is empty.
    mutating func items(_ o: [String: Any], _ key: String, at: String, max: Int) -> [(String, [String: Any])] {
        let path = join(at, key)
        guard let value = o[key] else { return [] }
        guard let array = value as? [Any] else {
            fail(path, "must be an array")
            return []
        }
        guard array.count <= max else {
            fail(path, "at most \(max) allowed, found \(array.count)")
            overLimit.insert(path)
            return []
        }
        return array.enumerated().compactMap { n, item in
            guard let object = item as? [String: Any] else {
                fail("\(path)[\(n)]", "must be an object")
                return nil
            }
            return ("\(path)[\(n)]", object)
        }
    }

    mutating func id(_ o: [String: Any], at: String, seen: inout Set<String>) -> String? {
        guard let id = text(o, "id", at: at, max: O.maxLabel) else { return nil }
        guard seen.insert(id).inserted else {
            fail(at, "duplicate id \"\(id)\"")
            return nil
        }
        return id
    }

    /// Ids naming parts (or lanes): a list, or with `one` a single string.
    /// `known` nil: taken unchecked.
    mutating func ids(_ o: [String: Any], _ key: String, at: String, known: Set<String>?, one: Bool = false) -> [String] {
        guard let value = o[key] else {
            if one { fail(join(at, key), "missing") }
            return []
        }
        guard let list = one ? (value as? String).map({ [$0] }) : value as? [String] else {
            fail(join(at, key), one ? "must be a string" : "must be an array of ids")
            return []
        }
        let what = key == "lane" ? "lane" : "part"
        guard let known else { return list }
        for id in list where !known.contains(id) { fail(at, "unknown \(what) \"\(id)\"") }
        return list.filter(known.contains)
    }

    /// `path` + `line`, both or (unless `required`) neither. `outside`: may
    /// be a file not in the diff (untouched parts) as long as it exists.
    mutating func anchor(_ o: [String: Any], at: String, outside: Bool, required: Bool = false) -> O.Anchor? {
        guard o["path"] != nil || o["line"] != nil else {
            if required { fail(at, "needs \"path\" and \"line\"") }
            return nil
        }
        guard let path = o["path"] as? String, O.isPlainPath(path) else {
            fail(join(at, "path"), "must be a path relative to the source root")
            return nil
        }
        guard let line = o["line"] as? Int, line >= 1 else {
            fail(join(at, "line"), "must be a line number")
            return nil
        }
        guard diffPaths.contains(path) || outside else {
            fail(join(at, "path"), "\"\(path)\" is not a file in the diff")
            return nil
        }
        guard let count = lineCount(path) else {
            fail(join(at, "path"), "no file \"\(path)\"")
            return nil
        }
        guard line <= count else {
            fail(join(at, "line"), "\(line) is past the end of \(path) (\(count) lines)")
            return nil
        }
        return O.Anchor(path: path, line: line)
    }
}
