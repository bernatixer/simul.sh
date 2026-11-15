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
- Sending comments queues one durable message when Chat owns the session.
  In Agent, it pastes without Return. "Ask agent to review" can submit to
  Claude only when idle and its input box holds nothing but the paste.
- Agent comments are drafts until the user keeps them; they don't count in
  Send to agent.
- The review should be architectural, not just line comments: an Overview
  pane (layout B, above the files) with a one-line summary, a change map,
  design-level concerns (Keep / Dismiss), a tour, layers, risk and effort.
  Inspired by PR Lens, CodeRabbit and Copilot review; none of their code.
- Look and feel copies GitHub's Files changed page: Primer colour tokens
  exactly (light and dark, in `UI/Review/ReviewPalette.swift`), word-level
  highlights, file tree, hunk expanders, compact rows. No low-contrast
  yellows. Review has its own light/dark switch; Chat uses a light window.
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

## Session names

The sidebar keeps its flat session cards, existing dimensions and launch folder
under each name. Manual session folders still work as before.

Names record their origin. A placeholder can use the first prompt, then a
provider title. A supplied or manually confirmed name always wins. Old records
without provenance decode as supplied names. Automatic names are bounded, and
renaming never sorts the sidebar. No extra model request is made for naming.

## Chat

Chat uses the installed Claude and Codex CLIs through their structured
interfaces. Authentication and provider configuration remain in those CLIs;
Simul does not call model APIs or keep credentials. The provider adapters
translate stream-json and app-server events into common rows and requests.

A session has one process owner. New Claude and Codex sessions start in Chat.
An existing terminal can hand over only while idle, with an exact conversation
ID. Simul closes that owner and checks its PID has exited before starting
its replacement. Launches share a per-session gate and generation so a late
resolver or response cannot create a second owner after a mode change.

The outbox saves a message's ID and contents before a write. A provider
acknowledgement settles that message; terminal silence cannot count as success.
A lost acknowledgement leaves an unconfirmed message. Reconnect reconciles
history by ID; it never automatically repeats a message. Queue work continues
only after an explicit successful turn. Stop, failure and restart pause it.
Draft attachments live in Application Support alongside the Chat snapshot.
Snapshots are atomic and keep a previous copy; unreadable or newer snapshots
are preserved rather than replaced with empty state.

ChatCenter owns live clients and session state independently of SwiftUI view
lifetimes. Stream events are batched over 32 ms. Pipe I/O, transcript parsing,
Markdown parsing and thumbnail decoding stay off the main thread. History
renders in 200-row windows. Parsed Markdown has a bounded cache, and transcript
imports retain at most two provider files. Tool previews are bounded while
full output remains available in a native text viewer.

Chat uses light colours across the main window. Ghostty retains its dark
terminal palette, and Review keeps its own light/dark preference. The measured
clip view controls following; selecting text or scrolling up pauses it.
Bottom visibility is measured separately, so selecting visible text does not
show Jump to latest. Session snapshots preserve the reading anchor and
expanded tools. Session identity stays in the sidebar; connection recovery
and idle terminal handoff appear beside the composer when needed.

Light colours use the user's GitHub palette: white canvas (#FFFFFF), surface
(#F6F8FA), border (#D0D7DE), primary text (#1F2328), secondary text (#656D76)
and muted text (#8C959F). Message/code surfaces use the surface colour. The
sidebar follows the user's Slack reference: #EFEFEF background and #D8D8D8
selected row, sampled in sRGB from the screenshot. Selection uses a grey fill
with dark text. Actions use the primary
text colour. Important labels and the composer placeholder use secondary text;
muted text is for auxiliary labels and glyphs. Stale usage retains readable
text, with a warning dot and timestamp for age. Increased contrast adds
stronger borders.

Model and effort labels report provider values and do not change configuration.
Claude replies supply the actual model; its transcript supplies the recorded
effort after each turn. Missing metadata stays hidden. Observed values are
never passed back as configuration when reconnecting.
