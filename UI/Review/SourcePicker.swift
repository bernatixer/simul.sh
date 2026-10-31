import SwiftUI

/// The source pill's popover: the session folder, the repo's other worktrees
/// and open pull requests, loaded each time it opens (only then: git and gh
/// don't run while it's closed).
struct SourcePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reviewPalette) private var palette
    let session: Session
    /// The repo's worktrees, shared with the panel so the pill can name a worktree's branch.
    @Binding var worktrees: [Worktree]
    let chooseFolder: () -> Void
    let dismiss: () -> Void

    @State private var loadingTrees = true
    /// The worktree holding the session folder, and the folder Simul's own worktrees live in (both resolved).
    @State private var own: String?
    @State private var simulDir = ""
    @State private var pullRequests: [PullRequest]?
    @State private var prError: String?
    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var resolving = false
    /// Looking up a pasted PR; cancelled when another source is picked or the popover closes.
    @State private var resolveTask: Task<Void, Never>?
    /// The worktree being removed.
    @State private var removing: String?
    /// The worktree showing "Remove worktree?", the one whose removal failed, and why.
    @State private var confirming: String?
    @State private var failed: String?
    @State private var removeError: String?

    private var reviews: ReviewCenter { model.reviews }
    private var source: ReviewSource { reviews.states[session.id]?.source ?? .sessionFolder }
    private var others: [Worktree] { worktrees.filter { $0.path != own } }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            section("Session folder")
            SourceRow(icon: "folder", title: "Session folder", detail: tilde(session.workingDirectory),
                      checked: source == .sessionFolder) { pick(.sessionFolder) }

            divider
            section("Worktrees")
            if loadingTrees {
                note("Loading…")
            } else if others.isEmpty {
                note("No other worktrees")
            } else {
                ForEach(others, id: \.path) { worktreeRow($0) }
            }

            divider
            section("Pull requests")
            pullRequestSection

            divider
            SourceRow(icon: "folder.badge.plus", title: "Choose Folder…", detail: nil, checked: false) {
                dismiss()
                Task { chooseFolder() }  // after the popover closes
            }
        }
        .padding(.vertical, 6)
        .frame(width: 380)
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .task { await loadWorktrees() }
        .task { await loadPullRequests() }
        .onDisappear { resolveTask?.cancel() }
    }

    // MARK: - Worktrees

    @ViewBuilder
    private func worktreeRow(_ tree: Worktree) -> some View {
        let removable = tree.path.hasPrefix(simulDir + "/")
        SourceRow(icon: "arrow.triangle.branch", title: tree.branch ?? URL(fileURLWithPath: tree.path).lastPathComponent,
                  detail: tilde(tree.path), checked: source == .folder(tree.path)) {
            pick(.folder(tree.path))
        } accessory: {
            if removing == tree.path {
                Text("Removing…").foregroundStyle(palette.secondaryText)
            } else if removable, confirming != tree.path {
                Button { confirming = tree.path; failed = nil } label: { Image(systemName: "trash") }
                    .buttonStyle(.simul(.quiet))
                    .help("Remove this worktree Simul made")
            }
        }
        if confirming == tree.path {
            HStack(spacing: 6) {
                Text("Remove worktree?").foregroundStyle(palette.secondaryText)
                Spacer()
                Button("Remove") { remove(tree.path, force: false) }.buttonStyle(.primer(height: 24))
                Button("Cancel") { confirming = nil }.buttonStyle(.simul(.quiet))
            }
            .padding(.horizontal, 14).padding(.vertical, 3)
        }
        if failed == tree.path, let removeError {
            HStack(spacing: 6) {
                Text(removeError).foregroundStyle(palette.removedText).lineLimit(2)
                Spacer()
                if removeError == Self.localChanges {
                    Button("Remove anyway") { remove(tree.path, force: true) }.buttonStyle(.primer(height: 24))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 3)
        }
    }

    private static let localChanges = "This PR's worktree has local changes"

    private func remove(_ path: String, force: Bool) {
        confirming = nil
        failed = nil
        // Off the folder it's about to lose first: a folder in (or linked to) it, or a PR reviewed in it.
        let root = reviews.snapshots[session.id]?.root
        let isCurrent = source == .folder(path) || (source != .sessionFolder && root.map(Self.real) == Self.real(path))
        if isCurrent { reviews.setSource(session.id, .sessionFolder) }
        removing = path
        Task {
            defer { removing = nil }
            do {
                try await reviews.removeSimulWorktree(path, for: session.id, force: force)
                await loadWorktrees()
            } catch {
                removeError = Self.message(error)
                failed = path
            }
        }
    }

    private func loadWorktrees() async {
        let trees = await reviews.worktrees(for: session.id)
        // Resolved, as git lists them.
        own = ReviewSource.containing(session.workingDirectory, in: trees)?.path
        let dir = Paths.reviewWorktrees.standardized.path
        simulDir = Self.real(dir)
        if worktrees != trees { worktrees = trees }
        loadingTrees = false
    }

    // MARK: - Pull requests

    @ViewBuilder
    private var pullRequestSection: some View {
        if prError == ReviewGit.ghUnavailable {
            note(ReviewGit.ghUnavailable)
        } else {
            TextField("Paste a PR link or number", text: $pasted)
                .simulField()
                .disabled(resolving)
                .onSubmit(resolvePasted)
                .padding(.horizontal, 12).padding(.vertical, 4)
            if let pasteError { note(pasteError, error: true) }
            if let prError {
                note(prError, error: true)
            } else if let pullRequests {
                if pullRequests.isEmpty {
                    note("No open pull requests by you or waiting for your review")
                } else if pullRequests.count > 8 {
                    ScrollView { prRows(pullRequests) }.frame(height: 220)
                } else {
                    prRows(pullRequests)
                }
            } else {
                note("Loading…")
            }
        }
    }

    private func prRows(_ list: [PullRequest]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(list) { pr in
                let target = ReviewSource.pullRequest(repo: pr.baseRepo, number: pr.number)
                SourceRow(icon: "arrow.triangle.pull", title: "#\(pr.number) \(pr.title) — \(pr.author)",
                          detail: nil, checked: source == target) { pick(target) }
                    .help(pr.url)
            }
        }
    }

    private func loadPullRequests() async {
        do {
            pullRequests = try await reviews.pullRequests(for: session.id)
        } catch {
            prError = Self.message(error)
        }
    }

    private func resolvePasted() {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !resolving else { return }
        resolving = true
        pasteError = nil
        resolveTask = Task {
            defer { resolving = false }
            do {
                let pr = try await reviews.pullRequest(text, for: session.id)
                guard !Task.isCancelled else { return }
                pick(.pullRequest(repo: pr.baseRepo, number: pr.number))
            } catch {
                if !Task.isCancelled { pasteError = Self.message(error) }
            }
        }
    }

    // MARK: - Pieces

    private func pick(_ new: ReviewSource) {
        resolveTask?.cancel()
        dismiss()
        if new != source { reviews.setSource(session.id, new) }
    }

    /// The path with symlinks resolved; as written when it is gone.
    private static func real(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardized.path
        return realpath(standard, nil).map { defer { free($0) }; return String(cString: $0) } ?? standard
    }

    /// As GitHub's ActionList group headings.
    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 4)
    }

    private func note(_ text: String, error: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(error ? palette.removedText : palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    /// Full width, as the panel's own.
    private var divider: some View {
        Rectangle().fill(palette.cardBorder).frame(height: 1).padding(.vertical, 6)
    }

    private func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    static func message(_ error: Error) -> String {
        switch error as? ReviewGitError {
        case let .notARepository(path): "Not a git repository: \(path)"
        case let .gitFailed(message): message
        case nil: error.localizedDescription
        }
    }
}

/// A picker row, as GitHub's single-select ActionList: a check on the current source,
/// icon, title, a dim detail (a path).
private struct SourceRow<Accessory: View>: View {
    @Environment(\.reviewPalette) private var palette
    let icon: String
    let title: String
    let detail: String?
    let checked: Bool
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovered = false

    init(icon: String, title: String, detail: String?, checked: Bool, action: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.checked = checked
        self.action = action
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                        .opacity(checked ? 1 : 0)
                        .accessibilityHidden(!checked)
                    Image(systemName: icon).frame(width: 16).foregroundStyle(palette.secondaryText)
                    Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                    if let detail {
                        Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? .isSelected : [])
            accessory()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? palette.rowHover : .clear))
        .padding(.horizontal, 6)
        .onHover { if hovered != $0 { hovered = $0 } }
    }
}
