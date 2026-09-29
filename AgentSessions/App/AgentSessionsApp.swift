import AppKit
import SwiftUI

@main
struct AgentSessionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model: AppModel

    init() {
        let resolver = ExecutableResolver()
        let backend = TmuxSessionBackend(resolver: resolver)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        GhosttyRuntime.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    /// hiddenTitleBar alone is not enough: NavigationSplitView installs an
    /// NSToolbar that still renders a navbar strip. Remove it outright.
    private func stripWindowChrome() {
        for window in NSApplication.shared.windows {
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

            Sessions are owned by tmux and survive app restarts.
            """)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420, height: 160)
    }
}
