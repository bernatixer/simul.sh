import SwiftUI

/// Lines folded into one muted row: a moved run ("N lines moved from p:l",
/// the place clickable) or a whitespace-only hunk. The chevron opens it in place.
/// Side by side, a moved run sits on its own side.
struct DiffFoldRow: View {
    enum Side { case left, right }
    let text: String
    var link: String?
    let open: Bool
    /// Kept open by a comment or the draft on its lines: can't fold.
    var held = false
    var side: Side?
    let onToggle: () -> Void
    var onLink: () -> Void = {}
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        if let side {
            HStack(spacing: 0) {
                if side == .left { label } else { filler }
                Rectangle().fill(palette.cardBorder).frame(width: 1)
                if side == .right { label } else { filler }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(held)
            .help(held ? "Open while it holds a comment" : open ? "Fold" : "Show the lines")
            if let link {
                Button(action: onLink) { Text(link).underline() }
                    .buttonStyle(.plain)
                    .help("Go to the other end")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filler: some View {
        palette.filler.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
