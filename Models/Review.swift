import Foundation

struct ReviewComment: Identifiable, Codable, Equatable {
    /// `posted`: submitted to GitHub as part of a PR review.
    enum State: String, Codable { case queued, sent, resolved, posted }

    let id: UUID
    var path: String
    /// New-side line number (start); `endLine == line` for single-line comments.
    var line: Int
    var endLine: Int
    /// Text of `line` when written, used to re-anchor.
    var quote: String
    var text: String
    var state: State
    /// Set by anchoring on every refresh; persisted so it survives restart.
    var isOutdated: Bool
    let createdAt: Date
    /// Drafted by the agent's review rather than written by the user.
    var byAgent = false

    init(id: UUID, path: String, line: Int, endLine: Int, quote: String, text: String,
         state: State, isOutdated: Bool, createdAt: Date, byAgent: Bool = false) {
        self.id = id
        self.path = path
        self.line = line
        self.endLine = endLine
        self.quote = quote
        self.text = text
        self.state = state
        self.isOutdated = isOutdated
        self.createdAt = createdAt
        self.byAgent = byAgent
    }

    // Explicit so files written before `isOutdated` and `byAgent` existed still decode.
    enum CodingKeys: String, CodingKey {
        case id, path, line, endLine, quote, text, state, isOutdated, createdAt, byAgent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        line = try c.decode(Int.self, forKey: .line)
        endLine = try c.decode(Int.self, forKey: .endLine)
        quote = try c.decode(String.self, forKey: .quote)
        text = try c.decode(String.self, forKey: .text)
        state = try c.decode(State.self, forKey: .state)
        isOutdated = try c.decodeIfPresent(Bool.self, forKey: .isOutdated) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        byAgent = try c.decodeIfPresent(Bool.self, forKey: .byAgent) ?? false
    }
}

struct ViewedMark: Codable, Equatable {
    var hash: String
    var viewedAt: Date
}

/// One source's review: what it's compared against, what's been viewed, and comments.
struct SourceState: Codable, Equatable {
    /// nil = automatic.
    var base: String?
    /// By path.
    var viewed: [String: ViewedMark] = [:]
    var comments: [ReviewComment] = []
    /// The agent's last valid overview of this source (AgentOverview).
    var overview: AgentOverview?
}

extension SourceState {
    /// An overview saved by another version that no longer decodes is dropped, not the whole state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base)
        viewed = try c.decode([String: ViewedMark].self, forKey: .viewed)
        comments = try c.decode([ReviewComment].self, forKey: .comments)
        overview = try? c.decodeIfPresent(AgentOverview.self, forKey: .overview)
    }
}

struct ReviewState: Codable, Equatable {
    /// The source being reviewed.
    var source: ReviewSource = .sessionFolder
    /// By `ReviewSource.key`.
    var sources: [String: SourceState] = [:]
    /// The user picked `source`; until then, opening the review follows the agent's worktree.
    var sourceChosen = false

    /// `source` is the one being reviewed; a session never reviewed (no state) is on the default one.
    static func isCurrent(_ state: ReviewState?, _ source: ReviewSource) -> Bool {
        (state ?? ReviewState()).source == source
    }

    /// The selected source's state.
    var current: SourceState {
        get { self[source] }
        set { self[source] = newValue }
    }

    /// Setting an empty state removes its entry, so reading and writing back
    /// an untouched source changes nothing.
    subscript(source: ReviewSource) -> SourceState {
        get { sources[source.key] ?? SourceState() }
        set { sources[source.key] = newValue == SourceState() ? nil : newValue }
    }

    init() {}

    enum CodingKeys: String, CodingKey { case source, sources, sourceChosen }
    /// Before sources: one folder's base, viewed and comments at the top level.
    private enum LegacyKeys: String, CodingKey { case folder, base, viewed, comments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(ReviewSource.self, forKey: .source) ?? .sessionFolder
        sources = try c.decodeIfPresent([String: SourceState].self, forKey: .sources) ?? [:]
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        if let folder = try old.decodeIfPresent(String.self, forKey: .folder) { source = .folder(folder) }
        let legacy = SourceState(
            base: try old.decodeIfPresent(String.self, forKey: .base),
            viewed: try old.decodeIfPresent([String: ViewedMark].self, forKey: .viewed) ?? [:],
            comments: try old.decodeIfPresent([ReviewComment].self, forKey: .comments) ?? []
        )
        if legacy != SourceState() { current = legacy }
        // Saved before sourceChosen: a folder was only ever set by the user.
        sourceChosen = try c.decodeIfPresent(Bool.self, forKey: .sourceChosen) ?? (source != .sessionFolder)
    }
}

enum ReviewAnchoring {
    /// Re-finds each comment's line in the file's current lines: same line if
    /// its text still equals `quote`, else the nearest line with that text
    /// (ties to the earlier line), else marks it outdated and keeps the line.
    static func reanchor(_ comments: [ReviewComment], path: String, lines: [String]) -> [ReviewComment] {
        // A trailing \r ignored on both sides, as GitHubReview.matchesHead does.
        func bare(_ s: String) -> Substring { s.hasSuffix("\r") ? s.dropLast() : Substring(s) }
        return comments.map { old in
            guard old.path == path else { return old }
            var c = old
            let quote = bare(c.quote)
            if lines.indices.contains(c.line - 1), bare(lines[c.line - 1]) == quote {
                c.isOutdated = false
            } else if let i = lines.indices
                .filter({ bare(lines[$0]) == quote })
                .min(by: { abs($0 + 1 - c.line) < abs($1 + 1 - c.line) }) {  // min keeps the first of equals
                c.endLine += i + 1 - c.line
                c.line = i + 1
                c.isOutdated = false
            } else {
                c.isOutdated = true
            }
            return c
        }
    }
}
