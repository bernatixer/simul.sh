import Foundation

/// How findings from reviews, checks and the pull request update one list.
/// Pure functions over [Finding], so every rule is testable.
enum FindingLedger {
    /// "F1", "F2"…: one more than the highest so far.
    static func nextID(_ findings: [Finding]) -> String {
        let used = findings.compactMap { Int($0.id.dropFirst()) }
        return "F\((used.max() ?? 0) + 1)"
    }

    // MARK: Reviews

    struct ReviewMerge: Equatable {
        var findings: [Finding]
        var new = 0
        var still = 0
        var verified = 0
        /// Verified gone before, found again.
        var cameBack: [String] = []
    }

    /// Adds reviewers' reports for `round`. A finding a reviewer raises again
    /// stays (or goes back to) open; one it doesn't raise, that was open or
    /// fixed, is verified gone. Only reviewer findings (no `key`) take part.
    /// `verifyUnmentioned`: every reviewer reported, so silence means gone;
    /// otherwise only findings a reviewer confirms fixed are verified.
    static func mergeReviews(_ findings: [Finding], reports: [(source: String, report: ReviewerReport)],
                             round: Int, verifyUnmentioned: Bool = true) -> ReviewMerge {
        var out = ReviewMerge(findings: findings)
        guard !reports.isEmpty else { return out }
        let before = Set(findings.map(\.id))
        var raised: Set<String> = []
        var resolvedBy: [String: String] = [:]
        for (source, report) in reports {
            for id in report.resolved { resolvedBy[id] = resolvedBy[id] ?? source }
            var taken: Set<String> = []  // one item of a report per finding: two of them are two problems
            for item in report.findings {
                if let index = out.findings.firstIndex(where: { $0.key == nil && !taken.contains($0.id)
                    && (($0.id == item.id && item.id != nil) || matches($0, item)) }) {
                    taken.insert(out.findings[index].id)
                    var f = out.findings[index]
                    if !f.sources.contains(source) { f.sources.append(source) }
                    if item.severity > f.severity { f.severity = item.severity }
                    if before.contains(f.id), !raised.contains(f.id) {
                        switch f.status {
                        case .verified:
                            f.status = .open
                            f.cameBack = true
                            f.note = "Found again after it was verified gone"
                            out.cameBack.append(f.id)
                        case .open, .fixing, .fixed:
                            if f.status == .fixed { f.note = "Still there after the fix" }
                            f.status = .open
                            out.still += 1
                        case .skipped, .yours:
                            break
                        }
                        f.updatedRound = round
                    }
                    raised.insert(f.id)
                    out.findings[index] = f
                } else {
                    let f = Finding(id: nextID(out.findings), key: nil, sources: [source], severity: item.severity,
                                    title: item.title, detail: item.detail, path: item.path, line: item.line,
                                    raisedRound: round, updatedRound: round)
                    raised.insert(f.id)
                    out.findings.append(f)
                    out.new += 1
                }
            }
        }
        for index in out.findings.indices {
            let f = out.findings[index]
            guard f.key == nil, before.contains(f.id), !raised.contains(f.id),
                  [.open, .fixing, .fixed].contains(f.status), verifyUnmentioned || resolvedBy[f.id] != nil else { continue }
            out.findings[index].status = .verified
            out.findings[index].updatedRound = round
            out.findings[index].note = resolvedBy[f.id].map { "Confirmed fixed by \($0)" } ?? "Not found again"
            out.verified += 1
        }
        return out
    }

    /// The same problem: the same file and nearby lines, or (without a
    /// place) much the same title.
    static func matches(_ f: Finding, _ item: ReviewerReport.Item) -> Bool {
        let similar = titleSimilarity(f.title, item.title)
        switch (f.path, item.path) {
        case let (a?, b?):
            guard a == b else { return false }
            if let l1 = f.line, let l2 = item.line, abs(l1 - l2) <= 3 { return similar >= 0.2 }
            return similar >= 0.5
        case (nil, nil):
            return similar >= 0.6
        default:
            return similar >= 0.75
        }
    }

    /// Shared words over all words (4+ letters, common ones left out).
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let common: Set<String> = ["when", "with", "that", "this", "from", "into", "than", "then", "does", "have",
                                   "without", "there", "their", "which", "after", "before", "should", "could"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 && !common.contains($0) })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty || !y.isEmpty else { return a.lowercased() == b.lowercased() ? 1 : 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    // MARK: Checks

    /// A check command's result. Failing: one high finding with the output's
    /// tail. Passing: its finding is verified gone.
    static func mergeCheck(_ findings: [Finding], command: String, passed: Bool, output: String, round: Int) -> [Finding] {
        let key = "check:" + command
        var findings = findings
        let index = findings.firstIndex { $0.key == key }
        if passed {
            if let index, [.open, .fixing, .fixed].contains(findings[index].status) {
                findings[index].status = .verified
                findings[index].note = "Passes now"
                findings[index].updatedRound = round
            }
            return findings
        }
        let title = "`\(command.count > 60 ? String(command.prefix(57)) + "…" : command)` fails"
        if let index {
            findings[index].detail = output
            findings[index].updatedRound = round
            if findings[index].status != .skipped, findings[index].status != .yours { findings[index].status = .open }
        } else {
            findings.append(Finding(id: nextID(findings), key: key, sources: ["Checks"], severity: .high, title: title,
                                    detail: output, raisedRound: round, updatedRound: round))
        }
        return findings
    }

    // MARK: Pull request

    struct FeedbackMerge: Equatable {
        var findings: [Finding]
        /// New comments from people, for the user.
        var people: [String] = []
        var new = 0
        var verified = 0
    }

    /// The PR's failing checks and open review threads. Bots' threads are for
    /// the agent; people's are the user's (`yours`) until they hand them over.
    static func mergeFeedback(_ findings: [Finding], failing: [PullRequestStatus.Check], threads: [ReviewThread],
                              round: Int) -> FeedbackMerge {
        var out = FeedbackMerge(findings: findings)
        let failingKeys = Set(failing.map { "ci:" + $0.name })
        for check in failing {
            let key = "ci:" + check.name
            if let index = out.findings.firstIndex(where: { $0.key == key }) {
                if [.verified, .fixed, .fixing].contains(out.findings[index].status) {
                    out.findings[index].status = .open
                    out.findings[index].note = "Failing again"
                }
                out.findings[index].url = check.url
                out.findings[index].updatedRound = round
            } else {
                out.findings.append(Finding(id: nextID(out.findings), key: key, sources: ["CI"], severity: .high,
                                            title: "CI: \(check.name) fails",
                                            detail: "Read the failing job's log (`gh run view --log-failed`, or the link).",
                                            url: check.url, raisedRound: round, updatedRound: round))
                out.new += 1
            }
        }
        for index in out.findings.indices where out.findings[index].key?.hasPrefix("ci:") == true
            && !failingKeys.contains(out.findings[index].key!) && [.open, .fixing, .fixed].contains(out.findings[index].status) {
            out.findings[index].status = .verified
            out.findings[index].note = "Passes on the latest push"
            out.findings[index].updatedRound = round
            out.verified += 1
        }

        // Outdated (the lines moved) isn't resolved: only new outdated threads are left out.
        let openKeys = Set(threads.filter { !$0.isResolved }.map { "thread:" + $0.id })
        for thread in threads where !thread.isResolved && !thread.isOutdated {
            let key = "thread:" + thread.id
            if out.findings.contains(where: { $0.key == key }) { continue }
            var f = Finding(id: nextID(out.findings), key: key, sources: [thread.author], severity: .medium,
                            title: firstLine(thread.body), detail: String(thread.body.prefix(2000)),
                            path: thread.path, line: thread.line, url: thread.url,
                            raisedRound: round, updatedRound: round)
            if !thread.authorIsBot {
                f.status = .yours
                out.people.append(f.id)
            }
            out.findings.append(f)
            out.new += 1
        }
        for index in out.findings.indices where out.findings[index].key?.hasPrefix("thread:") == true
            && !openKeys.contains(out.findings[index].key!) && !out.findings[index].isSettled {
            out.findings[index].status = .verified
            out.findings[index].note = "Resolved on GitHub"
            out.findings[index].updatedRound = round
            out.verified += 1
        }
        return out
    }

    static func firstLine(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let bare = line.replacingOccurrences(of: #"^[#>*\-\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        let text = bare.isEmpty ? "Comment" : bare
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    // MARK: Fixing

    /// Open findings at or above `atLeast` (fixed without asking), and the
    /// lower ones (asked about, or skipped).
    static func select(_ findings: [Finding], atLeast: Finding.Severity) -> (auto: [String], lower: [String]) {
        let open = findings.filter(\.isOpenForFix)
        return (open.filter { $0.severity >= atLeast }.map(\.id), open.filter { $0.severity < atLeast }.map(\.id))
    }

    static func set(_ findings: [Finding], _ ids: [String], status: Finding.Status, note: String? = nil,
                    round: Int? = nil, fixedIn: String? = nil) -> [Finding] {
        let ids = Set(ids)
        return findings.map { f in
            guard ids.contains(f.id) else { return f }
            var f = f
            f.status = status
            if let note { f.note = note }
            if let round { f.updatedRound = round }
            if let fixedIn { f.fixedIn = fixedIn }
            return f
        }
    }

    /// Findings still in the way: open (or being fixed) at or above `atLeast`.
    static func blocking(_ findings: [Finding], atLeast: Finding.Severity) -> [Finding] {
        findings.filter { [.open, .fixing].contains($0.status) && $0.severity >= atLeast }
    }
}
