# Changelog

What changed in each Simul release. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org), and stay 0.x until session storage and resume
are settled.

New work goes under **Unreleased**. `scripts/release.sh X.Y.Z` expects that
section renamed to `## [X.Y.Z] - YYYY-MM-DD` and uses it as the release notes.

## [Unreleased]

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
