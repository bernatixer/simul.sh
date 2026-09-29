# Agent Sessions

A small, native macOS app for managing coding-agent terminal sessions.

> It stores a list of terminal sessions and attaches Ghostty views to tmux sessions.

- **Left sidebar** with active sessions; `⌘1` … `⌘9` switches directly
- Each session is a **real terminal** (libghostty + Metal) attached to a **tmux** session
- Sessions can be renamed, reordered, archived, stopped, and reattached
- Processes survive UI switching **and app restarts** (tmux owns them)
- Claude Code / Codex / OpenCode keep using their own auth, config, MCPs, and updates — to this app they are opaque terminal programs
- No sandbox, no provider APIs, no IDE features. Implementation plan: [`../agent-sessions-macos-plan.md`](../agent-sessions-macos-plan.md)

## Architecture

```
SwiftUI sidebar  ─┐
                  ├─ TerminalHost (libghostty surface, Metal)
NavigationSplitView│        │ PTY
                  │        ▼
                  │      tmux  ──▶  claude / codex / opencode / shell
SessionStore (JSON)  AppModel (@Observable)
```

- `Sessions/` — the only place that knows tmux syntax (`TmuxSessionBackend`)
- `Terminal/` — the only place that knows libghostty (`GhosttyBridge/`)
- `Persistence/` — atomic versioned JSON at `~/Library/Application Support/AgentSessions/sessions.json`
- Everything else is ordinary SwiftUI + AppKit

## Building

Requirements: macOS 14+, Apple Silicon, Command Line Tools (no Xcode needed),
`tmux` on the login-shell PATH, plus the vendored Zig toolchain:

```sh
brew install tmux

# Zig 0.16.0 (exact version required by the pinned Ghostty revision)
cd AgentSessions/Vendor
curl -fsSL -o zig.tar.xz https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz
tar xf zig.tar.xz && mv zig-aarch64-macos-0.16.0 zig && rm zig.tar.xz

# Vendor Ghostty (pinned submodule)
git submodule update --init Vendor/Ghostty
```

Then:

```sh
cd AgentSessions
scripts/build-ghostty.sh   # applies the build patch, builds libghostty.a (~minutes)
scripts/build-app.sh       # compiles Swift, produces Build/AgentSessions.app
open Build/AgentSessions.app
```

Run the tests (models, persistence, tmux lifecycle integration):

```sh
swift run AgentSessionsTests
```

## Vendored Ghostty

`Vendor/Ghostty` is a git submodule pinned to an exact commit (see
`.gitmodules`). It is **never** modified in place; `scripts/build-ghostty.sh`
applies [`Vendor/patches/runtime-metallib.patch`](Vendor/patches/runtime-metallib.patch)
which:

1. compiles the Metal shaders **at runtime** (`newLibraryWithSource:`) so
   builds do not require the Xcode Metal toolchain (`metal`/`metallib`), and
2. installs `libghostty.a` + headers directly instead of wrapping them in an
   xcframework (no `xcodebuild`), and
3. optionally accepts a prebuilt metallib via `GHOSTTY_METALLIB_FILE=<path>`
   for future builds that do have the Metal toolchain.

Upgrade procedure (plan §18): bump the submodule, read upstream changes,
re-apply or update the patch, re-run `scripts/build-ghostty.sh`, then walk the
smoke-test matrix (plain shell, tmux attach/detach, Claude, Codex, OpenCode,
vim, htop, Unicode/emoji, mouse, clipboard, IME, resize, rapid ⌘1/⌘2
switching, sleep/wake, GUI quit/relaunch with tmux alive).

## Behavior notes

- **PATH resolution**: the app asks your login shell (`$SHELL -lic 'command -v …'`)
  where `tmux`/`claude`/`codex`/`opencode` live, and captures that PATH for new
  sessions. Homebrew, `~/.local/bin`, nvm/mise/asdf paths all work.
- **Attach**: the terminal runs `tmux attach-session -t as-<uuid>`; detaching
  (default prefix `ctrl-b d`) drops you on a placeholder with a re-attach button.
- **Stop** terminates the tmux session; **archive** only hides the row;
  **delete** removes metadata only.
- **Clipboard**: ⌘C/⌘V work through the terminal. OSC 52 clipboard *reads*
  are denied (no permission UI in v1); writes that need confirmation are skipped.
- **Appearance**: follows the system, and honors `~/.config/ghostty/config`.
