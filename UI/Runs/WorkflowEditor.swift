import AppKit
import SwiftUI

/// Edits one of the user's workflows as a form: its stages before, in and
/// after the loop, each stage's fields by kind, and the inputs it asks for.
/// Saves to its JSON file in the workflows folder.
struct WorkflowEditor: View {
    @Environment(AppModel.self) private var model
    let start: WorkflowEngine.Editor
    @State private var draft = Workflow(id: "", name: "", summary: "")
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        let problems = draft.validate() + idProblems
        VStack(alignment: .leading, spacing: 18) {
            header(problems)
            section("About") {
                field("Name") { TextField("e.g. Ship with my checks", text: $draft.name).simulField() }
                field("Summary", help: "One sentence: what it does and where it stops.") {
                    TextField("", text: $draft.summary, axis: .vertical).lineLimit(1...3).simulField()
                }
                field("Id", help: "Letters, digits and -. Names the file.") {
                    TextField("", text: $draft.id).font(.system(size: 12, design: .monospaced)).frame(width: 260).simulField()
                }
            }
            stagesSection("Before", part: .before, help: "Runs once, first.")
            loopSection
            stagesSection("After", part: .after, help: "Runs once, after the repeating part ends.")
            inputsSection
            thenSection
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .runsScroll()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = start.workflow
        }
    }

    /// An id already taken by a built-in or another file.
    private var idProblems: [String] {
        if WorkflowTemplates.named(draft.id) != nil { return ["id: \(draft.id) is a built-in workflow's"] }
        let others = model.workflows.library.filter { $0.file != start.file }.compactMap(\.workflow?.id)
        return others.contains(draft.id) ? ["id: another workflow uses \(draft.id)"] : []
    }

    private func header(_ problems: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(start.file == nil ? "New workflow" : "Edit workflow").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("Cancel") { model.workflows.editing = nil }.buttonStyle(.simul(.pill))
                if let file = start.file {
                    Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.buttonStyle(.simul(.quiet))
                }
                Button("Save") { save() }.buttonStyle(.simul(.primary)).disabled(!problems.isEmpty)
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.self) { Text($0) }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(RunColors.warn)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(RunColors.bad) }
        }
    }

    // MARK: Stages

    private func stages(_ part: StagePosition.Part) -> Binding<[WorkflowStage]> {
        switch part {
        case .before: $draft.before
        case .after: $draft.after
        case .loop:
            Binding(get: { draft.loop?.stages ?? [] },
                    set: { stages in
                        if draft.loop == nil { draft.loop = .init(stages: stages, maxRounds: "3") } else { draft.loop?.stages = stages }
                    })
        }
    }

    private var loopSection: some View {
        let hasLoop = Binding(get: { draft.loop != nil },
                              set: { on in draft.loop = on ? (draft.loop ?? .init(stages: [], maxRounds: "3")) : nil })
        return section("Repeats", help: "Runs again, round after round, until a Fix stage finds nothing left to fix, a wait ends it, or the rounds run out.") {
            HStack(spacing: 12) {
                Toggle("A part that repeats", isOn: hasLoop).toggleStyle(.switch).controlSize(.small)
                if draft.loop != nil {
                    Text("Rounds at most").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("3 or {input}", text: Binding(get: { draft.loop?.maxRounds ?? "" }, set: { draft.loop?.maxRounds = $0 }))
                        .frame(width: 110).simulField()
                }
            }
            if draft.loop != nil { stageList(.loop) }
        }
    }

    private func stagesSection(_ title: String, part: StagePosition.Part, help: String) -> some View {
        section(title, help: help) { stageList(part) }
    }

    private func stageList(_ part: StagePosition.Part) -> some View {
        let list = stages(part)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(list.wrappedValue.indices, id: \.self) { index in
                StageEditor(stage: list[index], inputs: draft.inputs.map(\.id),
                            moveUp: index > 0 ? { list.wrappedValue.swapAt(index, index - 1) } : nil,
                            moveDown: index < list.wrappedValue.count - 1 ? { list.wrappedValue.swapAt(index, index + 1) } : nil,
                            remove: { list.wrappedValue.remove(at: index) })
            }
            Menu {
                ForEach(WorkflowStage.Kind.allCases, id: \.self) { kind in
                    Button { list.wrappedValue.append(Self.newStage(kind)) } label: { Label(kind.name, systemImage: kind.icon) }
                }
            } label: {
                Label("Add stage", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    static func newStage(_ kind: WorkflowStage.Kind) -> WorkflowStage {
        switch kind {
        case .agent: WorkflowStage(.agent, "Agent step", prompt: "")
        case .review: WorkflowStage(.review, "Review", reviewers: "claude")
        case .fix: WorkflowStage(.fix, "Fix", fixAtLeast: "medium", askBelow: "true")
        case .check: WorkflowStage(.check, "Run checks", command: "", timeoutMinutes: 30)
        case .wait: WorkflowStage(.wait, "Wait for CI", waitFor: .checks)
        case .feedback: WorkflowStage(.feedback, "Read CI and comments")
        case .gate: WorkflowStage(.gate, "Your OK", question: "Go on?")
        case .verify: WorkflowStage(.verify, "Check it", prompt: "")
        }
    }

    // MARK: Inputs

    private var inputsSection: some View {
        section("Inputs", help: "What you fill in when starting it. Use one in a stage's text as {id}.") {
            ForEach($draft.inputs.indices, id: \.self) { index in
                InputEditor(input: $draft.inputs[index]) { draft.inputs.remove(at: index) }
            }
            Button {
                draft.inputs.append(WorkflowInput("input\(draft.inputs.count + 1)", "New input", .text))
            } label: { Label("Add input", systemImage: "plus") }
                .buttonStyle(.simul(.quiet))
        }
    }

    private var thenSection: some View {
        section("Then", help: "Another workflow to start on the same session when this one finishes, with the same inputs.") {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { draft.then ?? "" }, set: { draft.then = $0.isEmpty ? nil : $0 })) {
                    Text("Nothing").tag("")
                    ForEach(model.workflows.workflows.filter { $0.id != draft.id }) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 220)
                if draft.then != nil {
                    Text("only when").font(.system(size: 12)).foregroundStyle(.secondary)
                    InputPicker(selection: $draft.thenIf, inputs: draft.inputs.map(\.id), none: "always")
                }
            }
        }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            if let help { Text(help).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
            content()
        }
    }

    private func field<Content: View>(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5, weight: .medium)).frame(width: 90, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                content()
                if let help { Text(help).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
        }
    }

    private func save() {
        do {
            _ = try WorkflowLibrary.write(draft, replacing: start.file)
            model.workflows.reloadLibrary()
            model.workflows.editing = nil
            // Back to the form, on the workflow just saved.
            model.workflows.composing = .init(sessionID: model.selectedSessionID, workflowID: draft.id)
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// One stage's fields, by its kind.
private struct StageEditor: View {
    @Binding var stage: WorkflowStage
    let inputs: [String]
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: stage.kind.icon).frame(width: 16).foregroundStyle(.secondary)
                Picker("", selection: $stage.kind) {
                    ForEach(WorkflowStage.Kind.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("Title", text: $stage.title).font(.system(size: 12.5, weight: .medium)).simulField()
                Button { moveUp?() } label: { Image(systemName: "arrow.up") }.buttonStyle(.simul(.quiet)).disabled(moveUp == nil)
                Button { moveDown?() } label: { Image(systemName: "arrow.down") }.buttonStyle(.simul(.quiet)).disabled(moveDown == nil)
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.simul(.quiet)).help("Remove stage")
            }
            Text(stage.kind.explanation).font(.system(size: 11)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 6) {
                switch stage.kind {
                case .agent, .verify:
                    text("Prompt", $stage.prompt, lines: 2...8, placeholder: "What the agent should do. {input} fills in an input.")
                case .review:
                    text("Reviewers", $stage.reviewers, placeholder: "claude, codex, or {reviewers}")
                    text("Tell them", $stage.instructions, lines: 1...4, placeholder: "Added to every reviewer's prompt")
                case .fix:
                    text("Fix without asking", $stage.fixAtLeast, placeholder: "high, medium, low or {input}")
                    text("Ask about lower", $stage.askBelow, placeholder: "true, false or {input}")
                case .check:
                    text("Command", $stage.command, mono: true, placeholder: "npm test && npm run lint")
                    timeout
                case .wait:
                    HStack(spacing: 8) {
                        Text("Until").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        Picker("", selection: Binding(get: { stage.waitFor ?? .checks }, set: { stage.waitFor = $0 })) {
                            ForEach(WorkflowStage.WaitFor.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    if stage.waitFor == .command { text("Command", $stage.command, mono: true, placeholder: "exits 0 when it's done") }
                    if stage.waitFor == .time { text("Hours", $stage.hours, placeholder: "2 or {input}") }
                    timeout
                case .gate:
                    text("Question", $stage.question, placeholder: "Merge {pr}?")
                    HStack(spacing: 8) {
                        Text("Skip when at most").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        InputPicker(selection: $stage.skipIfDiffAtMost, inputs: inputs, none: "never")
                        Text("lines changed").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .feedback:
                    EmptyView()
                }
                HStack(spacing: 8) {
                    Text("Only when").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                    InputPicker(selection: $stage.skipUnless, inputs: inputs, none: "always")
                    Text("is filled in").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 24)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(RunColors.card))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(RunColors.line))
    }

    private var timeout: some View {
        HStack(spacing: 8) {
            Text("Give up after").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            TextField("never", text: Binding(get: { stage.timeoutMinutes.map(String.init) ?? "" },
                                             set: { stage.timeoutMinutes = Int($0) }))
                .frame(width: 70).simulField()
            Text("minutes").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func text(_ label: String, _ value: Binding<String?>, lines: ClosedRange<Int> = 1...1, mono: Bool = false,
                      placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            TextField(placeholder, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 }),
                      axis: lines.upperBound > 1 ? .vertical : .horizontal)
                .lineLimit(lines)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .simulField()
        }
    }
}

private struct InputEditor: View {
    @Binding var input: WorkflowInput
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("id", text: $input.id).font(.system(size: 12, design: .monospaced)).frame(width: 140).simulField()
                TextField("Label", text: $input.label).simulField()
                Picker("", selection: $input.kind) {
                    ForEach([WorkflowInput.Kind.text, .longText, .command, .pullRequest, .number, .toggle, .agents, .severity], id: \.self) {
                        Text($0.name).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Toggle("Required", isOn: Binding(get: { input.required == true }, set: { input.required = $0 ? true : nil }))
                    .toggleStyle(.checkbox)
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.simul(.quiet))
            }
            HStack(spacing: 8) {
                TextField("Default", text: Binding(get: { input.defaultValue ?? "" }, set: { input.defaultValue = $0.isEmpty ? nil : $0 }))
                    .frame(width: 140).simulField()
                TextField("Help", text: Binding(get: { input.help ?? "" }, set: { input.help = $0.isEmpty ? nil : $0 })).simulField()
                TextField("Placeholder", text: Binding(get: { input.placeholder ?? "" }, set: { input.placeholder = $0.isEmpty ? nil : $0 }))
                    .simulField()
                TextField("Box", text: Binding(get: { input.group ?? "" }, set: { input.group = $0.isEmpty ? nil : $0 }))
                    .frame(width: 110).simulField()
                    .help("Groups it on the start form, e.g. Review; \"\(WorkflowInput.advanced)\" starts folded")
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(RunColors.card))
    }
}

/// Picks one of the workflow's inputs, or none.
private struct InputPicker: View {
    @Binding var selection: String?
    let inputs: [String]
    let none: String

    var body: some View {
        Picker("", selection: Binding(get: { selection ?? "" }, set: { selection = $0.isEmpty ? nil : $0 })) {
            Text(none).tag("")
            ForEach(inputs, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 160)
    }
}

extension WorkflowStage.Kind {
    var name: String {
        switch self {
        case .agent: "Agent"
        case .review: "Review"
        case .fix: "Fix"
        case .check: "Check"
        case .wait: "Wait"
        case .feedback: "PR feedback"
        case .gate: "Your OK"
        case .verify: "Verify"
        }
    }

    var explanation: String {
        switch self {
        case .agent: "The session's agent does the prompt; done when its turn ends."
        case .review: "New reviewer sessions review the change and write findings."
        case .fix: "The session's agent fixes the open findings. In the repeating part, nothing left to fix ends it."
        case .check: "The command must exit 0; a failure becomes a finding to fix."
        case .wait: "Waits for something outside: CI, a merge, a push, a command, a time."
        case .feedback: "The pull request's failing checks and open comments become findings."
        case .gate: "Waits for your OK."
        case .verify: "The agent checks the prompt and reports ok or a problem, changing nothing."
        }
    }
}

extension WorkflowStage.WaitFor {
    var name: String {
        switch self {
        case .checks: "CI on the PR has finished"
        case .newCommit: "the PR has new commits"
        case .approved: "the PR is approved"
        case .merged: "the PR is merged"
        case .command: "a command succeeds"
        case .time: "some hours pass"
        }
    }
}

extension WorkflowInput.Kind {
    var name: String {
        switch self {
        case .text: "Text"
        case .longText: "Long text"
        case .command: "Command"
        case .pullRequest: "Pull request"
        case .number: "Number"
        case .toggle: "On / off"
        case .agents: "Agents"
        case .severity: "Severity"
        }
    }
}
