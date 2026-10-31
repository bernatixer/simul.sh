import Foundation

enum ReviewPrompt {
    /// The message sent to the agent: numbered comments, each with its
    /// location, the quoted first line and the comment text. `source` names
    /// what's reviewed when it isn't the session folder ("PR #123").
    static func text(for comments: [ReviewComment], root: String, source: String? = nil) -> String {
        let items = comments.enumerated().map { n, c in
            let range = c.endLine == c.line ? "\(c.line)" : "\(c.line)-\(c.endLine)"
            let body = c.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "   \($0)" }.joined(separator: "\n")
            return "\(n + 1). \(c.path):\(range)\n   > \(c.quote)\n\(body)"
        }
        let header = source.map { "Review comments on \($0) (files in \(root)):" }
            ?? "Review comments on your changes (paths relative to \(root)):"
        return header + "\n\n" + items.joined(separator: "\n\n")
    }

    /// Asks the agent to review the changes in `root` against `base` (the
    /// diff is against `point`, their merge base) and write an overview and
    /// line comments as AgentDrafts JSON (version 2) to `path`. `source`
    /// names what's reviewed when it isn't the session folder.
    static func askReview(source: String?, root: String, base: String, point: String, path: String) -> String {
        """
        Review the changes in `\(root)`\(source.map { " (\($0))" } ?? "") against \(base): run `git diff \(point)` there \
        (it includes uncommitted work), and read any new untracked files `git status` lists. Don't edit the code. \
        Moved code and whitespace-only changes aren't changes.
        Write your review ONLY as JSON to `\(path)` (overwrite it if it exists; quote the path, e.g. `cat > "\(path)"`), in this format:
        {"version":2,
         "summary":"Final misses now split by source: live ones alert, backfill ones fail quietly.",
         "risk":{"level":"medium","reason":"Changes how ingestion failures surface."},"effort":2,
         "layers":[{"title":"Workflow logic","note":"Where the error class is picked.","files":["posthog/x.py"]},
          {"title":"Tests","files":["posthog/test_x.py"]}],
         "map":{"lanes":[{"id":"wf","label":"Workflows"}],
          "parts":[{"id":"hydrate","lane":"wf","label":"hydrate_event_reference","note":"picks error class","state":"changed","path":"posthog/x.py","line":91},
            {"id":"live","lane":"wf","label":"live_ingest","state":"untouched"}],
          "edges":[{"from":"live","to":"hydrate","state":"untouched","label":"retry ×3"}]},
         "concerns":[{"severity":"high","title":"Backfill misses go dark","why":"Nothing logs them now, so a broken lookup looks like expired rows.",\
        "at":[{"path":"posthog/x.py","line":99}],"parts":["hydrate"]}],
         "tour":[{"title":"One raise, two outcomes","text":"…","focus":["hydrate"],"path":"posthog/x.py","line":99}],
         "comments":[{"path":"posthog/x.py","line":12,"endLine":14,"body":"…"}]}
        - summary: what the change does, one sentence (under 280 characters).
        - risk: how likely it breaks something, low, medium or high, with a one-line reason (under 120 characters). \
        effort: how hard it is to review, 1 (trivial) to 5 (very hard).
        - layers: 2–6 groups of the diff's files by purpose, in reading order (e.g. data model, logic, API, UI, \
        then tests and docs); title under 40 characters, optional note under 160. Each file in at most one layer; \
        leave out files not worth grouping. Skip layers for tiny changes.
        - map: 2–4 lanes (areas of the code), parts in them (functions, classes, files; 12 or fewer is best), \
        edges for calls or data between parts. Include untouched parts the change depends on or affects. \
        state: added, changed, removed or untouched. Labels and notes under 40 characters, edge labels under 24.
        - concerns: only design-level problems that could break or will hurt later (data, contracts, error handling, \
        concurrency, two sources of truth). Start with the problem, never restate the code, no style. \
        severity: high, medium or low; title under 70 characters, why under 240; "at": 1–3 changed lines. At most 6; none is fine ("concerns":[]).
        - tour: 2–5 steps in reading order, each one change; text under 240 characters.
        - comments: only truly line-level findings, one per comment. Start with the problem; never describe the code. \
        At most 2 short sentences (under 200 characters; over 600 is rejected): the problem, then the fix in the imperative.
        - Every path, line: a file in the diff, path exactly as `git diff --name-only \(point)` prints it or as \
        `git status` lists a new file (relative to `\(root)`, no "./"), and a line that exists in it now. \
        Only untouched parts may point at other files. endLine may be left out for one line. Ids must be unique; \
        lane, from, to, parts and focus name existing ids.
        Then reply "Done" in one line.
        """
    }

    /// Asks the agent to fix what couldn't be imported from its review file.
    static func fixReview(reasons: [String], path: String) -> String {
        "Your review file `\(path)` has problems:\n" + reasons.map { "- \($0)" }.joined(separator: "\n")
            + "\nFix it (in the format you were asked for), then reply \"Done\" in one line."
    }
}
