import SwiftUI

/// A drawer on the review's right edge for a followed name: its other uses in
/// the repo (outside the lines the diff adds), grouped by file. One the diff
/// shows scrolls there; any other opens the lines around it.
struct NameUsesList: View {
    @Environment(AppModel.self) private var model
    let name: String
    let session: Session
    let snapshot: ReviewSnapshot
    /// Files whose since-viewed diff is chosen: uses there show their lines instead.
    let sinceViewed: Set<String>
    let onJump: (NameUse) -> Void
    /// × closes the drawer; Clear and Esc also stop following the name.
    let onClose: () -> Void
    let onClear: () -> Void
    @State private var uses: [NameUse]?
    @State private var loadedName = ""
    /// More uses than listed.
    @State private var more = false
    /// Uses on a line the diff against the base shows.
    @State private var onDiffLine: Set<String> = []
    @State private var previews: [String: [NameUse]] = [:]
    @Environment(\.reviewPalette) private var palette

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle).foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 8)
                Button("Clear", action: onClear)
                    .buttonStyle(.simul(.quiet))
                    .help("Stop following \(name)  Esc")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.simul(.quiet))
                    .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(palette.divider).frame(height: 1)
            ScrollView {
                if let uses { list(uses) }
            }
        }
        .font(.system(size: 12))
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.panel)
        // Again when the review refreshes: uses and diff lines may have moved.
        .task(id: [name, snapshot.point, String(snapshot.hashes.hashValue)]) { await load() }
    }

    private var subtitle: String {
        guard let uses else { return "Loading…" }
        if uses.isEmpty { return "No other uses" }
        return "\(uses.count)\(more ? "+" : "") other use\(uses.count == 1 && !more ? "" : "s")"
    }

    /// Uses by file, files in the order found.
    private func groups(_ uses: [NameUse]) -> [(path: String, uses: [NameUse])] {
        var result: [(path: String, uses: [NameUse])] = [], at: [String: Int] = [:]
        for use in uses {
            if let i = at[use.path] { result[i].uses.append(use) } else {
                at[use.path] = result.count
                result.append((use.path, [use]))
            }
        }
        return result
    }

    private func list(_ uses: [NameUse]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups(uses), id: \.path) { group in
                Text(verbatim: group.path)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.path)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ForEach(group.uses) { use in
                    Button { open(use) } label: {
                        row(String(use.line), use.text.trimmingCharacters(in: .whitespaces))
                    }
                    .buttonStyle(.plain)
                    .help(inDiff(use) ? "Go to it in the diff" : "Show the lines around it")
                    if let lines = previews[use.id] { preview(lines, at: use.line) }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.bottom, 8)
    }

    /// Line number, then the whole line, wrapping, with the name marked.
    private func row(_ number: String, _ text: String, marked: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: number)
                .foregroundStyle(palette.secondaryText)
                .frame(width: 40, alignment: .trailing)
            diffText(text, highlighted: nil, marking: marked ? name : nil, palette: palette)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func preview(_ lines: [NameUse], at line: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { l in
                row(String(l.line), l.text, marked: false)
                    .background(l.line == line ? palette.nameMark : .clear)
            }
        }
        .padding(.vertical, 4)
        .background(palette.ink.opacity(0.04))
    }

    /// A file showing its since-viewed diff doesn't have the base diff's rows.
    private func inDiff(_ use: NameUse) -> Bool {
        onDiffLine.contains(use.id) && !sinceViewed.contains(use.path)
    }

    private func load() async {
        // A refresh keeps the old list until the new one is in; another name starts empty.
        if uses != nil, loadedName != name { uses = nil }
        if !previews.isEmpty { previews = [:] }
        let (found, more) = await model.reviews.uses(of: name, in: session.id)
        guard !Task.isCancelled else { return }
        self.more = more
        var shown: [String: Set<Int>] = [:]
        for file in snapshot.files where found.contains(where: { $0.path == file.path }) {
            shown[file.path] = Set(file.hunks.flatMap(\.lines).compactMap(\.newNumber))
        }
        onDiffLine = Set(found.filter { shown[$0.path]?.contains($0.line) == true }.map(\.id))
        uses = found
        loadedName = name
    }

    private func open(_ use: NameUse) {
        if inDiff(use) { return onJump(use) }
        if previews[use.id] != nil {
            previews[use.id] = nil
            return
        }
        Task {
            let lines = await model.reviews.lines(around: use.line, path: use.path, in: session.id)
            previews[use.id] = lines
        }
    }
}
