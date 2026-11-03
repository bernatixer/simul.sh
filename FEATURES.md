# Simul features

Everything Simul does today, by area. For what changed when, see
[CHANGELOG.md](CHANGELOG.md). Keep this file describing the current app:
update it in the same change that adds, alters or removes a feature.

## Sessions

- **Agents:** Claude Code, Codex, OpenCode, or a plain shell. Each runs its own
  CLI with your login, config and MCPs; Simul never calls provider APIs or
  handles credentials.
- **Real terminals:** every session is a Ghostty 1.4.0 terminal. Fonts, colors
  and keys come from `~/.config/ghostty/config`.
- **Resume:** each session is tied to one exact conversation, never "the
  latest in this folder". Claude gets the session's id (`--session-id`, later
  `--resume`); Codex's thread is found when its first turn ends and resumed by
  id. OpenCode and shells start fresh.
- **Lifetime:** agents run directly in their terminal and quit with the app;
  quitting asks first while sessions are running. Conversations stay in the
  agents' own storage.
- **Environment:** agents get your login shell's PATH and never inherit
  whatever launched Simul (such as another agent's `CLAUDE_CODE_*` variables).
- **Skip permissions:** optional per session; adds the agent's own flag
  (e.g. Claude's `--dangerously-skip-permissions`).
- **Extra arguments** per agent, in Settings.

## Pasting

- ⌘V with an image on the clipboard saves it and pastes its path; Claude
  Code turns that into an `[Image #N]` attachment. Ctrl+V still lets the
  agent read the clipboard itself.
- Files copied in Finder paste as their full paths, escaped for the shell.
- Hovering an `[Image #N]` shows that image in a popover, for images pasted
  in Simul since it launched (⌘V or Ctrl+V). Simul learns each image's
  number by reading the screen right after the paste. Pasted images are kept
  in `~/Library/Caches/Simul/pastes` and cleared on launch.

## Starting a session

- ⌘N or ⌘T opens the new-session page: pick an agent, a folder and an
  optional title.
- ⇧⌘N or ⇧⌘T does the same, but the new session joins the current one's
  folder (making one with the current session if needed).
- ⇥ / ⇧⇥ cycle the highlighted agent, ↩ starts it (wherever focus is on the page).
- Defaults (agent, folder, skip permissions) are set in Settings and
  remembered.

## Sidebar

- One card per session: agent logo, title and launch folder (can be hidden).
  The folder is where the session started; agents may work in other checkouts.
- ⌘1…⌘9 jump to the first nine visible sessions; drag cards to reorder.
  ⌃⇥ goes back to the session viewed before.
- Folders: sessions started with ⇧⌘N sit together in a box titled after
  the first one until renamed (double-click its header, or right-click ▸
  Rename Folder); click its header to collapse it immediately (not remembered
  across launches). A folder shows only while two or more of its sessions are
  awake; drag cards inside it to reorder them, and drag its header to move
  the folder as one.
  Dropping a card on the middle of another card or folder groups them;
  dragging a card out of its folder takes it out.
- Sleep (right-click or Session menu) stops a session and lists it under
  Sleeping, above Limits, with how long it has slept. Selecting it wakes it
  and resumes its conversation; it rejoins its folder.
- Double-click a card (or right-click ▸ Rename) to rename it inline; Return
  or a click anywhere else saves, Escape cancels.
- Right-click opens Simul's own menu (an icon per action; ⌃-click works too):
  rename, sleep or wake, unarchive, archive, delete metadata. Archive (amber)
  and Delete Metadata (red, last) keep the agent's conversation.
- Archived sessions sit behind a footer button, newest first, with their
  age; selecting one shows it, Unarchive brings it back.
- ⌘B shows or hides the sidebar.

## Knowing what needs you

- **Working:** a light orbits the agent tile, with the time since the turn
  started (a still outline with Reduce Motion). An agent that stops
  mid-turn to ask something counts as waiting, not working, until you
  answer.
- **Waiting:** an attention badge marks a session you aren't viewing that
  finished a turn, sent a notification, rang the bell or finished a shell
  command. Viewing the session clears it.
- **Notifications:** a session that needs you posts a macOS notification,
  unless Simul is in front showing that session. For Claude: the start
  of its last reply, read from Claude's own transcript (or its message, such as a permission request).
  Other agents: "Finished, waiting for you" or "Needs your attention". One
  per session until you look at it; clicking it opens the session; viewing
  the session removes it. Can be turned off in Settings.
- **Menu bar:** Simul's mark with the number of sessions waiting. Its menu
  lists waiting and working sessions (with when each started working),
  starts a new session or opens Simul. Can be hidden in Settings.
- **Plan limits:** Claude's and Codex's usage windows at the bottom of the
  sidebar, asked of the agents themselves (`claude /usage` in safe mode,
  `codex app-server`). Nothing is shown for token-priced plans. Can be hidden
  in Settings.

## Reviewing changes

- **Agent | Review:** the switch in the title bar (or ⇧⌘R) swaps the
  terminal for the review, which takes the whole detail area; the agent keeps
  running underneath. Nothing runs while the review isn't shown.
- **The change:** everything the source changed against its base. The base
  follows the source: a pull request's base branch (fetched along with the
  PR); otherwise the branch's pull request target (via `gh`, if installed),
  else origin's default branch, then `main` or `master`. With none of those,
  only uncommitted changes. Uncommitted and untracked files are included, and
  your git index is never touched. The base pill changes the base (Auto and
  Reset go back to the default).
- **Source:** the folder pill picks what is reviewed: the session folder, the
  repo's other worktrees, a pull request (paste a link or number, or pick one
  of yours or awaiting your review, via `gh`), or Choose Folder…. A Claude
  session opens on the worktree its agent is working in until you pick a
  source. A PR already checked out in one of your worktrees is reviewed
  there, untouched; otherwise Simul makes its own worktree under its data
  folder. Simul's worktrees can be removed from the picker (it asks first;
  local changes need "Remove anyway"); yours are never modified.
- **Toolbar:** one row, as GitHub's: the file tree and Overview toggles,
  progress and the summary on the left; the gear (Split / Unified, Light /
  Dark), base, source, refresh, Ask agent to review and Send to agent on the
  right, with Submit review as the green button on pull requests (otherwise
  Send to agent is).
- **Files:** one list of diffs, each file a card as on GitHub, coloured by
  added/removed lines, 20 pt lines with 50 pt line-number cells for only the
  columns each file needs. Split (the default, old left, new right; added and
  deleted files stay one column) or Unified, from the gear, remembered. Each
  file's header shows its path (copy button on hover), `+added −removed` with
  five GitHub-style squares, its comment count, a Viewed checkbox and a "…"
  menu: Copy path, Open file, Reveal in Finder, Expand / Collapse all files.
  The chevron collapses or expands it.
- **File tree:** on the left (the toolbar's sidebar button hides it,
  remembered): folders first then files, a folder holding only one folder
  shown as one path, each file's status icon, a tick once viewed, its
  comment count and a dot for the agent's highest open concern. Click a file
  to go to it; the file at the top of the diff is highlighted. "Filter
  files…" filters the tree and the diff list, which follows the tree's order.
  When the agent's review has layers, Files | Layers lists the files under
  numbered layers with their notes (the rest under Other), and the diff
  follows that order.
- **Expanding hunks:** the `@@` row's ↑ shows 20 more unchanged lines above
  a hunk, ↓ 20 more below the one before, ↕ the rest when 20 or fewer are
  left; once a gap is all shown the hunks join. The last hunk gets a ↓ to the
  end of the file. Lines come from the file on disk, read once per refresh,
  and get syntax colours like the rest (parsed off the main thread).
- **Light / Dark:** from the gear, switches the review (only the review)
  between dark and light, which uses GitHub's own light colours (Primer),
  syntax colours included; remembered.
- **Viewed:** mark files viewed, which collapses them; the mark clears when
  the file changes again. "Since viewed" shows only what changed after you
  marked them. Submodules can be marked viewed too (no "Since viewed" copy);
  other paths git can't hash (a nested repo) have Viewed disabled.
- **Progress:** the toolbar shows `V / N viewed` with a ring, and the
  `+added −removed` still left to review in files not yet viewed.
- **Comments:** hover a line and click its "+", or click its gutter
  (drag down the gutter or shift-click for a range, which turns yellow); ⌘↩
  queues the comment, Esc cancels. On a pull request, Suggest adds a
  ```suggestion block of the lines to edit; the comment shows it as a small
  diff ("Suggested change") and Submit review posts it as is, so GitHub
  offers to apply it.
- **Keyboard:** while the review shows and no text field is being typed in:
  j / k next / previous file, n / p next / previous hunk, v marks the file
  viewed and goes to the next, c comments on the hunk's first changed line,
  ⌥↓ / ⌥↑ next / previous open concern, ? shows these (Esc closes). The
  current hunk has a blue bar on its gutter's edge.
- **Changed words:** in a changed line pair (the lines split view shows side
  by side, in either layout) the words that changed are marked on a stronger
  tint, as on GitHub; pairs too different to be worth it, lines over 500
  characters, moved and whitespace-only lines aren't.
- **Send to agent (N):** pastes your queued comments into the agent's prompt
  without pressing Return, then switches back to the agent; disabled while
  the session isn't running. Sent
  comments are dimmed and can be resolved, which hides them; a comment whose
  line is gone is marked outdated.
- **Moves and formatting:** a block of 3+ lines moved within a file or
  across files (ignoring whitespace) folds to "N lines moved from/to
  path:line" with a jump. Lines that changed only in whitespace are dimmed
  with a "ws" badge, and hunks of only moves and whitespace fold. The top bar
  sums it up: "C lines changed · M moved · F whitespace" (changed lines,
  moved blocks, whitespace-only line pairs; zero parts left out) and "N
  functions changed".
- **Functions and colours:** Python, JavaScript and TypeScript/TSX files get
  syntax colours and a strip of their functions (Changed, Added, Deleted,
  Renamed, Moved, Formatting); click one to jump to it.
- **Follow a name:** in Python, JavaScript and TypeScript files, click a name
  to highlight it across the diff and list its other uses in the repo
  (`git grep`, up to 200, shown as "200+") in a drawer on the right, grouped
  by file with each whole line; click one to jump to it in the diff or see
  the lines around it. × closes the drawer; Esc or Clear stops following.
- **Big files:** files over 1,500 diff lines start collapsed; over 1 MB or
  1,500 diff lines they show plain, without colours or functions. Past about
  6,000 coloured lines in a review, further files show without colours
  (functions still listed).
- **Ask agent to review:** pastes a request for the agent to write its
  review to a file. With Claude, Simul presses Return only when the agent
  isn't working and its input box held nothing but the paste; otherwise it
  waits for you. The review comes back as an **Overview** pane above the
  files (it folds to one row): a one-line summary, a change map (lanes of
  parts that were added, changed, removed, or untouched but depended on,
  joined by arrows; hover a part to highlight it and its arrows, click it
  to jump to it), up to 6 design-level concerns by severity
  (Keep turns one into your comment, Dismiss hides it; file cards show the
  highest open one) and a short tour (‹ › walks the map and the diff). Its
  bar shows the agent's verdict: a risk level (reason beside it) and the
  review effort, 1–5. On a second review, concerns are marked "New" or
  "Still open", and the ones it no longer raises are under "Resolved since
  last review" (folded). The agent can also group the files into layers
  (see File tree). The toolbar's Overview button hides the pane. After
  the code changes it says "Out of date — Ask again". Line comments (short
  ones: the problem and the fix) arrive as drafts marked "by agent" when the review shows: Send to Agent
  doesn't count or send them until you click Keep, which makes one yours.
  Asking again replaces the drafts you didn't keep, so they don't pile up.
  Entries Simul can't place, or with a body over 600 characters, are kept
  with a reason and an "Ask agent to fix" button. A deleted session's review files
  are removed.
- **Submit review on GitHub…:** for pull request sources: Comment, Approve or
  Request changes (which needs a summary), a summary, and which comments to
  post; the agent's comments are listed "by agent" and only go when you tick
  them. Only available when your copy matches the PR head. Comments whose
  line differs from the PR head, or that are outside its diff, go into the
  summary when "Add to summary" is on; otherwise Submit says how many no
  longer match. Posted comments show "On GitHub". Nothing is posted until you
  click Submit.
- **Refreshing:** when the agent finishes a turn while the review is shown, and
  on Refresh. A pull request source is fetched again on each refresh.
- **Stored** in `reviews.json` next to `sessions.json`, with viewed copies
  under `reviews/` and the agent's review files under `drafts/`.

## Workflows

- **What:** a routine Simul runs on one of your sessions, stage by stage: its
  agent does the work in its own terminal, fresh reviewer sessions check it,
  your commands verify it, and Simul waits on GitHub for you. It asks you
  only when it needs you. Simul itself never calls a model, never posts a
  review and never merges: agents do what the stages say, in sessions you
  can watch and type into.
- **Built in:**
  - *Ship a change:* review, fix, run your checks, push (a draft PR if there
    isn't one), wait for CI, read failing checks and comments; repeat until
    clean (4 rounds at most). Then mark it ready, wait for approval, ask you
    before merging (or not, for changes of at most N lines), wait for the
    merge, and optionally start Watch after merge.
  - *Review and fix:* the same loop, nothing pushed: on the folder's branch, or
    on a pull request you pick (the folder switches to its branch).
  - *Review a pull request:* someone else's PR, in its own worktree, again
    each time they push, until it's merged or closed. Findings go to Review
    as the agent's drafts (Open in Review); nothing is posted.
  - *Watch after merge:* waits for the merge and, optionally, for a command
    that says it's deployed; then has the agent check what you described,
    and again after a few hours. It reports ok or a problem; it changes
    nothing.
- **Starting one:** + in Runs, or a session's menu ▸ Start Workflow….
  Pick the workflow (each card shows its stages as icons), the session (its
  agent does the work) and the folder (for Claude, the worktree it's working
  in). Below, the workflow is drawn top to bottom and you set it up in
  place: each stage holds its own settings (reviewers in Review, the command
  in Run checks, the size limit in the merge step) and says what it will do
  with them; the loop's header holds its round limit; stages that can be
  turned off (Review, what starts afterwards) have a switch. Starting with
  Review on and no reviewer picked is refused. One run per session at a time.
- **Stages:** agent (a prompt), review, fix, check (a command that must exit
  0), wait (CI finished, new commits, approved, merged, a command succeeds,
  a time), PR feedback, your OK, and verify (the agent checks and reports).
  At most one part repeats; the rest run once, before or after it.
- **Reviewers:** Claude, Codex or both, each a new session every round (so
  none reviews its own fixes), kept out of the sidebar while they review
  (the run's page lists them, with Watch to open one),
  archived when done. They write their findings to a file Simul names; from
  the second round they're told what was found before and what changed since.
  They may read, and write only their review, without asking: Claude gets an
  allow-list, Codex a sandbox with no network. Reviewing your own change they
  may also run read-only git and `gh`, and skip permission prompts if the
  run's session does. Reviewing someone else's PR they get no commands at
  all (Simul writes the diff for them) and never skip permissions.
- **Findings:** one list per run from every source (reviewers, your checks,
  CI, bots' and people's PR comments). The same problem from two reviewers
  is one finding with both names. Each is open, fixing, fixed (the next
  review or check confirms), verified, skipped (with why) or yours.
  Findings at or above the chosen severity are fixed straight away; lower
  ones are asked about or skipped. People's PR comments are always yours
  first: hand them to the agent or handle them yourself; Simul never replies.
  Bots' comments go to the agent marked as text to judge, not instructions.
- **Guards:** the loop ends when a round has nothing left to fix; a finding
  that comes back after it was verified gone stops to ask; failing checks
  go back to the fix twice before asking; a fix that deletes, skips or
  weakens tests, or a change that grows a lot after the first round, stops
  to ask; rounds and waits have limits.
- **Knowing what needs you:** Runs (⌥⌘R, or Runs beside Agent and Review in
  the title bar, with a purple count) lists the selected session's runs, or
  every session's: those that need you first, then running and finished
  ones. A run shows what it's doing now and what it needs with the buttons
  to answer, its stages top to bottom with what happened in each (the
  repeating part boxed, with a round picker), and every finding. A
  session's card shows its run under the folder: what it needs (in purple)
  or is doing, its stages and round; clicking it opens the run. A run that needs you, or finishes, posts a notification; runs that
  need you are counted in the menu bar too, and listed in its menu.
- **Typing for you:** Simul types a stage's prompt into the session when it's
  between turns and presses Return for Claude (only with its input box
  showing just the prompt) and Codex. If the box isn't showing (a question,
  a dialog such as trusting a new folder, text you typed) it waits and, after
  a while, tells you. Other agents get the prompt pasted and you press Return.
- **Pause and stop:** Pause stops before the next stage; Stop ends the run
  (its reviewer sessions are archived). Finished runs can be removed, with
  their reviewer sessions.
- **Your own workflows:** "Make one from this" opens the selected workflow
  as a new one in an editor: name and summary, the stages before, in and
  after the repeating part (add, reorder, remove; each with its fields),
  rounds, the inputs it asks for, and what to start after it. Problems show
  as you edit; Save is off until there are none. Yours show "Custom" and
  "Edit". "Ask the agent to write one" sends the format to the session's
  agent, which asks you what it should do. They're JSON files in
  `workflows/` in Simul's data folder; problems in a file are listed.
- **Restarts:** runs are saved in `runs.json` and pick up where they were
  after Simul restarts; a stage that was mid-turn asks before sending its
  prompt again.

## Closing and archiving

- ⌘W closes the selected session; a running agent asks first (can be turned
  off in Settings). Closed sessions are archived.
- ⇧⌘A archives or unarchives the selected session; archiving stops it.
- Sessions whose agent exits on its own are archived automatically.
- Delete Metadata removes a session from Simul only; the agent's
  conversation is untouched.

## Window

- One window, no title bar or window tabs; the title-bar strip holds the
  sidebar, Settings and new-session buttons.
- Always dark; the window takes the terminal's background color.
- Full screen keeps everything below the notch on notched displays.

## Data

- Session metadata is versioned JSON in
  `~/Library/Application Support/Simul/sessions.json`, with the previous
  copy kept as `sessions.json.prev`.
- Data from the app's earlier name (AgentSessions) is moved over once.

## Requirements

- macOS 14 or later, Apple Silicon.
- Built locally for now; there is no signed download yet (see README).
