import AppKit
import Foundation
import Ghostty

/// An NSView hosting one libghostty terminal surface.
///
/// The view owns: keyboard input (including IME), mouse, scroll, resize,
/// focus, and clipboard actions. Ported and slimmed down from Ghostty's own
/// SurfaceView_AppKit.swift.
final class GhosttySurfaceView: NSView {
    /// nonisolated(unsafe) only so the nonisolated `deinit` can free it:
    /// it is otherwise read and written on the main actor exclusively, and
    /// deinit has sole ownership.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    /// The session this surface presents (set by the host).
    var sessionID: UUID?

    /// Bell / progress events, attributed to the session.
    var onEvent: ((UUID, SurfaceEvent) -> Void)?

    var onChildExited: (() -> Void)?

    private var focused = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var leadSurrogate: LeadSurrogate?
    private var suppressNextLeftMouseUp = false
    private var isMouseInside = false
    private var currentCursor: NSCursor?
    private var isVisibleSurface = false
    /// Over a URL while the program has the mouse (Claude opens links on a
    /// plain click, so Ghostty never reports a link hover).
    private var isOverLink = false
    private var contentSize: CGSize = CGSize(width: 800, height: 600)
    private var cellSize = NSSize(width: 8, height: 16)

    override var acceptsFirstResponder: Bool { true }

    init(spec: ProcessSpec) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        guard let app = GhosttyRuntime.shared.app else {
            Log.terminal.error("no ghostty app; cannot create surface")
            return
        }

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 0 // inherit app config
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let envKeys = Array(spec.environment.keys)
        let envValues = Array(spec.environment.values)

        // The config and all C strings are only valid inside this closure.
        spec.command.withCString { cCommand in
            (spec.workingDirectory ?? "").withCString { cWorkingDir in
                // Manual C-string arrays (strdup/free) — the AppKit example's
                // withCStrings helper is not public API.
                let keyCStrings = envKeys.map { strdup($0) }
                let valueCStrings = envValues.map { strdup($0) }
                defer {
                    keyCStrings.forEach { free($0) }
                    valueCStrings.forEach { free($0) }
                }

                var envVars = [ghostty_env_var_s]()
                envVars.reserveCapacity(envKeys.count)
                for i in 0..<envKeys.count {
                    envVars.append(ghostty_env_var_s(key: keyCStrings[i], value: valueCStrings[i]))
                }
                let envVarCount = envVars.count
                return envVars.withUnsafeMutableBufferPointer { buffer in
                    config.command = cCommand
                    config.working_directory = cWorkingDir
                    config.env_vars = buffer.baseAddress
                    config.env_var_count = envVarCount
                    surface = ghostty_surface_new(app, &config)
                }
            }
        }

        guard surface != nil else {
            Log.terminal.error("ghostty_surface_new failed")
            return
        }

        updateTrackingAreas()
        applyBackingProperties()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        // `isolated deinit` needs macOS 15.4; free directly instead.
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Public control surface

    /// Frees the surface (and its PTY) now rather than whenever the last
    /// reference drops: callbacks already queued for this view then hit the
    /// `surface == nil` guards instead of a freed surface.
    func destroy() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// Hidden surfaces stop rendering; only the selected one draws.
    func setVisible(_ visible: Bool) {
        if isVisibleSurface != visible {
            isVisibleSurface = visible
            hoveredCell = nil
            isOverLink = false
            window?.invalidateCursorRects(for: self)
        }
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Cell size arrives in backing pixels; IME placement needs points.
    func setCellSize(width: UInt32, height: UInt32) {
        cellSize = convertFromBacking(NSSize(width: Double(width), height: Double(height)))
    }

    func hasProcessExited() -> Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingProperties()
        if window != nil, focused {
            setFocus(true)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            setFocus(false)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        hideImagePreview()
        setFocus(false)
        return super.resignFirstResponder()
    }

    private func setFocus(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        guard let surface else { return }
        ghostty_surface_set_focus(surface, value)
    }

    // MARK: - Resize / scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: CGSize) {
        guard let surface else { return }
        let scaled = convertToBacking(size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    private func applyBackingProperties() {
        guard let surface else { return }
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        let fbFrame = convertToBacking(frame)
        guard frame.width > 0, frame.height > 0 else { return }
        let xScale = fbFrame.size.width / frame.size.width
        let yScale = fbFrame.size.height / frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        let scaled = convertToBacking(contentSize)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        hideImagePreview()
        if let sessionID { onEvent?(sessionID, .input) }
        // Ctrl+V: agents read the clipboard's image themselves; keep a copy
        // to preview. The key still goes on to the program.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           event.charactersIgnoringModifiers == "v", let folder = pastesFolder,
           let image = ClipboardPaste.saveImage(from: .general, in: folder) {
            learnImageNumber(for: image)
        }
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Translate mods (handles configs like option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(
            surface, GhosttyInput.mods(event.modifierFlags))
        var translationMods = event.modifierFlags
        let ghosttyFlags = GhosttyInput.modifierFlags(fromMods: translationModsGhostty)
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if ghosttyFlags.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // Reuse the original event when mods match (important for IME).
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key_ev.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        }
        return ghostty_surface_key(surface, key_ev)
    }

    /// Committed text (IME, dictation) is sent as synthetic key events so
    /// programs see it as typed input, never as a paste.
    private func committedTextAction(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = 0
        key_ev.text = nil
        key_ev.composing = false
        key_ev.mods = GHOSTTY_MODS_NONE
        key_ev.consumed_mods = GHOSTTY_MODS_NONE
        key_ev.unshifted_codepoint = 0
        return text.withCString { ptr in
            key_ev.text = ptr
            return ghostty_surface_key(surface, key_ev)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    /// Command-modified keys must reach the menu (⌘1…⌘9, ⌘C, ⌘V, ...), so
    /// we do not consume them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        false
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseDown(with event: NSEvent) {
        hideImagePreview()
        // Focus on first click even when the window is not key.
        if !focused, window?.isKeyWindow == false {
            suppressNextLeftMouseUp = true
        }
        guard let surface else { return }
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        guard let surface else { return }
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS,
            GhosttyInput.mouseButton(fromNSEventButtonNumber: event.buttonNumber),
            GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE,
            GhosttyInput.mouseButton(fromNSEventButtonNumber: event.buttonNumber),
            GhosttyInput.mods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        hideImagePreview()
        hoveredCell = nil
        setOverLink(false)
        super.mouseExited(with: event)
        if let cursor = currentCursor, isVisibleSurface, window?.isKeyWindow == true {
            cursor.set()
        }
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface, Double(pos.x), Double(frame.height - pos.y), GhosttyInput.mods(event.modifierFlags))
        updateHover(at: pos)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        hideImagePreview()
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }
        let mods = GhosttyInput.scrollMods(
            precision: precision, momentumPhase: event.momentumPhase)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        guard window != nil else { return }
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: setCursor(.arrow)
        case GHOSTTY_MOUSE_SHAPE_TEXT: setCursor(.iBeam)
        case GHOSTTY_MOUSE_SHAPE_GRAB: setCursor(.openHand)
        case GHOSTTY_MOUSE_SHAPE_GRABBING: setCursor(.closedHand)
        case GHOSTTY_MOUSE_SHAPE_POINTER: setCursor(.pointingHand)
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: setCursor(.operationNotAllowed)
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: setCursor(.crosshair)
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: setCursor(.contextualMenu)
        default: setCursor(.arrow)
        }
    }

    private func setCursor(_ cursor: NSCursor) {
        guard cursor != currentCursor else { return }
        currentCursor = cursor
        applyCursor()
    }

    private func setOverLink(_ over: Bool) {
        guard over != isOverLink else { return }
        isOverLink = over
        applyCursor()
    }

    private var displayedCursor: NSCursor {
        isOverLink ? .pointingHand : currentCursor ?? .iBeam
    }

    private func applyCursor() {
        window?.invalidateCursorRects(for: self)
        if isMouseInside, isVisibleSurface, window?.isKeyWindow == true {
            displayedCursor.set()
        }
    }

    /// A cursor rect, not just `set()`: AppKit resets a set cursor on the
    /// next mouse move. Hidden sessions are stacked under the active one,
    /// so only the visible surface claims the cursor.
    override func resetCursorRects() {
        guard isVisibleSurface else { return }
        addCursorRect(bounds, cursor: displayedCursor)
    }

    // MARK: - Clipboard actions (menu / responder chain)

    @IBAction func copy(_ sender: Any?) {
        performBinding("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        performBinding("paste_from_clipboard")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        performBinding("select_all")
    }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
            Log.terminal.warning("terminal action failed: \(action, privacy: .public)")
        }
    }

    // MARK: - NSTextInputClient (IME)

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                markedText.string.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Events (from GhosttyRuntime)

    /// What a paste types: copied files as paths, text as is, an image saved
    /// for this session and pasted as its path (see ClipboardPaste).
    func pasteText(from pasteboard: NSPasteboard) -> String {
        guard let folder = pastesFolder else { return pasteboard.string(forType: .string) ?? "" }
        let paste = ClipboardPaste.text(from: pasteboard, savingImagesIn: folder)
        if let image = paste.savedImage { learnImageNumber(for: image) }
        return paste.text
    }

    // MARK: - Pasted image previews

    /// Images pasted here, by the number the agent shows for them
    /// ("[Image #N]"). Hovering that text shows the image.
    private var pastedImages: [Int: URL] = [:]
    private var imagePreview: (number: Int, popover: NSPopover)?
    private var hoveredCell: (column: Int, row: Int)?

    private var pastesFolder: URL? {
        sessionID.map { Paths.pastedImages.appendingPathComponent($0.uuidString, isDirectory: true) }
    }

    /// Finds the "[Image #N]" the agent shows for a just-pasted image: the
    /// highest number that shows up more often than before the paste. Codex
    /// restarts at #1 for each message, so a number can repeat; the newest
    /// paste wins. The file is kept either way: agents may read it only when
    /// the message is sent.
    // ponytail: two pastes within ~1s can swap numbers; match by order if needed.
    private func learnImageNumber(for url: URL) {
        let before = ImageTokens.numbers(in: viewportText())
        Task { [weak self] in
            for delay in [0.3, 0.5, 1.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                if let number = ImageTokens.newNumber(before: before, after: ImageTokens.numbers(in: self.viewportText())) {
                    self.pastedImages[number] = url
                    return
                }
            }
        }
    }

    /// Shows the image under the pointer when it rests on a known
    /// "[Image #N]". Reads one line, only when the pointer changes cell.
    private func updateHover(at pos: NSPoint) {
        guard isVisibleSurface, let surface else { return }
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? 2
        let cellWidth = Double(size.cell_width_px) / scale
        let cellHeight = Double(size.cell_height_px) / scale
        guard cellWidth > 0, cellHeight > 0, size.columns > 0 else { return }
        // ponytail: Ghostty's default window-padding (2pt); read the config
        // if someone changes it and hovering drifts.
        let padding = 2.0
        let column = Int(floor((pos.x - padding) / cellWidth))
        let row = Int(floor((frame.height - pos.y - padding) / cellHeight))
        if let cell = hoveredCell, cell == (column, row) { return }
        hoveredCell = (column, row)
        guard column >= 0, row >= 0, row < Int(size.rows) else {
            setOverLink(false)
            return hideImagePreview()
        }

        let line = readViewport(rows: UInt32(row)...UInt32(row), lastColumn: UInt32(size.columns) - 1)
        // OSC 8 links ("Docs") or plain URLs in the text.
        // ponytail: a plain URL wrapped onto the next line only gets the
        // hand on its first line.
        setOverLink(ghostty_surface_mouse_captured(surface)
            && (ghostty_surface_hyperlink_at(surface, UInt16(clamping: column), UInt32(row))
                || TerminalLinks.isURL(atColumn: column, in: line)))
        guard !pastedImages.isEmpty, let token = ImageTokens.token(atColumn: column, in: line),
              let url = pastedImages[token.number] else { return hideImagePreview() }
        guard imagePreview?.number != token.number else { return }
        let anchor = NSRect(
            x: padding + Double(token.columns.lowerBound) * cellWidth,
            y: frame.height - padding - Double(row + 1) * cellHeight,
            width: Double(token.columns.count) * cellWidth,
            height: cellHeight)
        showImagePreview(token.number, url: url, at: anchor)
    }

    private func showImagePreview(_ number: Int, url: URL, at anchor: NSRect) {
        hideImagePreview()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        imagePreview = (number, popover)
        Task { [weak self] in
            // Decoded at preview size, off the main thread; never kept.
            let image = await Task.detached(priority: .userInitiated) {
                ClipboardPaste.thumbnail(of: url, maxPixels: 640)
            }.value
            guard let self, let image, self.imagePreview?.popover === popover else { return }
            let scale = self.window?.backingScaleFactor ?? 2
            let fit = min(1, 320 / (Double(image.width) / scale), 240 / (Double(image.height) / scale))
            let size = NSSize(width: Double(image.width) / scale * fit, height: Double(image.height) / scale * fit)
            let view = NSImageView(image: NSImage(cgImage: image, size: size))
            view.frame = NSRect(origin: .zero, size: size)
            view.setAccessibilityLabel("Image \(number)")
            let controller = NSViewController()
            controller.view = view
            popover.contentViewController = controller
            popover.contentSize = size
            popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        }
    }

    private func hideImagePreview() {
        imagePreview?.popover.close()
        imagePreview = nil
    }

    private func viewportText() -> String {
        guard let surface else { return "" }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return "" }
        return readViewport(rows: 0...UInt32(size.rows - 1), lastColumn: UInt32(size.columns - 1))
    }

    private func readViewport(rows: ClosedRange<UInt32>, lastColumn: UInt32) -> String {
        guard let surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: rows.lowerBound),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: lastColumn, y: rows.upperBound),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    func titleChanged(_ title: String) {
        guard let sessionID else { return }
        onEvent?(sessionID, .title(title))
    }

    func requestAttention(message: String?) {
        guard let sessionID else { return }
        onEvent?(sessionID, .attention(message: message))
    }

    func reportProgress(state: ghostty_action_progress_report_state_e, percent: Int8) {
        guard let sessionID else { return }
        switch state {
        case GHOSTTY_PROGRESS_STATE_REMOVE, GHOSTTY_PROGRESS_STATE_ERROR:
            onEvent?(sessionID, .progress(active: false, percent: nil))
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
            onEvent?(sessionID, .progress(active: true, percent: nil))
        default:
            let p = percent >= 0 && percent <= 100 ? Int(percent) : nil
            onEvent?(sessionID, .progress(active: true, percent: p))
        }
    }

    func surfaceDidClose(processAlive: Bool) {
        onChildExited?()
    }
}

// AppKit only calls NSTextInputClient on the main thread.
extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as NSString:
            if let lead = LeadSurrogate(v) {
                leadSurrogate = lead
                chars = ""
            } else if let trail = TrailSurrogate(v) {
                chars = leadSurrogate?.encode(trail: trail) ?? ""
                leadSurrogate = nil
            } else {
                chars = v as String
                leadSurrogate = nil
            }
        default:
            return
        }

        unmarkText()

        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty {
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars)
        }
    }

    /// Swallow unimplemented IME commands to avoid NSBeep.
    override func doCommand(by selector: Selector) {}
}

private struct LeadSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let char = text.character(at: 0)
        guard UTF16.isLeadSurrogate(char) else { return nil }
        self.char = char
    }

    func encode(trail: TrailSurrogate) -> String {
        String(decoding: [char, trail.char], as: UTF16.self)
    }
}

private struct TrailSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let char = text.character(at: 0)
        guard UTF16.isTrailSurrogate(char) else { return nil }
        self.char = char
    }
}
