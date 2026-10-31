import SwiftUI

/// What the tree and the diff share without redrawing the panel: the file at the
/// top of the diff (highlighted in the tree) and one the tree asks the diff to show.
@MainActor @Observable final class ReviewFocus {
    var current: String?
    /// Set by a click in the tree; the diff scrolls to it and clears it.
    var reveal: String?
}

/// The review's left sidebar, as GitHub's: a filter, then the changed files as a tree
/// (or, when the agent sent layers, Files | Layers: the files under numbered layers).
/// Click a file to go to it; the file at the top of the diff is highlighted.
struct FileTreeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reviewPalette) private var palette
    let session: Session
    /// The files shown, filtered, in diff order.
    let files: [FileDiff]
    /// Layers mode's groups (nil in Files mode); a nil layer is "Other".
    let groups: [(layer: AgentOverview.Layer?, paths: [String])]?
    let canLayer: Bool
    @Binding var layered: Bool
    @Binding var filter: String
    let focus: ReviewFocus
    /// Folders the user folded (their paths).
    @State private var folded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
            filterField
            if canLayer {
                SegmentedSwitch(titles: ["Files", "Layers"], selected: Binding(
                    get: { layered ? 1 : 0 }, set: { if layered != ($0 == 1) { layered = $0 == 1 } }))
                    .help("Files as a tree, or in the agent's layers: the order to read them in")
            }
            }
            .padding(.horizontal, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if files.isEmpty {
                            Text(filter.isEmpty ? "No files" : "No files match")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.secondaryText)
                                .padding(8)
                        } else if let groups {
                            layerRows(groups)
                        } else {
                            treeRows
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    // Rows share ids (paths) across modes: a new stack per mode, or switching kept the other mode's rows.
                    .id(groups == nil)
                }
                .background { FollowFocus(focus: focus, proxy: proxy) }
            }
        }
        .padding(.top, 8)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondaryText)
            TextField("Filter files…", text: $filter)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.text)
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondaryText)
                    .help("Clear filter")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.buttonBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var treeRows: some View {
        let info = FileInfo(model: model, session: session, files: files)
        // A folded folder's rows (its path + "/" prefixes them) are left out.
        let rows = FileTree.rows(files.map(\.path)).filter { row in !folded.contains { row.id.hasPrefix($0 + "/") } }
        ForEach(rows) { row in
            if row.isFolder {
                TreeRow(depth: row.depth, selected: { false }) { toggle(row.path) } content: {
                    Image(systemName: folded.contains(row.path) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 12)
                    Image(systemName: "folder.fill")
                        .foregroundStyle(palette.folder)
                    Text(verbatim: row.name).foregroundStyle(palette.text).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .help(row.path)
            } else {
                fileRow(row.id, name: row.name, depth: row.depth, info)
            }
        }
    }

    @ViewBuilder
    private func layerRows(_ groups: [(layer: AgentOverview.Layer?, paths: [String])]) -> some View {
        let info = FileInfo(model: model, session: session, files: files)
        ForEach(Array(groups.enumerated()), id: \.offset) { n, group in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.layer == nil ? "·" : "\(n + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.link)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(palette.linkFill))
                    Text(verbatim: group.layer?.title ?? "Other")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.text)
                }
                if let note = group.layer?.note {
                    Text(verbatim: note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(3)
                        .padding(.leading, 22)
                        .help(note)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, n == 0 ? 4 : 12)
            .padding(.bottom, 4)
            ForEach(group.paths, id: \.self) { path in
                fileRow(path, name: (path as NSString).lastPathComponent, depth: 0, info, folder: (path as NSString).deletingLastPathComponent)
            }
        }
    }

    /// Name (muted and ticked once viewed), then comment count, concern dot and status icon.
    private func fileRow(_ path: String, name: String, depth: Int, _ info: FileInfo, folder: String = "") -> some View {
        let viewed = model.reviews.isViewed(session.id, path: path)
        return TreeRow(depth: depth, selected: { focus.current == path }) {
            if focus.current != path { focus.current = path }
            focus.reveal = path
        } content: {
            Color.clear.frame(width: 12)  // under a folder's chevron
            let label = Text(verbatim: name).foregroundStyle(viewed ? palette.secondaryText : palette.text)
                .truncationMode(.middle)
            // In layers, where it is: the folder in what the name leaves, middle-truncated; dropped
            // under 40 pt. (Its ideal width is capped: ViewThatFits measured the whole folder.)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    label.fixedSize()
                    Text(verbatim: folder).font(.system(size: 11)).foregroundStyle(palette.secondaryText)
                        .truncationMode(.middle)
                        .frame(minWidth: folder.isEmpty ? 0 : 40, idealWidth: folder.isEmpty ? 0 : 40, maxWidth: .infinity, alignment: .leading)
                }
                label
            }
            Spacer(minLength: 4)
            if viewed {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.secondaryText)
                    .help("Viewed")
            }
            if let n = info.comments[path], n > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble").font(.system(size: 10))
                    Text("\(n)").font(.system(size: 11))
                }
                .foregroundStyle(palette.secondaryText)
                .help("\(n) comment\(n == 1 ? "" : "s")")
            }
            if let severity = info.concerns[path] {
                Circle().fill(palette.severityText(severity)).frame(width: 6, height: 6)
                    .help("Open \(severity.rawValue) concern from the agent's overview")
            }
            if let status = info.status[path] { FileStatusIcon(status: status) }
        }
        .help(path)
        .id(path)
    }

    private func toggle(_ folder: String) {
        if folded.contains(folder) { folded.remove(folder) } else { folded.insert(folder) }
    }
}

/// Per-file badges, worked out once per tree update.
@MainActor private struct FileInfo {
    var status: [String: FileDiff.Status] = [:]
    var comments: [String: Int] = [:]
    /// The highest open concern anchored in each file.
    var concerns: [String: AgentOverview.Severity] = [:]

    init(model: AppModel, session: Session, files: [FileDiff]) {
        for file in files { status[file.path] = file.status }
        for c in model.reviews.states[session.id]?.current.comments ?? [] where c.state != .resolved {
            comments[c.path, default: 0] += 1
        }
        guard let o = model.reviews.overview(session.id) else { return }
        for i in o.concerns.indices where !o.dismissed.contains(i) {
            let rank = { AgentOverview.Severity.allCases.firstIndex(of: $0) ?? 0 }  // high first
            let severity = o.concerns[i].severity
            for anchor in o.concerns[i].at where concerns[anchor.path].map({ rank(severity) < rank($0) }) ?? true {
                concerns[anchor.path] = severity
            }
        }
    }
}

/// A tree row: indented, 28 tall, hover and selected fills; the selected one with
/// GitHub's accent bar on its leading edge.
private struct TreeRow<Content: View>: View {
    let depth: Int
    /// Read in the row's body: the focus moving redraws two rows, not the tree.
    let selected: () -> Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        let selected = selected()
        HStack(spacing: 6) { content }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.leading, 8 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.treeSelected : hovered ? palette.rowHover : .clear))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(palette.link).frame(width: 4, height: 20).offset(x: -6) }  // GitHub's: half outside
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { if hovered != $0 { hovered = $0 } }
            .accessibilityAddTraits(.isButton)
    }
}

/// Keeps the focused file's row in the tree's view; on its own, so only it observes the focus.
private struct FollowFocus: View {
    let focus: ReviewFocus
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear.onChange(of: focus.current) { _, path in
            if let path { proxy.scrollTo(path) }
        }
    }
}

/// GitHub's diff-added / -modified / -removed / -renamed icon, in its status colour.
struct FileStatusIcon: View {
    let status: FileDiff.Status
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        let (icon, name): (String, String) = switch status {
        case .added: ("plus.square", "Added")
        case .modified: ("dot.square", "Modified")
        case .deleted: ("minus.square", "Deleted")
        case .renamed: ("arrow.right.square", "Renamed")
        }
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(palette.status(status))
            .help(name)
            .accessibilityLabel(name)
    }
}

/// As GitHub's SegmentedControl: a muted track, the selected segment raised.
struct SegmentedSwitch: View {
    let titles: [String]
    @Binding var selected: Int
    @Environment(\.reviewPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { i in segment(titles[i], on: selected == i) { selected = i } }
        }
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.segmentTrack))
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .medium))
                .foregroundStyle(palette.buttonText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(on ? palette.segmentKnob : .clear))
                .overlay(shape.strokeBorder(on ? palette.buttonBorder : .clear, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
