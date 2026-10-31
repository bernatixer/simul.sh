import SwiftUI

/// The `@@` row between hunks, as GitHub's: in the line-number column the expanders
/// (↓ shows 20 more lines after the hunk above, ↑ 20 more before the one below, ↕ the
/// rest when 20 or fewer are left), then the header text on the hunk band.
struct HunkHeaderRow: View {
    enum Expand: Hashable { case down, up, all }
    let text: String
    let gutter: CGFloat
    let expand: [Expand]
    let onExpand: (Expand) -> Void
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        DiffRowLayout(gutters: [gutter]) {
            HStack(spacing: 0) {
                ForEach(expand, id: \.self) { e in ExpandButton(expand: e) { onExpand(e) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.hunkNum)
            Text(text)
                .foregroundStyle(palette.hunkText)
                .lineLimit(1)
                .padding(.vertical, DiffGutter.leading / 2)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(palette.hunkBackground)
    }
}

private struct ExpandButton: View {
    let expand: HunkHeaderRow.Expand
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        let (icon, help) = switch expand {
        case .down: ("chevron.down", "Show 20 more lines below")
        case .up: ("chevron.up", "Show 20 more lines above")
        case .all: ("chevron.up.chevron.down", "Show the hidden lines")
        }
        Image(systemName: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovered ? .white : palette.hunkText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovered ? palette.link : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { if hovered != $0 { hovered = $0 } }
            .help(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(help)
    }
}
