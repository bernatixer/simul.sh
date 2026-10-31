import SwiftUI

/// Submits the queued comments as a review of the PR on GitHub: inline where
/// GitHub's diff shows the lines, the rest optionally in the summary. Nothing
/// is posted until Submit is clicked; on failure nothing is marked.
struct SubmitReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reviewPalette) private var palette
    let session: Session
    let pullRequest: PullRequest
    let dismiss: () -> Void

    /// The queued comments, split once when the sheet opens.
    @State private var inline: [ReviewComment] = []
    @State private var outside: [ReviewComment] = []
    @State private var event = ReviewEvent.comment
    @State private var summary = ""
    @State private var selected: Set<UUID> = []
    @State private var outsideIntoSummary = true
    @State private var submitting = false
    @State private var error: String?
    /// Why it can't be submitted, checked when the sheet opens; nil while checking or when it can.
    @State private var blocker: String?
    @State private var checking = true

    private var reviews: ReviewCenter { model.reviews }
    private var hasSummary: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A review needs something to say: a comment that goes, a summary, or a verdict;
    /// requesting changes needs a summary.
    private var canSubmit: Bool {
        let comments = inline.contains { selected.contains($0.id) }
            || outsideIntoSummary && outside.contains { selected.contains($0.id) }
        guard !submitting, !checking, blocker == nil else { return false }
        return event == .requestChanges ? hasSummary : comments || event == .approve || hasSummary
    }

    private var submitHelp: String {
        if let blocker { return blocker }
        if event == .requestChanges && !hasSummary { return "Requesting changes needs a summary" }
        return "Post this review on PR #\(pullRequest.number)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Review PR #\(pullRequest.number): \(pullRequest.title)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Picker("", selection: $event) {
                ForEach(ReviewEvent.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextEditor(text: $summary)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.ink.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.ink.opacity(0.10), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if summary.isEmpty {
                        Text("Summary (optional)").foregroundStyle(palette.secondaryText).padding(.horizontal, 9).padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            comments
            if let error = blocker ?? error {
                Text(verbatim: error)
                    .foregroundStyle(palette.removedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                    .buttonStyle(.simul(.pill))
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(submitting ? "Submitting…" : "Submit review") { submit() }
                    .buttonStyle(.simul(.primary))
                    .disabled(!canSubmit)
                    .help(submitHelp)
            }
        }
        .interactiveDismissDisabled(submitting)
        .onAppear {
            split(local: [])
            // The agent's drafts go only once the user ticks them.
            selected = Set((inline + outside).filter { !$0.byAgent }.map(\.id))
        }
        // Again after each refresh: it may un-block (or block) the submit.
        .task(id: reviews.snapshots[session.id]) {
            checking = true
            do {
                split(local: try await reviews.checkSubmit(session.id).local)
                blocker = nil
            } catch {
                blocker = message(error)
            }
            checking = false
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 460)
        .background(palette.panel)
    }

    @ViewBuilder
    private var comments: some View {
        if inline.isEmpty && outside.isEmpty {
            Text("No queued comments").foregroundStyle(palette.secondaryText)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !inline.isEmpty {
                        section("On the diff")
                        ForEach(inline) { row($0) }
                    }
                    if !outside.isEmpty {
                        HStack {
                            section("Outside the pull request's diff")
                            Spacer()
                            Toggle("Add to summary", isOn: $outsideIntoSummary).toggleStyle(.checkbox)
                        }
                        .padding(.top, inline.isEmpty ? 0 : 6)
                        ForEach(outside) { row($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondaryText)
    }

    /// Checkbox, `path:line`, "by agent" and the comment's first line.
    private func row(_ c: ReviewComment) -> some View {
        let lines = c.endLine > c.line ? "\(c.line)-\(c.endLine)" : "\(c.line)"
        let first = c.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return Toggle(isOn: Binding(get: { selected.contains(c.id) },
                                    set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } })) {
            HStack(spacing: 6) {
                Text(verbatim: "\(c.path):\(lines)").font(.system(size: 11.5, design: .monospaced)).truncationMode(.head)
                if c.byAgent {
                    Text("by agent")
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(palette.ink.opacity(0.08)))
                }
                if c.isOutdated { Text("Outdated").foregroundStyle(palette.secondaryText) }
                Text(verbatim: first).foregroundStyle(palette.secondaryText).truncationMode(.tail)
            }
            .lineLimit(1)
        }
        .toggleStyle(.checkbox)
        .disabled(submitting)
    }

    /// Inline where GitHub's diff shows the lines; local files' comments never are.
    private func split(local: Set<String>) {
        let comments = reviews.submittable(session.id)
        let shown = GitHubReview.shownLines(reviews.snapshots[session.id]?.files.filter { !local.contains($0.path) } ?? [])
        inline = comments.filter { GitHubReview.isInline($0, shown: shown) }
        outside = comments.filter { !GitHubReview.isInline($0, shown: shown) }
    }

    private func message(_ error: Error) -> String {
        if case let .gitFailed(message)? = error as? ReviewGitError { message } else { "\(error)" }
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            do {
                try await reviews.submitReview(session.id, pullRequest: pullRequest, event: event, summary: summary,
                                              selected: selected, outsideIntoSummary: outsideIntoSummary)
                dismiss()
            } catch {
                self.error = message(error)
                submitting = false
            }
        }
    }
}
