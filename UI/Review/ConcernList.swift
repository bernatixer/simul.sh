import SwiftUI

/// The overview's open concerns: severity, title, why, where (click to go
/// there), Keep (becomes your comment, so Send to Agent carries it) and
/// Dismiss. Hovering one focuses its parts on the change map.
struct ConcernList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reviewPalette) private var palette
    let sessionID: Session.ID
    let overview: AgentOverview
    /// The concern under the pointer.
    @Binding var hovered: Int?
    let onJump: (AgentOverview.Anchor) -> Void
    @State private var showResolved = false

    var body: some View {
        let open = overview.concerns.indices.filter { !overview.dismissed.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            if open.isEmpty {
                Text(overview.concerns.isEmpty ? "None found" : "All kept or dismissed")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
            }
            ForEach(open, id: \.self) { row($0) }
            if !overview.resolved.isEmpty { resolved }
        }
    }

    /// The last review's concerns this one no longer raises, folded.
    private var resolved: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showResolved.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showResolved ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("Resolved since last review (\(overview.resolved.count))")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showResolved {
                ForEach(overview.resolved.indices, id: \.self) { i in
                    let c = overview.resolved[i]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.done)
                        Text(verbatim: c.title).strikethrough(color: palette.secondaryText)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.leading, 16)
                    .help(c.why)
                }
            }
        }
        .padding(.top, 2)
    }

    private func row(_ i: Int) -> some View {
        let reviews = model.reviews, concern = overview.concerns[i]
        let keep = reviews.keepAnchor(sessionID, concern: i)
        let target = concern.at.first { reviews.overviewAnchorHolds(sessionID, $0) }
        let shape = RoundedRectangle(cornerRadius: 8)
        return VStack(alignment: .leading, spacing: 4) {
            // Only the title and why go there: a click on a plain chip or a
            // disabled Keep mustn't fall through to it.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(concern.severity.rawValue.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(palette.severityText(concern.severity))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.severityBorder(concern.severity), lineWidth: 1))
                        .fixedSize()
                    Text(verbatim: concern.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.text)
                    // Against the review it replaced: raised now, or raised then too.
                    if overview.newConcerns != nil {
                        if overview.isNew(i) {
                            PrimerLabel(text: "New", color: palette.addedText, border: palette.stroke(.added))
                                .help("Not in the last review")
                        } else {
                            PrimerLabel(text: "Still open", color: palette.secondaryText, border: palette.cardBorder)
                                .help("The last review raised it too")
                        }
                    }
                }
                Text(verbatim: concern.why)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if let target { onJump(target) } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(target == nil ? [] : .isButton)
            .accessibilityActions {
                if let target { Button("Jump to code") { onJump(target) } }
            }
            if !concern.at.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(concern.at, id: \.self) { chip($0, linked: reviews.overviewAnchorHolds(sessionID, $0)) }
                }
                .padding(.top, 2)
            }
            HStack(spacing: 6) {
                Button("Keep") { Task { await reviews.keepConcern(sessionID, concern: i) } }
                    .buttonStyle(.simul(.pill))
                    .disabled(keep == nil)
                    .help(keep.map { "Make it your comment on \(Self.place($0))" } ?? "Not on a changed line")
                Button("Dismiss") { reviews.dismissConcern(sessionID, concern: i) }
                    .buttonStyle(.simul(.quiet))
                    .help("Remove it from the list")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(palette.panel))
        .overlay(shape.strokeBorder(hovered == i ? palette.link : palette.cardBorder, lineWidth: 1))
        .contentShape(shape)
        .onHover { inside in
            if inside { if hovered != i { hovered = i } } else if hovered == i { hovered = nil }
        }
    }

    /// `file.py:99`; one whose file changed since the review is plain text.
    @ViewBuilder
    private func chip(_ anchor: AgentOverview.Anchor, linked: Bool) -> some View {
        let label = Text(verbatim: Self.place(anchor))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(linked ? palette.link : palette.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(linked ? palette.linkFill : palette.ink.opacity(0.04)))
            .contentShape(Rectangle())
        if linked {
            Button { onJump(anchor) } label: { label }
                .buttonStyle(.plain)
                .help("\(anchor.path):\(anchor.line)")
        } else {
            label.help("\(anchor.path) changed since the review")
        }
    }

    static func place(_ anchor: AgentOverview.Anchor) -> String {
        "\((anchor.path as NSString).lastPathComponent):\(anchor.line)"
    }
}

/// "1 high": an outlined capsule in the severity's colours (the pane's bar, file cards).
struct SeverityChip: View {
    let text: String
    let severity: AgentOverview.Severity
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        PrimerLabel(text: text, color: palette.severityText(severity), border: palette.severityBorder(severity))
    }
}

/// Primer's Label: small text in an outlined capsule.
struct PrimerLabel: View {
    let text: String
    let color: Color
    let border: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .fixedSize()
    }
}
