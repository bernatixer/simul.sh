import AppKit
import Foundation
import Observation

/// Runs workflows: moves each run from stage to stage as its sessions
/// finish turns, checks pass, and GitHub changes; stops to ask the user
/// when a stage needs them. Never calls a model itself: agents do the work
/// in their own visible sessions.
@MainActor
@Observable
final class WorkflowEngine {
    private(set) var runs: [WorkflowRun] = []
    /// The user's own workflows (`<data dir>/workflows`), read when the Runs view opens.
    private(set) var library: [WorkflowLibrary.Entry] = []
    /// The Runs view covers the detail area.
    var showing = false
    /// Runs lists every session's runs, not just the selected one's.
    var allSessions = false
    /// The start form being filled in, for dev hooks to time changes to it.
    @ObservationIgnored weak var form: RunForm?
    var selectedRunID: UUID?
    /// "New run" form, for this session (nil: the selected one).
    var composing: Composer?

    /// A workflow open in the editor; `file` nil for a new one.
    var editing: Editor?

    struct Editor: Equatable {
        var workflow: Workflow
        var file: URL?
    }

    struct Composer: Hashable {
        var sessionID: UUID?
        var workflowID: String?
    }

    weak var app: AppModel?
    private let store: RunStore
    private let resolver: ExecutableResolver
    private var tools: WorkflowTools?
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "sh.simul.runs.save")

    init(store: RunStore = RunStore(), resolver: ExecutableResolver) {
        self.store = store
        self.resolver = resolver
    }

    // MARK: - Reading

    /// Built-ins first, then the user's valid ones.
    var workflows: [Workflow] {
        WorkflowTemplates.all + library.compactMap { $0.problems.isEmpty ? $0.workflow : nil }
    }

    func run(_ id: UUID?) -> WorkflowRun? { id.flatMap { id in runs.first { $0.id == id } } }

    /// The live run whose work happens in this session.
    func liveRun(for sessionID: Session.ID) -> WorkflowRun? {
        runs.last { $0.sessionID == sessionID && $0.isLive }
    }

    /// The run a reviewer session works for.
    func runReviewing(with sessionID: Session.ID) -> WorkflowRun? {
        runs.first { $0.isLive && $0.reviewerSessionIDs.contains(sessionID) }
    }

    var needingYou: [WorkflowRun] { runs.filter { $0.status == .needsYou } }

    /// Reviewer sessions working for live runs.
    var liveReviewerIDs: Set<Session.ID> { Set(runs.filter(\.isLive).flatMap(\.reviewerSessionIDs)) }

    /// Runs on this session, or that it reviews for.
    func runs(for sessionID: Session.ID?) -> [WorkflowRun] {
        guard let sessionID else { return [] }
        return runs.filter { $0.sessionID == sessionID || $0.reviewerSessionIDs.contains(sessionID) }
    }

    var hasLiveRuns: Bool { runs.contains(where: \.isLive) }

    /// runs.json is from another version of Simul: runs aren't saved.
    private(set) var cantSave = false

    func reloadLibrary() {
        Task {
            let loaded = await Task.detached(priority: .utility) { WorkflowLibrary.load() }.value
            if loaded != library { library = loaded }
        }
    }

    // MARK: - Lifecycle

    /// After sessions are loaded: picks up runs from last time. A stage
    /// that was mid-turn when Simul quit asks before sending its prompt again.
    func restore() {
        runs = store.load()
        if store.readOnly != cantSave { cantSave = store.readOnly }
        reloadLibrary()
        // Waiting on you for a session that's gone now (it stopped with Simul): ask to send it again.
        for run in runs where run.status == .needsYou && run.ask?.kind == .pressReturn {
            if let asked = run.ask?.session, run.reviewerSessionIDs.contains(asked) {
                // About a reviewer: the review is picked up below like a running one.
                update(run.id) { r in
                    r.ask = nil
                    r.status = .active
                }
                continue
            }
            update(run.id) { r in
                r.ask = Ask(kind: .problem, title: "Simul closed during “\(r.currentStage?.title ?? "")”",
                            detail: "Try again sends the step's prompt again.", actions: [.retry, .skip, .stop])
            }
        }
        for run in runs where run.isLive && run.currentStage?.kind == .review && !run.stage.reviewers.isEmpty && run.status != .active {
            // Its reviewers stopped with Simul: keep what they wrote.
            update(run.id) { r in
                for i in r.stage.reviewers.indices where r.stage.reviewers[i].state == .working {
                    let wrote = Self.readReport(r.stage.reviewers[i].file).flatMap { try? ReviewerReport.parse($0) } != nil
                    r.stage.reviewers[i].state = wrote ? .done : .failed
                }
            }
        }
        for run in runs where run.status == .active {
            let stage = run.currentStage
            if stage?.kind == .wait {
                // Same wait, same deadline: look again now.
                update(run.id) { $0.stage.nextPollAt = Date() }
                continue
            }
            if stage?.kind == .review, !run.stage.reviewers.isEmpty {
                // The reviewers stopped with Simul: keep the reviews they wrote, else review again.
                update(run.id) { r in
                    for i in r.stage.reviewers.indices where r.stage.reviewers[i].state == .working {
                        let wrote = Self.readReport(r.stage.reviewers[i].file).flatMap { try? ReviewerReport.parse($0) } != nil
                        r.stage.reviewers[i].state = wrote ? .done : .failed
                    }
                }
                if self.run(run.id)?.stage.reviewers.contains(where: { $0.state == .done }) == true {
                    finishReviewIfDone(run.id)
                } else {
                    closeReviewers(run)
                    enter(run.id)
                }
                continue
            }
            if let stage, [.agent, .fix, .verify].contains(stage.kind), run.stage.promptSentAt != nil {
                update(run.id) { r in
                    r.status = .needsYou
                    r.ask = Ask(kind: .problem, title: "Simul closed during “\(stage.title)”",
                                detail: "The agent's work may be half done. Try again sends the step's prompt again.",
                                actions: [.retry, .skip, .stop])
                }
            } else {
                enter(run.id)
            }
        }
        scheduleTimer()
    }

    /// Starts `workflow` on `session`. Returns the run, or why it can't start.
    @discardableResult
    func start(_ workflow: Workflow, on session: Session, inputs: [String: String], folder: String? = nil) -> Result<UUID, StartError> {
        let problems = workflow.validate()
        guard problems.isEmpty else { return .failure(.invalid(problems)) }
        if liveRun(for: session.id) != nil { return .failure(.busy) }
        for input in workflow.inputs where input.required == true && (inputs[input.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(.missing(input.label))
        }
        // What comes after needs its inputs too, from these.
        if let next = workflow.then.flatMap({ id in workflows.first { $0.id == id } }),
           workflow.thenIf.map({ WorkflowText.isOn(inputs[$0] ?? workflow.defaults[$0]) }) ?? true {
            for input in next.inputs where input.required == true && input.id != "pr"
                && (inputs[input.id] ?? input.defaultValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return .failure(.missing(input.label))
            }
        }
        // A review that will run needs someone to review.
        if workflow.lacksReviewers(inputs, known: Set(AgentDefinition.builtIns.filter { $0.resume != .none }.map(\.id))) {
            return .failure(.noReviewers)
        }
        // Agent stages need to know when a turn ends: Claude and Codex tell.
        if workflow.allPositions.contains(where: { [.agent, .fix, .verify].contains(workflow.stage(at: $0)?.kind) }),
           !["claude", "codex"].contains(session.agentID) {
            return .failure(.agent)
        }
        // Every input has a value, empty if nothing else, so {name} never reaches an agent as written.
        var filled = Dictionary(uniqueKeysWithValues: workflow.inputs.map { ($0.id, $0.defaultValue ?? "") })
        inputs.forEach { filled[$0.key] = $0.value }
        var run = WorkflowRun(workflow: workflow, sessionID: session.id, folder: folder ?? session.workingDirectory, inputs: filled)
        run.log("Started \(workflow.name) in \((run.folder as NSString).abbreviatingWithTildeInPath)", .stage)
        runs.append(run)
        selectedRunID = run.id
        save()
        enter(run.id)
        scheduleTimer()
        return .success(run.id)
    }

    enum StartError: Error, Equatable {
        case invalid([String]), busy, missing(String), agent, noReviewers
        var message: String {
            switch self {
            case let .invalid(p): "This workflow has problems: " + p.joined(separator: "; ")
            case .busy: "This session already has a run going. Stop it first."
            case let .missing(label): "Fill in “\(label)”."
            case .agent: "This workflow needs a Claude or Codex session: Simul can tell when their turns end."
            case .noReviewers: "Pick a reviewer, or turn Review off."
            }
        }
    }

    // MARK: - User actions

    func answer(_ id: UUID, _ action: Ask.Action, selected: Set<String> = []) {
        guard let run = run(id), let ask = run.ask, ask.actions.contains(action) || action == .openSession else { return }
        app?.notifier.remove([id])
        switch action {
        case .stop:
            stop(id)
        case .openSession:
            let target = ask.session ?? run.sessionID
            if let session = app?.sessions.first(where: { $0.id == target }) { app?.select(session) }
        case .openReview:
            openReview(id)
        case .retry:
            clearAsk(id)
            enter(id)
        case .skip, .continue:
            clearAsk(id)
            advance(id)
        case .oneMoreRound:
            clearAsk(id)
            update(id) { r in
                r.extraRounds += 1
                r.round += 1
                r.position = StagePosition(part: .loop, index: 0)
                r.resetRound()
                r.log("Round \(r.round), one more", .stage)
            }
            go(id)
        case .leaveLoop:
            clearAsk(id)
            leaveLoop(id, reason: "Went on with findings open")
        case .fixSelected, .skipAll:
            let lower = Set(ask.findings)
            let chosen = action == .fixSelected ? lower.intersection(selected) : []
            update(id) { r in
                r.findings = FindingLedger.set(r.findings, Array(lower.subtracting(chosen)), status: .skipped, note: "You skipped it")
            }
            clearAsk(id)
            sendFix(id, ids: (self.run(id)?.stage.fixing ?? []) + ask.findings.filter(chosen.contains))
        case .agentHandles:
            let threshold = fixThreshold(run)
            update(id) { r in
                r.findings = FindingLedger.set(r.findings, ask.findings, status: .open, note: "You handed it to the agent")
                for i in r.findings.indices where ask.findings.contains(r.findings[i].id) && r.findings[i].severity < threshold {
                    r.findings[i].severity = threshold  // so the next fix takes it
                }
            }
            clearAsk(id)
            advance(id)
        case .iHandle:
            update(id) { r in
                r.findings = FindingLedger.set(r.findings, ask.findings, status: .skipped, note: "You're handling it")
            }
            clearAsk(id)
            advance(id)
        }
    }

    /// Takes effect when the current stage ends: the next one waits.
    func pause(_ id: UUID) {
        update(id) { r in
            guard r.status == .active || r.status == .needsYou else { return }
            r.pauseRequested = true
            r.log("Pausing after this step", .you)
        }
    }

    func resume(_ id: UUID) {
        guard let run = run(id) else { return }
        if run.pauseRequested { update(id) { $0.pauseRequested = false } }
        guard run.status == .paused else { return }
        update(id) { r in
            r.status = .active
            r.log("Resumed", .you)
        }
        enter(id)
        scheduleTimer()
    }

    func stop(_ id: UUID, reason: String = "Stopped by you") {
        guard let run = run(id), run.isLive else { return }
        closeReviewers(run)
        update(id) { r in
            r.status = .stopped
            r.ask = nil
            r.activity = reason
            r.finishedAt = Date()
            r.stage = WorkflowRun.StageState()
            r.log(reason, .warning)
        }
        scheduleTimer()
    }

    /// Removes a finished run from the list.
    func remove(_ id: UUID) {
        guard let run = run(id), !run.isLive else { return }
        // Its reviewers' sessions go too (their conversations stay with the agents).
        for helper in run.helperSessions {
            if let session = app?.sessions.first(where: { $0.id == helper }), session.isArchived { app?.deleteMetadata(session) }
        }
        runs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Paths.runFiles(id))
        if selectedRunID == id { selectedRunID = nil }
        save()
    }

    // MARK: - Session events (from AppModel)

    func turnStarted(_ sessionID: Session.ID) {
        for run in runs where run.isLive {
            guard let index = run.stage.reviewers.firstIndex(where: { $0.sessionID == sessionID }), !run.stage.reviewers[index].started else { continue }
            update(run.id) { r in
                r.stage.reviewers[index].started = true
                if r.ask?.kind == .pressReturn, r.ask?.session == sessionID {
                    r.ask = nil
                    r.status = .active
                }
            }
        }
        for run in runs where run.isLive && run.sessionID == sessionID && run.stage.promptSentAt != nil && !run.stage.turnStarted {
            update(run.id) { r in
                r.stage.turnStarted = true
                if r.ask?.kind == .pressReturn {
                    r.ask = nil
                    r.status = .active
                }
            }
        }
    }

    func turnEnded(_ sessionID: Session.ID) {
        for run in runs where run.isLive {
            if run.sessionID == sessionID, run.status == .active {
                if run.stage.pendingPrompt != nil {
                    deliver(run.id)
                } else if run.stage.promptSentAt != nil, run.stage.turnStarted {
                    agentTurnEnded(run.id)
                }
            }
            if run.reviewerSessionIDs.contains(sessionID) {
                reviewerTurnEnded(run.id, session: sessionID)
            }
        }
    }

    /// A session's process ended (quit, crashed, closed).
    func sessionExited(_ sessionID: Session.ID) {
        for run in runs where run.isLive {
            if run.reviewerSessionIDs.contains(sessionID) {
                update(run.id) { r in
                    if r.ask?.session == sessionID {
                        r.ask = nil
                        r.status = .active
                    }
                    if let i = r.stage.reviewers.firstIndex(where: { $0.sessionID == sessionID }), r.stage.reviewers[i].state == .working {
                        r.stage.reviewers[i].state = .failed
                        r.log("A reviewer's session ended before it wrote its review", .warning)
                    }
                }
                finishReviewIfDone(run.id)
            } else if run.sessionID == sessionID, run.status == .active, run.stage.promptSentAt != nil {
                ask(run.id, Ask(kind: .problem, title: "The session stopped",
                                detail: "Its agent exited during “\(run.currentStage?.title ?? "")”. Try again restarts it and sends the step again.",
                                actions: [.retry, .skip, .stop]))
            }
        }
    }

    func sessionDeleted(_ sessionID: Session.ID) {
        for run in runs where run.isLive && run.sessionID == sessionID {
            stop(run.id, reason: "Its session was deleted")
        }
    }

    // MARK: - Moving on

    /// Starts the stage the run is at (stages.swift does the work per kind).
    func enter(_ id: UUID) {
        guard let run = run(id), run.status == .active else { return }
        guard let stage = run.currentStage else { return finish(id) }
        if let input = stage.skipUnless, !WorkflowText.isOn(run.inputs[input]) {
            let label = run.workflow.inputs.first { $0.id == input }?.label ?? input
            update(id) { $0.log("Skipped “\(stage.title)”: “\(label)” is off") }
            return advance(id)
        }
        closeReviewers(run)  // any left from the stage before (skipped, retried)
        update(id) { r in
            r.stage = WorkflowRun.StageState()
            r.activity = stage.title
            r.log(stage.title, .stage)
        }
        startStage(id, stage)
    }

    /// The current stage is done: on to the next, through the loop's rounds.
    func advance(_ id: UUID) {
        if run(id)?.ask?.kind == .pressReturn { clearAsk(id) }  // about a session the stage is done with
        guard var run = run(id), run.isLive else { return }
        let next = run.position.index + 1
        if next < run.workflow.stages(run.position.part).count {
            run.position.index = next
        } else {
            switch run.position.part {
            case .before:
                guard let first = run.workflow.first(from: .loop) else { return finish(id) }
                run.position = first
                if first.part == .loop { run.round = 1 }
            case .loop:
                // A round that found nothing to fix, with nothing in the way: done looping.
                if run.workflow.loop?.stages.contains(where: { $0.kind == .fix }) == true, !run.fixesThisRound,
                   FindingLedger.blocking(run.findings, atLeast: fixThreshold(run)).isEmpty {
                    return leaveLoop(id, reason: "Clean: nothing left to fix")
                }
                if run.round >= run.maxRounds {
                    let open = FindingLedger.blocking(run.findings, atLeast: fixThreshold(run)).count
                    return ask(id, Ask(kind: .outOfRounds, title: "\(run.round) rounds done",
                                       detail: open == 0 ? "That was the last round." : "\(open) finding\(open == 1 ? " is" : "s are") still open.",
                                       actions: [.oneMoreRound, .leaveLoop, .stop]))
                }
                run.round += 1
                run.position = StagePosition(part: .loop, index: 0)
                run.resetRound()
                run.log("Round \(run.round)", .stage)
            case .after:
                return finish(id)
            }
        }
        commit(run)
        if run.pauseRequested { return pauseHere(id) }
        enter(id)
    }

    func leaveLoop(_ id: UUID, reason: String) {
        update(id) { $0.log(reason, .good) }
        guard let run = run(id), let after = run.workflow.first(from: .after), after.part == .after else { return finish(id) }
        update(id) { $0.position = after }
        if run.pauseRequested { return pauseHere(id) }
        enter(id)
    }

    /// Starts the stage the run is at, unless a pause was asked for.
    func go(_ id: UUID) {
        if run(id)?.pauseRequested == true { return pauseHere(id) }
        enter(id)
    }

    /// Pause was asked for: stop before the stage the run is now at.
    private func pauseHere(_ id: UUID) {
        update(id) { r in
            r.pauseRequested = false
            r.status = .paused
            r.activity = "Paused before “\(r.currentStage?.title ?? "")”"
            r.log("Paused", .you)
        }
    }

    func finish(_ id: UUID) {
        guard let run = run(id), run.isLive else { return }
        closeReviewers(run)
        let open = FindingLedger.blocking(run.findings, atLeast: .low).count
        update(id) { r in
            r.status = .done
            r.ask = nil
            r.finishedAt = Date()
            r.stage = WorkflowRun.StageState()
            let verified = r.findings.filter { $0.status == .verified }.count
            r.activity = open > 0 ? "Finished with \(open) open finding\(open == 1 ? "" : "s")"
                : verified > 0 ? "Finished: \(verified) verified fixed" : "Finished"
            r.log(r.activity, .good)
        }
        notify(id, body: self.run(id)?.activity ?? "Finished")
        scheduleTimer()
        // ponytail: keeps the last 100 finished runs; older ones go with their files.
        let finished = runs.filter { !$0.isLive }.sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }
        for old in finished.dropFirst(100) { remove(old.id) }
        // Then another workflow, if asked for.
        if let next = run.workflow.then, run.workflow.thenIf.map({ WorkflowText.isOn(run.inputs[$0]) }) ?? true,
           let workflow = workflows.first(where: { $0.id == next }),
           let session = app?.sessions.first(where: { $0.id == run.sessionID }) {
            var inputs = run.inputs.filter { !$0.value.isEmpty }  // empty ones leave the next workflow's defaults
            if let pr = run.pullRequest { inputs["pr"] = String(pr.number) }
            if case let .failure(error) = start(workflow, on: session, inputs: inputs.filter { key, _ in workflow.inputs.contains { $0.id == key } }, folder: run.folder) {
                update(id) { $0.log("Couldn't start \(workflow.name): \(error.message)", .warning) }
            }
        }
    }

    // MARK: - Asking

    func ask(_ id: UUID, _ ask: Ask) {
        update(id) { r in
            r.status = .needsYou
            r.ask = ask
            r.activity = ask.title
            r.log(ask.title, .you)
        }
        notify(id, body: ask.title + (ask.detail.isEmpty ? "" : ". " + ask.detail))
    }

    func clearAsk(_ id: UUID) {
        update(id) { r in
            r.ask = nil
            if r.status == .needsYou { r.status = .active }
        }
    }

    /// A notification for the run unless the user is looking at it.
    private func notify(_ id: UUID, body: String) {
        guard let run = run(id), let app else { return }
        if NSApp.isActive, showing, selectedRunID == id { return }
        let title = app.sessions.first { $0.id == run.sessionID }.map { "\(run.workflow.name) · \($0.title)" } ?? run.workflow.name
        app.notifier.post(id: id, title: title, body: body)
    }

    // MARK: - Helpers for stages

    func update(_ id: UUID, _ change: (inout WorkflowRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var run = runs[index]
        change(&run)
        guard run != runs[index] else { return }
        run.updatedAt = Date()
        runs[index] = run
        save()
    }

    private func commit(_ run: WorkflowRun) { update(run.id) { $0 = run } }

    func fixThreshold(_ run: WorkflowRun) -> Finding.Severity {
        let stage = run.workflow.loop?.stages.first { $0.kind == .fix } ?? run.currentStage
        return stage?.fixAtLeast.flatMap { Finding.Severity(rawValue: WorkflowText.fill($0, run.inputs).lowercased()) } ?? .medium
    }

    func makeTools() async -> WorkflowTools {
        if let tools { return tools }
        await resolver.bootstrap()
        let made = WorkflowTools(shell: resolver.userShell, gh: await resolver.resolve(command: "gh"),
                                 environment: resolver.shellPathEnvironment)
        tools = made
        return made
    }

    /// Coalesced, written one at a time in order (saveQueue), never on the main thread.
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.runs, store = self.store
            self.saveQueue.async { store.save(snapshot) }
        }
    }

    /// Simul is quitting: what the last 300 ms changed goes to disk now.
    func flush() {
        saveTask?.cancel()
        let snapshot = runs, store = store
        saveQueue.sync { store.save(snapshot) }
    }

    // MARK: - Timer

    /// Ticks only while a run is live: polls waits, notices prompts nobody
    /// sent and reviewers that went quiet.
    func scheduleTimer() {
        if hasLiveRuns {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        for run in runs where run.isLive && run.status != .paused {
            if run.stage.pendingPrompt != nil { deliver(run.id) }
            // A reviewer that never started is likely stuck on a dialog (trusting a new folder).
            if run.ask == nil, let stuck = run.stage.reviewers.first(where: { $0.state == .working && !$0.started && now.timeIntervalSince($0.createdAt) > 60 }),
               let session = app?.sessions.first(where: { $0.id == stuck.sessionID }) {
                ask(run.id, Ask(kind: .pressReturn, title: "\(session.title) is waiting for you",
                                detail: "The reviewer hasn't started: it may be asking whether to trust the folder. Answer it; the review goes on by itself.",
                                actions: [.openSession, .skip, .stop], session: session.id))
            }
            if run.currentStage?.kind == .review, now.timeIntervalSince(run.stage.startedAt) > 45 * 60 {
                update(run.id) { r in
                    for i in r.stage.reviewers.indices where r.stage.reviewers[i].state == .working {
                        let wrote = Self.readReport(r.stage.reviewers[i].file).flatMap { try? ReviewerReport.parse($0) } != nil
                        r.stage.reviewers[i].state = wrote ? .done : .failed
                    }
                    if r.ask?.kind == .pressReturn { r.ask = nil; r.status = .active }
                }
                finishReviewIfDone(run.id)
            }
            // A reviewer stopped mid-review to ask something (a permission): say so; clear it once answered.
            if let app, let asking = run.stage.reviewers.first(where: { $0.state == .working && $0.started && app.waitingIDs.contains($0.sessionID) }),
               run.ask == nil, let session = app.sessions.first(where: { $0.id == asking.sessionID }) {
                ask(run.id, Ask(kind: .pressReturn, title: "\(session.title) is asking you something",
                                detail: "The reviewer is waiting for an answer before it can finish.",
                                actions: [.openSession, .skip, .stop], session: session.id))
            } else if let asked = run.ask?.session, run.ask?.kind == .pressReturn, run.reviewerSessionIDs.contains(asked),
                      run.stage.reviewers.first(where: { $0.sessionID == asked })?.started == true,
                      app?.waitingIDs.contains(asked) == false {
                clearAsk(run.id)
            }
            guard self.run(run.id)?.status == .active else { continue }
            if let poll = run.stage.nextPollAt, poll <= now { self.poll(run.id) }
            // A look that never came back (it's bounded, so this is a backstop): look again.
            if run.currentStage?.kind == .wait, run.stage.nextPollAt == nil,
               let since = run.stage.lookingSince, now.timeIntervalSince(since) > 600 {
                update(run.id) { $0.stage.nextPollAt = now }
            }
            if let sent = run.stage.promptSentAt, !run.stage.turnStarted, now.timeIntervalSince(sent) > 30, run.ask == nil {
                let name = app?.sessions.first { $0.id == run.sessionID }?.title ?? "the session"
                ask(run.id, Ask(kind: .pressReturn, title: "Press Return in \(name)",
                                detail: "The prompt for “\(run.currentStage?.title ?? "")” is in its input box, but the agent hasn't started.",
                                actions: [.openSession, .skip, .stop]))
            }
        }
    }
}

extension WorkflowRun {
    /// Fresh per-round counters.
    mutating func resetRound() {
        fixesThisRound = false
        checkRetries = 0
        stage = StageState()
    }
}
