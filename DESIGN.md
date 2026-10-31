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
