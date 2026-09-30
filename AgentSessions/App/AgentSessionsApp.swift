import AppKit
import SwiftUI

@main
struct AgentSessionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let model: AppModel

    init() {
        let resolver = ExecutableResolver()
        // Direct-PTY by default: the surface spawns the agent itself (fast,
        // no attach dance). TmuxSessionBackend is kept for an opt-in later.
        let backend: SessionBackend = DirectSessionBackend(resolver: resolver)
        model = AppModel(
            store: SessionStore(),
            backend: backend,
            resolver: resolver
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear { model.start() }
                .task {
                    guard SmokeMode.isEnabled else { return }
                    let status = await SmokeMode.run(model: model)
                    exit(status)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Minimal AppKit delegate: starts the Ghostty runtime before any terminal
/// surface exists, and strips window chrome (no titlebar, no toolbar).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [Any] = []

    /// Set by AppModel.init; used by the quit guard.
    static weak var appModel: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        GhosttyRuntime.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dark appearance by default; users can still override per-app in
        // System Settings. Ghostty surfaces follow via appearance tracking.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        stripWindowChrome()

        // SwiftUI can re-create toolbars as scenes update; reapply on key
        // window changes and full-screen transitions.
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.stripWindowChrome() },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.stripWindowChrome() },
        ]
    }

    /// Agent processes are direct children of the app now: confirm before
    /// quitting while sessions are live.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.appModel,
              model.backend is DirectSessionBackend,
              model.liveSessionCount > 0
        else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Agent Sessions?"
        alert.informativeText = "\(model.liveSessionCount) running session\(model.liveSessionCount == 1 ? "" : "s") will be terminated. Conversations are kept by the agents themselves."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// hiddenTitleBar alone is not enough: NavigationSplitView installs an
    /// NSToolbar that still renders a navbar strip. Remove it outright, and
    /// keep windows non-restorable for deterministic launches.
    private func stripWindowChrome() {
        for window in NSApplication.shared.windows {
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
        }
    }
}

/// Minimal preferences (plan: minimal surface). Terminal appearance comes
/// from ~/.config/ghostty/config; the app itself has almost no settings.
struct SettingsView: View {
    var body: some View {
        Form {
            Text("""
            Terminals are provided by Ghostty and configured through \
            ~/.config/ghostty/config.

            Agent processes run directly in each terminal and live as long \
            as the app is open. Conversations are kept by the agents \
            themselves (e.g. claude --continue, codex resume).
            """)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420, height: 180)
    }
}
