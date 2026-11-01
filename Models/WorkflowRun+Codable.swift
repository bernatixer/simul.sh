import Foundation

// Saved runs read leniently: a field added later (or one that can't be
// read) takes its default, so an older runs.json still loads. Only ids,
// the workflow and the session are required.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension WorkflowRun {
    enum CodingKeys: String, CodingKey {
        case id, workflow, sessionID, folder, inputs, createdAt, updatedAt, status, position, round, stage, activity, ask
        case findings, events, pullRequest, pauseRequested, lastReviewedHead
        case baselineDiffLines, diffWarned, fixesThisRound, checkRetries, finishedAt, helperSessions, extraRounds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let workflow = try c.decode(Workflow.self, forKey: .workflow)
        self.init(id: try c.decode(UUID.self, forKey: .id), workflow: workflow, sessionID: try c.decode(UUID.self, forKey: .sessionID),
                  folder: c.value(.folder, ""), inputs: c.value(.inputs, [:]), now: c.value(.createdAt, Date()))
        updatedAt = c.value(.updatedAt, createdAt)
        status = c.value(.status, .stopped)
        position = c.value(.position, position)
        round = c.value(.round, 0)
        stage = c.value(.stage, StageState())
        activity = c.value(.activity, "")
        ask = c.value(.ask, nil)
        findings = c.value(.findings, [])
        events = c.value(.events, [])
        pullRequest = c.value(.pullRequest, nil)
        pauseRequested = c.value(.pauseRequested, false)
        lastReviewedHead = c.value(.lastReviewedHead, nil)
        baselineDiffLines = c.value(.baselineDiffLines, nil)
        diffWarned = c.value(.diffWarned, false)
        fixesThisRound = c.value(.fixesThisRound, false)
        checkRetries = c.value(.checkRetries, 0)
        finishedAt = c.value(.finishedAt, nil)
        helperSessions = c.value(.helperSessions, [])
        extraRounds = c.value(.extraRounds, 0)
    }
}

extension WorkflowRun.StageState {
    enum CodingKeys: String, CodingKey {
        case token, startedAt, pendingPrompt, pendingSince, headAtStart, promptSentAt, turnStarted, reviewers
        case nextPollAt, lookingSince, deadline, pollFailures, beforeTree, fixing, resultFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        token = c.value(.token, UUID())
        startedAt = c.value(.startedAt, Date())
        pendingPrompt = c.value(.pendingPrompt, nil)
        pendingSince = c.value(.pendingSince, nil)
        headAtStart = c.value(.headAtStart, nil)
        promptSentAt = c.value(.promptSentAt, nil)
        turnStarted = c.value(.turnStarted, false)
        reviewers = c.value(.reviewers, [])
        nextPollAt = c.value(.nextPollAt, nil)
        lookingSince = c.value(.lookingSince, nil)
        deadline = c.value(.deadline, nil)
        pollFailures = c.value(.pollFailures, 0)
        beforeTree = c.value(.beforeTree, nil)
        fixing = c.value(.fixing, [])
        resultFile = c.value(.resultFile, nil)
    }
}

extension WorkflowRun.Reviewer {
    enum CodingKeys: String, CodingKey { case agentID, sessionID, file, state, nudges, started, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(agentID: try c.decode(String.self, forKey: .agentID), sessionID: try c.decode(UUID.self, forKey: .sessionID),
                  file: c.value(.file, ""), state: c.value(.state, .failed), nudges: c.value(.nudges, 0), started: c.value(.started, true),
                  createdAt: c.value(.createdAt, Date()))
    }
}

extension Finding {
    enum CodingKeys: String, CodingKey {
        case id, key, sources, severity, title, detail, path, line, url, status, raisedRound, updatedRound, fixedIn, note, cameBack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), key: c.value(.key, nil), sources: c.value(.sources, []),
                  severity: c.value(.severity, .medium), title: c.value(.title, ""), detail: c.value(.detail, ""),
                  path: c.value(.path, nil), line: c.value(.line, nil), url: c.value(.url, nil), status: c.value(.status, .open),
                  raisedRound: c.value(.raisedRound, 0), updatedRound: c.value(.updatedRound, 0), fixedIn: c.value(.fixedIn, nil),
                  note: c.value(.note, nil), cameBack: c.value(.cameBack, false))
    }
}

extension Ask {
    enum CodingKeys: String, CodingKey { case kind, title, detail, actions, findings, session }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: c.value(.kind, .problem), title: c.value(.title, ""), detail: c.value(.detail, ""),
                  actions: c.value(.actions, [.stop]), findings: c.value(.findings, []), session: c.value(.session, nil))
    }
}
