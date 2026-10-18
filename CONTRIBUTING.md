# Contributing to Simul

Build steps are in the [README](README.md); [AGENTS.md](AGENTS.md) has the
rules for changes, testing and releases.

## How it works

- `Sessions/` starts agents and is the only place that knows process
  details. By default each agent runs directly in its terminal's PTY and
  lives as long as the app (quitting asks first). A tmux backend exists for
  processes that outlive the app, but isn't wired to a setting.
- `Terminal/` is the only place that knows libghostty (`GhosttyBridge/`).
- `Persistence/` keeps session metadata as versioned JSON in
  `~/Library/Application Support/Simul/sessions.json`.
- Everything else is plain SwiftUI + AppKit with `@Observable` state.

Behavior worth knowing:

- **Resume.** Each session is tied to one exact conversation, never "the
  latest in this folder": Claude gets the session's UUID (`--session-id`,
  later `--resume`); Codex's thread is found afterwards and resumed by id, or
  the session starts fresh. OpenCode and shells always start fresh.
- **Attention.** A badge marks sessions you aren't looking at that finished a
  turn, sent a notification, rang the bell, or finished a shell command.
- **Limits.** Asked of the agents themselves (`claude /usage` in safe mode,
  `codex app-server`); nothing shown for token-priced plans.
- **Environment.** Agents get your login shell's PATH and never inherit
  whatever launched Simul (e.g. another agent's `CLAUDE_CODE_*` variables).
- **Look.** Fonts, colors and keys come from `~/.config/ghostty/config`; the
  window takes its colors from the terminal background.

## Vendored Ghostty

`Vendor/Ghostty` is a submodule pinned to an exact commit and never edited in
place. `scripts/build-ghostty.sh` applies the patches in `Vendor/patches`:
`runtime-metallib.patch` so it builds without Xcode (Metal shaders compile at
runtime, and `libghostty.a` is installed directly instead of as an
xcframework), and `hyperlink-at.patch`, which lets Simul ask whether a cell
is an OSC 8 link. To upgrade,
bump the submodule, refresh the patch, rebuild, and smoke-test agents, vim,
Unicode, mouse, clipboard, IME and resize.
