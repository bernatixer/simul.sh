import Foundation

/// One workflow running on one session. Holds a copy of the workflow as it
/// was started, so editing the file later doesn't change a run midway.
struct WorkflowRun: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var workflow: Workflow
    /// The session whose agent does the work (and where the run shows).
    var sessionID: UUID
    /// Where checks run and reviewers look.
    var folder: String
    var inputs: [String: String]
    let createdAt: Date
    var updatedAt: Date

    var status: Status = .active
    var position: StagePosition
    /// 0 before the loop; 1… inside it and after it (the last round).
    var round = 0
    var stage = StageState()
    /// What it's doing now, in a sentence ("Waiting for CI on #12: 3 of 5 done").
    var activity = ""
    /// What it needs from the user; nil when it needs nothing.
    var ask: Ask?
    var findings: [Finding] = []
    var events: [Event] = []
    var pullRequest: PullRequestRef?
    /// Pause at the next stage instead of starting it.
    var pauseRequested = false
    /// The head the last review looked at (review rounds after the first
    /// focus on what changed since).
    var lastReviewedHead: String?
    /// Lines changed after the first round's fixes, to notice the diff growing.
    var baselineDiffLines: Int?
    var diffWarned = false
    /// This round's fix stage sent something (a round without fixes ends the loop).
    var fixesThisRound = false
    /// Failing checks sent back to this round's fix.
    var checkRetries = 0
    var finishedAt: Date?
    /// Rounds added past the workflow's maximum ("One more round").
    var extraRounds = 0
    /// Every session the run started (reviewers); removed with the run.
    var helperSessions: [UUID] = []

    enum Status: String, Codable, Sendable {
        case active, needsYou, paused, done, stopped
        var isLive: Bool { self == .active || self == .needsYou || self == .paused }
    }

    /// What the current stage is waiting on; reset when a stage starts.
    struct StageState: Codable, Equatable, Sendable {
        /// Names this visit to the stage; async work drops its result if it changed.
        var token = UUID()
        var startedAt = Date()
        /// Waiting for the session to be free to take it.
        var pendingPrompt: String?
        /// When the session first wasn't ready for it (to tell the user after a while).
        var pendingSince: Date?
        /// HEAD when the stage started (a fix's commit; what a review saw).
        var headAtStart: String?
        /// A prompt was sent to the session's agent; its next turn is the stage's work.
        var promptSentAt: Date?
        /// That turn started (so its end finishes the stage).
        var turnStarted = false
        var reviewers: [Reviewer] = []
        var nextPollAt: Date?
        /// A look (gh, a command) under way since; nil when none is.
        var lookingSince: Date?
        var deadline: Date?
        var pollFailures = 0
        /// Working tree before a fix (`git stash create` or HEAD), to see what the fix changed.
        var beforeTree: String?
        /// Findings this fix stage sent.
        var fixing: [String] = []
        /// Where the verify agent writes its result.
        var resultFile: String?
    }

    struct Reviewer: Codable, Equatable, Sendable {
        var agentID: String
        var sessionID: UUID
        var file: String
        var state: State = .working
        var nudges = 0
        /// Its first turn started (it isn't stuck on a dialog).
        var started = false
        /// When its session was started (for "it hasn't started" after a while).
        var createdAt = Date()
        enum State: String, Codable, Sendable { case working, done, failed }
    }

    struct PullRequestRef: Codable, Equatable, Sendable {
        var number: Int
        var url: String
        /// "owner/name".
        var repo: String
    }

    init(id: UUID = UUID(), workflow: Workflow, sessionID: UUID, folder: String, inputs: [String: String], now: Date = Date()) {
        self.id = id
        self.workflow = workflow
        self.sessionID = sessionID
        self.folder = folder
        self.inputs = inputs
        createdAt = now
        updatedAt = now
        position = workflow.first(from: .before) ?? StagePosition(part: .before, index: 0)
        if position.part != .before { round = 1 }
    }

    var currentStage: WorkflowStage? { workflow.stage(at: position) }

    var maxRounds: Int {
        (workflow.loop.flatMap { WorkflowText.number($0.maxRounds, inputs) }.map { max(1, Int($0)) } ?? 1) + extraRounds
    }

    var isLive: Bool { status.isLive }

    /// A PR workflow with nothing to fix: the PR is someone else's, so
    /// reviewers look at it in its own worktree.
    var reviewsSomeoneElsesPR: Bool {
        workflow.usesPullRequest && !workflow.allPositions.contains { workflow.stage(at: $0)?.kind == .fix }
    }

    /// Sessions the run started for itself (reviewers), still listed.
    var reviewerSessionIDs: [UUID] { stage.reviewers.map(\.sessionID) }
}

// MARK: - Findings

/// One problem from any source, followed until it's verified gone, skipped
/// or handed to the user.
struct Finding: Codable, Equatable, Sendable, Identifiable {
    enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case high, medium, low
        var rank: Int { switch self { case .high: 3; case .medium: 2; case .low: 1 } }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    enum Status: String, Codable, Sendable {
        /// Needs fixing.
        case open
        /// Sent to the agent; its turn hasn't ended.
        case fixing
        /// The agent fixed it; the next review or check confirms.
        case fixed
        /// A later review or check no longer finds it.
        case verified
        /// Left alone, by a rule or by the user (see `note`).
        case skipped
        /// For the user to handle: a person's comment, or something only they can judge.
        case yours
    }

    /// "F1", "F2"… in the order they were found.
    var id: String
    /// Sources match on this when it's set (a check, a CI job, a PR thread);
    /// reviewers' findings match by place and title instead.
    var key: String?
    var sources: [String]
    var severity: Severity
    var title: String
    var detail: String
    var path: String?
    var line: Int?
    var url: String?
    var status: Status = .open
    var raisedRound: Int
    var updatedRound: Int
    /// Short commit the fix landed in, when it was committed.
    var fixedIn: String?
    /// Why it was skipped, or what verified it.
    var note: String?
    /// It was verified gone, then found again.
    var cameBack = false

    var isOpenForFix: Bool { status == .open }
    var isSettled: Bool { status == .verified || status == .skipped }
}

// MARK: - Asks

/// What the run needs from the user, with the buttons that answer it.
struct Ask: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A gate stage's question.
        case confirm
        /// Lower-severity findings: fix some or skip them.
        case chooseFindings
        /// The prompt is in the session's input box; Return wasn't pressed.
        case pressReturn
        /// Comments from people on the pull request.
        case peopleComments
        /// A stage failed or something looks wrong.
        case problem
        /// The loop ran its rounds with findings still open.
        case outOfRounds
        /// A finding came back after it was verified gone.
        case cameBack
        /// A review of someone's PR is ready to look at.
        case reviewReady
    }

    enum Action: String, Codable, Sendable {
        case `continue`, stop, retry, skip, oneMoreRound, leaveLoop, fixSelected, skipAll
        case openSession, agentHandles, iHandle, openReview
    }

    var kind: Kind
    var title: String
    var detail: String
    var actions: [Action]
    /// For chooseFindings and peopleComments: which findings.
    var findings: [String] = []
    /// The session Open session opens (default: the run's).
    var session: UUID?
}

extension Ask.Action {
    var label: String {
        switch self {
        case .continue: "Continue"
        case .stop: "Stop run"
        case .retry: "Try again"
        case .skip: "Skip this step"
        case .oneMoreRound: "One more round"
        case .leaveLoop: "Go on anyway"
        case .fixSelected: "Fix selected"
        case .skipAll: "Skip them"
        case .openSession: "Open session"
        case .agentHandles: "Agent addresses them"
        case .iHandle: "I'll handle them"
        case .openReview: "Open in Review"
        }
    }

    /// The button that moves the run forward, drawn as the main one.
    var isPrimary: Bool {
        [.continue, .retry, .oneMoreRound, .fixSelected, .agentHandles, .openReview].contains(self)
    }
}

// MARK: - Timeline

struct Event: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case stage, info, good, warning, you }
    var id = UUID()
    var at: Date
    var round: Int
    var kind: Kind
    var text: String
    /// The stage the run was at; nil in runs from before stages were logged.
    var stage: StagePosition?
}

extension WorkflowRun {
    mutating func log(_ text: String, _ kind: Event.Kind = .info, at now: Date = Date()) {
        events.append(Event(at: now, round: round, kind: kind, text: text, stage: position))
        // ponytail: plain cap; a run with thousands of events would want paging.
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    /// Values for `{name}` in prompts: the inputs plus what Simul knows.
    func values(extra: [String: String] = [:]) -> [String: String] {
        var values = inputs
        values["folder"] = folder
        values["round"] = String(round)
        if let pr = pullRequest {
            values["pr"] = "#\(pr.number)"
            values["pr_number"] = String(pr.number)
            values["pr_url"] = pr.url
        } else if values["pr"].map({ $0.isEmpty }) ?? true {
            values["pr"] = "this branch's pull request"
        }
        return values.merging(extra) { _, new in new }
    }
}
