# Simul

**One player, many boards.** A native macOS app for running several coding
agents side by side — Claude Code, Codex, OpenCode or a plain shell — each in
a real terminal, one keystroke apart (`⌘1`…`⌘9`).

Named after a chess *simul*, where one player walks between many boards and
plays wherever a move is waiting. [simul.sh](https://simul.sh)

- **Real terminals.** Every session is a [Ghostty](https://ghostty.org)
  terminal running the agent's own CLI, with your login, config and MCPs —
  Simul never talks to provider APIs or touches credentials.
- **Picks up where you left off.** Each session reopens its own conversation.
- **Knows what needs you.** Sessions show when an agent is working and when
  it's done; plan limits for Claude and Codex sit at the bottom.

Early and personal: macOS 14+, Apple Silicon.

## Building

Needs the Command Line Tools (no Xcode) and Zig 0.16.0, the exact version the
pinned Ghostty expects:

```sh
git submodule update --init Vendor/Ghostty
curl -fsSL https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz | tar xJ -C Vendor
mv Vendor/zig-aarch64-macos-0.16.0 Vendor/zig

scripts/build-ghostty.sh   # builds libghostty.a (a few minutes, once)
scripts/build-app.sh       # builds Build/Simul.app, then runs scripts/smoke.sh
scripts/install.sh         # optional: copies it to /Applications and opens it
swift run SimulTests       # tests (tmux tests need `brew install tmux`)
```

Releases: move the CHANGELOG's Unreleased notes under `## [X.Y.Z] - date`,
commit, then `scripts/release.sh X.Y.Z` (add `--dry-run` to build and zip
without tagging or publishing). [FEATURES.md](FEATURES.md) lists what the app
does today; [CHANGELOG.md](CHANGELOG.md) what changed when.

`scripts/make-icon.sh` regenerates `Resources/AppIcon.icns` from the
dot-matrix art.

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

## Website

[simul.sh](https://simul.sh) is the static page in `site/` (plain HTML, CSS
and JS; no build step). Serve that folder from any static host.

## Vendored Ghostty

`Vendor/Ghostty` is a submodule pinned to an exact commit and never edited in
place. `scripts/build-ghostty.sh` applies the patches in `Vendor/patches`:
`runtime-metallib.patch` so it builds without Xcode (Metal shaders compile at
runtime, and `libghostty.a` is installed directly instead of as an
xcframework), and `hyperlink-at.patch`, which lets Simul ask whether a cell
is an OSC 8 link. To upgrade,
bump the submodule, refresh the patch, rebuild, and smoke-test agents, vim,
Unicode, mouse, clipboard, IME and resize.

## License

[MIT](LICENSE) © Bernat Torres.

Simul builds on [Ghostty](https://github.com/ghostty-org/ghostty) (MIT,
© Mitchell Hashimoto and Ghostty contributors), included as a submodule and
linked into the app; its license ships with it and must accompany any
distributed build.

Claude, Codex/OpenAI and OpenCode names and logos are trademarks of their
respective owners, used only to show which agent a session runs. Simul is not
affiliated with or endorsed by them.
