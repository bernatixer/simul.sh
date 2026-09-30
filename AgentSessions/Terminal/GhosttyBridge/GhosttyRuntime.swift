import AppKit
import Foundation
import Ghostty

/// One-time libghostty application runtime: init, config, app handle,
/// clipboard plumbing, wakeups, and appearance tracking.
///
/// This is the only file that creates a `ghostty_app_t`. Everything else
/// talks to `GhosttySurfaceView`.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var appearanceObserver: Any?

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

        runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { runtime.tick() }
            },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyRuntime.shared.handleAction(app, target: target, action: action)
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
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { view.surfaceDidClose(processAlive: processAlive) }
            }
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            Log.terminal.error("ghostty_app_new failed")
            ghostty_config_free(config)
            return
        }
        self.app = app
        ghostty_config_free(config)

        ghostty_app_set_focus(app, NSApp.isActive)
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
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.applyColorScheme(NSApp.effectiveAppearance)
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Actions

    /// Handles apprt actions. We deliberately implement almost none: this
    /// app is a plain host, not a terminal emulator product. Returning false
    /// lets libghostty know the action was not handled.
    private func handleAction(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                if let view = surfaceView(surface) {
                    view.setCursorShape(action.action.mouse_shape)
                }
            }
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                if let view = surfaceView(surface) {
                    view.setCursorVisibility(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
                }
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                let view = surfaceView(surface)
                DispatchQueue.main.async {
                    view?.ringBell()
                }
            }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                let view = surfaceView(surface)
                let state = action.action.progress_report.state
                let percent = action.action.progress_report.progress
                DispatchQueue.main.async {
                    view?.reportProgress(state: state, percent: percent)
                }
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            // Scrollback changed → the terminal produced output. Cheap,
            // provider-neutral unread signal.
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                let view = surfaceView(surface)
                DispatchQueue.main.async {
                    view?.contentChanged()
                }
            }
            return true
        default:
            return false
        }
    }

    private func surfaceView(_ surface: ghostty_surface_t) -> GhosttySurfaceView? {
        guard let userdata = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
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
        GhosttySurfaceView.enumerate { view in
            view.setColorScheme(scheme)
        }
    }

    // MARK: - Resources

    /// libghostty finds terminfo/shell-integration/themes through the
    /// GHOSTTY_RESOURCES_DIR environment variable.
    private func setResourcesDir() {
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] != nil { return }

        let candidates: [URL?] = [
            // Bundled app: .../AgentSessions.app/Contents/Resources/share/ghostty
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

    fileprivate static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface, location == GHOSTTY_CLIPBOARD_STANDARD else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        let pasteboard = NSPasteboard.general
        var contents: [(mime: String, data: Data)] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<mimesLen {
                guard let ptr = mimes[i] else { continue }
                let mime = String(cString: ptr)
                guard !seen.contains(mime) else { continue }
                seen.insert(mime)
                let data = pasteboardData(pasteboard, forMime: mime)
                contents.append((mime, data))
            }
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

    fileprivate static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // v1 has no clipboard permission UI; deny anything requiring
        // confirmation (OSC 52 / Kitty clipboard reads). Standard paste via
        // ⌘V does not go through this path.
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface else { return }
        ghostty_surface_deny_clipboard_request(surface, state)
    }

    fileprivate static func writeClipboard(
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

    private static func pasteboardData(
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

        var complete = ghostty_clipboard_complete_s(
            contents: cContents,
            contents_len: cContents.count,
            available: availableCStrings,
            available_len: available.count,
            confirmed: true,
            remember: false
        )
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
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
        case "public.tiff": self = .tiff
        case "public.png": self = .png
        default: return nil
        }
    }

    var mimeType: String? {
        switch self {
        case .string: return "text/plain"
        case .html: return "text/html"
        case .rtf: return "text/rtf"
        case .tiff: return "public.tiff"
        case .png: return "public/png"
        default: return nil
        }
    }
}
