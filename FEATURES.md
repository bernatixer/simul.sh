# Simul features

Everything Simul does today, by area. For what changed when, see
[CHANGELOG.md](CHANGELOG.md). Keep this file describing the current app:
update it in the same change that adds, alters or removes a feature.

## Sessions

- **Agents:** Claude Code, Codex, OpenCode, or a plain shell. Each runs its own
  CLI with your login, config and MCPs; Simul never calls provider APIs or
  handles credentials.
- **Real terminals:** every session is a Ghostty terminal. Fonts, colors and
  keys come from `~/.config/ghostty/config`.
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
- ⇥ / ⇧⇥ cycle the highlighted agent, ↩ starts it.
- Defaults (agent, folder, skip permissions) are set in Settings and
  remembered.

## Sidebar

- One card per session: agent logo, title, folder and git branch (can be
  hidden).
- ⌘1…⌘9 jump to the first nine visible sessions; drag cards to reorder.
  ⌃⇥ goes back to the session viewed before.
- Folders: sessions started with ⇧⌘N sit together in a box titled after
  the first one until renamed (double-click its header, or right-click ▸
  Rename Folder); click its header to collapse it (not remembered across
  launches). A folder shows only while two or more of its sessions are
  awake; drag cards inside it to reorder them, and drag its header to move
  the folder as one.
  Dropping a card on the middle of another card or folder groups them;
  dragging a card out of its folder takes it out.
- Sleep (right-click or Session menu) stops a session and lists it under
  Sleeping, above Limits, with how long it has slept. Selecting it wakes it
  and resumes its conversation; it rejoins its folder.
- Double-click a card (or right-click ▸ Rename) to rename it inline.
- Right-click opens Simul's own menu (an icon per action; ⌃-click works too): rename, sleep or wake, archive, stop, delete metadata.
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

## Closing and archiving

- ⌘W closes the selected session; a running agent asks first (can be turned
  off in Settings). Closed sessions are archived.
- ⇧⌘A archives or unarchives the selected session; archiving stops it.
- Sessions whose agent exits on its own are archived automatically; an
  explicit Stop keeps them in the list.
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
