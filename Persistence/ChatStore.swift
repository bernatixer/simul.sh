import Foundation

/// One atomic snapshot per session, including the outbox before a pipe write.
final class ChatStore: @unchecked Sendable {
    private let folder: URL
    init(folder: URL = Paths.applicationSupport.appendingPathComponent("chat", isDirectory: true)) { self.folder = folder }

    private struct Snapshot: Codable {
        let version: Int
        let state: ChatState
    }

    private struct Header: Decodable { let version: Int }
    private struct UnsupportedVersion: LocalizedError {
        var errorDescription: String? { "This Chat was saved by a newer version of Simul." }
    }

    func load(for id: UUID) throws -> ChatState? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try read(file) }
        catch is UnsupportedVersion { throw UnsupportedVersion() }
        catch {
            if let previous = try? read(file.appendingPathExtension("prev")) { return previous }
            throw error
        }
    }

    private func read(_ file: URL) throws -> ChatState {
        let data = try Data(contentsOf: file)
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else { throw UnsupportedVersion() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        return snapshot.state
    }

    func save(_ state: ChatState, for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = url(id)
        if let data = try? Data(contentsOf: file), let header = try? JSONDecoder().decode(Header.self, from: data), header.version != 1 {
            throw UnsupportedVersion()
        }
        let data = try JSONEncoder().encode(Snapshot(version: 1, state: state))
        if (try? read(file)) != nil {
            let backup = file.appendingPathExtension("prev")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func remove(for id: UUID) throws {
        for file in [url(id), url(id).appendingPathExtension("prev")] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}
