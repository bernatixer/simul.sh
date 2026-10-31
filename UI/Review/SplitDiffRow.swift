import AppKit
import SwiftUI

/// One side-by-side row: the old line on the left, the new on the right,
/// both as tall as the taller one. As in unified, comments attach to the
/// new line, so only the right gutter (and its hover "+") takes clicks.
struct SplitDiffRow: View {
    let row: SplitRow
    /// Each side's text in token colours, once the review has parsed the file.
    var highlighted: (left: AttributedString?, right: AttributedString?) = (nil, nil)
    /// The followed name, marked wherever it appears.
    var marking: String?
    let gutter: DiffGutter
    let selected: Bool
    /// Each side only changed whitespace: dimmed, "ws" in its gutter.
    var formatting = (left: false, right: false)
    /// In the keyboard's current hunk: a bar on the left gutter's edge.
    var current = false
    let onGutter: (GutterAction) -> Void
    /// Here, so crossing rows redraws only those two.
    @State private var hovered = false
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        let left = row.left, right = row.right
        DiffRowLayout(gutters: [gutter.badge + (gutter.old ?? 0), gutter.badge + (gutter.new ?? 0)]) {
            gutterCell(left, number: left?.oldNumber, tint: palette.removedGutter, formatting: formatting.left,
                       selected: false, bar: current)
            textCell(left, highlighted: highlighted.left, tint: palette.removed, formatting: formatting.left, selected: false)
            palette.cardBorder
            gutterCell(right, number: right?.newNumber, tint: palette.addedGutter, formatting: formatting.right,
                       selected: selected)
                .onGutter { if right?.newNumber != nil { onGutter($0) } }
                .overlay(alignment: .topTrailing) {
                    if hovered, right?.newNumber != nil { CommentPlus(action: onGutter) }  // on the gutter's right edge
                }
            textCell(right, highlighted: highlighted.right, tint: palette.added, formatting: formatting.right,
                     selected: selected)
        }
        .font(.system(size: 12, design: .monospaced))
        .onHover { inside in if hovered != inside { hovered = inside } }
    }

    private func gutterCell(_ line: DiffLine?, number: Int?, tint: Color, formatting: Bool, selected: Bool,
                            bar: Bool = false) -> some View {
        Text(number.map(String.init) ?? "")
            .padding(.trailing, 8)
            .diffGutterCell(selected ? palette.selectedNum : line?.kind ?? .context == .context ? .clear : tint,
                            badge: formatting && gutter.badge > 0 ? gutter.badge : nil, bar: bar ? palette.link : nil)
            .background(background(line, tint: tint, selected: selected))
    }

    private func textCell(_ line: DiffLine?, highlighted: AttributedString?, tint: Color, formatting: Bool,
                          selected: Bool) -> some View {
        diffText(line?.text ?? "", highlighted: highlighted, marking: marking, palette: palette)
            .diffTextCell(formatting: formatting)
            .background(background(line, tint: tint, selected: selected))
    }

    private func background(_ line: DiffLine?, tint: Color, selected: Bool) -> Color {
        if selected { return palette.selectedLine }
        guard let line else { return palette.filler }
        return line.kind == .context ? .clear : tint
    }
}
