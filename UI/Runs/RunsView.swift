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

/// As many equal columns of at least `minWidth` as fit; each row as tall as
/// its tallest card.
struct CardGrid: Layout {
    let minWidth: CGFloat
    let spacing: CGFloat

    typealias Row = (indices: Range<Int>, height: CGFloat)

    /// The rows for the last width: a sibling growing asks again with the same one.
    struct Cache {
        var width: CGFloat = -1
        var rows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? minWidth
        let rows = rows(width, subviews, &cache)
        return CGSize(width: width, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        let column = columnWidth(bounds.width)
        for row in rows(bounds.width, subviews, &cache) {
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

    private func rows(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [Row] {
        if cache.width == width { return cache.rows }
        let n = columns(width), column = columnWidth(width)
        let rows: [Row] = stride(from: 0, to: subviews.count, by: n).map { start in
            let indices = start..<min(start + n, subviews.count)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return (indices, height)
        }
        cache = Cache(width: width, rows: rows)
        return rows
    }
}
