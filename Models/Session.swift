import Foundation

/// A single managed terminal session.
///
/// Sessions are pure metadata. The backing process lives in the terminal
/// surface (direct backend) or in tmux, keyed by the stable `id`.
struct Session: Identifiable, Codable, Hashable {
    let id: UUID

    var title: String
    var workingDirectory: String
    var agentID: String

    var isArchived: Bool
    var sortOrder: Int

    let createdAt: Date
    var lastOpenedAt: Date

    /// Launch the agent with its "dangerously skip permissions" flag
    /// (e.g. `claude --dangerously-skip-permissions`). Off by default.
    var skipPermissions: Bool

    /// The agent's own conversation ID, so relaunching resumes exactly this
    /// session's conversation (never "the latest one in the directory").
    /// Claude: chosen by us up front (`--session-id`). Codex: discovered
    /// after the fact (see AgentConversations).
    var agentSessionID: String?

    /// When the agent was last started; bounds Codex thread discovery.
    var lastLaunchedAt: Date?

    /// When the session was archived; orders the archived list.
    var archivedAt: Date?

    /// When the session was put to sleep: stopped, listed apart, woken by
    /// selecting it. nil = awake.
    var sleptAt: Date?

    /// Sessions sharing a folder sit together in the sidebar (⇧⌘N).
    var folderID: UUID?

    /// The folder's name, if renamed; kept on every member so it survives
    /// whichever one is first. nil = titled after the first session.
    var folderTitle: String?

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        agentID: String,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        skipPermissions: Bool = false,
        agentSessionID: String? = nil,
        lastLaunchedAt: Date? = nil,
        archivedAt: Date? = nil,
        sleptAt: Date? = nil,
        folderID: UUID? = nil,
        folderTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.agentID = agentID
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.skipPermissions = skipPermissions
        self.agentSessionID = agentSessionID
        self.lastLaunchedAt = lastLaunchedAt
        self.archivedAt = archivedAt
        self.sleptAt = sleptAt
        self.folderID = folderID
        self.folderTitle = folderTitle
    }

    // MARK: - Codable (fields after lastOpenedAt are additive; older files decode fine)

    enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory, agentID, isArchived, sortOrder, createdAt, lastOpenedAt, skipPermissions
        case agentSessionID, lastLaunchedAt, archivedAt, sleptAt, folderID, folderTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        agentID = try c.decode(String.self, forKey: .agentID)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? false
        agentSessionID = try c.decodeIfPresent(String.self, forKey: .agentSessionID)
        lastLaunchedAt = try c.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        sleptAt = try c.decodeIfPresent(Date.self, forKey: .sleptAt)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        folderTitle = try c.decodeIfPresent(String.self, forKey: .folderTitle)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(agentID, forKey: .agentID)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encode(skipPermissions, forKey: .skipPermissions)
        try c.encodeIfPresent(agentSessionID, forKey: .agentSessionID)
        try c.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(sleptAt, forKey: .sleptAt)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(folderTitle, forKey: .folderTitle)
    }
}

// MARK: - Folders

extension Session {
    /// Folders that show as folders: holding two or more of `active`.
    static func shownFolders(in active: [Session]) -> Set<UUID> {
        var counts: [UUID: Int] = [:]
        for folder in active.compactMap(\.folderID) { counts[folder, default: 0] += 1 }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    /// The folder's header: its custom name, else its first session's title.
    static func folderTitle(_ folder: UUID, members: [Session], all: [Session]) -> String {
        all.first { $0.folderID == folder && $0.folderTitle != nil }?.folderTitle ?? members[0].title
    }

    /// `active` (by sortOrder) with each shown folder's sessions together,
    /// where its first one is.
    static func sidebarOrder(_ active: [Session]) -> [Session] {
        let folders = shownFolders(in: active)
        var placed: Set<UUID> = []
        var ordered: [Session] = []
        for session in active {
            guard let folder = session.folderID, folders.contains(folder) else {
                ordered.append(session)
                continue
            }
            if placed.insert(folder).inserted {
                ordered += active.filter { $0.folderID == folder }
            }
        }
        return ordered
    }
}
