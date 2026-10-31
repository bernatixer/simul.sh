import AppKit
import SwiftUI

/// A file card's header, as GitHub's: chevron, path (copy button on hover), +/− and squares;
/// then the concern chip, "Since viewed", comment count, Viewed and the "…" menu.
struct FileHeader: View {
    let file: FileDiff
    let root: String
    let collapsed: Bool
    /// nil: the path can't be tracked (no hash), Viewed is disabled.
    let viewed: Bool?
    let comments: Int
    var concern: (text: String, severity: AgentOverview.Severity)?
    /// nil: the file didn't change since viewed; else whether its since-viewed diff shows.
    var sinceViewed: Bool?
    let onToggle: () -> Void
    let onViewed: (Bool) -> Void
    let onSinceViewed: (Bool) -> Void
    let onAll: (_ open: Bool) -> Void
    @State private var hovered = false
    @State private var menuOpen = false
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 12)
                    Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand" : "Collapse")
            Button(action: copyPath) {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.simul(.quiet))
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .help("Copy path")
            .accessibilityLabel("Copy path")
            DiffStatBar(added: file.added, removed: file.removed)
            if let concern {
                SeverityChip(text: concern.text, severity: concern.severity)
                    .help("Open concerns from the agent's overview here")
            }
            Spacer(minLength: 0)
            if let on = sinceViewed {
                checkbox("Since viewed", on: on) { onSinceViewed(!on) }
                    .help("Show only what changed since you marked it viewed")
            }
            if comments > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                    Text("\(comments)")
                }
                .foregroundStyle(palette.secondaryText)
                .help("\(comments) comment\(comments == 1 ? "" : "s")")
            }
            checkbox("Viewed", on: viewed ?? false) { onViewed(!(viewed ?? false)) }
                .disabled(viewed == nil)
                .help(viewed == nil ? "Can't track this path" : "Viewed files collapse until they change")
            menu
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background {
            // The card's top, its border's bottom edge the line under the header; the
            // panel colour behind keeps a pinned header's corners opaque.
            let r = collapsed ? ReviewDiffView.radius : 0
            let shape = UnevenRoundedRectangle(topLeadingRadius: ReviewDiffView.radius, bottomLeadingRadius: r,
                                               bottomTrailingRadius: r, topTrailingRadius: ReviewDiffView.radius)
            shape.fill(palette.fileHeader)
                .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 1))
                .background(palette.panel)
        }
        .onHover { if hovered != $0 { hovered = $0 } }
    }

    /// GitHub's "Viewed": a small default button with a checkbox, blue when ticked.
    private func checkbox(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(on ? palette.link : palette.panel)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(on ? palette.link : palette.secondaryText.opacity(0.7), lineWidth: 1)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 13, height: 13)
                Text(title)
            }
        }
        .buttonStyle(.primer(height: 26))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A plain button opening a popover: a Menu per header is an AppKit control built as
    /// each card scrolls in, which cost frames.
    private var menu: some View {
        Button { menuOpen = true } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.simul(.quiet))
        .help("More")
        .accessibilityLabel("More")
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                MenuRow("Copy path", icon: "doc.on.doc", dismiss: { menuOpen = false }) { copyPath() }
                if file.status != .deleted {
                    MenuRow("Open file", icon: "arrow.up.forward.app", dismiss: { menuOpen = false }) { NSWorkspace.shared.open(url) }
                    MenuRow("Reveal in Finder", icon: "folder", dismiss: { menuOpen = false }) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Rectangle().fill(palette.cardBorder).frame(height: 1).padding(.vertical, 4)
                MenuRow("Expand all files", icon: "rectangle.expand.vertical", dismiss: { menuOpen = false }) { onAll(true) }
                MenuRow("Collapse all files", icon: "rectangle.compress.vertical", dismiss: { menuOpen = false }) { onAll(false) }
            }
            .padding(6)
            .frame(width: 210)
            .presentationBackground(palette.panel)
            .preferredColorScheme(palette.light ? .light : .dark)
        }
    }

    private var url: URL { URL(fileURLWithPath: root + "/" + file.path) }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }
}

/// A row of the header's "…" popover, as GitHub's ActionList: icon, title, hover fill.
private struct MenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.reviewPalette) private var palette
    let dismiss: () -> Void

    init(_ title: String, icon: String, dismiss: @escaping () -> Void, action: @escaping () -> Void) {
        (self.title, self.icon, self.dismiss, self.action) = (title, icon, dismiss, action)
    }

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(palette.secondaryText).frame(width: 16)
                Text(title).foregroundStyle(palette.text)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? palette.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if hovered != $0 { hovered = $0 } }
    }
}
