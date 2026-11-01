import Foundation

/// A routine Simul runs on a session: stages in order, at most one loop of
/// them, then more stages. Never a graph: anything that needs more is two
/// workflows. Built-ins live in WorkflowTemplates; the user's own are JSON
/// files in `<data dir>/workflows/` (same shape as this struct).
struct Workflow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    /// One sentence: what it does and where it stops.
    var summary: String
    var inputs: [WorkflowInput]
    var before: [WorkflowStage]
    var loop: Loop?
    var after: [WorkflowStage]
    /// Another workflow to start on the same session when this one finishes,
    /// with the same inputs; only when the `thenIf` input is on.
    var then: String?
    var thenIf: String?

    struct Loop: Codable, Equatable, Sendable {
        var stages: [WorkflowStage]
        /// A number, or "{input}".
        var maxRounds: String
    }

    init(id: String, name: String, summary: String, inputs: [WorkflowInput] = [], before: [WorkflowStage] = [],
         loop: Loop? = nil, after: [WorkflowStage] = [], then: String? = nil, thenIf: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.inputs = inputs
        self.before = before
        self.loop = loop
        self.after = after
        self.then = then
        self.thenIf = thenIf
    }

    // Hand-written files may leave out empty lists.
    enum CodingKeys: String, CodingKey { case id, name, summary, inputs, before, loop, after, then, thenIf }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        inputs = try c.decodeIfPresent([WorkflowInput].self, forKey: .inputs) ?? []
        before = try c.decodeIfPresent([WorkflowStage].self, forKey: .before) ?? []
        loop = try c.decodeIfPresent(Loop.self, forKey: .loop)
        after = try c.decodeIfPresent([WorkflowStage].self, forKey: .after) ?? []
        then = try c.decodeIfPresent(String.self, forKey: .then)
        thenIf = try c.decodeIfPresent(String.self, forKey: .thenIf)
    }
}

/// Something the user fills in when starting a run.
struct WorkflowInput: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case text, longText, command, pullRequest, number, toggle
        /// Comma-separated agent ids ("claude,codex").
        case agents
        /// high, medium or low.
        case severity
    }

    var id: String
    var label: String
    var kind: Kind
    var help: String?
    var placeholder: String?
    var defaultValue: String?
    var required: Bool?
    init(_ id: String, _ label: String, _ kind: Kind, help: String? = nil, placeholder: String? = nil,
         defaultValue: String? = nil, required: Bool? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.help = help
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.required = required
    }
}

/// One step. Which fields matter depends on `kind` (see validate()).
struct WorkflowStage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// The session's agent does `prompt`; done when its turn ends.
        case agent
        /// Fresh reviewer sessions write findings; done when all have.
        case review
        /// The session's agent fixes the open findings; in a loop, nothing
        /// left to fix ends the loop.
        case fix
        /// `command` must exit 0; a failure is a finding to fix.
        case check
        /// Something outside happens (CI, a merge, a push, a time).
        case wait
        /// The pull request's failing checks and open threads become findings.
        case feedback
        /// The user decides before the run goes on.
        case gate
        /// The agent checks `prompt` and reports ok or a problem; changes nothing.
        case verify
    }

    enum WaitFor: String, Codable, Sendable, CaseIterable {
        /// The PR's checks all finished (any result).
        case checks
        /// The PR's head moved past the last reviewed commit (at once the
        /// first time). Merged or closed ends the loop.
        case newCommit
        /// Approved, or nothing requires approval.
        case approved
        case merged
        /// `command` exits 0.
        case command
        /// `hours` passed.
        case time
    }

    var kind: Kind
    var title: String
    var prompt: String?
    var command: String?
    /// Agent ids, comma-separated, or "{input}".
    var reviewers: String?
    /// Added to every reviewer's prompt ("Use the /review skill").
    var instructions: String?
    var waitFor: WaitFor?
    /// For waitFor time: a number or "{input}".
    var hours: String?
    var timeoutMinutes: Int?
    var question: String?
    /// Fix: the lowest severity fixed without asking (a severity or "{input}").
    var fixAtLeast: String?
    /// Fix: ask about lower findings instead of skipping them ("true" or "{input}").
    var askBelow: String?
    /// Skipped unless this input is on (filled in, not 0 / false / no / off).
    var skipUnless: String?
    /// Gate: skipped when the change is at most this many lines (an input
    /// id holding a number; 0 never skips).
    var skipIfDiffAtMost: String?

    init(_ kind: Kind, _ title: String, prompt: String? = nil, command: String? = nil, reviewers: String? = nil,
         instructions: String? = nil, waitFor: WaitFor? = nil, hours: String? = nil, timeoutMinutes: Int? = nil,
         question: String? = nil, fixAtLeast: String? = nil, askBelow: String? = nil, skipUnless: String? = nil,
         skipIfDiffAtMost: String? = nil) {
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.command = command
        self.reviewers = reviewers
        self.instructions = instructions
        self.waitFor = waitFor
        self.hours = hours
        self.timeoutMinutes = timeoutMinutes
        self.question = question
        self.fixAtLeast = fixAtLeast
        self.askBelow = askBelow
        self.skipUnless = skipUnless
        self.skipIfDiffAtMost = skipIfDiffAtMost
    }

    /// Needs a pull request to run.
    var usesPullRequest: Bool {
        switch kind {
        case .feedback: true
        case .wait: waitFor != .command && waitFor != .time
        default: false
        }
    }
}

// MARK: - Positions

/// Where a run is: which list, which stage in it.
struct StagePosition: Codable, Equatable, Hashable, Sendable {
    enum Part: String, Codable, Sendable, CaseIterable { case before, loop, after }
    var part: Part
    var index: Int
}

extension Workflow {
    func stages(_ part: StagePosition.Part) -> [WorkflowStage] {
        switch part {
        case .before: before
        case .loop: loop?.stages ?? []
        case .after: after
        }
    }

    func stage(at position: StagePosition) -> WorkflowStage? {
        let list = stages(position.part)
        return list.indices.contains(position.index) ? list[position.index] : nil
    }

    /// The first stage of the first non-empty part from `part` on.
    func first(from part: StagePosition.Part) -> StagePosition? {
        let order: [StagePosition.Part] = [.before, .loop, .after]
        for p in order.drop(while: { $0 != part }) where !stages(p).isEmpty {
            return StagePosition(part: p, index: 0)
        }
        return nil
    }

    /// Every stage in order, for the stage rail.
    var allPositions: [StagePosition] {
        [StagePosition.Part.before, .loop, .after].flatMap { part in
            stages(part).indices.map { StagePosition(part: part, index: $0) }
        }
    }

    var usesPullRequest: Bool {
        allPositions.contains { stage(at: $0)?.usesPullRequest == true }
    }
}

// MARK: - Inputs and text

enum WorkflowText {
    /// Values Simul fills in itself, besides the inputs.
    /// {pr} is "#12" for prompts; {pr_number} is "12" for commands.
    static let builtIns: Set<String> = ["pr", "pr_number", "pr_url", "folder", "merge_sha", "round"]

    /// `text` with each `{name}` replaced by its value; unknown names stay as written.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        guard text.contains("{") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = values[String(after[..<close])] {
                out += value
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }

    /// The `{name}`s in `text` that look like references (letters, digits, _).
    static func references(_ text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "}") else { break }
            let name = String(after[..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { names.append(name) }
            rest = after[after.index(after: close)...]
        }
        return names
    }

    /// Filled in, and not 0 / false / no / off.
    static func isOn(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        return !["0", "false", "no", "off"].contains(value.lowercased())
    }

    /// A number, or "{input}" holding one.
    static func number(_ text: String?, _ values: [String: String]) -> Double? {
        guard let text else { return nil }
        return Double(fill(text, values).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Validation

extension Workflow {
    /// What's wrong with it, in words a person can fix; empty when it can run.
    func validate() -> [String] {
        var problems: [String] = []
        let id = id.trimmingCharacters(in: .whitespaces)
        if id.isEmpty || !id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            problems.append("id: use letters, digits, - and _ only")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name: missing") }
        let inputIDs = inputs.map(\.id)
        if Set(inputIDs).count != inputIDs.count { problems.append("inputs: two inputs have the same id") }
        let known = Set(inputIDs).union(WorkflowText.builtIns)
        if allPositions.isEmpty { problems.append("no stages") }
        if let loop {
            if loop.stages.isEmpty { problems.append("loop: no stages") }
            if WorkflowText.number(loop.maxRounds, defaults).map({ $0 < 1 }) ?? true {
                problems.append("loop.maxRounds: a number of at least 1, or {input}")
            }
        }
        for position in allPositions {
            guard let stage = stage(at: position) else { continue }
            let at = "\(position.part.rawValue)[\(position.index)] \(stage.title)"
            problems += stage.problems().map { "\(at): \($0)" }
            for text in [stage.prompt, stage.command, stage.reviewers, stage.instructions, stage.hours, stage.question,
                         stage.fixAtLeast, stage.askBelow].compactMap({ $0 }) {
                for name in WorkflowText.references(text) where !known.contains(name) {
                    problems.append("\(at): {\(name)} isn't an input")
                }
            }
            for name in [stage.skipUnless, stage.skipIfDiffAtMost].compactMap({ $0 }) where !inputIDs.contains(name) {
                problems.append("\(at): \(name) isn't an input")
            }
        }
        if let thenIf, !inputIDs.contains(thenIf) { problems.append("thenIf: \(thenIf) isn't an input") }
        if then == id { problems.append("then: a workflow can't start itself") }
        return problems
    }

    /// Each input's default, for checks that need a value.
    /// A review stage that will run (its switch is on) has no reviewer
    /// among `known` agent ids.
    func lacksReviewers(_ inputs: [String: String], known: Set<String>) -> Bool {
        let values = defaults.merging(inputs) { $1 }
        return allPositions.contains { position in
            guard let stage = stage(at: position), stage.kind == .review,
                  stage.skipUnless.map({ WorkflowText.isOn(values[$0]) }) ?? true else { return false }
            return !WorkflowText.fill(stage.reviewers ?? "", values).split(separator: ",")
                .contains { known.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
    }

    var defaults: [String: String] {
        Dictionary(inputs.compactMap { input in input.defaultValue.map { (input.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
}

extension WorkflowStage {
    func problems() -> [String] {
        var problems: [String] = []
        if title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("title missing") }
        func need(_ value: String?, _ name: String) {
            if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { problems.append("\(name) missing") }
        }
        switch kind {
        case .agent, .verify: need(prompt, "prompt")
        case .check: need(command, "command")
        case .review: need(reviewers, "reviewers")
        case .gate: need(question, "question")
        case .fix, .feedback: break
        case .wait:
            switch waitFor {
            case nil: problems.append("waitFor missing (\(WaitFor.allCases.map(\.rawValue).joined(separator: ", ")))")
            case .command?: need(command, "command")
            case .time?: need(hours, "hours")
            default: break
            }
        }
        return problems
    }
}
