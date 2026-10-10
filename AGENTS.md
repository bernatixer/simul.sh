# Working on Simul

Native macOS app (SwiftUI + AppKit, Swift 6 language mode) that runs coding
agents in Ghostty terminals. Built with plain `swiftc` and the Command Line
Tools: no Xcode, no xcodeproj. README.md has setup and architecture;
FEATURES.md says what the app does today.

## The user's Simul is live

You are probably running inside the user's Simul right now, and so are their
other agents. Killing that app ends every session in it, including yours.

- Never run `scripts/install.sh`, `killall Simul`, or `pkill -f` with a
  pattern matching `Simul.app`: they hit the user's running copy. Stop only
  processes you started, by PID.
- Never `open` a build: it may just bring the user's Simul to the front.
  Launch the binary directly, with its own data folder (below).
- Installing a build into `/Applications` is the user's call; ask, and say
  it will end their running sessions.

## Build, try, test

```sh
scripts/build-app.sh   # Build/Simul.app, then scripts/smoke.sh (idle-CPU check)
SIMUL_DATA_DIR=~/.simul-dev Build/Simul.app/Contents/MacOS/Simul &   # try it
swift run SimulTests   # model, storage and launch-logic tests
```

- `SIMUL_DATA_DIR` keeps a test copy away from the user's real sessions.
  Settings (UserDefaults) are still shared with the user's Simul: don't
  change them from a test copy.
- A failing smoke check means the app keeps using CPU while idle, almost
  always a SwiftUI redraw loop. Fix it; don't raise the limit.
- To see what keeps redrawing a view, temporarily add
  `let _ = Self._printChanges()` to its `body`, and remove it afterwards.

## Code rules

- Only write `@Observable` model properties and UserDefaults when the value
  actually changes (`if new != old { old = new }`). Every write notifies
  observers even when the value is the same, and unguarded writes from view
  updates loop forever.
- Never bind a system-managed control (`MenuBarExtra(isInserted:)`, status
  items, window state) straight to `@AppStorage`; wrap it in a `Binding`
  whose setter only writes real changes. This exact loop froze the app in 0.2.0.
- No disk or process work in a view `body`: cache it (see
  `ProviderIcon`) or move it into the model.
- Match the surrounding code: comment density, naming, small files.

## With every change

- Add a line under `## [Unreleased]` in CHANGELOG.md for anything a user
  would notice (Added / Changed / Fixed).
- Update FEATURES.md in the same change if what the app does changed.

## Commits and releases

- Commit only when the user asks.
- Commits are authored as `Bernat Torres <bernat.torres.bellido@gmail.com>`
  (set in this repo's git config); don't change it.
- Release, only when asked: rename `## [Unreleased]` to
  `## [X.Y.Z] - YYYY-MM-DD` (adding a fresh empty Unreleased above it),
  commit, then `scripts/release.sh X.Y.Z`. It builds, zips, tags, pushes the
  tag and creates a GitHub release; `--dry-run` stops before tagging.
  Versions stay 0.x for now; releases are ad-hoc signed, for the user's own
  Mac only.
- `Vendor/Ghostty` always shows as modified: build-ghostty.sh patches it in
  place. Never commit inside it or edit it by hand (see README).
