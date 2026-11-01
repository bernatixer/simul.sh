import AppKit
import SwiftUI

/// Colors that mean the same everywhere in runs: purple is you.
enum RunColors {
    static let you = Color(red: 0.76, green: 0.59, blue: 1.0)
    static let good = Color(red: 0.29, green: 0.76, blue: 0.42)
    static let warn = Color(red: 0.83, green: 0.65, blue: 0.17)
    static let bad = Color(red: 1.0, green: 0.48, blue: 0.45)
    static let card = Color.white.opacity(0.05)
    static let line = Color.white.opacity(0.08)

    static func status(_ status: WorkflowRun.Status) -> Color {
        switch status {
        case .active: .accentColor
        case .needsYou: you
        case .paused: .secondary
        case .done: good
        case .stopped: .secondary
        }
    }

    static func severity(_ severity: Finding.Severity) -> Color {
        switch severity {
        case .high: bad
        case .medium: warn
        case .low: .secondary
        }
    }
}

extension WorkflowRun.Status {
    var label: String {
        switch self {
        case .active: "Running"
        case .needsYou: "Needs you"
        case .paused: "Paused"
        case .done: "Done"
        case .stopped: "Stopped"
        }
    }
}

extension WorkflowStage.Kind {
    var icon: String {
        switch self {
        case .agent: "text.bubble"
        case .review: "eye"
        case .fix: "wrench.and.screwdriver"
        case .check: "checkmark.seal"
        case .wait: "hourglass"
        case .feedback: "bubble.left.and.exclamationmark.bubble.right"
        case .gate: "hand.raised"
        case .verify: "stethoscope"
        }
    }
}

/// A small filled dot with a soft ring.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.25)).frame(width: size + 5, height: size + 5))
    }
}

/// "Round 2 of 4"; nil without a loop or before it.
func roundText(_ run: WorkflowRun) -> String? {
    guard run.workflow.loop != nil, run.round > 0 else { return nil }
    return "Round \(run.round) of \(run.maxRounds)"
}

// MARK: - Stage rail

/// Every stage as a small bar, the current one in the run's color.
struct StageRail: View {
    let run: WorkflowRun

    var body: some View {
        HStack(spacing: 3) {
            ForEach(run.workflow.allPositions, id: \.self) { position in
                Capsule().fill(color(StageState.of(position, in: run))).frame(width: 9, height: 4)
            }
        }
    }

    private func color(_ state: StageState) -> Color {
        switch state {
        case .done, .skipped: Color.white.opacity(0.35)
        case .current: RunColors.status(run.status)
        case .upcoming, .stopped: Color.white.opacity(0.10)
        }
    }
}

enum StageState {
    case done, skipped, current, stopped, upcoming

    /// Where `position` stands for the run as it is now.
    static func of(_ position: StagePosition, in run: WorkflowRun) -> StageState {
        if !run.isLive && run.status == .done { return .done }
        if position == run.position { return run.isLive ? .current : .stopped }
        let order: [StagePosition.Part] = [.before, .loop, .after]
        let a = order.firstIndex(of: position.part)!, b = order.firstIndex(of: run.position.part)!
        if a != b { return a < b ? .done : .upcoming }
        return position.index < run.position.index ? .done : .upcoming
    }
}

// MARK: - Stage graph

/// The workflow top to bottom on one line, each stage with what happened
/// in it; the loop's stages boxed, with a round picker.
struct StageGraph: View {
    let run: WorkflowRun
    @State private var open: Set<StagePosition> = []
    /// The loop round being looked at; nil: the current one.
    @State private var viewedRound: Int?

    var body: some View {
        let positions = run.workflow.allPositions
        let logged = run.events.contains { $0.stage != nil }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(StagePosition.Part.allCases, id: \.self) { part in
                let inPart = positions.filter { $0.part == part }
                if !inPart.isEmpty {
                    if part == .loop {
                        VStack(alignment: .leading, spacing: 0) {
                            loopHeader(logged: logged)
                            nodes(inPart, all: positions, logged: logged)
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.025)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    } else {
                        nodes(inPart, all: positions, logged: logged)
                    }
                }
            }
            // Runs from before events knew their stage.
            let loose = run.events.filter { $0.stage == nil && $0.kind != .stage }
            if !loose.isEmpty {
                DisclosureGroup("Earlier log (\(loose.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(loose.suffix(150).reversed()) { EventLine(event: $0) }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
        }
    }

    private var round: Int {
        let current = max(run.round, 1)
        return min(viewedRound ?? current, current)
    }

    private func loopHeader(logged: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "repeat").font(.system(size: 9.5, weight: .semibold))
            Text(run.round > 0 ? "Round \(round) of \(run.maxRounds)" : "Repeats up to \(run.maxRounds)×")
                .font(.system(size: 10.5, weight: .medium))
            Spacer()
            if run.round > 1, logged {
                HStack(spacing: 2) {
                    ForEach(1...run.round, id: \.self) { r in
                        Button { viewedRound = r == run.round ? nil : r } label: {
                            Text(verbatim: "R\(r)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(r == round ? 0.14 : 0)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("What happened in round \(r)")
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.vertical, 4)
    }

    private func nodes(_ part: [StagePosition], all: [StagePosition], logged: Bool) -> some View {
        ForEach(part, id: \.self) { position in
            node(position, first: position == all.first, last: position == all.last, logged: logged)
        }
    }

    private func events(_ position: StagePosition) -> [Event] {
        run.events.filter { $0.stage == position && (position.part != .loop || $0.round == round) }
    }

    /// Positional state, corrected by what the log says actually ran (a
    /// round that ended early, a stage that was skipped, an older round).
    private func state(_ position: StagePosition, _ events: [Event], logged: Bool) -> StageState {
        let now = StageState.of(position, in: run)
        guard logged else { return now }
        let older = position.part == .loop && round < run.round
        if now == .current && !older { return .current }
        if now == .stopped && !older { return .stopped }
        let title = run.workflow.stage(at: position)?.title
        if events.contains(where: { $0.kind == .stage && $0.text == title }) { return .done }
        if !events.isEmpty { return .skipped }
        return older || now == .done ? .skipped : .upcoming
    }

    private func node(_ position: StagePosition, first: Bool, last: Bool, logged: Bool) -> some View {
        let stage = run.workflow.stage(at: position)
        let events = events(position)
        let state = state(position, events, logged: logged)
        let tint = RunColors.status(run.status)
        let lines = events.filter { $0.kind != .stage }
        let expanded = state == .current || state == .stopped || open.contains(position)
        return HStack(alignment: .top, spacing: 10) {
            marker(stage, state, tint)
                .padding(.top, 6)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stage?.title ?? "")
                        .font(.system(size: 12.5, weight: state == .current ? .semibold : .regular))
                        .foregroundStyle(state == .upcoming || state == .skipped ? .tertiary : .primary)
                    if state == .skipped { Text("skipped").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                    if state == .stopped { Text("stopped here").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    Spacer(minLength: 6)
                    if let start = events.first?.at {
                        Text(start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if expanded {
                    ForEach(lines.suffix(30)) { EventLine(event: $0, time: false) }
                } else if let last = lines.last, state != .skipped {
                    Text(last.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(EventLine.color(last.kind).opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        // The line joining the markers, drawn behind them at the row's height.
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? .clear : RunColors.line).frame(height: 16)
                Rectangle().fill(last ? .clear : RunColors.line)
            }
            .frame(width: 1.5)
            .padding(.leading, 10.25)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(state == .current ? tint.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard lines.count > 1, state != .current else { return }
            if open.contains(position) { open.remove(position) } else { open.insert(position) }
        }
        .help(stage.map { $0.kind.rawValue.capitalized } ?? "")
    }

    /// What a stage will do, in a few words, with the form's values.
    static func describe(_ stage: WorkflowStage, _ values: [String: String]) -> String {
        let fill = { (text: String?) in WorkflowText.fill(text ?? "", values).trimmingCharacters(in: .whitespacesAndNewlines) }
        func firstLine(_ text: String?) -> String { String(fill(text).split(separator: "\n").first ?? "") }
        switch stage.kind {
        case .agent: return firstLine(stage.prompt)
        case .review:
            let names = fill(stage.reviewers).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).capitalized }.filter { !$0.isEmpty }
            return names.isEmpty ? "Fresh reviewers look at the change" : "Fresh \(names.joined(separator: " and ")) review\(names.count == 1 ? "s" : "") the change"
        case .fix:
            let at = fill(stage.fixAtLeast)
            return "The agent fixes \(at.isEmpty ? "the" : at + " and higher") findings" + (WorkflowText.isOn(fill(stage.askBelow)) ? "; asks you about lower ones" : "")
        case .check:
            let command = fill(stage.command)
            return command.isEmpty ? "Runs your checks" : command
        case .wait:
            switch stage.waitFor {
            case .checks: return "Until the pull request's CI finishes"
            case .newCommit: return "Until the pull request gets new commits"
            case .approved: return "Until it's approved"
            case .merged: return "Until it's merged"
            case .command: let c = fill(stage.command); return c.isEmpty ? "Until a command succeeds" : "Until this succeeds: \(c)"
            case .time: return "\(fill(stage.hours)) hours"
            case nil: return ""
            }
        case .feedback: return "Failing CI and review comments become findings"
        case .gate: return "Asks you: " + fill(stage.question)
        case .verify: return firstLine(stage.prompt)
        }
    }

    private func marker(_ stage: WorkflowStage?, _ state: StageState, _ tint: Color) -> some View {
        let icon = switch state {
        case .done: "checkmark"
        case .skipped: "arrow.turn.down.right"
        case .stopped: "stop.fill"
        default: stage?.kind.icon ?? "circle"
        }
        return Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(state == .current ? Color.white : state == .done ? RunColors.good : Color.secondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(state == .current ? tint : Color.white.opacity(state == .upcoming || state == .skipped ? 0.04 : 0.08)))
            .overlay(Circle().strokeBorder(state == .upcoming ? RunColors.line : .clear))
    }
}

/// One line of a run's log.
struct EventLine: View {
    let event: Event
    var time = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if time {
                Text(event.at.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 58, alignment: .leading)
            }
            Text(event.text)
                .font(.system(size: 11.5, weight: event.kind == .stage ? .semibold : .regular))
                .foregroundStyle(Self.color(event.kind))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func color(_ kind: Event.Kind) -> Color {
        switch kind {
        case .stage: .primary
        case .info: .secondary
        case .good: RunColors.good
        case .warning: RunColors.warn
        case .you: RunColors.you
        }
    }
}

/// A workflow's stages as icons joined by lines, the loop boxed, wrapping
/// onto more lines when the row doesn't fit; names on hover.
struct StageFlow: View {
    let workflow: Workflow

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                HStack(spacing: 0) {
                    if n > 0 { link }
                    if let loop = item.loop {
                        HStack(spacing: 0) {
                            Image(systemName: "repeat").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).padding(.trailing, 4)
                            ForEach(Array(loop.enumerated()), id: \.offset) { i, stage in
                                if i > 0 { link }
                                node(stage)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    } else if let stage = item.stage {
                        node(stage)
                    }
                }
                .frame(height: 28)
            }
        }
    }

    /// Each stage outside the loop, and the loop as one piece.
    private var items: [(stage: WorkflowStage?, loop: [WorkflowStage]?)] {
        workflow.before.map { ($0, nil) }
            + (workflow.loop.map { [(nil, $0.stages)] } ?? [])
            + workflow.after.map { ($0, nil) }
    }

    private func node(_ stage: WorkflowStage) -> some View {
        Image(systemName: stage.kind.icon)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .help(stage.title)
    }

    private var link: some View { Rectangle().fill(RunColors.line).frame(width: 6, height: 1.5) }
}

// MARK: - Findings

struct FindingRow: View {
    let finding: Finding
    var selectable = false
    var selected = false
    var toggle: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if selectable {
                    Button(action: toggle) {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(finding.id)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
                Circle().fill(RunColors.severity(finding.severity)).frame(width: 7, height: 7)
                    .help("\(finding.severity.rawValue.capitalized) severity")
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.system(size: 12.5))
                        .strikethrough(finding.status == .verified, color: .secondary)
                        .foregroundStyle(finding.isSettled ? .secondary : .primary)
                        .lineLimit(expanded ? nil : 1)
                    HStack(spacing: 6) {
                        ForEach(finding.sources, id: \.self) { SourceChip(name: $0) }
                        if let path = finding.path {
                            Text(verbatim: path + (finding.line.map { ":\($0)" } ?? ""))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                Spacer(minLength: 8)
                if !selectable { StatusTag(finding: finding) }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !finding.detail.isEmpty {
                        Text(finding.detail)
                            .font(.system(size: 11.5, design: finding.key?.hasPrefix("check:") == true ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let note = finding.note {
                        Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 10) {
                        Text("Found in round \(finding.raisedRound)" + (finding.updatedRound != finding.raisedRound ? ", last seen in \(finding.updatedRound)" : ""))
                        if let sha = finding.fixedIn { Text("Fix: \(sha)").font(.system(size: 10.5, design: .monospaced)) }
                        if let url = finding.url, let link = URL(string: url) {
                            Button("Open link") { NSWorkspace.shared.open(link) }
                                .buttonStyle(.simul(.quiet))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }
                .padding(.leading, selectable ? 66 : 49)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { if selectable { toggle() } else { expanded.toggle() } }
    }
}

struct SourceChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch name {
        case "Claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "Codex": Color(red: 0.48, green: 0.64, blue: 0.97)
        case "CI", "Checks": RunColors.bad
        case "Simul": RunColors.warn
        default: name.hasPrefix("@") ? RunColors.you : Color.secondary
        }
    }
}

struct StatusTag: View {
    let finding: Finding

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.13)))
            .help(finding.note ?? "")
    }

    private var text: String {
        if finding.cameBack, finding.status == .open { return "Came back" }
        switch finding.status {
        case .open: return "Open"
        case .fixing: return "Fixing"
        case .fixed: return finding.fixedIn.map { "Fixed in \($0.prefix(7))" } ?? "Fixed, to verify"
        case .verified: return "Verified"
        case .skipped: return "Skipped"
        case .yours: return "Yours"
        }
    }

    private var color: Color {
        if finding.cameBack, finding.status == .open { return RunColors.bad }
        switch finding.status {
        case .open: return RunColors.warn
        case .fixing, .fixed: return .accentColor
        case .verified: return RunColors.good
        case .skipped: return .secondary
        case .yours: return RunColors.you
        }
    }
}

// MARK: - Sidebar

/// In a session's sidebar card while a run works in it: what it needs from
/// you (purple) or where it is, and its stages. A reviewer session gets one
/// quiet line. Clicking opens the run.
struct RunLine: View {
    @Environment(AppModel.self) private var model
    let run: WorkflowRun
    /// The session is one of the run's reviewers.
    var reviewer = false

    var body: some View {
        let tint = RunColors.status(run.status)
        let needsYou = run.status == .needsYou
        Group {
            if reviewer {
                Label("Reviewing for \(run.workflow.name)", systemImage: "eye")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: needsYou ? "hand.raised.fill" : run.status == .paused ? "pause.fill" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                        Text(text)
                            .font(.system(size: 11, weight: needsYou ? .semibold : .regular))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(needsYou ? tint : .primary.opacity(0.85))
                    HStack(spacing: 6) {
                        StageRail(run: run)
                        Spacer(minLength: 4)
                        Text(meta)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(needsYou ? tint.opacity(0.14) : Color.black.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(needsYou ? tint.opacity(0.35) : .clear))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.showRuns(run.id) }
        .help(reviewer ? "Reviewing for \(run.workflow.name). Click to see the run." : "\(run.workflow.name): \(run.activity). Click to see the run.")
    }

    private var text: String {
        let stage = run.currentStage?.title ?? ""
        switch run.status {
        case .needsYou: return run.ask?.title ?? stage
        case .paused: return "Paused · " + stage
        default: return run.activity.isEmpty ? stage : run.activity
        }
    }

    /// "Review and fix · 2/3"
    private var meta: String {
        run.workflow.name + (run.workflow.loop != nil && run.round > 0 ? " · \(run.round)/\(run.maxRounds)" : "")
    }
}

// MARK: - Scrolling

private struct RunsUnscrolledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draws runs views without their scroll views (dev hooks render them
    /// offscreen, which can't draw a scroll view's content).
    var runsUnscrolled: Bool {
        get { self[RunsUnscrolledKey.self] }
        set { self[RunsUnscrolledKey.self] = newValue }
    }
}

extension View {
    /// In a vertical ScrollView, unless rendering offscreen.
    func runsScroll() -> some View { modifier(RunsScroll()) }
}

private struct RunsScroll: ViewModifier {
    @Environment(\.runsUnscrolled) private var unscrolled

    func body(content: Content) -> some View {
        if unscrolled {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}
