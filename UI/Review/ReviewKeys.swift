import AppKit
import SwiftUI

/// Keyboard review: which key-downs are the review's. Only plain letters, ? and ⌥↓ / ⌥↑ in the
/// main window while it's key with no sheet, and never while a text field is editing or the
/// terminal has the keyboard; the panel's monitor also checks the review is showing.
@MainActor
enum ReviewKeys {
    static let letters: Set<String> = ["j", "k", "n", "p", "v", "c", "?"]
    /// Keys that don't repeat while held (repeats are swallowed).
    static let once: Set<String> = ["v", "c", "?"]

    static func key(for event: NSEvent) -> String? {
        guard let window = event.window, window === AppDelegate.mainWindow, window.isKeyWindow,
              window.attachedSheet == nil else { return nil }
        if window.firstResponder is NSText || window.firstResponder is GhosttySurfaceView { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .option {
            switch event.keyCode {
            case 125: return "⌥↓"
            case 126: return "⌥↑"
            default: return nil
            }
        }
        if flags.isEmpty, event.keyCode == 53 { return "esc" }
        guard flags.isEmpty || flags == .shift, let c = event.charactersIgnoringModifiers, letters.contains(c) else { return nil }
        return c
    }
}

/// The ? sheet: the review's shortcuts, in a small card over the diff's corner.
struct ReviewKeysHelp: View {
    @Environment(\.reviewPalette) private var palette
    let onClose: () -> Void

    private static let rows: [([String], String)] = [
        (["j", "k"], "Next / previous file"),
        (["n", "p"], "Next / previous hunk"),
        (["v"], "Mark viewed, go to the next file"),
        (["c"], "Comment on the hunk"),
        (["⌥↓", "⌥↑"], "Next / previous concern"),
        (["⇧"], "Click a line for more lines (or drag the gutter)"),
        (["?"], "Show / hide these"),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.simul(.quiet))
                    .help("Close  Esc")
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Rectangle().fill(palette.cardBorder).frame(height: 1)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Self.rows, id: \.1) { keys, text in
                    GridRow {
                        HStack(spacing: 4) { ForEach(keys, id: \.self) { Kbd(text: $0) } }
                        Text(text).foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(14)
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.text)
        .frame(width: 340)
        .background(shape.fill(palette.panel))
        .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(palette.light ? 0.12 : 0.4), radius: 12, y: 6)
    }
}

/// A key cap, as GitHub's <kbd>.
private struct Kbd: View {
    @Environment(\.reviewPalette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.buttonFill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.buttonBorder, lineWidth: 1))
            .overlay(alignment: .bottom) {
                // <kbd>'s inset bottom edge.
                RoundedRectangle(cornerRadius: 6).fill(palette.buttonBorder).frame(height: 1).padding(.horizontal, 3)
            }
    }
}
