# Design decisions

Why features are built the way they are. FEATURES.md says what the app
does; CONTRIBUTING.md how the code is laid out. Update this when a decision
below changes.

## Review (0.7.0)

Built Oct 2026 in four phases plus a GitHub-parity round. Replaces the
"check the agent's work on GitHub" step: review locally, send fixes to the
agent, push once happy. The same screen reviews other people's PRs.

### Product rules (decided with the user)

- Review the whole change (branch vs merge-base with its PR's base, else
  the default branch; uncommitted and untracked files included), never
  per agent turn. Viewed marks store the file's content hash and clear
  themselves when it changes, with a "since viewed" diff.
- A PR is just another **source** (session folder, the repo's worktrees,
  a PR, any folder), not a separate feature. Claude sessions open on the
  agent's current worktree (read from its transcript). PRs reuse a worktree
  that has the branch, else get a Simul-owned one under the data dir.
- Nothing reaches GitHub until "Submit review on GitHub…"; comments that
  can't go inline go in the summary. Agents never post.
- Sending comments pastes one prompt into the agent's terminal without
  Return. Exception: "Ask agent to review" presses Return for Claude only
  when it's idle and its input box holds nothing but the paste.
- Agent comments are drafts until the user keeps them; they don't count in
  Send to agent.
- The review should be architectural, not just line comments: an Overview
  pane (layout B, above the files) with a one-line summary, a change map,
  design-level concerns (Keep / Dismiss), a tour, layers, risk and effort.
  Inspired by PR Lens, CodeRabbit and Copilot review; none of their code.
- Look and feel copies GitHub's Files changed page: Primer colour tokens
  exactly (light and dark, in `UI/Review/ReviewPalette.swift`), word-level
  highlights, file tree, hunk expanders, compact rows. No low-contrast
  yellows. Review-only light/dark switch.
- Out of scope: per-turn diffs, a push button, PR inbox/CI/merging,
  LLM API calls from Simul (understanding is asked of a session's agent),
  an agentic graph.

### How it works

- Git and `gh` run as processes off the main thread (`Sessions/ReviewGit.swift`,
  `Sessions/ReviewSources.swift`); results cached by content hash; nothing
  runs while the review is hidden. Refresh on turn end and on demand.
- Moves and whitespace-only edits are Simul's own detection (blocks of 3+
  lines equal after normalising whitespace), for every language.
- Tree-sitter (vendored C sources in `Vendor/tree-sitter`, pinned by
  `scripts/fetch-tree-sitter.sh`, compiled by `build-app.sh`) gives Python,
  JS and TS/TSX syntax colours, the function strip and follow-a-name
  (`git grep -w` for other uses).
- Agent handoff is a JSON file Simul names (`Models/AgentDrafts.swift`,
  `Models/AgentOverview.swift`), never terminal scraping. Version 2 adds
  summary, map, concerns, tour, layers, risk, effort. Every anchor is
  validated (path inside the root, line in range, ≤ 2 MB files); a bad
  overview is rejected with reasons and comments still import.
- Expanded context lines are read only on click and only if the file's
  blob hash still matches the snapshot.

### Performance

- Scroll lag came from SwiftUI laying out nested stacks per diff row. Each
  row is now one `DiffRowLayout` (`UI/Review/ReviewDiffRows.swift`), built
  from a flat per-file row list. Keep it that way: no per-row menus,
  buttons, popovers or extra gestures. Baseline on a 17-file PR: ~8 ms
  median per 80 pt scroll step, ≤ 2 frames over 16 ms.
- Measure with `App/DevHooks.swift`: launch a test copy with
  `SIMUL_DEV_HOOKS=1`, write commands (`select`, `review`, `pr`, `folder`,
  `scroll`, `snap`, `key`, …) to `<data dir>/devcmd`, send SIGUSR1, read
  `<data dir>/devlog`. Snapshots need no screen-recording permission. With
  the screen locked macOS shows no windows and PR fetches fail.

### Not done yet

- Hide whitespace and compact line height settings; remembering the
  Overview toggle and Files | Layers choice.
- Local risk rules (database, network, shell, secrets, dependencies) and
  "callers not updated" from the original Phase 4 idea.
- Sequence diagram for request flows, if the change map isn't enough.

## Workflows (unreleased)

Built to stop people babysitting agents through the same routine on every
change: review it, fix what's found, run the checks, push, wait for CI, read
the bots' comments, fix, again, then merge and check it in production.
Loops are cheap; trusting what they produced is the hard part, so the
product is the findings list and its evidence as much as the loop.

### Product rules

- A workflow is stages in order with at most one loop: before, loop, after.
  Never a graph. Branching is a stage that skips itself (`skipUnless`,
  `skipIfDiffAtMost`); anything more is two workflows (`then`).
- Agents do all the work, in sessions you can watch and type into. Simul
  never calls a model, never posts to GitHub and never merges; it reads PR
  state with `gh` to know when to move on. A stage may tell an agent to push
  or merge (Ship a change does, after your OK).
- Reviewers are new sessions every round: one agent reviewing its own fix
  is the weakest check there is. Claude and Codex can review together.
- Mechanical checks beat judgement: a check stage's exit code decides, and a
  finding is "verified" only when a later fresh review or check no longer
  finds it, never because the fixing agent said so.
- Findings from every source go in one list with one lifecycle (open →
  fixing → fixed → verified, or skipped / yours). Findings below the chosen
  severity are asked about, so fixes don't grow the change.
- People are the user's: a person's PR comment is never handed to the agent
  without the user, and Simul never replies to anyone.
- Code Simul didn't write with the user is untrusted. Reviewers of someone
  else's PR get no shell (read-only git has flags that run or write things:
  `git grep -O`, `--output`), never skip permissions, and read a diff Simul
  wrote; Codex works sandboxed in Simul's runs folder. Text from GitHub
  (bots' comments) reaches the fixing agent framed as something to judge.
- Ship never pushes to the default branch (the agent is told to branch
  first) and never merges without your OK unless you set a size under which
  it may, once GitHub says nothing blocks it.
- Every unattended part is bounded: rounds, check retries, wait timeouts,
  reviewer reminders. Something that looks like a loop going in circles (a
  finding that comes back, tests getting weaker, the change growing) stops
  and asks.
- "What needs me" is the first thing on screen: Needs you on top of Runs, a
  purple block on the session's card, a notification. Runs is a mode of the
  session like Review, listing that session's runs by default (All is one
  click away): you work session by session. A run's Now card says
  what it's doing or what it needs in one sentence, with the buttons.

### How it works

- `Models/Workflow.swift` (the definition), `WorkflowRun.swift` (a run, its
  findings and asks), `FindingLedger.swift` (how reviews, checks and PR
  feedback update findings; pure, tested), `WorkflowTemplates.swift` (the
  built-ins). `State/WorkflowEngine*.swift` moves runs along;
  `State/AppModel+Workflows.swift` starts reviewer sessions and types prompts.
- Events, not polling, drive agent stages: AppModel's turn start and end
  (the same signals as the sidebar's working and finished states) call the
  engine. A 15 s timer runs only while a run is live, for waits, GitHub
  polls (every 1–2 minutes) and prompts that couldn't be typed yet.
- Commands (checks, git, gh) write to files, not pipes, and always time
  out, so a child left running in the background can't hang a stage.
- Async stage work captures the stage's token and drops its result if the
  run moved on meanwhile (an answer, a stop).
- Reviewers get their task as the agent's prompt argument (`claude "…"`,
  `codex "…"`) and write JSON to a file Simul names under
  `runs/<run id>/`; Simul never reads their terminal. Prompts for the run's
  own session are typed only when Claude's input box is empty (or showing
  its hint) and Return only when it then holds exactly the prompt, so a
  dialog (trust this folder?) can't be answered by accident.
- What a fix changed is `git stash create` before and after (the working
  tree, untouched), diffed for weakened tests.
- Someone else's PR is reviewed in the same worktree Review uses for PR
  sources; its findings reach Review as the agent's draft comments.
- Runs are saved in `runs.json` (read leniently, so added fields don't break
  older files); finished runs stay until removed.

### Not done yet

- Codex's input box isn't read, so text typed there goes out with a prompt.
- A turn that ends with the agent asking something ("Should I push?")
  counts as the stage done; the next stage or review catches what's missing.
- Stop doesn't kill a check command that's already running (it finishes on
  its own time limit; its result is dropped).
- The tmux backend (processes outliving Simul) isn't handled: a restart
  treats an agent stage as interrupted and asks.
- GitHub only (`gh`); GitLab and others would need their own status reads.
