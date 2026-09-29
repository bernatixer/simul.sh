import Foundation
@testable import AgentSessionsCore

@MainActor
func registerTmuxTests() {
    test("tmux: names derived from UUID and sanitized") {
        let session = Session(title: "Any Human Title", workingDirectory: "/tmp", agentID: "claude")
        let name = TmuxSessionBackend.tmuxName(for: session)
        expect(name.hasPrefix("as-"), "name prefix")
        expect(name.contains(session.id.uuidString.lowercased()), "name contains uuid")
        expect(!name.contains(" "), "name sanitized")
    }

    test("tmux: name -> id round trip") {
        let session = Session(title: "t", workingDirectory: "/tmp", agentID: "claude")
        let name = TmuxSessionBackend.tmuxName(for: session)
        expectEqual(TmuxSessionBackend.sessionID(fromTmuxName: name), session.id, "round trip")
        expect(TmuxSessionBackend.sessionID(fromTmuxName: "other") == nil, "foreign names rejected")
        expect(TmuxSessionBackend.sessionID(fromTmuxName: "as-not-a-uuid") == nil, "bad uuid rejected")
    }

    test("tmux: attach command targets the stable name ") {
        let resolver = ExecutableResolver(tmuxOverride: "/opt/homebrew/bin/tmux")
        let backend = TmuxSessionBackend(resolver: resolver)
        let session = Session(title: "t", workingDirectory: "/tmp", agentID: "claude")
        let spec = try backend.attachCommand(for: session)
        // The terminal host runs a single shell command string.
        expectEqual(
            spec.command,
            "'/opt/homebrew/bin/tmux' 'attach-session' '-t' '\(TmuxSessionBackend.tmuxName(for: session))'",
            "attach command string targets the tmux name")
        expectEqual(spec.workingDirectory ?? "", "/tmp", "inherits working directory")
    }

    test("tmux: lifecycle create/exists/list/stop") {
        try requireTmux()
        let backend = TmuxSessionBackend(resolver: ExecutableResolver())
        let session = Session(
            title: "integration",
            workingDirectory: NSHomeDirectory(),
            agentID: "shell"
        )

        try? await backend.stop(session)
        let existedBefore = try await backend.exists(session)
        expect(!existedBefore, "should not exist initially")

        try await backend.create(session, agent: AgentDefinition.builtIns[3]) // shell
        let existsAfter = try await backend.exists(session)
        expect(existsAfter, "should exist after create")
        let running = try await backend.listRunningIDs()
        expect(running.contains(session.id), "listed as running")

        try await backend.stop(session)
        let existsAfterStop = try await backend.exists(session)
        expect(!existsAfterStop, "gone after stop")
        let runningAfter = try await backend.listRunningIDs()
        expect(!runningAfter.contains(session.id), "not listed after stop")
    }

    test("tmux: missing executable error is clear") {
        try requireTmux()
        let backend = TmuxSessionBackend(resolver: ExecutableResolver())
        let session = Session(title: "missing", workingDirectory: NSHomeDirectory(), agentID: "claude")
        let bogus = AgentDefinition(
            id: "bogus", name: "Bogus", executable: "definitely-not-a-real-agent-xyz")
        try? await backend.stop(session)

        var threw = false
        do {
            try await backend.create(session, agent: bogus)
        } catch {
            threw = true
            expect(
                String(describing: error).contains("definitely-not-a-real-agent-xyz"),
                "error mentions the missing executable")
        }
        expect(threw, "create with bogus executable must throw")
        try? await backend.stop(session)
    }
}

private func requireTmux() throws {
    let present = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }
    guard present else {
        throw NSError(domain: "skip", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "tmux not installed; skipping integration test",
        ])
    }
}
