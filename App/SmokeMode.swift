import AppKit
import Foundation
import UserNotifications

/// Automated smoke test mode: `Simul --smoke`
///
/// Creates a shell session, attaches a real libghostty surface to its tmux
/// session, verifies the surface stayed alive, cleans up, and exits with a
/// status code. Exercises the full pipeline without UI interaction.
enum SmokeMode {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--smoke")
    }

    private static func elog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        let url = URL(fileURLWithPath: "/tmp/simul-smoke-status.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((message + "\n").utf8))
        }
    }

    @MainActor
    static func run(model: AppModel) async -> Int32 {
        elog("smoke: starting")
        await model.resolver.bootstrap()
        elog("smoke: bootstrap done, tmux=\(model.resolver.tmuxPath ?? "nil")")

        let session = Session(
            title: "Smoke Test",
            workingDirectory: NSHomeDirectory(),
            agentID: AgentDefinition.shellID
        )
        model.sessions.append(session)
        model.selectedSessionID = session.id

        elog("smoke: launching session")
        await model.launch(session)
        elog("smoke: launch returned, error=\(model.launchErrors[session.id] ?? "none")")

        if let error = model.launchErrors[session.id] {
            elog("smoke: FAIL launch error: \(error)")
            return 1
        }
        guard model.isRunning(session) else {
            elog("smoke: FAIL session not running after launch")
            return 1
        }

        // Give the surface time to spawn, attach, and render.
        for tick in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            let host = model.hostCenter.host(for: session)
            if host.surfaceView != nil,
               host.surfaceView?.hasProcessExited() == false {
                elog("smoke: surface alive after \(tick * 250 + 250)ms")

                // For the tmux backend, prove the surface attached to the
                // right tmux session. (Direct backend: surface-alive suffices.)
                if model.backend is TmuxSessionBackend {
                    let name = TmuxSessionBackend.tmuxName(for: session)
                    if let tmux = model.resolver.tmuxPath {
                        let clients = await ProcessRunner.run(
                            tmux, arguments: ["list-clients", "-t", name])
                        let attached = clients.exitCode == 0 && !clients.stdout.isEmpty
                        elog("smoke: attach client on \(name): \(attached ? "yes" : "NO")")
                        if !attached {
                            model.deleteMetadata(session)
                            await model.stop(session)
                            return 1
                        }
                    }
                }

                if CommandLine.arguments.contains("--notify"), await !checkNotification(model, session, host) {
                    model.deleteMetadata(session)
                    return 1
                }

                model.deleteMetadata(session)
                await model.stop(session)
                elog("smoke: OK")
                return 0
            }
        }

        elog("smoke: FAIL surface never became alive")
        model.deleteMetadata(session)
        return 1
    }

    /// `--smoke --notify`: an agent notification from a session you aren't
    /// viewing posts a macOS notification; viewing the session removes it.
    /// Needs notification permission for Simul.
    @MainActor
    private static func checkNotification(_ model: AppModel, _ session: Session, _ host: GhosttyTerminalHost) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        elog("smoke: notification permission: \(status.rawValue) (2 = authorized)")

        model.selectedSessionID = nil
        elog("smoke: app active: \(NSApp.isActive)")
        // What the OSC 9 handler calls (GhosttyRuntime → surface view).
        host.surfaceView?.requestAttention(message: "Smoke notification")
        try? await Task.sleep(for: .seconds(1))

        let posted = await center.deliveredNotifications().contains { $0.request.identifier == session.id.uuidString }
        elog("smoke: notification delivered: \(posted ? "yes" : "NO")")

        model.select(session)
        try? await Task.sleep(for: .seconds(1))
        let removed = await !center.deliveredNotifications().contains { $0.request.identifier == session.id.uuidString }
        elog("smoke: removed after viewing: \(removed ? "yes" : "NO")")
        return posted && removed
    }
}
