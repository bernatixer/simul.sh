import Foundation
@testable import AgentSessionsCore

@MainActor
func registerStoreTests() {
    test("store: round trip preserves sessions") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(
            fileURL: dir.appendingPathComponent("sessions.json"),
            backupURL: dir.appendingPathComponent("sessions.json.prev")
        )
        let sessions = [
            Session(title: "Auth refactor", workingDirectory: "/Users/me/code/app", agentID: "claude"),
            Session(title: "Billing", workingDirectory: "/Users/me/code/app", agentID: "codex", sortOrder: 1),
        ]
        store.save(sessions)
        let loaded = store.load()
        expectEqual(loaded.count, 2, "session count preserved")
        expectEqual(loaded.map(\.id), sessions.map(\.id), "ids and order preserved")
        expectEqual(loaded.map(\.title), sessions.map(\.title), "titles preserved")
        expectEqual(loaded.map(\.workingDirectory), sessions.map(\.workingDirectory), "directories preserved")
        // Dates are ISO8601 (second precision); compare within tolerance.
        for (a, b) in zip(loaded, sessions) {
            expect(
                abs(a.createdAt.timeIntervalSince(b.createdAt)) < 1,
                "createdAt preserved within a second")
        }
    }

    test("store: missing file loads empty") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(
            fileURL: dir.appendingPathComponent("sessions.json"),
            backupURL: dir.appendingPathComponent("sessions.json.prev")
        )
        expect(store.load().isEmpty, "missing file should load as empty")
    }

    test("store: corrupt file falls back to backup ") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(
            fileURL: dir.appendingPathComponent("sessions.json"),
            backupURL: dir.appendingPathComponent("sessions.json.prev")
        )
        store.save([Session(title: "one", workingDirectory: "/tmp", agentID: "claude")])
        // Rotate a valid backup (now holding the first save), then corrupt the primary.
        store.save([
            Session(title: "one", workingDirectory: "/tmp", agentID: "claude"),
            Session(title: "two", workingDirectory: "/tmp", agentID: "codex", sortOrder: 1),
        ])
        try Data("not json".utf8).write(to: dir.appendingPathComponent("sessions.json"))

        // The backup holds the previous good save: one session.
        let loaded = store.load()
        expectEqual(loaded.count, 1, "backup (previous save) recovered")
        expect(loaded.contains { $0.title == "one" }, "backup contents are the previous snapshot")
    }

    test("store: JSON is versioned ") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(
            fileURL: dir.appendingPathComponent("sessions.json"),
            backupURL: dir.appendingPathComponent("sessions.json.prev")
        )
        store.save([Session(title: "one", workingDirectory: "/tmp", agentID: "claude")])
        let data = try Data(contentsOf: dir.appendingPathComponent("sessions.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        expectEqual(object["version"] as? Int, 1, "top-level version must be 1")
        expect((object["sessions"] as? [[String: Any]])?.count == 1, "sessions array present")
    }
}

private func XCTUnwrap<T>(_ value: T?, _ message: String = "") throws -> T {
    guard let value else { throw NSError(domain: "unwrap", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}
