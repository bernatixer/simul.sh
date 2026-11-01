import AppKit
import SwiftUI

/// The selected session's workflow runs (or every session's): what needs
/// you on top, then what's running, then what finished; the selected run
/// (or a new one) on the right.
struct RunsView: View {
    @Environment(AppModel.self) private var model

    /// What the list shows: this session's runs, or all.
    private var shown: [WorkflowRun] {
        let engine = model.workflows
        return engine.allSessions || model.selectedSessionID == nil ? engine.runs : engine.runs(for: model.selectedSessionID)
    }

    /// The selected run if it's listed, else the one most worth a look.
    private var selected: WorkflowRun? {
        let shown = shown
        if let run = model.workflows.run(model.workflows.selectedRunID), shown.contains(where: { $0.id == run.id }) { return run }
        return shown.first { $0.status == .needsYou } ?? shown.filter(\.isLive).last ?? shown.last
    }

    var body: some View {
        let engine = model.workflows
        HStack(spacing: 0) {
            list
                .frame(width: 290)
                .background(Color.black.opacity(0.12))
            Rectangle().fill(Theme.divider).frame(width: 1)
            Group {
                if let editing = engine.editing {
                    WorkflowEditor(start: editing)
                        .id(editing.file?.path ?? "new:" + editing.workflow.id)
                } else if let composing = engine.composing {
                    RunComposer(start: composing)
                        .id(composing)
                } else if let run = selected {
                    RunDetail(run: run)
                        .id(run.id)  // its state (ticked findings, open sections) is this run's
                } else {
                    RunComposer(start: .init())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { engine.reloadLibrary() }
    }

    private var list: some View {
        let engine = model.workflows
        let runs = shown
        let selectedID = engine.composing == nil ? selected?.id : nil
        let needs = runs.filter { $0.status == .needsYou }.sorted { $0.updatedAt > $1.updatedAt }
        let running = runs.filter { $0.status == .active || $0.status == .paused }.sorted { $0.createdAt > $1.createdAt }
        let finished = runs.filter { !$0.isLive }.sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }
        return VStack(spacing: 0) {
            HStack {
                Text("Runs").font(.system(size: 14, weight: .semibold))
                if model.selectedSessionID != nil {
                    Menu {
                        Picker("", selection: Binding(get: { engine.allSessions }, set: { if engine.allSessions != $0 { engine.allSessions = $0 } })) {
                            Text("This session").tag(false)
                            Text("All sessions").tag(true)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(engine.allSessions ? "All sessions" : "This session")
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12))
                    .fixedSize()
                }
                Spacer()
                Button {
                    engine.composing = .init(sessionID: model.selectedSessionID)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.simul(.quiet))
                .help("Start a workflow")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if engine.cantSave {
                Text("runs.json is from another version of Simul, so runs aren't being saved.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RunColors.warn)
                    .padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 4) {
                if runs.isEmpty {
                    Text(engine.allSessions || model.selectedSessionID == nil
                         ? "No runs yet. Pick a workflow on the right to run it on a session."
                         : "No runs on this session yet. Pick a workflow on the right to start one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                group("Needs you", needs, selectedID, tint: RunColors.you)
                group("Running", running, selectedID)
                group("Finished", finished, selectedID)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            .runsScroll()
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ runs: [WorkflowRun], _ selectedID: UUID?, tint: Color = .secondary) -> some View {
        if !runs.isEmpty {
            Text("\(title.uppercased())  \(runs.count)")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .padding(.bottom, 2)
            ForEach(runs.prefix(40)) { RunListRow(run: $0, selected: $0.id == selectedID, showSession: model.workflows.allSessions) }
            if runs.count > 40 {
                Text("\(runs.count - 40) older not shown").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 6)
            }
        }
    }
}

private struct RunListRow: View {
    @Environment(AppModel.self) private var model
    let run: WorkflowRun
    let selected: Bool
    /// Listing every session's runs: say whose this is.
    let showSession: Bool
    @State private var hovering = false

    var body: some View {
        let engine = model.workflows
        let tint = RunColors.status(run.status)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StatusDot(color: tint, size: 6)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ElapsedLabel(since: run.createdAt, until: run.finishedAt)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(run.ask?.title ?? (run.activity.isEmpty ? run.status.label : run.activity))
                .font(.system(size: 11.5))
                .foregroundStyle(run.status == .needsYou ? RunColors.you : .secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                StageRail(run: run)
                Spacer(minLength: 4)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.12 : hovering ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(run.status == .needsYou ? RunColors.you.opacity(0.45) : .clear))
        .contentShape(Rectangle())
        .onHover { if hovering != $0 { hovering = $0 } }
        .onTapGesture {
            engine.composing = nil
            engine.selectedRunID = run.id
            model.notifier.remove([run.id])
        }
    }

    /// "Review a pull request #12".
    private var title: String {
        run.workflow.name + (run.pullRequest.map { " #\($0.number)" } ?? "")
    }

    /// "R2/4", and the session when listing all.
    private var meta: String {
        var parts: [String] = []
        if showSession { parts.append(model.sessions.first { $0.id == run.sessionID }?.title ?? "Session") }
        if run.workflow.loop != nil, run.round > 0 { parts.append("R\(run.round)/\(run.maxRounds)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - New run

/// Pick a workflow, fill in its inputs, pick the session, start.
struct RunComposer: View {
    @Environment(AppModel.self) private var model
    let start: WorkflowEngine.Composer
    @State private var workflowID = WorkflowTemplates.ship.id
    @State private var sessionID: UUID?
    @State private var values: [String: String] = [:]
    @State private var folder = ""
    @State private var error: String?
    @State private var asked = false
    @State private var showAdvanced = false

    var body: some View {
        let engine = model.workflows
        Group {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a workflow").font(.system(size: 19, weight: .semibold))
                    Text("A workflow runs on one of your sessions: its agent does the work, fresh reviewer sessions check it, and you're asked only when it needs you.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Not lazy: a lazy grid rebuilds the cards each time they scroll back in.
                CardGrid(minWidth: 260, spacing: 10) {
                    ForEach(engine.workflows) { workflow in card(workflow) }
                }
                if let workflow {
                    // The form, with how the workflow runs beside it when there's room.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            form(workflow).frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity)
                            preview(workflow).frame(width: 300)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            preview(workflow)
                            form(workflow)
                        }
                    }
                }
                library
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .runsScroll()
        .onAppear {
            if let id = start.workflowID { workflowID = id }
            sessionID = start.sessionID ?? model.selectedSessionID ?? model.activeSessions.first?.id
            resetValues()
        }
        .onChange(of: workflowID) { _, _ in resetValues() }
        .onChange(of: sessionID) { _, _ in resetFolder() }
    }

    private var workflow: Workflow? { model.workflows.workflows.first { $0.id == workflowID } }
    private var session: Session? { sessionID.flatMap { id in model.sessions.first { $0.id == id } } }

    private func card(_ workflow: Workflow) -> some View {
        let selected = workflow.id == workflowID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workflow.name).font(.system(size: 13.5, weight: .semibold))
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
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            StageFlow(workflow: workflow)
                .help(stageLine(workflow))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : RunColors.line, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { workflowID = workflow.id }
    }

    /// "Review → Fix → Run checks ↻ · Mark ready → …"
    private func stageLine(_ w: Workflow) -> String {
        [w.before.map(\.title).joined(separator: " → "),
         w.loop.map { "[" + $0.stages.map(\.title).joined(separator: " → ") + "] ↻" } ?? "",
         w.after.map(\.title).joined(separator: " → ")]
            .filter { !$0.isEmpty }.joined(separator: " → ")
    }

    // MARK: Form

    private func form(_ workflow: Workflow) -> some View {
        let groups = workflow.inputs.compactMap(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 12) {
            box(nil) {
                row("Session", help: workflow.allPositions.contains { [.agent, .fix, .verify].contains(workflow.stage(at: $0)?.kind) }
                    ? "Its agent does the work. Reviewers start next to it in the sidebar."
                    : "The run shows on this session. Reviewers start next to it in the sidebar.") {
                    Menu {
                        ForEach(model.activeSessions) { s in
                            Button(s.title + " · " + (model.agent(for: s)?.name ?? s.agentID)) { sessionID = s.id }
                        }
                    } label: {
                        Text(session.map { $0.title + " · " + (model.agent(for: $0)?.name ?? $0.agentID) } ?? "Pick a session")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                row("Folder", help: "Where checks run and reviewers look. For Claude, the worktree it's working in.") {
                    HStack(spacing: 6) {
                        Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Change…") { chooseFolder() }.buttonStyle(.simul(.quiet))
                    }
                }
                inputs(workflow, group: nil)
            }
            ForEach(groups.filter { $0 != WorkflowInput.advanced }, id: \.self) { group in
                box(group) { inputs(workflow, group: group) }
            }
            if groups.contains(WorkflowInput.advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Button { showAdvanced.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text(WorkflowInput.advanced.uppercased())
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showAdvanced { inputs(workflow, group: WorkflowInput.advanced) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(RunColors.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RunColors.line))
            }
            HStack(spacing: 10) {
                Button { startRun(workflow) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.simul(.primary))
                    .disabled(session == nil)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(RunColors.bad)
                }
            }
            .padding(.top, 4)
        }
    }

    /// The workflow's stages, each saying what it will do with these values.
    private func preview(_ workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW IT RUNS").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            StageGraph(run: WorkflowRun(workflow: workflow, sessionID: sessionID ?? UUID(), folder: folder, inputs: previewValues), preview: true)
                .id(workflow.id)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The form's values, with readable stand-ins for what's known only once it runs.
    private var previewValues: [String: String] {
        var v = values
        if (v["pr"] ?? "").isEmpty { v["pr"] = "the pull request" }
        v["pr_url"] = v["pr"]
        v["merge_sha"] = "the merge commit"
        v["folder"] = (folder as NSString).abbreviatingWithTildeInPath
        return v
    }

    private func inputs(_ workflow: Workflow, group: String?) -> some View {
        ForEach(workflow.inputs.filter { $0.group == group }) { input in
            row(input.label, help: input.required == true ? (input.help.map { $0 + " " } ?? "") + "Required." : input.help) { field(input) }
        }
    }

    /// A titled card of form rows.
    private func box<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(RunColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RunColors.line))
    }

    private func row<Content: View>(_ label: String, help: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 170, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                content()
                if let help {
                    Text(help).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    @ViewBuilder
    private func field(_ input: WorkflowInput) -> some View {
        let binding = Binding(get: { values[input.id] ?? "" }, set: { if values[input.id] != $0 { values[input.id] = $0 } })
        switch input.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { WorkflowText.isOn(binding.wrappedValue) }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        case .severity:
            Picker("", selection: binding) {
                ForEach(Finding.Severity.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        case .agents:
            HStack(spacing: 6) {
                ForEach(model.agents.filter { $0.resume != .none }) { agent in
                    let on = binding.wrappedValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(agent.id)
                    Button {
                        var ids = binding.wrappedValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if on { ids.removeAll { $0 == agent.id } } else { ids.append(agent.id) }
                        binding.wrappedValue = ids.joined(separator: ",")
                    } label: {
                        Label(agent.name, systemImage: on ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.simul(on ? .pill : .quiet))
                }
            }
        case .longText:
            TextField(input.placeholder ?? "", text: binding, axis: .vertical)
                .lineLimit(2...6)
                .font(.system(size: 12.5))
                .simulField()
        case .command:
            TextField(input.placeholder ?? "", text: binding)
                .font(.system(size: 12, design: .monospaced))
                .simulField()
        case .number:
            TextField(input.placeholder ?? "", text: binding)
                .font(.system(size: 12.5).monospacedDigit())
                .frame(width: 80)
                .simulField()
        case .text, .pullRequest:
            TextField(input.placeholder ?? "", text: binding)
                .font(.system(size: 12.5))
                .simulField()
        }
    }

    // MARK: Your own workflows

    private var library: some View {
        let entries = model.workflows.library
        return VStack(alignment: .leading, spacing: 8) {
            Text("YOUR WORKFLOWS").font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text("Make your own from the one selected above and change its stages and inputs, or describe one to the session's agent and it writes it. They're JSON files in Simul's workflows folder.")
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
    }

    // MARK: Actions

    private func resetValues() {
        guard let workflow else { return }
        values = workflow.defaults
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

    private func startRun(_ workflow: Workflow) {
        guard let session else { return }
        switch model.workflows.start(workflow, on: session, inputs: values, folder: folder) {
        case .success:
            model.workflows.composing = nil
            error = nil
        case let .failure(problem):
            error = problem.message
        }
    }

    /// The selected workflow, as a new one of yours, in the editor.
    private func copySelected() {
        guard var copy = workflow else { return }
        let taken = Set(model.workflows.workflows.map(\.id))
        var n = 1
        repeat { copy.id = workflow!.id + (n == 1 ? "-mine" : "-mine-\(n)"); n += 1 } while taken.contains(copy.id)
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

/// As many equal columns of at least `minWidth` as fit; each row as tall as
/// its tallest card.
private struct CardGrid: Layout {
    let minWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minWidth
        let rows = rows(width, subviews)
        return CGSize(width: width, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        let column = columnWidth(bounds.width)
        for row in rows(bounds.width, subviews) {
            for (n, index) in row.indices.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(n) * (column + spacing), y: y),
                                      proposal: ProposedViewSize(width: column, height: row.height))
            }
            y += row.height + spacing
        }
    }

    private func columns(_ width: CGFloat) -> Int { max(1, Int((width + spacing) / (minWidth + spacing))) }

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        let n = CGFloat(columns(width))
        return (width - spacing * (n - 1)) / n
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(indices: Range<Int>, height: CGFloat)] {
        let n = columns(width), column = columnWidth(width)
        return stride(from: 0, to: subviews.count, by: n).map { start in
            let indices = start..<min(start + n, subviews.count)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return (indices, height)
        }
    }
}
