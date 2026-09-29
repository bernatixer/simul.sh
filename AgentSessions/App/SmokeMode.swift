import AppKit
import Foundation

/// Automated smoke test mode: `AgentSessions --smoke`
///
/// Creates a shell session, attaches a real libghostty surface to its tmux
/// session, verifies the surface stayed alive, cleans up, and exits with a
/// status code. Exercises the full pipeline without UI interaction.
enum SmokeMode {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--smoke")
    }

    @MainActor
    static func run(model: AppModel) async -> Int32 {
        print("smoke: starting")
        await model.resolver.bootstrap()

        let session = Session(
            title: "Smoke Test",
            workingDirectory: NSHomeDirectory(),
            agentID: AgentDefinition.shellID
        )
        model.sessions.append(session)
        model.selectedSessionID = session.id

        print("smoke: launching session")
        await model.launch(session)

        if let error = model.launchErrors[session.id] {
            print("smoke: FAIL launch error: \(error)")
            return 1
        }
        guard model.isRunning(session) else {
            print("smoke: FAIL session not running after launch")
            return 1
        }

        // Give the surface time to spawn, attach, and render.
        for tick in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            let host = model.hostCenter.host(for: session)
            if host.surfaceView != nil,
               host.surfaceView?.hasProcessExited() == false {
                print("smoke: surface alive after \(tick * 250 + 250)ms")

                // Prove the surface is attached to the right tmux session:
                // there must be a client on as-<uuid> running our attach command.
                let name = TmuxSessionBackend.tmuxName(for: session)
                if let tmux = model.resolver.tmuxPath {
                    let clients = await ProcessRunner.run(
                        tmux, arguments: ["list-clients", "-t", name])
                    let attached = clients.exitCode == 0 && !clients.stdout.isEmpty
                    print("smoke: attach client on \(name): \(attached ? "yes" : "NO")")
                    if !attached {
                        model.deleteMetadata(session)
                        await model.stop(session)
                        return 1
                    }
                }

                model.deleteMetadata(session)
                await model.stop(session)
                print("smoke: OK")
                return 0
            }
        }

        print("smoke: FAIL surface never became alive")
        model.deleteMetadata(session)
        return 1
    }
}
