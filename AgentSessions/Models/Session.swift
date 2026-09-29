import Foundation

/// A single managed terminal session.
///
/// Sessions are pure metadata. The backing terminal process is owned by tmux
/// and derived from the stable `id` (see `SessionBackend.tmuxName`).
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

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        agentID: String,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        skipPermissions: Bool = false
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
    }

    // MARK: - Codable (skipPermissions is additive; older files decode fine)

    enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory, agentID, isArchived, sortOrder, createdAt, lastOpenedAt, skipPermissions
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
    }
}
