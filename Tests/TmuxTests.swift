import Foundation
@testable import SimulCore

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
        let spec = try backend.attachCommand(for: session, agent: AgentDefinition.builtIns[0], conversation: .none)
        // The terminal host runs a single shell command string.
        expectEqual(
            spec.command,
            "'/opt/homebrew/bin/tmux' 'attach-session' '-t' '\(TmuxSessionBackend.tmuxName(for: session))'",
            "attach command string targets the tmux name")
        expectEqual(spec.workingDirectory ?? "", "/tmp", "inherits working directory")
    }

    test("tmux: dangerous arguments appended only when opted in") {
        func make(_ agentID: String, skip: Bool) -> Session {
            Session(title: "t", workingDirectory: "/tmp", agentID: agentID, skipPermissions: skip)
        }
        let claude = AgentDefinition.builtIns[0]
        let codex = AgentDefinition.builtIns[1]
        let opencode = AgentDefinition.builtIns[2]
        let shell = AgentDefinition.builtIns[3]

        expect(
            TmuxSessionBackend.launchArguments(for: make("claude", skip: true), agent: claude)
                == ["--dangerously-skip-permissions"],
            "claude danger flag")
        expect(
            TmuxSessionBackend.launchArguments(for: make("codex", skip: true), agent: codex)
                == codex.arguments + ["--dangerously-bypass-approvals-and-sandbox"],
            "codex danger flag")
        expect(
            TmuxSessionBackend.launchArguments(for: make("opencode", skip: true), agent: opencode)
                == ["--dangerously-skip-permissions"],
            "opencode danger flag")
        expect(
            TmuxSessionBackend.launchArguments(for: make("claude", skip: false), agent: claude)
                .isEmpty,
            "no flag when off")
        expect(
            TmuxSessionBackend.launchArguments(for: make("shell", skip: true), agent: shell)
                .isEmpty,
            "shell has no danger flag")
    }

    test("direct: attach command runs the agent itself with danger flags") {
        let resolver = ExecutableResolver()
        // Preload resolution results (normally done via login-shell probes).
        resolver.cache["cmd:claude"] = "/Users/me/.local/bin/claude"
        let backend = DirectSessionBackend(resolver: resolver)
        let claude = AgentDefinition.builtIns[0]
        let session = Session(title: "t", workingDirectory: "/tmp", agentID: "claude")

        try? await backend.create(session, agent: claude, conversation: .none)

        let spec = try backend.attachCommand(for: session, agent: AgentDefinition.builtIns[0], conversation: .none)
        expectEqual(
            spec.command,
            "'/Users/me/.local/bin/claude'",
            "direct command is the resolved executable")
        expectEqual(spec.workingDirectory ?? "", "/tmp", "inherits working directory")

        // skipPermissions sessions get the flag appended at attach time.
        let danger = Session(title: "t", workingDirectory: "/tmp", agentID: "claude", skipPermissions: true)
        let specDanger = try backend.attachCommand(for: danger, agent: AgentDefinition.builtIns[0], conversation: .none)
        expectEqual(
            specDanger.command,
            "'/Users/me/.local/bin/claude' '--dangerously-skip-permissions'",
            "danger flag appended")

        // The given agent is used as-is, so user extra arguments reach the command.
        var custom = claude
        custom.arguments += ["--model", "opus 4"]
        let specCustom = try backend.attachCommand(for: session, agent: custom, conversation: .none)
        expectEqual(
            specCustom.command,
            "'/Users/me/.local/bin/claude' '--model' 'opus 4'",
            "extra arguments passed through, quoted")
    }

    test("launch: exact conversation args per agent") {
        let claude = AgentDefinition.builtIns[0]
        let codex = AgentDefinition.builtIns[1]
        let opencode = AgentDefinition.builtIns[2]
        let shell = AgentDefinition.builtIns[3]
        let id = "0b9c7c3e-0000-4000-8000-000000000001"
        expectEqual(claude.launchArguments(skippingPermissions: false), [], "no conversation")
        expectEqual(claude.launchArguments(skippingPermissions: false, conversation: .start(id)),
                    ["--session-id", id], "claude starts under our id")
        expectEqual(claude.launchArguments(skippingPermissions: true, conversation: .resume(id)),
                    ["--dangerously-skip-permissions", "--resume", id], "claude resumes exactly")
        expectEqual(codex.launchArguments(skippingPermissions: true, conversation: .resume(id)),
                    codex.arguments + ["--dangerously-bypass-approvals-and-sandbox", "resume", id],
                    "codex: config, then danger flag, then resume subcommand")
        expectEqual(codex.launchArguments(skippingPermissions: false, conversation: .start(id)), codex.arguments,
                    "codex cannot be told an id up front")
        expectEqual(opencode.launchArguments(skippingPermissions: false, conversation: .resume(id)), [],
                    "opencode never resumes")
        expectEqual(shell.launchArguments(skippingPermissions: false, conversation: .resume(id)), [],
                    "shell never resumes")
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

        try await backend.create(session, agent: AgentDefinition.builtIns[3], conversation: .none) // shell
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
            try await backend.create(session, agent: bogus, conversation: .none)
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
