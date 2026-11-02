import AppKit
import SwiftUI

/// Pick a workflow, then set it up on its own graph: each stage holds its
/// settings and says what it will do with them.
struct RunComposer: View {
    @Environment(AppModel.self) private var model
    let start: WorkflowEngine.Composer
    @State private var workflowID = WorkflowTemplates.ship.id
    @State private var form: RunForm?
    @State private var sessionID: UUID?
    @State private var folder = ""
    @State private var error: String?
    @State private var asked = false

    var body: some View {
        let engine = model.workflows
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start a workflow").font(.system(size: 19, weight: .semibold))
                Text("It runs on one of your sessions: its agent does the work, fresh reviewers check it, and you're asked only when it needs you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Not lazy: a lazy grid rebuilds the cards each time they scroll back in.
            CardGrid(minWidth: 220, spacing: 10) {
                ForEach(engine.workflows) { workflow in card(workflow) }
            }
            if let form, form.workflow.id == workflowID {
                setup(form)
                StageEditor(form: form, agents: reviewerAgents,
                            then: form.workflow.then.flatMap { id in engine.workflows.first { $0.id == id } })
            }
            library
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .runsScroll()
        .onAppear {
            if let id = start.workflowID { workflowID = id }
            sessionID = start.sessionID ?? model.selectedSessionID ?? model.activeSessions.first?.id
            makeForm()
        }
        .onChange(of: workflowID) { _, _ in makeForm() }
        .onChange(of: sessionID) { _, _ in resetFolder() }
    }

    private var workflow: Workflow? { model.workflows.workflows.first { $0.id == workflowID } }
    private var session: Session? { sessionID.flatMap { id in model.sessions.first { $0.id == id } } }
    private var reviewerAgents: [AgentDefinition] { AgentDefinition.builtIns.filter { $0.resume != .none } }

    // MARK: Cards

    private func card(_ workflow: Workflow) -> some View {
        let selected = workflow.id == workflowID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workflow.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if WorkflowTemplates.named(workflow.id) == nil {
                    Text("Custom").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Button("Edit") {
                        let file = model.workflows.library.first { $0.workflow?.id == workflow.id }?.file
                        model.workflows.editing = .init(workflow: workflow, file: file)
                    }
                    .buttonStyle(.simul(.quiet))
                }
            }
            Text(workflow.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            StageFlow(workflow: workflow)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : RunColors.line, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if workflowID != workflow.id { workflowID = workflow.id } }
    }

    // MARK: Where it runs

    private func setup(_ form: RunForm) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Menu {
                    ForEach(model.listedSessions) { s in
                        Button(s.title + " · " + (model.agent(for: s)?.name ?? s.agentID)) { sessionID = s.id }
                    }
                } label: {
                    Label(session.map { $0.title + " · " + (model.agent(for: $0)?.name ?? $0.agentID) } ?? "Pick a session", systemImage: "terminal")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Its agent does the work. Reviewers start next to it in the sidebar.")
                Button { chooseFolder() } label: {
                    Label { Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head) }
                        icon: { Image(systemName: "folder") }
                }
                .buttonStyle(.simul(.quiet))
                .help("Where checks run and reviewers look; for Claude, the worktree it's working in. Click to change.")
                Spacer(minLength: 8)
                Button { startRun(form) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.simul(.primary))
                    .disabled(session == nil)
            }
            ForEach(form.setup) { input in
                if let field = form.fields[input.id] { InputControl(input: input, field: field, agents: reviewerAgents) }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(RunColors.bad)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(RunColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RunColors.line))
    }

    // MARK: Your own workflows

    private var library: some View {
        let entries = model.workflows.library
        return VStack(alignment: .leading, spacing: 8) {
            Text("YOUR WORKFLOWS").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text("Change this one's stages in a copy, or describe one to the session's agent and it writes it. They're JSON files in Simul's workflows folder.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button { copySelected() } label: { Label("Make one from this", systemImage: "doc.on.doc") }
                    .buttonStyle(.simul(.pill))
                Button { describe() } label: { Label(asked ? "Asked, see the session" : "Ask the agent to write one", systemImage: "text.bubble") }
                    .buttonStyle(.simul(.pill))
                    .disabled(session == nil || asked)
                    .help("Sends the format to the selected session's agent, which asks you what the workflow should do")
                Button { openFolder() } label: { Label("Open folder", systemImage: "folder") }
                    .buttonStyle(.simul(.quiet))
                Button { model.workflows.reloadLibrary() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .buttonStyle(.simul(.quiet))
            }
            ForEach(entries.filter { !$0.problems.isEmpty }) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.file.lastPathComponent).font(.system(size: 12, weight: .medium))
                    ForEach(entry.problems, id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(RunColors.warn) }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Actions

    private func makeForm() {
        guard let workflow else { return }
        let new = RunForm(workflow)
        form = new
        model.workflows.form = new
        error = nil
        resetFolder()
    }

    /// The session folder; for Claude, the worktree it's working in.
    private func resetFolder() {
        guard let session else { return }
        folder = session.workingDirectory
        guard session.agentID == "claude", let id = session.agentSessionID else { return }
        Task {
            let cwd = await Task.detached(priority: .utility) { AgentConversations.claudeCwd(id: id) }.value
            if let cwd, sessionID == session.id { folder = cwd }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func startRun(_ form: RunForm) {
        guard let session else { return }
        switch model.workflows.start(form.workflow, on: session, inputs: form.values, folder: folder) {
        case .success:
            model.workflows.composing = nil
            error = nil
        case let .failure(problem):
            error = problem.message
        }
    }

    /// The selected workflow, as a new one of yours, in the editor.
    private func copySelected() {
        guard let workflow else { return }
        var copy = workflow
        let taken = Set(model.workflows.workflows.map(\.id))
        var n = 1
        repeat { copy.id = workflow.id + (n == 1 ? "-mine" : "-mine-\(n)"); n += 1 } while taken.contains(copy.id)
        copy.name += " (mine)"
        model.workflows.editing = .init(workflow: copy, file: nil)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: Paths.workflows, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.workflows)
    }

    private func describe() {
        guard let session, let workflow else { return }
        try? FileManager.default.createDirectory(at: Paths.workflows, withIntermediateDirectories: true)
        switch model.sendPrompt(WorkflowPrompt.authoring(example: workflow, folder: Paths.workflows.path), to: session.id) {
        case .submitted, .pasted: asked = true
        case .notReady: error = "The session isn't ready: clear its input box or answer what it's asking, then try again."
        case .failed: error = "Start the session first."
        }
    }
}

// MARK: - The graph, editable

/// The workflow top to bottom, the loop boxed with its round limit, and
/// what starts after it; each stage with its settings.
private struct StageEditor: View {
    let form: RunForm
    let agents: [AgentDefinition]
    let then: Workflow?

    var body: some View {
        let workflow = form.workflow
        let positions = workflow.allPositions
        VStack(alignment: .leading, spacing: 0) {
            ForEach(StagePosition.Part.allCases, id: \.self) { part in
                let inPart = positions.filter { $0.part == part }
                if part == .loop, !inPart.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        loopHeader
                        nodes(inPart, positions)
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .padding(.vertical, 4)
                } else {
                    nodes(inPart, positions)
                }
            }
            if let then {
                StageNode(title: "Then: \(then.name)", icon: "arrow.turn.down.right", summary: { _ in then.summary },
                          references: [], inputs: form.thenInputs, toggle: form.thenToggle, onlyWhen: nil,
                          form: form, agents: agents, first: positions.isEmpty, last: true)
            }
        }
    }

    private var loopHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "repeat").font(.system(size: 10, weight: .semibold))
            if let rounds = form.rounds, let field = form.fields[rounds.id] {
                Text("Repeats until nothing is left, up to")
                RoundsField(field: field)
                Text("rounds")
            } else {
                Text("Repeats up to \(form.workflow.loop?.maxRounds ?? "")×")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func nodes(_ part: [StagePosition], _ all: [StagePosition]) -> some View {
        ForEach(part, id: \.self) { position in
            if let stage = form.workflow.stage(at: position) {
                let toggle = form.toggles[position]
                StageNode(title: stage.title, icon: stage.kind.icon, summary: { StageGraph.describe(stage, $0) },
                          references: RunForm.references(stage), inputs: form.inputs[position] ?? [], toggle: toggle,
                          onlyWhen: stage.skipUnless == toggle?.id ? nil : stage.skipUnless.flatMap { id in form.workflow.inputs.first { $0.id == id } },
                          form: form, agents: agents, first: position == all.first, last: position == all.last && form.workflow.then == nil)
            }
        }
    }
}

/// One stage: its icon on the line, title and on/off switch, what it will
/// do, and its settings while it's on.
private struct StageNode: View {
    let title: String
    let icon: String
    let summary: ([String: String]) -> String
    let references: [String]
    let inputs: [WorkflowInput]
    let toggle: WorkflowInput?
    /// A text input that must be filled in for the stage to run (Checks).
    let onlyWhen: WorkflowInput?
    let form: RunForm
    let agents: [AgentDefinition]
    let first: Bool
    let last: Bool

    var body: some View {
        let on = isOn
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(on ? 0.10 : 0.04)))
                .overlay(Circle().strokeBorder(RunColors.line))
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? .primary : .secondary)
                    Spacer(minLength: 8)
                    if let toggle, let field = form.fields[toggle.id] {
                        Switch(field: field).help(toggle.help ?? toggle.label)
                    }
                }
                Text(on ? summary(form.values(references)) : offText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if on || toggle == nil, !inputs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(inputs) { input in
                            if let field = form.fields[input.id] { InputControl(input: input, field: field, agents: agents) }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(RunColors.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RunColors.line))
                }
            }
            .padding(.vertical, 10)
        }
        // The line joining the stages, behind the icons.
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? .clear : RunColors.line).frame(height: 20)
                Rectangle().fill(last ? .clear : RunColors.line)
            }
            .frame(width: 1.5)
            .padding(.leading, 11.25)
        }
        .padding(.leading, 8)
    }

    private var isOn: Bool {
        if let toggle { return WorkflowText.isOn(form.fields[toggle.id]?.text) }
        if let onlyWhen { return WorkflowText.isOn(form.fields[onlyWhen.id]?.text) }
        return true
    }

    private var offText: String {
        if toggle != nil { return "Off" }
        return "Off until “\(onlyWhen?.label ?? "")” is filled in"
    }
}

private struct Switch: View {
    @Bindable var field: FormField

    var body: some View {
        Toggle("", isOn: Binding(get: { WorkflowText.isOn(field.text) },
                                 set: { let v = $0 ? "true" : "false"; if field.text != v { field.text = v } }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
    }
}

private struct RoundsField: View {
    @Bindable var field: FormField

    var body: some View {
        TextField("", text: $field.text)
            .font(.system(size: 11.5).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 34)
            .simulField()
    }
}

/// One input: its label (help on hover) and the control for its kind.
private struct InputControl: View {
    let input: WorkflowInput
    @Bindable var field: FormField
    let agents: [AgentDefinition]

    var body: some View {
        if input.kind == .toggle {
            HStack(spacing: 8) {
                label
                Switch(field: field)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                label
                control
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(input.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            if input.required == true { Text("required").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            if let help = input.help {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary).help(help)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch input.kind {
        case .toggle:
            Switch(field: field)
        case .severity:
            Picker("", selection: $field.text) {
                ForEach(Finding.Severity.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        case .agents:
            HStack(spacing: 6) {
                ForEach(agents) { agent in
                    let ids = field.text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let on = ids.contains(agent.id)
                    Button {
                        field.text = (on ? ids.filter { $0 != agent.id } : ids + [agent.id]).joined(separator: ",")
                    } label: {
                        Label(agent.name, systemImage: on ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.simul(on ? .pill : .quiet))
                }
            }
        case .longText:
            TextField(input.placeholder ?? "", text: $field.text, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 12.5))
                .simulField()
        case .command:
            TextField(input.placeholder ?? "", text: $field.text)
                .font(.system(size: 12, design: .monospaced))
                .simulField()
        case .number:
            TextField(input.placeholder ?? "", text: $field.text)
                .font(.system(size: 12.5).monospacedDigit())
                .frame(width: 80)
                .simulField()
        case .text, .pullRequest:
            TextField(input.placeholder ?? "", text: $field.text)
                .font(.system(size: 12.5))
                .simulField()
        }
    }
}
