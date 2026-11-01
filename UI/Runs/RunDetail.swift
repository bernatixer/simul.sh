import AppKit
import SwiftUI

/// One run: what it's doing now and what it needs, then its stages (each
/// with what happened in it) beside every finding with its status.
struct RunDetail: View {
    @Environment(AppModel.self) private var model
    let run: WorkflowRun
    @State private var showSettled = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            NowCard(run: run)
            // Side by side when there's room for both.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    progress.frame(width: 300)
                    findings.frame(minWidth: 360, idealWidth: 360, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    progress
                    findings
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .runsScroll()
    }

    private var session: Session? { model.sessions.first { $0.id == run.sessionID } }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(run.workflow.name)
                    .font(.system(size: 19, weight: .semibold))
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        StatusDot(color: RunColors.status(run.status))
                        Text(run.status.label).foregroundStyle(RunColors.status(run.status))
                    }
                    if let round = roundText(run) { Text(round) }
                    if let session {
                        Button { model.select(session) } label: {
                            Label(session.title, systemImage: "terminal").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Open the session")
                    }
                    if let pr = run.pullRequest, let url = URL(string: pr.url) {
                        Button { NSWorkspace.shared.open(url) } label: { Text(verbatim: "#\(pr.number)") }
                            .buttonStyle(.plain)
                            .help(pr.url)
                    }
                    ElapsedLabel(since: run.createdAt, until: run.finishedAt)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                if run.isLive {
                    if run.status == .paused {
                        Button { model.workflows.resume(run.id) } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.simul(.pill))
                    } else if run.pauseRequested {
                        Button { model.workflows.resume(run.id) } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.simul(.pill))
                            .help("Pausing after this step; keeps going instead")
                    } else {
                        Button { model.workflows.pause(run.id) } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.simul(.pill))
                            .help("Stops before the next step starts")
                    }
                    Button { model.workflows.stop(run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.simul(.pill))
                } else {
                    Button { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
                        .buttonStyle(.simul(.pill))
                        .confirmationDialog("Remove this run?", isPresented: $confirmRemove, titleVisibility: .visible) {
                            Button("Remove Run", role: .destructive) { model.workflows.remove(run.id) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Its findings and history go, and so do its reviewer sessions (their conversations stay with the agents). The changes in your folder stay.")
                        }
                }
            }
        }
    }

    // MARK: Findings

    private var findings: some View {
        let active = run.findings.filter { !$0.isSettled }.sorted(by: Self.order)
        let settled = run.findings.filter(\.isSettled).sorted(by: Self.order)
        return section("Findings", trailing: summary) {
            if run.findings.isEmpty {
                Text(run.workflow.allPositions.contains { [.review, .check, .feedback].contains(run.workflow.stage(at: $0)?.kind) }
                     ? "Nothing yet. Reviews, checks and the pull request's CI and comments land here."
                     : "This workflow doesn't collect findings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(active) { FindingRow(finding: $0); divider }
                    // Nothing open: the settled ones are the story, shown.
                    if !settled.isEmpty, !active.isEmpty {
                        Button { showSettled.toggle() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showSettled ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                                Text("\(settled.count) verified or skipped")
                                Spacer()
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if showSettled || active.isEmpty {
                        ForEach(settled) { FindingRow(finding: $0); divider }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(RunColors.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RunColors.line))
            }
        }
    }

    private var divider: some View { Rectangle().fill(RunColors.line).frame(height: 1) }

    /// Open first, by severity, then by id.
    private static func order(_ a: Finding, _ b: Finding) -> Bool {
        func rank(_ f: Finding) -> Int {
            switch f.status {
            case .open: f.cameBack ? 0 : 1
            case .yours: 2
            case .fixing: 3
            case .fixed: 4
            case .verified: 5
            case .skipped: 6
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if a.severity != b.severity { return a.severity > b.severity }
        return (Int(a.id.dropFirst()) ?? 0) < (Int(b.id.dropFirst()) ?? 0)
    }

    private var summary: String {
        let count = { (s: Finding.Status) in run.findings.filter { $0.status == s }.count }
        return [("open", count(.open) + count(.fixing)), ("to verify", count(.fixed)), ("yours", count(.yours)),
                ("verified", count(.verified)), ("skipped", count(.skipped))]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }.joined(separator: " · ")
    }

    private var progress: some View {
        section("Stages") { StageGraph(run: run).fixedSize(horizontal: false, vertical: true) }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, trailing: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                if let trailing, !trailing.isEmpty {
                    Text(trailing).textCase(nil).fontWeight(.regular)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            content()
        }
    }
}

/// What the run is doing now, and what it needs from you (with the buttons).
struct NowCard: View {
    @Environment(AppModel.self) private var model
    let run: WorkflowRun
    @State private var selected: Set<String> = []

    var body: some View {
        let tint = RunColors.status(run.status)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if let ask = run.ask, ask.kind == .chooseFindings || ask.kind == .peopleComments {
                VStack(spacing: 0) {
                    ForEach(run.findings.filter { ask.findings.contains($0.id) }) { finding in
                        FindingRow(finding: finding, selectable: ask.kind == .chooseFindings, selected: selected.contains(finding.id)) {
                            if selected.contains(finding.id) { selected.remove(finding.id) } else { selected.insert(finding.id) }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.15)))
            }
            if !run.stage.reviewers.isEmpty { reviewers }
            if let permission = askingSession {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.bubble").foregroundStyle(RunColors.you)
                    Text("\(permission.title) is asking you something.").font(.system(size: 12.5))
                    Button("Open") { model.select(permission) }.buttonStyle(.simul(.pill))
                }
            }
            if !run.isLive, let session = model.sessions.first(where: { $0.id == run.sessionID }) {
                HStack(spacing: 6) {
                    Button("Review the change") {
                        model.select(session)
                        if !model.reviews.isShowing(session.id) { model.reviews.show(session) }
                    }
                    .buttonStyle(.simul(.primary))
                    Button("Open session") { model.select(session) }.buttonStyle(.simul(.pill))
                }
            }
            if let ask = run.ask {
                HStack(spacing: 6) {
                    let primary = ask.actions.first(where: \.isPrimary)  // one main button
                    ForEach(ask.actions, id: \.self) { action in
                        let disabled = action == .fixSelected && selected.isEmpty
                        Button(label(action, ask)) { model.workflows.answer(run.id, action, selected: selected) }
                            .buttonStyle(.simul(action == primary && !disabled ? .primary : .pill))
                            .disabled(disabled)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(run.status == .needsYou ? 0.12 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(run.status == .needsYou ? 0.5 : 0.2), lineWidth: 1))
        .onChange(of: run.ask?.findings) { _, _ in selected = [] }
    }

    private var title: String {
        if let ask = run.ask { return ask.title }
        switch run.status {
        case .paused: return run.activity.isEmpty ? "Paused" : run.activity
        case .done, .stopped: return run.activity.isEmpty ? run.status.label : run.activity
        default: return run.activity.isEmpty ? (run.currentStage?.title ?? "") : run.activity
        }
    }

    private var detail: String? {
        if let ask = run.ask { return ask.detail }
        if !run.isLive { return outcome }
        if run.pauseRequested { return "Pausing after this step." }
        guard run.isLive, let stage = run.currentStage else { return nil }
        return "Step: \(stage.title)" + (roundText(run).map { " · \($0)" } ?? "") + ". Nothing needed from you."
    }

    /// "4 verified fixed, 1 skipped · 2 rounds · 3m".
    private var outcome: String {
        let count = { (s: Finding.Status) in run.findings.filter { $0.status == s }.count }
        var parts = [(count(.verified), "verified fixed"), (count(.fixed), "fixed, not verified"), (count(.open) + count(.fixing), "open"),
                     (count(.yours), "for you"), (count(.skipped), "skipped")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if parts.isEmpty, !run.findings.isEmpty || run.workflow.loop != nil { parts = ["no findings"] }
        var line = parts.joined(separator: ", ")
        if run.workflow.loop != nil, run.round > 0 { line += (line.isEmpty ? "" : " · ") + "\(run.round) round\(run.round == 1 ? "" : "s")" }
        if let end = run.finishedAt { line += " · took \(RelativeAge.short(end.timeIntervalSince(run.createdAt)))" }
        return line
    }

    private var icon: String {
        switch run.status {
        case .needsYou: "hand.raised.fill"
        case .paused: "pause.circle"
        case .done: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .active: run.currentStage?.kind.icon ?? "circle"
        }
    }

    /// The run's session or a reviewer stopped to ask something (a permission prompt).
    private var askingSession: Session? {
        let ids = [run.sessionID] + run.reviewerSessionIDs
        return ids.lazy.filter { model.waitingIDs.contains($0) }.compactMap { id in model.sessions.first { $0.id == id } }.first
    }

    private func label(_ action: Ask.Action, _ ask: Ask) -> String {
        switch (action, ask.kind) {
        case (.fixSelected, _): selected.isEmpty ? "Fix selected" : "Fix \(selected.count) selected"
        case (.continue, .reviewReady): "Wait for the next push"
        case (.continue, .confirm): "Yes, go on"
        default: action.label
        }
    }

    private var reviewers: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(run.stage.reviewers, id: \.sessionID) { reviewer in
                HStack(spacing: 8) {
                    Image(systemName: reviewer.state == .done ? "checkmark.circle.fill" : reviewer.state == .failed ? "xmark.circle" : "circle.dotted")
                        .foregroundStyle(reviewer.state == .done ? RunColors.good : reviewer.state == .failed ? RunColors.bad : .secondary)
                    Text(model.agents.first { $0.id == reviewer.agentID }?.name ?? reviewer.agentID)
                        .font(.system(size: 12.5))
                    Text(reviewer.state == .working ? "reviewing" : reviewer.state == .done ? "done" : "no review")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let session = model.sessions.first(where: { $0.id == reviewer.sessionID }), !session.isArchived {
                        Button("Watch") { model.select(session) }.buttonStyle(.simul(.quiet))
                    }
                }
            }
        }
    }
}

/// "12m", "3h" since `since` (until `until`), updated every minute.
struct ElapsedLabel: View {
    let since: Date
    var until: Date?

    var body: some View {
        if let until {
            Text(RelativeAge.short(until.timeIntervalSince(since)))
        } else {
            TimelineView(.everyMinute) { context in
                Text(RelativeAge.short(context.date.timeIntervalSince(since)))
            }
        }
    }
}
