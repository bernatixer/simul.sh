import AppKit
import SwiftUI

/// Simul's own right-click menu: the app's colors and icons instead of the
/// system menu. Right-click (or ⌃-click) opens it at the pointer; clicking
/// an item, clicking elsewhere or Escape closes it.
extension View {
    func simulContextMenu<Menu: View>(@ViewBuilder _ menu: @escaping () -> Menu) -> some View {
        modifier(SimulContextMenu(menu: menu))
    }
}

private struct SimulContextMenu<Menu: View>: ViewModifier {
    @Environment(AppModel.self) private var model
    let menu: () -> Menu

    func body(content: Content) -> some View {
        content.overlay {
            RightClickCatcher {
                SimulMenuPanel.show(
                    VStack(alignment: .leading, spacing: 1) { menu() }
                        .padding(5)
                        .frame(minWidth: 180, alignment: .leading)
                        .fixedSize()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.sidebar)
                                .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .environment(model)
                )
            }
        }
    }
}

/// One row: icon, title; amber for actions that remove a session from view.
struct SimulMenuItem: View {
    @Environment(\.simulMenuDismiss) private var dismiss
    let title: String
    let icon: String
    var caution = false
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, icon: String, caution: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.caution = caution
        self.action = action
    }

    var body: some View {
        Button {
            dismiss() // close first, so a rename field or alert gets the main window
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .frame(width: 16)
                    .foregroundStyle(caution ? Color.orange : hovered ? Color.primary : Color.secondary)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(caution ? Color.orange : Color.primary)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? (caution ? Color.orange.opacity(0.15) : Color.white.opacity(0.10)) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct SimulMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

private struct SimulMenuDismissKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var simulMenuDismiss: @MainActor () -> Void {
        get { self[SimulMenuDismissKey.self] }
        set { self[SimulMenuDismissKey.self] = newValue }
    }
}

/// Borderless key panel holding the open menu. Closes when it loses key
/// (a click anywhere else) or on Escape.
private final class SimulMenuPanel: NSPanel {
    private static var current: SimulMenuPanel?

    override var canBecomeKey: Bool { true }

    static func show(_ content: some View) {
        current?.close()
        let panel = SimulMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        // An item hands key back to the window it was opened from before
        // acting, so a rename field it opens can take focus.
        let parent = NSApp.keyWindow
        let host = NSHostingView(rootView: content.environment(\.simulMenuDismiss) { [weak panel] in
            panel?.close()
            parent?.makeKey()
        })
        panel.contentView = host

        // Top-left at the pointer, kept on screen (opens upward near the bottom).
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        if origin.y < screen.minY { origin.y = mouse.y }
        origin.x = min(origin.x, screen.maxX - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        current = panel
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        super.close()
        if Self.current === self { Self.current = nil }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { close() } else { super.sendEvent(event) }
    }
}

/// Transparent overlay that takes only right-clicks and ⌃-clicks; every
/// other click passes through to the SwiftUI view underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    final class CatcherView: NSView {
        var onRightClick: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let rightClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return rightClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { onRightClick() }
        override func mouseDown(with event: NSEvent) { onRightClick() }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }
}
