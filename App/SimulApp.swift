import AppKit
import SwiftUI

@main
struct SimulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let model: AppModel

    init() {
        Paths.migrateLegacyData()
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [Any] = []

    /// Set by AppModel.init; used by the quit guard.
    static weak var appModel: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything spawns: agents must not inherit whatever launched
        // the app (e.g. another Claude session's markers).
        LaunchEnvironment.scrub()
        // Always dark. Set before the Ghostty runtime starts so it picks up
        // the dark color scheme once (the appearance never changes after).
        NSApp.appearance = NSAppearance(named: .darkAqua)
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
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stripWindowChrome() } },
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stripWindowChrome() } },
            center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stripWindowChrome() } },
        ]
    }

    /// Agent processes are direct children of the app now: confirm before
    /// quitting while sessions are live.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.appModel,
              !model.backend.processesOutliveApp,
              model.liveSessionCount > 0
        else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Simul?"
        alert.informativeText = "\(model.liveSessionCount) running session\(model.liveSessionCount == 1 ? "" : "s") will be terminated. Conversations are kept by the agents themselves."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The session window, registered by ContentView (MainWindowMarker).
    /// Only it gets restyled: Settings, About, open panels and alerts keep
    /// their standard chrome, and can't feed wrong title-bar metrics.
    static weak var mainWindow: NSWindow?

    private func stripWindowChrome() {
        retargetCloseShortcut()
        if let window = Self.mainWindow {
            Self.configureMainWindow(window)
        }
    }

    /// hiddenTitleBar alone leaves a toolbar strip: remove it outright, draw
    /// under the transparent title bar, and keep the window non-restorable
    /// for deterministic launches.
    static func configureMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.backgroundColor = GhosttyRuntime.shared.backgroundColor
        updateTitleBarMetrics(for: window)
    }

    /// Simul's title-bar buttons sit right of the traffic lights, centered
    /// on them; in full screen the lights are hidden, so they move left.
    private static func updateTitleBarMetrics(for window: NSWindow) {
        guard let model = Self.appModel, let content = window.contentView else { return }
        if window.styleMask.contains(.fullScreen) {
            // No traffic lights, but on notched displays the window reaches
            // under the camera housing: start below that band.
            let notch = max(content.safeAreaInsets.top, window.screen?.safeAreaInsets.top ?? 0)
            model.titleBar = TitleBarMetrics(leading: 12, centerY: notch + 14, topInset: notch)
            return
        }
        guard let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview else { return }
        let frame = superview.convert(zoom.frame, to: content)
        let centerY = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
        model.titleBar = TitleBarMetrics(leading: frame.maxX + 14, centerY: centerY.rounded())
    }

    /// ⌘W closes the selected session instead of the window: retarget the
    /// built-in File ▸ Close item (SwiftUI has no placement for it on this
    /// SDK).
    private func retargetCloseShortcut() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        for item in fileMenu.items where item.keyEquivalent.lowercased() == "w" {
            item.title = "Close Session"
            item.target = self
            item.action = #selector(closeSelectedSession)
        }
    }

    @objc private func closeSelectedSession() {
        Self.appModel?.requestCloseSelected()
    }
}
