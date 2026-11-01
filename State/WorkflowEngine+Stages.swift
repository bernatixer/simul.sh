import Foundation

/// What each kind of stage does. Async work checks the run is still on the
/// same stage (its token) before it applies a result.
extension WorkflowEngine {
    func startStage(_ id: UUID, _ stage: WorkflowStage) {
        guard let run = run(id) else { return }
        let values = run.values()
        switch stage.kind {
        case .agent:
            sendToSession(id, WorkflowText.fill(stage.prompt ?? "", values), doing: stage.title)
        case .verify:
            let file = Paths.runFiles(id).appendingPathComponent("verify-\(run.round)-\(run.position.part.rawValue)\(run.position.index).json")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            update(id) { $0.stage.resultFile = file.path }
            sendToSession(id, WorkflowPrompt.verify(WorkflowText.fill(stage.prompt ?? "", values), file: file.path), doing: stage.title)
        case .fix:
            startFix(id, stage)
        case .review:
            startReview(id, stage)
        case .check:
            startCheck(id, stage)
        case .wait:
            startWait(id, stage)
        case .feedback:
            startFeedback(id)
        case .gate:
            startGate(id, stage)
        }
    }

    /// Whether `token` still names the run's current stage (and the run is going).
    private func current(_ id: UUID, _ token: UUID) -> Bool {
        guard let run = run(id) else { return false }
        return run.isLive && run.stage.token == token
    }

    private func problem(_ id: UUID, _ title: String, _ detail: String, _ actions: [Ask.Action] = [.retry, .skip, .stop]) {
        ask(id, Ask(kind: .problem, title: title, detail: detail, actions: actions))
    }

    // MARK: - Prompts to the session's agent

    /// Queues `text` for the run's session; it's typed in as soon as the
    /// session is up and between turns.
    func sendToSession(_ id: UUID, _ text: String, doing: String) {
        update(id) { r in
            r.stage.pendingPrompt = text
            r.activity = "Getting the session ready for “\(doing)”"
        }
        deliver(id)
    }

    /// Types the pending prompt in if the session can take it now.
    func deliver(_ id: UUID) {
        guard let run = run(id), run.status == .active || run.ask?.kind == .pressReturn,
              let text = run.stage.pendingPrompt, let app else { return }
        guard let session = app.sessions.first(where: { $0.id == run.sessionID }) else {
            return stop(id, reason: "Its session is gone")
        }
        if session.isArchived || session.sleptAt != nil {
            if session.isArchived { app.setArchived(session, false) }
            app.wake(session)
        }
        if !app.hostCenter.hasHost(for: session.id) {
            if !app.isLaunching(session) { Task { await app.launch(session) } }
            return  // the tick or its first turn end tries again
        }
        guard !app.isBusy(session.id) else { return }
        let agentName = app.agent(for: session)?.name ?? "The agent"
        let delivery = app.sendPrompt(text, to: session.id)
        if delivery == .notReady || delivery == .failed {
            // Not taking prompts (a dialog, a question, text in its box): say so after a while.
            update(id) { $0.stage.pendingSince = $0.stage.pendingSince ?? Date() }
            if let since = self.run(id)?.stage.pendingSince, Date().timeIntervalSince(since) > 45, self.run(id)?.ask == nil {
                ask(id, Ask(kind: .pressReturn, title: "\(session.title) is waiting for you",
                            detail: "Its input box isn't showing: it may be asking something (like whether to trust the folder), or has text typed in it. Answer or clear it; “\(run.currentStage?.title ?? "")” goes in as soon as it's ready.",
                            actions: [.openSession, .skip, .stop], session: session.id))
            }
            return
        }
        let waitedForYou = run.ask?.kind == .pressReturn
        update(id) { r in
            r.stage.pendingPrompt = nil
            r.stage.pendingSince = nil
            r.stage.promptSentAt = Date()
            r.stage.turnStarted = false
            r.activity = "\(agentName) is on “\(r.currentStage?.title ?? "")”"
            if waitedForYou {
                r.ask = nil
                r.status = .active
            }
        }
        if delivery == .pasted {
            ask(id, Ask(kind: .pressReturn, title: "Press Return in \(session.title)",
                        detail: "The prompt for “\(run.currentStage?.title ?? "")” is in its input box. Simul only presses Return itself for Claude and Codex.",
                        actions: [.openSession, .skip, .stop], session: session.id))
        }
    }

    /// The session's agent finished the turn a stage started.
    func agentTurnEnded(_ id: UUID) {
        guard let run = run(id), let stage = run.currentStage else { return }
        update(id) { r in
            r.stage.promptSentAt = nil
            r.stage.turnStarted = false
        }
        switch stage.kind {
        case .fix: finishFix(id)
        case .verify: finishVerify(id)
        default:
            guard run.workflow.usesPullRequest, run.pullRequest == nil else { return advance(id) }
            let token = run.stage.token
            Task {
                await discoverPullRequest(id)
                guard current(id, token) else { return }
                advance(id)
            }
        }
    }

    // MARK: - Fix

    private func startFix(_ id: UUID, _ stage: WorkflowStage) {
        // Entered again (Try again, a restart): what it was fixing is open again.
        update(id) { r in r.findings = r.findings.map { f in var f = f; if f.status == .fixing { f.status = .open }; return f } }
        guard let run = run(id) else { return }
        let threshold = fixThreshold(run)
        let askBelow = WorkflowText.isOn(stage.askBelow.map { WorkflowText.fill($0, run.inputs) })
        let (auto, lower) = FindingLedger.select(run.findings, atLeast: threshold)
        if !lower.isEmpty {
            if askBelow {
                update(id) { $0.stage.fixing = auto }
                let n = lower.count
                return ask(id, Ask(kind: .chooseFindings, title: "\(n) lower finding\(n == 1 ? "" : "s") to decide on",
                                   detail: auto.isEmpty ? "Pick the ones worth fixing." : "\(auto.count) more are being fixed either way.",
                                   actions: [.fixSelected, .skipAll, .stop], findings: lower))
            }
            update(id) { r in
                r.findings = FindingLedger.set(r.findings, lower, status: .skipped, note: "Below \(threshold.rawValue)")
                r.log("Skipped \(lower.count) below \(threshold.rawValue)")
            }
        }
        sendFix(id, ids: auto)
    }

    /// Sends `ids` to the agent; with nothing to fix, moves on (or ends the loop).
    func sendFix(_ id: UUID, ids: [String]) {
        guard let run = run(id) else { return }
        guard !ids.isEmpty else {
            update(id) { $0.log("Nothing to fix") }
            return advance(id)
        }
        let token = run.stage.token
        Task {
            let tools = await makeTools()
            let before = await tools.snapshotTree(run.folder)
            let head = await tools.head(run.folder)
            guard current(id, token), let run = self.run(id) else { return }
            let chosen = run.findings.filter { ids.contains($0.id) }
            update(id) { r in
                r.stage.beforeTree = before
                r.stage.headAtStart = head
                r.stage.fixing = ids
                r.findings = FindingLedger.set(r.findings, ids, status: .fixing, round: r.round)
                r.fixesThisRound = true
            }
            sendToSession(id, WorkflowPrompt.fix(chosen, folder: run.folder), doing: "Fix")
            update(id) { r in
                if r.stage.pendingPrompt != nil { r.activity = "Fixing \(ids.count) finding\(ids.count == 1 ? "" : "s")" }
            }
        }
    }

    private func finishFix(_ id: UUID) {
        guard let run = run(id) else { return }
        let token = run.stage.token
        Task {
            let tools = await makeTools()
            let after = await tools.snapshotTree(run.folder)
            let head = await tools.head(run.folder)
            var diff = ""
            if let before = run.stage.beforeTree, let after, before != after { diff = await tools.diff(from: before, to: after, in: run.folder) }
            let point = await tools.mergePoint(run.folder)
            let lines = await tools.diffLines(run.folder, since: point)
            guard current(id, token) else { return }
            let guardResult = FixGuard.check(diff: diff)
            let committed = head != nil && head != run.stage.headAtStart ? head.map { String($0.prefix(8)) } : nil
            var warn: Ask?
            update(id) { r in
                r.findings = FindingLedger.set(r.findings, r.stage.fixing, status: .fixed, round: r.round, fixedIn: committed)
                let files = guardResult.files.count
                r.log("Fixed \(r.stage.fixing.count), touching \(files) file\(files == 1 ? "" : "s")" + (committed.map { " (\($0))" } ?? ""), .good)
                for warning in guardResult.testWarnings {
                    r.findings.append(Finding(id: FindingLedger.nextID(r.findings), key: "guard:\(r.round):\(warning)",
                                              sources: ["Simul"], severity: .high, title: "The fix \(warning)",
                                              detail: "Check this is right: fixes shouldn't make tests weaker.",
                                              status: .yours, raisedRound: r.round, updatedRound: r.round))
                }
                if !guardResult.testWarnings.isEmpty {
                    warn = Ask(kind: .problem, title: "The fix changed tests",
                               detail: guardResult.testWarnings.joined(separator: "; ").capitalizedFirst + ". Look before going on.",
                               actions: [.continue, .openSession, .stop])
                }
                // The change growing a lot after the first round's fixes is worth a look.
                if let base = r.baselineDiffLines {
                    if !r.diffWarned, lines > max(base * 3 / 2, base + 150) {
                        r.diffWarned = true
                        warn = warn ?? Ask(kind: .problem, title: "The change is growing",
                                           detail: "It was \(base) lines after round 1's fixes and is \(lines) now.",
                                           actions: [.continue, .openSession, .stop])
                    }
                } else {
                    r.baselineDiffLines = lines
                }
                r.stage.fixing = []
            }
            if let warn { return ask(id, warn) }
            advance(id)
        }
    }

    // MARK: - Verify

    private func finishVerify(_ id: UUID) {
        guard let run = run(id), let file = run.stage.resultFile else { return advance(id) }
        guard let data = Self.readReport(file), let report = try? VerifyReport.parse(data) else {
            return problem(id, "No result from “\(run.currentStage?.title ?? "")”",
                           "The agent didn't write \((file as NSString).lastPathComponent) as asked.", [.retry, .skip, .stop])
        }
        if report.ok {
            update(id) { $0.log("OK: \(report.summary)", .good) }
            advance(id)
        } else {
            update(id) { $0.log("Problem: \(report.summary)", .warning) }
            problem(id, "Problem found", report.summary, [.continue, .openSession, .stop])
        }
    }

    // MARK: - Review

    private func startReview(_ id: UUID, _ stage: WorkflowStage) {
        guard let run = run(id), let app else { return }
        let ids = WorkflowText.fill(stage.reviewers ?? "", run.inputs).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let agents = ids.compactMap { id in app.agents.first { $0.id == id && $0.resume != .none } }
        guard !agents.isEmpty else {
            return problem(id, "No reviewers", "Reviewers must be Claude or Codex (got “\(ids.joined(separator: ", "))”).", [.skip, .stop])
        }
        guard let builder = app.sessions.first(where: { $0.id == run.sessionID }) else { return stop(id, reason: "Its session is gone") }
        let token = run.stage.token
        update(id) { $0.activity = "Getting the change ready to review" }
        Task {
            let tools = await makeTools()
            var folder = run.folder
            var point = await tools.mergePoint(folder)
            var what = "the change on this branch"
            var head: String?
            let untrusted = run.reviewsSomeoneElsesPR
            if untrusted {
                // Someone else's PR: in a worktree at its head.
                do {
                    let pr = try await self.reviewWorktree(id)
                    folder = pr.folder
                    point = await tools.mergePoint(folder, base: pr.base)
                    what = "pull request \(pr.name)"
                    head = pr.head  // the PR's, even when the worktree is the user's and ahead of it
                } catch {
                    guard current(id, token) else { return }
                    return problem(id, "Couldn't check out the pull request", error.localizedDescription)
                }
            } else {
                head = await tools.head(folder)
            }
            guard current(id, token), let run = self.run(id) else { return }
            let since = run.round > 1 ? run.lastReviewedHead : nil
            let dir = Paths.runFiles(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Untrusted code: its reviewers get no commands, so Simul writes the diffs for them.
            var diffs: WorkflowPrompt.Diffs?
            if untrusted {
                let change = dir.appendingPathComponent("review-\(run.round).diff")
                guard let text = await tools.git(["diff", "--no-color", "--no-ext-diff", point, head ?? "HEAD"], in: folder),
                      (try? (text + "\n").write(to: change, atomically: true, encoding: .utf8)) != nil else {
                    guard current(id, token) else { return }
                    return problem(id, "Couldn't get the pull request's diff", "git diff failed in \(folder).")
                }
                var sinceFile: String?
                if let since, let head, since != head,
                   let text = await tools.git(["diff", "--no-color", "--no-ext-diff", since, head], in: folder) {
                    let url = dir.appendingPathComponent("review-\(run.round)-since.diff")
                    try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
                    sinceFile = url.path
                }
                diffs = WorkflowPrompt.Diffs(change: change.path, since: sinceFile)
                guard current(id, token) else { return }
            }
            let previous = run.findings.filter { $0.key == nil && [.open, .fixing, .fixed].contains($0.status) }
            let instructions = stage.instructions.map { WorkflowText.fill($0, run.inputs) }
            var reviewers: [WorkflowRun.Reviewer] = []
            for agent in agents {
                let file = dir.appendingPathComponent("review-\(run.round)-\(agent.id).json")
                try? FileManager.default.removeItem(at: file)
                let prompt = WorkflowPrompt.review(what: what, folder: folder, point: point, since: since, previous: previous,
                                                   instructions: instructions, file: file.path, diffs: diffs)
                // Untrusted code: reviewers run in Simul's runs folder, never in the PR's (its agent config stays off).
                let home = untrusted ? dir.deletingLastPathComponent().path : folder
                let session = app.startReviewerSession(agentID: agent.id, title: "\(agent.name) review · round \(run.round)",
                                                       folder: home, code: folder, alongside: builder, prompt: prompt,
                                                       report: file.path, trusted: !untrusted)
                reviewers.append(WorkflowRun.Reviewer(agentID: agent.id, sessionID: session.id, file: file.path))
            }
            update(id) { r in
                r.stage.reviewers = reviewers
                r.helperSessions += reviewers.map(\.sessionID)
                r.stage.headAtStart = head
                r.activity = reviewers.count == 1 ? "\(agents[0].name) is reviewing" : "\(reviewers.count) reviewers are reviewing"
            }
        }
    }

    /// A reviewer's turn ended: its report is in, or it gets one reminder.
    func reviewerTurnEnded(_ id: UUID, session: Session.ID) {
        guard let run = run(id), let index = run.stage.reviewers.firstIndex(where: { $0.sessionID == session }),
              run.stage.reviewers[index].state == .working else { return }
        let reviewer = run.stage.reviewers[index]
        var problem: String?
        if let data = Self.readReport(reviewer.file) {
            do {
                _ = try ReviewerReport.parse(data)
                update(id) { $0.stage.reviewers[index].state = .done }
                return finishReviewIfDone(id)
            } catch {
                problem = (error as? ReviewerReport.Problem)?.message ?? "it can't be read"
            }
        }
        let delivery = reviewer.nudges < 2 ? app?.sendPrompt(WorkflowPrompt.reviewAgain(file: reviewer.file, problem: problem), to: session) : nil
        if delivery == .submitted || delivery == .pasted {
            update(id) { $0.stage.reviewers[index].nudges += 1 }
        } else if delivery == .notReady {
            // Asking something (a permission): its next turn end tries again; the timeout still applies.
            update(id) { $0.log("\(reviewer.agentID.capitalized) is waiting for an answer before it can write its review", .you) }
        } else {
            update(id) { r in
                r.stage.reviewers[index].state = .failed
                r.log("\(reviewer.agentID.capitalized) didn't write a usable review", .warning)
            }
            finishReviewIfDone(id)
        }
    }

    func finishReviewIfDone(_ id: UUID) {
        guard let run = run(id), run.currentStage?.kind == .review, !run.stage.reviewers.isEmpty,
              !run.stage.reviewers.contains(where: { $0.state == .working }) else { return }
        let names = Dictionary(uniqueKeysWithValues: (app?.agents ?? []).map { ($0.id, $0.name) })
        let reports: [(source: String, report: ReviewerReport)] = run.stage.reviewers.compactMap { r in
            guard r.state == .done, let data = Self.readReport(r.file),
                  let report = try? ReviewerReport.parse(data) else { return nil }
            return (names[r.agentID] ?? r.agentID, report)
        }
        closeReviewers(run)
        guard !reports.isEmpty else {
            update(id) { $0.stage.reviewers = [] }
            return problem(id, "No review came back", "The reviewers stopped without writing a review.")
        }
        var cameBack: [String] = []
        update(id) { r in
            let everyone = r.stage.reviewers.allSatisfy { $0.state == .done }
            let merged = FindingLedger.mergeReviews(r.findings, reports: reports, round: r.round, verifyUnmentioned: everyone)
            r.findings = merged.findings
            cameBack = merged.cameBack
            if let head = r.stage.headAtStart { r.lastReviewedHead = head }
            var parts = ["\(merged.new) new"]
            if merged.still > 0 { parts.append("\(merged.still) still there") }
            if merged.verified > 0 { parts.append("\(merged.verified) verified fixed") }
            r.log("Review: " + parts.joined(separator: ", "), merged.new + merged.still == 0 ? .good : .info)
            r.stage.reviewers = []
        }
        if !cameBack.isEmpty {
            return ask(id, Ask(kind: .cameBack, title: "\(cameBack.joined(separator: ", ")) came back",
                               detail: "Fixed before, found again: fixes may be going in circles.",
                               actions: [.continue, .leaveLoop, .stop], findings: cameBack))
        }
        advance(id)
    }

    /// Archives the reviewer sessions of the run's current stage.
    func closeReviewers(_ run: WorkflowRun) {
        for reviewer in run.stage.reviewers { app?.archiveHelper(reviewer.sessionID) }
    }

    /// An agent-written report, if it's there and not over 1 MB.
    static func readReport(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ReviewerReport.maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Check

    private func startCheck(_ id: UUID, _ stage: WorkflowStage) {
        guard let run = run(id) else { return }
        let command = WorkflowText.fill(stage.command ?? "", run.values())
        let token = run.stage.token
        update(id) { $0.activity = "Running \(command)" }
        Task {
            let result = await makeTools().runShell(command, in: run.folder, timeout: TimeInterval((stage.timeoutMinutes ?? 30) * 60))
            guard current(id, token) else { return }
            let passed = result.exitCode == 0
            let output = result.timedOut ? "Timed out after \(stage.timeoutMinutes ?? 30) minutes.\n" + result.output : result.output
            update(id) { r in
                r.findings = FindingLedger.mergeCheck(r.findings, command: command, passed: passed, output: output, round: r.round)
                r.log(passed ? "\(command): passed" : "\(command): failed", passed ? .good : .warning)
            }
            guard !passed else { return advance(id) }
            // Back to this round's fix, a couple of times, before asking.
            guard let run = self.run(id) else { return }
            let fix = run.workflow.stages(run.position.part)[..<run.position.index].lastIndex { $0.kind == .fix }
            if let fix, run.checkRetries < 2 {
                update(id) { r in
                    r.checkRetries += 1
                    r.position.index = fix
                    r.log("Back to “\(r.currentStage?.title ?? "Fix")” for the failing checks")
                }
                return go(id)
            }
            problem(id, "Checks still fail", String(output.suffix(600)), [.retry, .skip, .openSession, .stop])
        }
    }

    // MARK: - Wait

    private func startWait(_ id: UUID, _ stage: WorkflowStage) {
        guard let run = run(id), let waitFor = stage.waitFor else { return advance(id) }
        let now = Date()
        switch waitFor {
        case .time:
            let hours = WorkflowText.number(stage.hours, run.inputs) ?? 0
            let until = now.addingTimeInterval(hours * 3600)
            update(id) { r in
                r.stage.deadline = until
                r.stage.nextPollAt = until
                r.activity = "Waiting until \(until.formatted(date: .omitted, time: .shortened))"
            }
        case .command:
            update(id) { r in
                r.stage.deadline = now.addingTimeInterval(TimeInterval((stage.timeoutMinutes ?? 180) * 60))
                r.stage.nextPollAt = now
                r.activity = "Waiting until `\(WorkflowText.fill(stage.command ?? "", r.values()))` succeeds"
            }
        default:
            update(id) { r in
                r.stage.deadline = stage.timeoutMinutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) }
                r.stage.nextPollAt = now
                r.activity = Self.waitText(waitFor, r.pullRequest)
            }
        }
        poll(id)
    }

    static func waitText(_ waitFor: WorkflowStage.WaitFor, _ pr: WorkflowRun.PullRequestRef?) -> String {
        let name = pr.map { "#\($0.number)" } ?? "the pull request"
        switch waitFor {
        case .checks: return "Waiting for CI on \(name)"
        case .newCommit: return "Waiting for new commits on \(name)"
        case .approved: return "Waiting for \(name) to be approved"
        case .merged: return "Waiting for \(name) to merge"
        case .command, .time: return "Waiting"
        }
    }

    /// One look at what a wait stage waits for.
    func poll(_ id: UUID) {
        guard let run = run(id), run.status == .active, let stage = run.currentStage, stage.kind == .wait,
              let waitFor = stage.waitFor else { return }
        let token = run.stage.token
        update(id) { r in
            r.stage.nextPollAt = nil  // until this look is done
            r.stage.lookingSince = Date()
        }
        Task {
            let now = Date()
            let deadlinePassed = run.stage.deadline.map { now >= $0 } ?? false
            switch waitFor {
            case .time:
                guard current(id, token) else { return }
                if deadlinePassed { return advance(id) }
                update(id) { $0.stage.nextPollAt = $0.stage.deadline }
            case .command:
                let command = WorkflowText.fill(stage.command ?? "", run.values())
                let result = await makeTools().runShell(command, in: run.folder, timeout: 120, keep: 20)
                guard current(id, token) else { return }
                if result.exitCode == 0 {
                    update(id) { $0.log("\(command): succeeded", .good) }
                    return advance(id)
                }
                if deadlinePassed {
                    return problem(id, "Still waiting", "`\(command)` hasn't succeeded yet.\n\(result.output.suffix(300))", [.retry, .skip, .stop])
                }
                update(id) { $0.stage.nextPollAt = now.addingTimeInterval(300) }
            default:
                await pollPullRequest(id, token: token, waitFor: waitFor, deadlinePassed: deadlinePassed)
            }
        }
    }

    private func pollPullRequest(_ id: UUID, token: UUID, waitFor: WorkflowStage.WaitFor, deadlinePassed: Bool) async {
        guard let run = run(id) else { return }
        let status: PullRequestStatus
        do {
            status = try await pullRequestStatus(id)
        } catch {
            guard current(id, token) else { return }
            update(id) { r in
                r.stage.pollFailures += 1
                r.stage.nextPollAt = Date().addingTimeInterval(120)
            }
            // No PR known yet: likely there's none, so say so soon; otherwise ride out GitHub hiccups.
            if (self.run(id)?.stage.pollFailures ?? 0) >= (run.pullRequest == nil ? 2 : 8) {
                problem(id, run.pullRequest == nil ? "No pull request found" : "Can't reach GitHub", error.localizedDescription)
            }
            return
        }
        guard current(id, token) else { return }
        update(id) { r in
            r.stage.pollFailures = 0
            if let merge = status.mergeCommit { r.inputs["merge_sha"] = merge }
        }
        let name = "#\(status.number)"
        switch waitFor {
        case .checks:
            let elapsed = Date().timeIntervalSince(run.stage.startedAt)
            // GitHub may not have the push yet: its checks would be the last commit's.
            if status.isMerged || status.isClosed {
                return finishWith(id, "\(name) was \(status.isMerged ? "merged" : "closed")", closed: !status.isMerged)
            }
            if let local = await makeTools().head(run.folder), local != status.headSHA {
                guard current(id, token) else { return }
                guard elapsed < 600 else {
                    return problem(id, "The push didn't reach GitHub",
                                   "\(name) is at \(status.headSHA.prefix(8)) but this folder is at \(local.prefix(8)). Push it (or have the agent), then Try again.",
                                   [.retry, .openSession, .skip, .stop])
                }
                update(id) { r in
                    r.activity = "Waiting for GitHub to see the push on \(name)"
                    r.stage.nextPollAt = Date().addingTimeInterval(30)
                }
                return
            }
            // Right after a push the checks may not be listed yet.
            if status.checksFinished, !status.checks.isEmpty || elapsed > 180 {
                let failed = status.failing.count
                update(id) { $0.log(status.checks.isEmpty ? "No CI checks on \(name)"
                                    : "CI finished on \(name): \(failed == 0 ? "all passed" : "\(failed) failed")", failed == 0 ? .good : .warning) }
                return advance(id)
            }
            let done = status.checks.filter { $0.state != .pending }.count
            update(id) { $0.activity = "Waiting for CI on \(name): \(done) of \(status.checks.count) done" }
        case .newCommit:
            if status.isMerged || status.isClosed {
                return finishWith(id, "\(name) was \(status.isMerged ? "merged" : "closed")", closed: !status.isMerged)
            }
            if run.lastReviewedHead != status.headSHA {
                if run.lastReviewedHead != nil { update(id) { $0.log("New commits on \(name)") } }
                return advance(id)
            }
        case .approved:
            if status.isMerged { return skipPastMerge(id, name) }
            if status.isClosed { return stop(id, reason: "\(name) was closed without merging") }
            if status.approved {
                update(id) { $0.log("\(name) is approved", .good) }
                return advance(id)
            }
            if status.reviewDecision == "CHANGES_REQUESTED" {
                update(id) { $0.activity = "Changes requested on \(name)" }
            }
        case .merged:
            if status.isMerged {
                update(id) { $0.log("\(name) merged", .good) }
                return advance(id)
            }
            if status.isClosed { return stop(id, reason: "\(name) was closed without merging") }
        case .command, .time:
            break
        }
        if deadlinePassed {
            return problem(id, "Still waiting", Self.waitText(waitFor, run.pullRequest) + " after the time it was given.", [.retry, .skip, .stop])
        }
        update(id) { $0.stage.nextPollAt = Date().addingTimeInterval(waitFor == .checks ? 60 : 120) }
    }

    /// Merged already: on past the stages that would merge it.
    private func skipPastMerge(_ id: UUID, _ name: String) {
        guard let run = run(id) else { return }
        let stages = run.workflow.stages(run.position.part)
        update(id) { r in
            r.log("\(name) is already merged", .good)
            if let wait = stages.indices.dropFirst(r.position.index).first(where: { stages[$0].kind == .wait && stages[$0].waitFor == .merged }) {
                r.position.index = wait
            }
        }
        advance(id)
    }

    /// The PR was merged (done: nothing after it needs to run) or closed (stopped).
    private func finishWith(_ id: UUID, _ reason: String, closed: Bool = false) {
        if closed { return stop(id, reason: reason) }
        update(id) { $0.log(reason, .good) }
        finish(id)
    }

    // MARK: - Feedback

    private func startFeedback(_ id: UUID) {
        guard let run = run(id) else { return }
        let token = run.stage.token
        update(id) { $0.activity = "Reading CI and comments" }
        Task {
            do {
                let status = try await pullRequestStatus(id)
                if status.isMerged || status.isClosed {
                    guard current(id, token) else { return }
                    return finishWith(id, "#\(status.number) was \(status.isMerged ? "merged" : "closed")", closed: !status.isMerged)
                }
                guard let repo = status.repo else { throw WorkflowTools.GitHubError(message: "Unexpected pull request link \(status.url)") }
                let threads = try await makeTools().threads(repo: repo, number: status.number, in: run.folder)
                guard current(id, token) else { return }
                var people: [String] = []
                update(id) { r in
                    let merged = FindingLedger.mergeFeedback(r.findings, failing: status.failing, threads: threads, round: r.round)
                    r.findings = merged.findings
                    people = merged.people
                    let bots = threads.filter { !$0.isResolved && !$0.isOutdated && $0.authorIsBot }.count
                    r.log("CI: \(status.failing.isEmpty ? "green" : "\(status.failing.count) failing") · \(bots) bot comment\(bots == 1 ? "" : "s") · \(people.count) new from people",
                          status.failing.isEmpty && bots == 0 ? .good : .info)
                }
                if !people.isEmpty {
                    return ask(id, Ask(kind: .peopleComments, title: "\(people.count) comment\(people.count == 1 ? "" : "s") from people",
                                       detail: "Simul never replies to people. Hand them to the agent to address in code, or handle them yourself.",
                                       actions: [.agentHandles, .iHandle, .stop], findings: people))
                }
                advance(id)
            } catch {
                guard current(id, token) else { return }
                problem(id, "Couldn't read the pull request", error.localizedDescription)
            }
        }
    }

    // MARK: - Gate

    private func startGate(_ id: UUID, _ stage: WorkflowStage) {
        guard let run = run(id) else { return }
        let question = WorkflowText.fill(stage.question ?? "", run.values())
        let open = run.findings.filter { $0.status == .open || $0.status == .yours }
        var detail = open.isEmpty ? "No open findings." : "\(open.count) open finding\(open.count == 1 ? "" : "s")."
        var actions: [Ask.Action] = [.continue, .stop]
        let reviewing = run.reviewsSomeoneElsesPR && run.pullRequest != nil
        if reviewing {
            detail += " Open them in Review to keep the ones you agree with and submit them yourself. Continue waits for the next push."
            actions = [.openReview, .continue, .stop]
        }
        guard let limitInput = stage.skipIfDiffAtMost, let limit = WorkflowText.number(run.inputs[limitInput], [:]), limit > 0 else {
            return ask(id, Ask(kind: reviewing ? .reviewReady : .confirm, title: question, detail: detail, actions: actions))
        }
        let token = run.stage.token
        Task {
            let tools = await makeTools()
            let lines = await tools.diffLines(run.folder, since: await tools.mergePoint(run.folder))
            guard current(id, token) else { return }
            if Double(lines) <= limit {
                update(id) { $0.log("Skipped “\(stage.title)”: \(lines) lines, at most \(Int(limit))") }
                return advance(id)
            }
            ask(id, Ask(kind: .confirm, title: question, detail: "\(lines) lines changed. " + detail, actions: actions))
        }
    }

    // MARK: - Pull requests

    /// The run's PR (from its input, else this branch's), remembered on the run.
    func pullRequestStatus(_ id: UUID) async throws -> PullRequestStatus {
        guard let run = run(id) else { throw WorkflowTools.GitHubError(message: "The run is gone") }
        let target = run.pullRequest.map { $0.url } ?? (run.inputs["pr"] ?? "")
        let status = try await makeTools().pullRequest(target, in: run.folder)
        if run.pullRequest == nil, let repo = status.repo {
            update(id) { r in
                r.pullRequest = WorkflowRun.PullRequestRef(number: status.number, url: status.url, repo: repo)
                r.log("Pull request #\(status.number)")
            }
        }
        return status
    }

    func discoverPullRequest(_ id: UUID) async {
        _ = try? await pullRequestStatus(id)
    }

    /// Someone else's PR checked out at its head (Simul's own worktree, or the user's if it's there).
    private func reviewWorktree(_ id: UUID) async throws -> (folder: String, base: String, name: String, head: String) {
        guard let app else { throw WorkflowTools.GitHubError(message: "The run is gone") }
        let status = try await pullRequestStatus(id)
        guard let run = run(id), let repo = status.repo else { throw WorkflowTools.GitHubError(message: "Unexpected pull request link \(status.url)") }
        let prepared = try await app.reviews.preparePullRequest(repo: repo, number: status.number, folder: run.folder)
        return (prepared.path, prepared.base, "#\(status.number)", status.headSHA)
    }

    /// Shows the run's reviewer findings as the agent's draft comments on its PR in Review.
    func openReview(_ id: UUID) {
        guard let run = run(id), let app, let pr = run.pullRequest,
              let session = app.sessions.first(where: { $0.id == run.sessionID }) else { return }
        let source = ReviewSource.pullRequest(repo: pr.repo, number: pr.number)
        let comments = run.findings.filter { $0.key == nil && $0.status == .open && $0.path != nil && $0.line != nil }
            .map { f -> [String: Any] in
                ["path": f.path ?? "", "line": f.line ?? 1, "body": "**\(f.title)**" + (f.detail.isEmpty ? "" : " " + f.detail)]
            }
        let file = AgentDrafts.file(session: session.id, source: source)
        try? FileManager.default.createDirectory(at: Paths.agentDrafts, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "comments": comments]) {
            try? data.write(to: file, options: .atomic)
        }
        showing = false
        app.select(session)
        app.reviews.setSource(session.id, source)
        if !app.reviews.isShowing(session.id) { app.reviews.show(session) }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
