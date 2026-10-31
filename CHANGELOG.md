# Changelog

What changed in each Simul release. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org), and stay 0.x until session storage and resume
are settled.

New work goes under **Unreleased**. `scripts/release.sh X.Y.Z` expects that
section renamed to `## [X.Y.Z] - YYYY-MM-DD` and uses it as the release notes.

## [Unreleased]

## [0.7.0] - 2026-10-31

### Added
- Review (Agent | Review switch in the title bar, ⇧⌘R): see everything a
  session's branch changed, full width, mark files viewed (cleared when they
  change again), and send line comments (hover a line, click +) to the
  agent as one prompt. Files are collapsible GitHub-style cards with
  per-file `+/−` stats; the top bar counts the lines left to review. Diffs show
  side by side or unified (remembered), in dark or light colours (the
  toolbar's gear, remembered).
- Review understands the change: blocks moved within or across files fold
  to a jump link, whitespace-only edits are dimmed or folded, the top bar
  sums it up ("40 lines changed · 2 moved · 11 whitespace": changed lines,
  moved blocks, whitespace-only line pairs), and Python, JavaScript and
  TypeScript files get syntax colours, a function strip, and click-a-name to
  highlight it and list its other uses in the repo in a drawer beside the
  diff.
- Review sources: pick what to review from the folder pill: the session
  folder, the repo's other worktrees, a pull request (paste a link or
  number, or pick yours or review-requested via `gh`) or any folder. Claude
  sessions open on their agent's worktree. The base follows the source; PRs
  get a Simul worktree only when none of yours has them checked out, and you
  can remove Simul's from the picker.
- Submit review on GitHub… for pull requests: Comment, Approve or Request
  changes with chosen comments (the agent's only when ticked); comments
  GitHub can't take inline go in the summary when "Add to summary" is on.
  Posted comments show "On GitHub".
- Ask agent to review: an Overview pane above the files with a one-line
  summary, a change map, design-level concerns (Keep / Dismiss) and a short
  tour; with Claude it presses Return when the input box was empty. The
  agent's short line comments (the problem, then the fix) come in as drafts marked "by agent"; Keep makes one yours, so Send
  to Agent counts and sends it; asking again replaces the drafts not kept.
  Ones Simul can't place are kept with a reason and "Ask agent to fix".
- Review marks the words that changed inside a changed line pair, and its
  light colours are GitHub's, syntax colours included.
- Review looks like GitHub's Files changed page: one toolbar (file tree and
  Overview toggles, progress, a gear for Split / Unified and Light / Dark,
  base, source, refresh, Ask agent to review, Send to agent, and a green
  Submit review on pull requests), no bottom bar; 20 pt diff lines with
  50 pt line-number cells; file headers with copy path, comment count, a
  Viewed checkbox and a "…" menu (copy path, open, reveal, expand or
  collapse all files).
- Review file tree on the left: folders first, single-child folders
  joined, status icons, viewed ticks, comment counts and concern dots; click
  a file to go to it, the file at the top of the diff is highlighted, and
  "Filter files…" filters the tree and the diff. The sidebar button hides it.
- Hunk expanders: ↑ / ↓ show 20 more unchanged lines around a hunk, ↕ the
  rest when 20 or fewer are left, and hunks join once the gap is shown.
  Revealed lines get syntax colours too.
- Keyboard review: j / k next / previous file, n / p hunk, v marks the file
  viewed and moves on, c comments on the hunk, ⌥↓ / ⌥↑ next / previous
  concern, ? lists them. The current hunk has a blue bar in the gutter. Only
  while the review shows and you aren't typing.
- Comment on several lines by dragging down the gutter (or its "+"), as on
  GitHub; the lines turn yellow.
- Suggested changes on pull requests: Suggest in the comment box adds a
  ```suggestion block of the lines to edit; the comment shows it as a
  small diff, and Submit review posts it for GitHub to apply.
- The agent's review can group files into layers (Files | Layers in the
  tree, and the diff follows that order), give a risk level with its reason
  and a 1–5 review effort, and on a second review marks concerns "New" or
  "Still open", with the ones gone listed under "Resolved since last review".

## [0.6.1] - 2026-10-20

### Changed
- Remove Stop Session from the session menus. Archive sits at the bottom of
  the context menu, with Archive and Delete Metadata in amber instead of red.
- Session cards show their launch folder without branch or worktree badges,
  which could describe a different checkout from the one the agent is using.

### Fixed
- Folder headers open or close immediately on a single click, while
  double-clicking still renames them. Double-clicks follow the macOS timing setting.

## [0.6.0] - 2026-10-19

### Added
- Double-click a folder's header to rename it; a single click still opens or
  closes it, and the chevron does so at once.
- Drag cards inside a folder to reorder them.
- Right-click menus in Simul's own style, with an icon per action.

### Fixed
- Renaming a card or folder now focuses the field with its text selected,
  ready to type.

## [0.5.2] - 2026-10-19

### Added
- Rename a folder: right-click its header ▸ Rename Folder.

### Changed
- The selected session's card is lighter, so it's easier to see where you are.

## [0.5.1] - 2026-10-18

### Added
- Drag a session onto another session or a folder to group them; drag one out of its folder to take it out.

## [0.5.0] - 2026-10-18

### Added
- ⇧⌘N / ⇧⌘T starts a session in the same folder as the one you're viewing, so review agents sit together under the session that started them. Click a folder's header to collapse it.
- Sleep (right-click or the Session menu) stops a session and keeps it in a Sleeping list at the bottom of the sidebar; selecting it wakes it and resumes its conversation.
- ⌃⇥ switches to the session you were viewing before.

## [0.4.4] - 2026-10-16

### Changed
- The sidebar no longer shows the app version at the bottom.

### Fixed
- A session that asks you a question or for permission mid-turn no longer shows as working at the same time; it works again once you answer.
- Hovering a link in Claude shows the pointing hand, including links shown as a short name ("Docs").

## [0.4.3] - 2026-10-13

### Fixed
- Codex sessions no longer show as finished while Codex is still thinking or waiting on a background command.

## [0.4.2] - 2026-10-12

### Fixed
- A session's unread dot no longer stays on after you switch back to Simul with that session already open.

## [0.4.1] - 2026-10-12

### Added
- The app version at the bottom of the sidebar.

### Fixed
- Pasted images no longer go missing in Codex once an earlier message
  had images, and hovering `[Image #N]` shows the right image.

## [0.4.0] - 2026-10-10

### Added
- macOS notifications when a session you aren't looking at needs you,
  also while Simul is in front. For Claude they show the start of its
  reply (or its own message, e.g. a permission request); other agents get
  a short status. Clicking one opens the session; looking at the session
  removes it. Toggle in Settings.

## [0.3.0] - 2026-10-10

### Added
- ⌘V pastes images: an image on the clipboard is saved and pasted as its
  path, which Claude Code turns into an attachment. Ctrl+V keeps working as
  before.
- Copied files (e.g. from Finder) paste as their full paths.
- Hovering an `[Image #N]` that was pasted in Simul (⌘V or Ctrl+V) shows
  the image in a popover.

## [0.2.0] - 2026-10-07

### Added
- Menu bar item: Simul's mark with a count of sessions waiting for you; its
  menu lists what's waiting and what's working, and opens or starts sessions.
  Can be hidden in Settings.
- Session menu lists your sessions by name with their ⌘1…⌘9 shortcuts.
- New-session page: ⇥ / ⇧⇥ cycle the highlighted agent, ↩ starts it.
- Working sessions show a light orbiting the agent tile (an outline only with
  Reduce Motion).
- Build check: `scripts/build-app.sh` launches the app and fails if it keeps
  using CPU while idle.
- Version comes from the latest `vX.Y.Z` git tag; `scripts/release.sh` builds
  and publishes a release.

### Changed
- "New Session" moved to the File menu (⌘N, and ⌘T as before).
- A turn only counts as finished when progress stays off for 2.5 s, so brief
  gaps between an agent's steps no longer flag the session.
- With the sidebar shown, the terminal starts at the top of the window.
- macOS window tabs are turned off (Simul is one window with its own sidebar).
- Stop is disabled for sessions that aren't running.

### Fixed
- The app could freeze, using 100% CPU, after the menu bar item was added
  (its setting was rewritten on every redraw, triggering another redraw).
- Provider logos were read from disk on every sidebar redraw.
- An empty band below the notch in full screen.
- The menu bar's working time didn't update; it now shows when the turn
  started.

## [0.1.0] - 2026-10-04

First version, built and run locally.

### Added
- Several coding agents side by side (Claude Code, Codex, OpenCode or a
  plain shell), each in a real Ghostty terminal running the agent's own CLI.
- Sidebar of session cards: ⌘1…⌘9 switching, drag to reorder, inline rename,
  archive (newest first, with ages), stop, folder and git branch.
- Each session resumes its own conversation: Claude by session id, Codex by
  the thread found at turn end; never "the latest in this folder".
- Attention badge when a session you aren't viewing finishes a turn, sends a
  notification or rings the bell; working sessions show elapsed time.
- Plan limits for Claude and Codex, asked of the agents themselves; Simul
  handles no credentials.
- New-session page with agent picker, folder choice and an optional
  skip-permissions flag; Settings for defaults, closing and display.
- ⌘W closes the selected session (asks first for a running agent), ⌘B toggles
  the sidebar.
- Agents run directly in their terminal's PTY and quit with the app (which
  asks first); a tmux backend exists but isn't exposed as a setting.
- Agents get your login shell's PATH and never inherit Simul's launch
  environment.
- Fonts, colors and keys from `~/.config/ghostty/config`; the window takes
  the terminal's background color.
- Session metadata stored as versioned JSON with a backup copy.

[Unreleased]: https://github.com/bernatixer/simul.sh/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/bernatixer/simul.sh/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/bernatixer/simul.sh/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bernatixer/simul.sh/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bernatixer/simul.sh/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bernatixer/simul.sh/releases/tag/v0.1.0
