import AppKit
import Foundation
import Ghostty

/// One-time libghostty application runtime: init, config, app handle,
/// clipboard plumbing, wakeups, and appearance tracking.
///
/// This is the only file that creates a `ghostty_app_t`. Everything else
/// talks to `GhosttySurfaceView`.
///
/// Threading: libghostty invokes runtime callbacks from `ghostty_app_tick`,
/// i.e. on the main thread — except `wakeup_cb`, which can come from any
/// thread. The C callbacks are `nonisolated` and enter the main actor via
/// `onMain` / `onMainSync`, which check rather than assume.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    /// The terminal background from the user's Ghostty config (or Ghostty's
    /// default). The whole window is themed from it so app chrome and
    /// terminal read as one surface.
    private(set) var backgroundColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1)

    private var runtimeConfig = ghostty_runtime_config_s()

    /// Must be called once on the main thread before any surface is created.
    func start() {
        guard app == nil else { return }

        setResourcesDir()
        guard ghostty_init(0, nil) == 0 else {
            Log.terminal.error("ghostty_init failed")
            return
        }

        // Honor the user's Ghostty config if present, then finalize.
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var background = ghostty_config_color_s()
        let key = "background"
        if ghostty_config_get(config, &background, key, UInt(key.utf8.count)) {
            backgroundColor = NSColor(
                srgbRed: CGFloat(background.r) / 255,
                green: CGFloat(background.g) / 255,
                blue: CGFloat(background.b) / 255,
                alpha: 1)
        }

        runtimeConfig = Self.makeRuntimeConfig(userdata: Unmanaged.passUnretained(self).toOpaque())

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            Log.terminal.error("ghostty_app_new failed")
            ghostty_config_free(config)
            return
        }
        self.app = app
        ghostty_config_free(config)

        ghostty_app_set_focus(app, NSApp.isActive)
        // The app forces dark appearance before start() (AppDelegate), so
        // this is applied once; no appearance tracking needed.
        applyColorScheme(NSApp.effectiveAppearance)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    /// Built outside the main actor on purpose: closures written in a
    /// @MainActor method inherit that isolation, and Swift 6 then traps
    /// when libghostty calls them from another thread (wakeup_cb does).
    nonisolated private static func makeRuntimeConfig(
        userdata: UnsafeMutableRawPointer
    ) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                // Always async: ticking from inside a callback would re-enter.
                DispatchQueue.main.async { MainActor.assumeIsolated { runtime.tick() } }
            },
            action_cb: { _, target, action in
                GhosttyRuntime.handleAction(target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(
                    userdata, location: location, state: state,
                    mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(
                    userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(
                    userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata else { return }
                let view = GhosttyRuntime.surfaceView(userdata: userdata)
                // Async: the surface may be freed in response.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { view.surfaceDidClose(processAlive: processAlive) }
                }
            }
        )
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Main-actor entry from C callbacks

    /// Runs `body` on the main actor: inline when already there (the normal
    /// case), otherwise hopped asynchronously.
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    /// For callbacks that must answer synchronously: runs `body` when on the
    /// main thread, otherwise logs and returns `fallback`.
    nonisolated private static func onMainSync<T: Sendable>(_ fallback: T, _ body: @MainActor () -> T) -> T {
        guard Thread.isMainThread else {
            Log.terminal.error("ghostty callback off the main thread; ignored")
            return fallback
        }
        return MainActor.assumeIsolated(body)
    }

    nonisolated private static func surfaceView(userdata: UnsafeMutableRawPointer) -> GhosttySurfaceView {
        Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: - Actions

    /// Handles apprt actions. We deliberately implement almost none: this
    /// app is a plain host, not a terminal emulator product. Returning false
    /// lets libghostty know the action was not handled.
    nonisolated private static func handleAction(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        var view: GhosttySurfaceView?
        if target.tag == GHOSTTY_TARGET_SURFACE,
           let surface = target.target.surface,
           let userdata = ghostty_surface_userdata(surface) {
            view = surfaceView(userdata: userdata)
        }
        let surfaceView = view

        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            onMain { surfaceView?.setCursorShape(shape) }
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            break // rely on the OS cursor; hiding is rarely desired in a host
        case GHOSTTY_ACTION_CELL_SIZE:
            let width = action.action.cell_size.width
            let height = action.action.cell_size.height
            onMain { surfaceView?.setCellSize(width: width, height: height) }
        case GHOSTTY_ACTION_RING_BELL,
             GHOSTTY_ACTION_COMMAND_FINISHED: // shell integration
            onMain { surfaceView?.requestAttention(message: nil) }
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION: // OSC 9 / 777 (Claude, Codex)
            // The C strings are only valid during this call: copy them now.
            let notification = action.action.desktop_notification
            let message = [notification.body, notification.title]
                .compactMap { $0.map { String(cString: $0) } }
                .first { !$0.isEmpty }
            onMain { surfaceView?.requestAttention(message: message) }
        case GHOSTTY_ACTION_SET_TITLE:
            // The C string is only valid during this call: copy it now.
            guard let cTitle = action.action.set_title.title else { return true }
            let title = String(cString: cTitle)
            onMain { surfaceView?.titleChanged(title) }
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let state = action.action.progress_report.state
            let percent = action.action.progress_report.progress
            onMain { surfaceView?.reportProgress(state: state, percent: percent) }
        default:
            return false
        }
        return true
    }

    // MARK: - Appearance

    @objc private func appDidBecomeActive() {
        if let app { ghostty_app_set_focus(app, true) }
    }

    @objc private func appDidResignActive() {
        if let app { ghostty_app_set_focus(app, false) }
    }

    private func applyColorScheme(_ appearance: NSAppearance) {
        guard let app else { return }
        let scheme: ghostty_color_scheme_e = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, scheme)
    }

    // MARK: - Resources

    /// libghostty finds terminfo/shell-integration/themes through the
    /// GHOSTTY_RESOURCES_DIR environment variable.
    private func setResourcesDir() {
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] != nil { return }

        let candidates: [URL?] = [
            // Bundled app: .../Simul.app/Contents/Resources/share/ghostty
            Bundle.main.resourceURL?.appendingPathComponent("share/ghostty"),
            // Unbundled dev binary sitting next to a share/ directory.
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("share/ghostty"),
        ]
        for candidate in candidates {
            // Resources dir is .../share/ghostty; the terminfo bundle is its
            // sibling .../share/terminfo (see Ghostty's Exec.zig).
            guard let candidate,
                  FileManager.default.fileExists(
                    atPath: candidate.deletingLastPathComponent()
                        .appendingPathComponent("terminfo/78/xterm-ghostty").path)
            else { continue }
            setenv("GHOSTTY_RESOURCES_DIR", candidate.path, 0)
            Log.terminal.info("using ghostty resources at \(candidate.path, privacy: .public)")
            return
        }
        Log.terminal.warning("no ghostty resources dir found; falling back to TERM=xterm-256color")
    }

    // MARK: - Clipboard callbacks (static C callbacks)

    nonisolated fileprivate static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        let view = surfaceView(userdata: userdata)
        var requested: [String] = []
        if let mimes {
            for i in 0..<mimesLen {
                guard let ptr = mimes[i] else { continue }
                let mime = String(cString: ptr)
                if !requested.contains(mime) { requested.append(mime) }
            }
        }
        // `state` is only valid for this call, so complete synchronously.
        // onMainSync runs inline, so the pointer never actually crosses threads.
        nonisolated(unsafe) let state = state
        return onMainSync(GHOSTTY_CLIPBOARD_READ_UNSUPPORTED) {
            guard let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            let pasteboard = NSPasteboard.general
            // ponytail: OSC 52 reads also land here (and are then denied), so
            // a program reading an image clipboard would save a stray paste.
            let contents = requested.map { mime in
                (mime: mime, data: mime == "text/plain"
                    ? Data(view.pasteText(from: pasteboard).utf8)
                    : pasteboardData(pasteboard, forMime: mime))
            }
            if contents.isEmpty && !list {
                return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
            }
            completeClipboardRequest(
                surface,
                contents: contents,
                available: list ? pasteboard.availableMimes() : [],
                state: state
            )
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    nonisolated fileprivate static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // v1 has no clipboard permission UI; deny anything requiring
        // confirmation (OSC 52 / Kitty clipboard reads). Standard paste via
        // ⌘V does not go through this path.
        guard let userdata else { return }
        let view = surfaceView(userdata: userdata)
        nonisolated(unsafe) let state = state // used inline, see readClipboard
        onMainSync(()) {
            guard let surface = view.surface else { return }
            ghostty_surface_deny_clipboard_request(surface, state)
        }
    }

    /// Touches only the pasteboard (thread-safe), never view state.
    nonisolated fileprivate static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard !confirm, location == GHOSTTY_CLIPBOARD_STANDARD,
              let content, len > 0 else { return }
        let pasteboard = NSPasteboard.general
        var types: [NSPasteboard.PasteboardType] = []
        var payloads: [NSPasteboard.PasteboardType: Data] = [:]
        for i in 0..<len {
            let entry = content[i]
            guard let mimePtr = entry.mime else { continue }
            let mime = String(cString: mimePtr)
            guard let type = NSPasteboard.PasteboardType(mimeType: mime) else { continue }
            types.append(type)
            payloads[type] = Data(bytes: entry.data, count: entry.len)
        }
        guard !types.isEmpty else { return }
        pasteboard.declareTypes(types, owner: nil)
        for (type, data) in payloads {
            pasteboard.setData(data, forType: type)
        }
    }

    nonisolated private static func pasteboardData(
        _ pasteboard: NSPasteboard,
        forMime mime: String
    ) -> Data {
        guard let type = NSPasteboard.PasteboardType(mimeType: mime),
              let data = pasteboard.data(forType: type) else { return Data() }
        return data
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [(mime: String, data: Data)],
        available: [String],
        state: UnsafeMutableRawPointer?
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var cDatas: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            cDatas.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            cStrings.append(mime)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            cDatas.append(buf)
            entry.data.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    buf.copyMemory(from: base, byteCount: src.count)
                }
            }
            cContents.append(ghostty_clipboard_content_s(mime: mime, data: buf.assumingMemoryBound(to: CChar.self), len: entry.data.count))
        }

        let availableCStrings: [UnsafePointer<CChar>?] = available.map {
            guard let dup = strdup($0) else { return nil }
            return UnsafePointer(dup)
        }
        defer { availableCStrings.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }

        // Both arrays must stay pinned for the whole C call, not just the
        // struct initializer.
        cContents.withUnsafeBufferPointer { contentsBuf in
            availableCStrings.withUnsafeBufferPointer { availableBuf in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress,
                    contents_len: contentsBuf.count,
                    available: availableBuf.baseAddress,
                    available_len: availableBuf.count,
                    confirmed: true,
                    remember: false
                )
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
}

private extension NSPasteboard {
    func availableMimes() -> [String] {
        types?.compactMap { $0.mimeType }.filter { !$0.isEmpty } ?? []
    }
}

private extension NSPasteboard.PasteboardType {
    /// Minimal MIME mapping used by the clipboard callbacks.
    init?(mimeType: String) {
        switch mimeType {
        case "text/plain": self = .string
        case "text/html": self = .html
        case "text/rtf": self = .rtf
        case "image/tiff": self = .tiff
        case "image/png": self = .png
        default: return nil
        }
    }

    var mimeType: String? {
        switch self {
        case .string: return "text/plain"
        case .html: return "text/html"
        case .rtf: return "text/rtf"
        case .tiff: return "image/tiff"
        case .png: return "image/png"
        default: return nil
        }
    }
}
