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

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        agentID: String,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.agentID = agentID
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}
