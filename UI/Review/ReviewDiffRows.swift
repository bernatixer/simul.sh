import AppKit
import SwiftUI

/// A comment being written: the lines it covers (new side) and the text of
/// its first line, which anchors it when the file changes.
struct CommentDraft: Equatable {
    let path: String
    /// The line first clicked; shift-click extends from it.
    let anchor: Int
    let anchorText: String
    let lines: ClosedRange<Int>
    let quote: String
    var text: String
    /// The suggestion block Suggest put in, to follow the lines if they change.
    var block: String?
}

/// The line-number columns a file needs: new side only for an added
/// file, old side only for a deleted one, each as wide as its largest number.
struct DiffGutter {
    let old: CGFloat?
    let new: CGFloat?
    /// A column before the numbers for the "ws" badge; 0 if no line needs it.
    let badge: CGFloat

    /// `lines`: the hunks' and the revealed ones, so every shown number fits.
    init(status: FileDiff.Status, lines: [DiffLine], whitespace: Bool = false) {
        old = status == .added ? nil : Self.width(lines.compactMap(\.oldNumber).max())
        new = status == .deleted ? nil : Self.width(lines.compactMap(\.newNumber).max())
        badge = whitespace ? 14 : 0
    }

    var width: CGFloat { badge + (old ?? 0) + (new ?? 0) }

    private static let digit = ("0" as NSString).size(
        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
    /// A diff line is 20 pt, as GitHub's: the font's own line height plus this, half above and half below.
    @MainActor static let leading = max(0, 20 - NSLayoutManager().defaultLineHeight(
        for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))

    /// GitHub's number cells: at least 50 wide, 8 of padding each side.
    private static func width(_ largest: Int?) -> CGFloat {
        max(50, CGFloat(String(largest ?? 0).count) * digit + 16)
    }
}

/// A diff row's cells in one layout pass: per side a gutter of fixed width, then the text
/// taking the rest; sides split evenly with a 1 pt divider between, every cell as tall as
/// the tallest. Nested stacks with fixedSize measured each row several times while scrolling.
struct DiffRowLayout: Layout {
    /// Each side's gutter width; subviews are gutter, text (, divider, gutter, text).
    let gutters: [CGFloat]

    private func widths(_ width: CGFloat) -> [CGFloat] {
        let side = (width - CGFloat(gutters.count - 1)) / CGFloat(gutters.count)
        var widths: [CGFloat] = []
        for (k, gutter) in gutters.enumerated() {
            if k > 0 { widths.append(1) }
            widths += [gutter, max(0, side - gutter)]
        }
        return widths
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var height: CGFloat = 0
        for (i, (view, w)) in zip(subviews, widths(width)).enumerated() where i % 3 != 2 {  // not dividers
            height = max(height, view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, w) in zip(subviews, widths(bounds.width)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w
        }
    }
}

extension View {
    /// A diff row's text cell: dimmed if whitespace only, filling the row's height.
    func diffTextCell(formatting: Bool) -> some View {
        opacity(formatting ? 0.5 : 1)
            .lineSpacing(DiffGutter.leading)
            .padding(.vertical, DiffGutter.leading / 2)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A diff row's gutter cell: numbers at the top right filling the row's height,
    /// "ws" before them if `badge`, and on its left edge a `bar` (the keyboard's current hunk).
    func diffGutterCell(_ tint: Color, badge: CGFloat?, bar: Color? = nil) -> some View {
        padding(.vertical, DiffGutter.leading / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .overlay(alignment: .topLeading) {
                if let badge { WhitespaceBadge(width: badge, shown: true) }
                if let bar { bar.frame(width: 2).frame(maxHeight: .infinity) }
            }
            .foregroundStyle(.tertiary)
            .background(tint)
    }

    /// Presses and drags anywhere in the cell: the gutter's comment action. One drag gesture
    /// (no minimum distance, so a click is a press and a release) in place of a tap.
    func onGutter(_ action: @escaping (GutterAction) -> Void) -> some View {
        modifier(GutterGesture(action: action))
    }

    /// While a gutter drag is on in this row's file: where its new-side line is, for the drag to find.
    func gutterSpot(_ line: DiffLine?, active: Bool) -> some View {
        background {
            if active, let line, let n = line.newNumber {
                GeometryReader { g in
                    Color.clear.preference(key: GutterSpots.self,
                                           value: [n: GutterSpot(frame: g.frame(in: .named(ReviewDiffView.space)), text: line.text)])
                }
            }
        }
    }
}

/// The gutter's pointer: pressed, dragged (in the diff's coordinates) and released (or cancelled).
enum GutterAction {
    case press
    case drag(y: CGFloat)
    case release
}

/// The gutter's drag gesture. A cancelled one never ends, but its GestureState resets: that
/// releases too, so the next press is a press again and a drag never stays on.
private struct GutterGesture: ViewModifier {
    let action: (GutterAction) -> Void
    @State private var pressed = false
    @GestureState private var active = false

    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(ReviewDiffView.space))
                .updating($active) { _, active, _ in active = true }
                .onChanged { value in
                    if pressed { return action(.drag(y: value.location.y)) }
                    pressed = true
                    action(.press)
                }
                .onEnded { _ in end() })
            .onChange(of: active) { _, now in if !now { end() } }
    }

    private func end() {
        if pressed { pressed = false }
        action(.release)
    }
}

/// A shown new-side line's frame and text, by line number (only while a gutter drag is on).
struct GutterSpot: Equatable {
    let frame: CGRect
    let text: String
}

struct GutterSpots: PreferenceKey {
    static let defaultValue: [Int: GutterSpot] = [:]
    static func reduce(value: inout [Int: GutterSpot], nextValue: () -> [Int: GutterSpot]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A diff line's text: token colours from `palette` once parsed, changed words on their
/// tint, and each whole-word use of `name` marked. Per row on screen, so only the visible
/// lines are coloured and searched.
@MainActor func diffText(_ text: String, highlighted: AttributedString?, marking name: String?,
                         palette: ReviewPalette) -> Text {
    let ranges = name.map { text.wordOffsets(of: $0) } ?? []
    guard highlighted != nil || !ranges.isEmpty else { return Text(text).foregroundStyle(palette.text) }
    var marked = highlighted ?? AttributedString(text)
    marked.foregroundColor = palette.text
    for (kind, range) in marked.runs[TokenKindAttribute.self] {
        if let kind, let colour = palette.token(kind) { marked[range].foregroundColor = colour }
    }
    for (kind, range) in marked.runs[WordChangeAttribute.self] where kind != nil {
        marked[range].backgroundColor = kind == .added ? palette.addedWord : palette.removedWord
    }
    // Coloured now: without them, runs of the same colour merge and Text resolves fewer.
    marked[TokenKindAttribute.self] = nil
    marked[WordChangeAttribute.self] = nil
    let count = marked.characters.count
    for range in ranges where range.upperBound <= count {
        let lower = marked.index(marked.startIndex, offsetByCharacters: range.lowerBound)
        let upper = marked.index(marked.startIndex, offsetByCharacters: range.upperBound)
        marked[lower..<upper].backgroundColor = palette.nameMark
    }
    return Text(marked)
}

/// One diff line: its line numbers (click to comment), then the text. The
/// row colour says added/removed; a whitespace-only change is dimmed with
/// "ws" in the gutter. Hovering a line that can take a comment shows a "+"
/// on the gutter's edge, as on GitHub.
struct DiffLineRow: View {
    let line: DiffLine
    /// The line's text in token colours, once the review has parsed the file.
    var highlighted: AttributedString?
    /// The followed name, marked wherever it appears.
    var marking: String?
    let gutter: DiffGutter
    let selected: Bool
    var formatting = false
    /// In the keyboard's current hunk: a bar on the gutter's edge.
    var current = false
    let onGutter: (GutterAction) -> Void
    /// Here, so crossing rows redraws only those two.
    @State private var hovered = false
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        DiffRowLayout(gutters: [gutter.width]) {
            HStack(spacing: 0) {
                if let width = gutter.old { number(line.oldNumber, width: width) }
                if let width = gutter.new { number(line.newNumber, width: width) }
            }
            .diffGutterCell(gutterTint, badge: formatting && gutter.badge > 0 ? gutter.badge : nil,
                            bar: current ? palette.link : nil)
            .onGutter(onGutter)
            diffText(line.text, highlighted: highlighted, marking: marking, palette: palette)
                .diffTextCell(formatting: formatting)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(background)
        .overlay(alignment: .topLeading) {
            if hovered, line.newNumber != nil {
                CommentPlus(action: onGutter).offset(x: gutter.width - 18)  // inside the gutter, on its right edge
            }
        }
        .onHover { inside in if hovered != inside { hovered = inside } }
    }

    private func number(_ n: Int?, width: CGFloat) -> some View {
        Text(n.map(String.init) ?? "").padding(.trailing, 8).frame(width: width, alignment: .trailing)
    }

    private var background: Color {
        if selected { return palette.selectedLine }
        switch line.kind {
        case .added: return palette.added
        case .removed: return palette.removed
        case .context: return .clear
        }
    }

    private var gutterTint: Color {
        if selected { return palette.selectedNum }
        switch line.kind {
        case .added: return palette.addedGutter
        case .removed: return palette.removedGutter
        case .context: return .clear
        }
    }
}

/// The "+" on a hovered line's gutter edge. Not a Button: one appearing on each row
/// the pointer crosses while scrolling churned the window's focus.
struct CommentPlus: View {
    let action: (GutterAction) -> Void

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue))
            .padding(.top, 1)
            .onGutter(action)
            .help("Comment on this line  Drag or ⇧-click for more lines")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Comment on this line")
    }
}

/// The gutter's badge column: "ws" when the line only changed whitespace.
struct WhitespaceBadge: View {
    @Environment(\.reviewPalette) private var palette
    let width: CGFloat
    let shown: Bool

    var body: some View {
        if width > 0 {
            Text(shown ? "ws" : "")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .frame(width: width)
                .padding(.top, 3 + DiffGutter.leading / 2)
                .help(shown ? "Whitespace only" : "")
        }
    }
}

/// A comment under its line, as GitHub's: a slim header ("Lines 3–5 · by agent", the buttons), the text
/// below. The agent's drafts (until Keep makes them the user's) have a dashed border: suggestions.
/// Queued (× deletes), sent (dimmed, Resolve), or outdated (its line is gone).
struct ReviewCommentRow: View {
    @Environment(\.reviewPalette) private var palette
    @Environment(AppModel.self) private var model
    let sessionID: Session.ID
    let comment: ReviewComment
    /// The commented lines' text, for a suggestion's mini diff.
    var original: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 8)
                if isSent {
                    Button("Resolve") { model.reviews.setCommentState(sessionID, comment: comment.id, .resolved) }
                        .buttonStyle(.primer(height: 22))
                } else {
                    if comment.byAgent {
                        Button("Keep") { model.reviews.keepComment(sessionID, comment: comment.id) }
                            .buttonStyle(.primer(height: 22))
                            .help("Make it your comment, to send to the agent")
                    }
                    Button { model.reviews.deleteComment(sessionID, comment: comment.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.simul(.quiet))
                    .help("Delete comment")
                    .accessibilityLabel("Delete comment")
                }
            }
            CommentText(text: comment.text, original: original)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .commentCard(dashed: comment.byAgent)
        .opacity(isSent ? 0.55 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Sent to the agent or posted to GitHub: done with, dimmed, resolvable.
    private var isSent: Bool { comment.state == .sent || comment.state == .posted }

    private var label: String {
        var parts = [comment.line == comment.endLine ? "Line \(comment.line)" : "Lines \(comment.line)–\(comment.endLine)"]
        if comment.isOutdated { parts.append("Outdated") }
        if comment.state == .sent { parts.append("Sent") }
        if comment.state == .posted { parts.append("On GitHub") }
        if comment.byAgent { parts.append("by agent") }
        return parts.joined(separator: " · ")
    }
}

/// Writes a comment: ⌘↩ queues it, Esc cancels. On a pull request, Suggest adds a
/// ```suggestion block of the lines, to edit into the change (GitHub applies it).
struct ReviewComposer: View {
    @Environment(\.reviewPalette) private var palette
    let draft: CommentDraft
    @Binding var text: String
    /// Bumped to focus the field again.
    var focus = 0
    /// Inserts a suggestion block; nil off pull requests or when the lines aren't in one hunk.
    var onSuggest: (() -> Void)?
    let onQueue: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.lines.count == 1 ? "Line \(draft.lines.lowerBound)"
                                        : "Lines \(draft.lines.lowerBound)–\(draft.lines.upperBound)")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryText)
            TextField("Comment for the agent", text: $text, axis: .vertical)
                .lineLimit(2...8)
                .monospaced(Suggestion.contains(text))  // code lines up
                .simulField()
                .focused($focused)
                .onExitCommand(perform: onCancel)
            HStack {
                if let onSuggest {
                    Button(action: onSuggest) {
                        Label("Suggest", systemImage: "plus.forwardslash.minus")
                    }
                    .buttonStyle(.primer(height: 24))
                    .help("Suggest a change to these lines (GitHub can apply it)")
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.simul(.quiet))
                Button("Queue") { onQueue(trimmed) }
                    // Only while typing here, so ⌘↩ otherwise reaches the terminal.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help("Queue comment  ⌘↩")
                    .disabled(trimmed.isEmpty)
                    .buttonStyle(.simul(.primary))
            }
        }
        .font(.system(size: 12))
        .padding(8)
        .commentCard()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onAppear { focused = true }
        .onChange(of: focus) { _, _ in
            focused = true
            // Focusing selects all the text, which the next key would replace: the caret at the end instead.
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension View {
    /// The card under a diff line that holds a comment or the composer; dashed for the agent's drafts.
    func commentCard(dashed: Bool = false) -> some View { modifier(CommentCard(dashed: dashed)) }
}

private struct CommentCard: ViewModifier {
    @Environment(\.reviewPalette) private var palette
    let dashed: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(palette.panel))
            .overlay(shape.strokeBorder(palette.cardBorder, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
    }
}
