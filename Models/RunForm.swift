import Foundation
import Observation

/// One input's value, observed on its own: typing in a field redraws that
/// field and the stage that uses it, not the whole form.
@available(macOS 14, *)
@Observable final class FormField {
    var text: String
    init(_ text: String) { self.text = text }
}

/// The start form of one workflow: a field per input, and where each input
/// is edited (in the stage that uses it, so the form is the workflow's graph).
@available(macOS 14, *)
final class RunForm {
    let workflow: Workflow
    let fields: [String: FormField]
    /// Asked about before any stage: the pull request, and inputs no stage uses.
    private(set) var setup: [WorkflowInput] = []
    /// The loop's round limit, edited in its header.
    private(set) var rounds: WorkflowInput?
    /// Inputs edited in each stage; the stage's on/off switch.
    private(set) var inputs: [StagePosition: [WorkflowInput]] = [:]
    private(set) var toggles: [StagePosition: WorkflowInput] = [:]
    /// The workflow started after this one: its switch and what it needs.
    private(set) var thenToggle: WorkflowInput?
    private(set) var thenInputs: [WorkflowInput] = []

    init(_ workflow: Workflow) {
        self.workflow = workflow
        fields = Dictionary(workflow.inputs.map { ($0.id, FormField($0.defaultValue ?? "")) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(workflow.inputs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<String>()
        func claim(_ id: String?) -> WorkflowInput? {
            guard let id, let input = byID[id], !claimed.contains(id) else { return nil }
            claimed.insert(id)
            return input
        }
        setup = workflow.inputs.filter { $0.kind == .pullRequest }.compactMap { claim($0.id) }
        rounds = workflow.loop.flatMap { claim(WorkflowText.references($0.maxRounds).first) }
        if let id = workflow.thenIf, byID[id]?.kind == .toggle { thenToggle = claim(id) }
        // Each input goes to the first stage that uses it.
        for position in workflow.allPositions {
            guard let stage = workflow.stage(at: position) else { continue }
            if let id = stage.skipUnless, byID[id]?.kind == .toggle { toggles[position] = claim(id) }
            inputs[position] = (Self.references(stage) + [stage.skipUnless, stage.skipIfDiffAtMost].compactMap { $0 }).compactMap(claim)
        }
        let rest = workflow.inputs.filter { !claimed.contains($0.id) }
        if workflow.then != nil { thenInputs = rest } else { setup += rest }
    }

    var values: [String: String] { fields.mapValues(\.text) }

    /// Only these fields' values (reading them is all a stage observes),
    /// with readable stand-ins for what's known only once it runs.
    func values(_ ids: [String]) -> [String: String] {
        var values = Dictionary(ids.compactMap { id in fields[id].map { (id, $0.text) } }, uniquingKeysWith: { a, _ in a })
        let pr = ids.contains("pr") ? fields["pr"]?.text.trimmingCharacters(in: .whitespaces) ?? "" : ""
        let standIns = ["pr": pr.isEmpty ? "the pull request" : (Int(pr) != nil ? "#" + pr : pr),
                        "pr_number": "the pull request", "pr_url": "the pull request",
                        "merge_sha": "the merge commit", "folder": "the folder", "round": "this round"]
        for (id, text) in standIns where ids.contains(id) && (id == "pr" || values[id] == nil) { values[id] = text }
        return values
    }

    static func references(_ stage: WorkflowStage) -> [String] {
        [stage.prompt, stage.command, stage.reviewers, stage.instructions, stage.hours, stage.question,
         stage.fixAtLeast, stage.askBelow].compactMap { $0 }.flatMap(WorkflowText.references)
    }
}
