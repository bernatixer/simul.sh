import Foundation

/// What a reviewer session writes:
/// `{"findings":[{"id"?,"severity","title","detail","path"?,"line"?}],"resolved":["F1"]}`.
/// Read leniently: an entry without a title is dropped, an unknown severity
/// is medium, a path outside the folder is dropped.
struct ReviewerReport: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var id: String?
        var severity: Finding.Severity
        var title: String
        var detail: String
        var path: String?
        var line: Int?
    }

    var findings: [Item]
    /// Earlier findings (by id) the reviewer confirms are fixed.
    var resolved: [String]

    struct Problem: Error, Equatable { let message: String }

    static let maxBytes = 1_000_000
    static let maxFindings = 40

    static func parse(_ data: Data) throws -> ReviewerReport {
        guard data.count <= maxBytes else { throw Problem(message: "the file is over 1 MB") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem(message: "it isn't a JSON object")
        }
        guard let list = root["findings"] as? [Any] else { throw Problem(message: "\"findings\" is missing or not a list") }
        var items: [Item] = []
        for case let entry as [String: Any] in list.prefix(maxFindings) {
            guard let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            let severity = (entry["severity"] as? String).flatMap { Finding.Severity(rawValue: $0.lowercased()) } ?? .medium
            let detail = (entry["detail"] as? String) ?? (entry["why"] as? String) ?? ""
            let line = (entry["line"] as? Int) ?? (entry["line"] as? String).flatMap(Int.init)
            items.append(Item(id: entry["id"] as? String, severity: severity, title: clip(title, 160), detail: clip(detail, 1500),
                              path: (entry["path"] as? String).flatMap(cleanPath), line: line.flatMap { $0 > 0 ? $0 : nil }))
        }
        let resolved = (root["resolved"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ReviewerReport(findings: items, resolved: resolved)
    }

    /// Relative, inside the folder, no "./".
    static func cleanPath(_ path: String) -> String? {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") { p.removeFirst(2) }
        guard !p.isEmpty, !p.hasPrefix("/"), !p.hasPrefix("~"), !p.split(separator: "/").contains("..") else { return nil }
        return p
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
}

/// What a verify stage's agent writes: `{"status":"ok"|"problem","summary":"…"}`.
struct VerifyReport: Equatable, Sendable {
    var ok: Bool
    var summary: String

    static func parse(_ data: Data) throws -> VerifyReport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = (root["status"] as? String)?.lowercased(), ["ok", "problem"].contains(status) else {
            throw ReviewerReport.Problem(message: "expected {\"status\":\"ok\" or \"problem\",\"summary\":\"…\"}")
        }
        return VerifyReport(ok: status == "ok", summary: ReviewerReport.clip((root["summary"] as? String) ?? "", 600))
    }
}

// MARK: - GitHub

/// `gh pr view --json` with `ghFields`.
struct PullRequestStatus: Equatable, Sendable {
    struct Check: Equatable, Sendable {
        enum State: String, Sendable { case pending, passed, failed, skipped }
        var name: String
        var state: State
        var url: String?
    }

    var number: Int
    var url: String
    /// OPEN, MERGED or CLOSED.
    var state: String
    var isDraft: Bool
    var headSHA: String
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil when nothing requires review.
    var reviewDecision: String?
    var mergeCommit: String?
    var baseRef: String
    var checks: [Check]
    /// The PR's branch.
    var headRef = ""

    static let ghFields = "number,url,state,isDraft,headRefOid,headRefName,baseRefName,reviewDecision,mergeCommit,statusCheckRollup"

    var isMerged: Bool { state == "MERGED" }
    var isClosed: Bool { state == "CLOSED" }
    var checksFinished: Bool { !checks.contains { $0.state == .pending } }
    var failing: [Check] { checks.filter { $0.state == .failed } }
    /// Approved, or nothing asks for approval.
    var approved: Bool { reviewDecision == nil || reviewDecision == "" || reviewDecision == "APPROVED" }
    /// "owner/name" from the URL.
    var repo: String? {
        guard let range = url.range(of: "github.com/") else { return nil }
        let parts = url[range.upperBound...].split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    static func decode(ghJSON data: Data) throws -> PullRequestStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = root["number"] as? Int, let url = root["url"] as? String else {
            throw ReviewerReport.Problem(message: "unexpected reply from gh pr view")
        }
        var checks: [Check] = []
        var seen: Set<String> = []
        for case let c as [String: Any] in (root["statusCheckRollup"] as? [Any]) ?? [] {
            let name = (c["name"] as? String) ?? (c["context"] as? String) ?? "check"
            // Re-runs list a job more than once; the first is the latest.
            guard seen.insert(name).inserted else { continue }
            let state: Check.State
            if c["__typename"] as? String == "StatusContext" || c["context"] != nil {
                switch (c["state"] as? String ?? "").uppercased() {
                case "SUCCESS": state = .passed
                case "FAILURE", "ERROR": state = .failed
                default: state = .pending
                }
            } else if (c["status"] as? String ?? "").uppercased() != "COMPLETED" {
                state = .pending
            } else {
                switch (c["conclusion"] as? String ?? "").uppercased() {
                case "SUCCESS": state = .passed
                case "NEUTRAL", "SKIPPED", "CANCELLED", "STALE": state = .skipped
                default: state = .failed
                }
            }
            checks.append(Check(name: name, state: state, url: (c["detailsUrl"] as? String) ?? (c["targetUrl"] as? String)))
        }
        return PullRequestStatus(number: number, url: url, state: (root["state"] as? String) ?? "OPEN",
                                 isDraft: (root["isDraft"] as? Bool) ?? false, headSHA: (root["headRefOid"] as? String) ?? "",
                                 reviewDecision: root["reviewDecision"] as? String,
                                 mergeCommit: (root["mergeCommit"] as? [String: Any])?["oid"] as? String,
                                 baseRef: (root["baseRefName"] as? String) ?? "", checks: checks,
                                 headRef: (root["headRefName"] as? String) ?? "")
    }
}

/// A review thread on a pull request (GitHub GraphQL).
struct ReviewThread: Equatable, Sendable {
    var id: String
    var isResolved: Bool
    var isOutdated: Bool
    var path: String?
    var line: Int?
    var author: String
    var authorIsBot: Bool
    var body: String
    var url: String?

    static let query = """
        query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){\
        reviewThreads(first:100){nodes{id isResolved isOutdated path line \
        comments(first:1){nodes{body url author{login __typename}}}}}}}}
        """

    static func decode(graphQL data: Data) throws -> [ReviewThread] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pr = ((root["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let nodes = (pr["reviewThreads"] as? [String: Any])?["nodes"] as? [Any] else {
            throw ReviewerReport.Problem(message: "unexpected reply from GitHub's API")
        }
        return nodes.compactMap { node -> ReviewThread? in
            guard let t = node as? [String: Any], let id = t["id"] as? String,
                  let first = ((t["comments"] as? [String: Any])?["nodes"] as? [Any])?.first as? [String: Any] else { return nil }
            let author = first["author"] as? [String: Any]
            let login = (author?["login"] as? String) ?? "someone"
            let isBot = author?["__typename"] as? String == "Bot" || login.hasSuffix("[bot]")
            return ReviewThread(id: id, isResolved: (t["isResolved"] as? Bool) ?? false, isOutdated: (t["isOutdated"] as? Bool) ?? false,
                                path: t["path"] as? String, line: t["line"] as? Int, author: isBot ? login : "@" + login,
                                authorIsBot: isBot, body: (first["body"] as? String) ?? "", url: first["url"] as? String)
        }
    }
}

// MARK: - Fix guard

/// Reads what a fix changed (a unified diff) for things a person should
/// look at: tests deleted, skipped or with fewer assertions.
enum FixGuard {
    struct Result: Equatable {
        var files: [String] = []
        var testWarnings: [String] = []
    }

    static func check(diff: String) -> Result {
        var result = Result()
        var path: String?, deleted = false, added = 0, removed = 0, skips = 0
        func flush() {
            guard let p = path else { return }
            result.files.append(p)
            if isTest(p) {
                if deleted { result.testWarnings.append("deletes \(p)") }
                if skips > 0 { result.testWarnings.append("skips or focuses tests in \(p)") }
                if removed > added { result.testWarnings.append("removes \(removed - added) assertion\(removed - added == 1 ? "" : "s") in \(p)") }
            }
            path = nil; deleted = false; added = 0; removed = 0; skips = 0
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                // "diff --git a/x b/x": the b side (the a side for a deletion is the same).
                if let b = line.range(of: " b/", options: .backwards) { path = String(line[b.upperBound...]) }
            } else if line.hasPrefix("deleted file mode") {
                deleted = true
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                if isAssertion(line) { added += 1 }
                if isSkip(line) { skips += 1 }
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                if isAssertion(line) { removed += 1 }
            }
        }
        flush()
        return result
    }

    static func isTest(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let dirs = lower.split(separator: "/").dropLast()
        return dirs.contains { ["test", "tests", "__tests__", "spec", "specs"].contains($0) }
            || name.hasPrefix("test_") || name.contains("_test.") || name.contains(".test.") || name.contains(".spec.")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift")
    }

    private static func isAssertion(_ line: Substring) -> Bool {
        line.range(of: #"\bassert|expect\(|XCTAssert|#expect|\.should\b|\.to(Be|Equal|Have|Throw)|require\.|\bt\.(Error|Fatal)"#,
                   options: .regularExpression) != nil
    }

    private static func isSkip(_ line: Substring) -> Bool {
        line.range(of: #"\.skip\(|\bxit\(|\bxdescribe\(|\.only\(|@pytest\.mark\.(skip|xfail)|@unittest\.skip|\bt\.Skip\(|#\[ignore\]|XCTSkip|@Disabled|@Ignore\b"#,
                   options: .regularExpression) != nil
    }
}
