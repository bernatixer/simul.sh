import Foundation

/// Workflows that ship with Simul. General on purpose: GitHub through `gh`,
/// and whatever test or lint command the user types in.
enum WorkflowTemplates {
    static let all: [Workflow] = [ship, reviewAndFix, reviewPullRequest, watchAfterMerge]

    static func named(_ id: String) -> Workflow? { all.first { $0.id == id } }

    // MARK: Inputs shared by several templates

    private static let reviewers = WorkflowInput(
        "reviewers", "Reviewers", .agents,
        help: "Each gets a fresh session every round, so it never reviews its own fixes.",
        defaultValue: "claude", group: "Review")
    private static let reviewerInstructions = WorkflowInput(
        "reviewerInstructions", "Tell reviewers", .longText,
        help: "Added to every reviewer's prompt.",
        placeholder: "e.g. Use the /review skill. Focus on data loss and error handling.", group: "Review")
    private static let checks = WorkflowInput(
        "checks", "Checks", .command,
        help: "Runs in the folder after each fix; it must exit 0. Leave empty to skip.",
        placeholder: "e.g. npm test && npm run lint", group: "Fix")
    private static let fixAtLeast = WorkflowInput(
        "fixAtLeast", "Fix without asking", .severity,
        help: "Findings at this severity or above are fixed straight away.", defaultValue: "medium", group: "Fix")
    private static let askBelow = WorkflowInput(
        "askBelow", "Ask me about lower ones", .toggle,
        help: "Off: lower findings are skipped and listed.", defaultValue: "true", group: "Fix")

    // MARK: Ship a change

    static let ship = Workflow(
        id: "ship-change",
        name: "Ship a change",
        summary: "Review, fix and check your change, push it as a draft PR, fix CI and bot comments, repeat until clean, then merge with your OK.",
        inputs: [
            WorkflowInput("pr", "Pull request", .pullRequest,
                          help: "Leave empty to open one from this branch as a draft.",
                          placeholder: "Number or link (optional)"),
            reviewers, reviewerInstructions, checks, fixAtLeast, askBelow,
            WorkflowInput("maxRounds", "Rounds at most", .number, defaultValue: "4", group: WorkflowInput.advanced),
            WorkflowInput("merge", "How to merge", .text,
                          help: "Told to the agent once you approve.",
                          defaultValue: "gh pr merge --squash --delete-branch", group: WorkflowInput.advanced),
            WorkflowInput("mergeUpTo", "Merge without asking up to", .number,
                          help: "Changes of at most this many lines merge without asking, once nothing blocks them (approved, or no approval required). 0: always ask.",
                          defaultValue: "0", group: "Merge"),
            WorkflowInput("watch", "Then watch after merge", .toggle,
                          help: "Starts Watch after merge when this finishes.", defaultValue: "false", group: "After merge"),
            WorkflowInput("verify", "What to check after merge", .longText,
                          help: "For Watch after merge: what “working” looks like, and where the agent can see it.",
                          placeholder: "e.g. The /health endpoint reports the new version.", group: "After merge"),
        ],
        loop: Workflow.Loop(stages: [
            WorkflowStage(.review, "Review", reviewers: "{reviewers}", instructions: "{reviewerInstructions}"),
            WorkflowStage(.fix, "Fix", fixAtLeast: "{fixAtLeast}", askBelow: "{askBelow}"),
            WorkflowStage(.check, "Run checks", command: "{checks}", timeoutMinutes: 30, skipUnless: "checks"),
            WorkflowStage(.agent, "Push", prompt: """
                Commit your changes with a short, clear message (skip this if there's nothing to commit) and push the \
                branch. Never push to the repository's default branch: if you're on it, create a branch named after the \
                change first. If the branch has no pull request yet, open one as a draft with `gh pr create --draft --fill`. \
                Don't merge anything. Reply with the pull request's URL in one line.
                """),
            WorkflowStage(.wait, "Wait for CI", waitFor: .checks, timeoutMinutes: 120),
            WorkflowStage(.feedback, "Read CI and comments"),
        ], maxRounds: "{maxRounds}"),
        after: [
            WorkflowStage(.agent, "Mark ready", prompt: """
                Mark {pr} ready for review if it's still a draft (`gh pr ready`). Don't merge it. Reply "Done" in one line.
                """),
            WorkflowStage(.wait, "Wait for approval", waitFor: .approved),
            WorkflowStage(.gate, "Your OK to merge", question: "Merge {pr}? It's reviewed, checked and approved.",
                          skipIfDiffAtMost: "mergeUpTo"),
            WorkflowStage(.agent, "Merge", prompt: """
                Merge {pr}: {merge}. If it can't merge (conflicts, failing or pending checks), don't force it: \
                say what's blocking in one line.
                """),
            WorkflowStage(.wait, "Wait for merge", waitFor: .merged, timeoutMinutes: 240),
        ],
        then: "watch-merge", thenIf: "watch")

    // MARK: Review and fix (local)

    static let reviewAndFix = Workflow(
        id: "review-fix",
        name: "Review and fix",
        summary: "Fresh reviewers check your change, the agent fixes what they find and runs your checks, until nothing is left. Nothing is pushed.",
        inputs: [reviewers, reviewerInstructions, checks, fixAtLeast, askBelow,
                 WorkflowInput("maxRounds", "Rounds at most", .number, defaultValue: "3", group: WorkflowInput.advanced)],
        loop: Workflow.Loop(stages: [
            WorkflowStage(.review, "Review", reviewers: "{reviewers}", instructions: "{reviewerInstructions}"),
            WorkflowStage(.fix, "Fix", fixAtLeast: "{fixAtLeast}", askBelow: "{askBelow}"),
            WorkflowStage(.check, "Run checks", command: "{checks}", timeoutMinutes: 30, skipUnless: "checks"),
        ], maxRounds: "{maxRounds}"))

    // MARK: Review a pull request

    static let reviewPullRequest = Workflow(
        id: "review-pr",
        name: "Review a pull request",
        summary: "Fresh reviewers go over someone's PR, and again each time they push, until it's merged or closed. Findings come to you as drafts; nothing is posted.",
        inputs: [
            WorkflowInput("pr", "Pull request", .pullRequest, placeholder: "Number or link", required: true),
            reviewers, reviewerInstructions,
            WorkflowInput("maxRounds", "Rounds at most", .number, defaultValue: "10", group: WorkflowInput.advanced),
        ],
        loop: Workflow.Loop(stages: [
            WorkflowStage(.wait, "Wait for new commits", waitFor: .newCommit),
            WorkflowStage(.review, "Review", reviewers: "{reviewers}", instructions: "{reviewerInstructions}"),
            WorkflowStage(.gate, "Your review", question: "The review of {pr} is ready."),
        ], maxRounds: "{maxRounds}"))

    // MARK: Watch after merge

    static let watchAfterMerge = Workflow(
        id: "watch-merge",
        name: "Watch after merge",
        summary: "Waits for the PR to merge and deploy, then has the agent check it a few times. It reports; it never changes anything.",
        inputs: [
            WorkflowInput("pr", "Pull request", .pullRequest,
                          help: "Leave empty for this branch's pull request.", placeholder: "Number or link (optional)"),
            WorkflowInput("verify", "What to check", .longText,
                          help: "What “working” looks like, and where the agent can see it.",
                          placeholder: "e.g. The /health endpoint reports the new version, and the error rate on the dashboard didn't rise.",
                          required: true),
            WorkflowInput("deployed", "Deployed when", .command,
                          help: "Simul runs this every few minutes after the merge until it exits 0. {merge_sha} is the merge commit. Leave empty to check right after the merge.",
                          placeholder: "e.g. curl -fs https://example.com/version | grep -q {merge_sha}"),
            WorkflowInput("again", "Check again after (hours)", .number, defaultValue: "2", group: "Schedule"),
            WorkflowInput("last", "And a last time after (hours)", .number, defaultValue: "24", group: "Schedule"),
        ],
        before: [
            WorkflowStage(.wait, "Wait for merge", waitFor: .merged),
            WorkflowStage(.wait, "Wait for deploy", command: "{deployed}", waitFor: .command, timeoutMinutes: 180,
                          skipUnless: "deployed"),
            WorkflowStage(.verify, "Check it", prompt: "{pr} was merged and deployed. Check that it works: {verify}"),
            WorkflowStage(.wait, "Wait", waitFor: .time, hours: "{again}", skipUnless: "again"),
            WorkflowStage(.verify, "Check again", prompt: "Check again that {pr} still works: {verify}", skipUnless: "again"),
            WorkflowStage(.wait, "Wait", waitFor: .time, hours: "{last}", skipUnless: "last"),
            WorkflowStage(.verify, "Last check", prompt: "One last check that {pr} still works: {verify}", skipUnless: "last"),
        ])
}
