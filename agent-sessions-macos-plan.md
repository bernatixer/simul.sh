# Agent Sessions for macOS — Implementation Plan

## 1. Goal

Build a **small, native macOS app for managing coding-agent terminal sessions**.

The app is intentionally not an IDE, agent framework, or provider client.

It should do one thing well:

> Provide a fast sidebar for switching between persistent terminal sessions running Claude Code, Codex, OpenCode/Z.ai, or arbitrary CLI agents.

Core interaction:

- Left sidebar with active sessions
- `⌘1` … `⌘9` switches directly between sessions
- Each session is a real terminal
- Sessions can be renamed
- Sessions can be archived/restored
- Processes survive UI switching and ideally app restarts
- Claude/Codex/OpenCode keep using their own authentication, subscriptions, configuration, MCPs, skills, and update mechanisms
- No macOS App Sandbox
- Native macOS look and behavior
- Extremely small maintenance surface

---

## 2. Product philosophy

### The app owns

- Session metadata
- Session ordering
- Active/archive state
- Keyboard navigation
- Terminal presentation
- Process/session attachment
- Minimal preferences

### The app does **not** own

- Model APIs
- Provider authentication
- Claude session protocol
- Codex session protocol
- OpenCode session protocol
- AI transcripts
- Prompt history
- Agent permissions
- Agent configuration
- Git
- GitHub
- MCP management
- Code editing
- Diff rendering
- Browser automation
- Worktree lifecycle, initially
- Agent orchestration, initially

The architecture should assume:

```text
Claude Code, Codex and OpenCode are opaque terminal programs.
```

If they work in a normal terminal, they should work here.

---

## 3. Proposed stack

### Application

- **Swift 6**
- **SwiftUI**
- Small amounts of **AppKit** where necessary

No third-party application framework.

### Terminal

- **libghostty**
- Ghostty Metal renderer
- Ghostty terminal emulation/input stack
- Swift/AppKit host

Ghostty is preferred deliberately even though its standalone embedding API is still evolving.

Mitigation:

- Pin Ghostty to an exact known-good commit
- Keep all Ghostty integration behind one narrow adapter
- Never expose Ghostty C types to the rest of the application
- Upgrade Ghostty intentionally, not automatically
- Maintain one small integration test app/window for validating upgrades

### Persistent process layer

- **tmux**

tmux owns long-lived terminal sessions.

The macOS app attaches a Ghostty terminal surface to a tmux client.

This avoids building a custom daemon or process supervisor.

### Persistence

- **Codable**
- One atomic JSON file

Suggested location:

```text
~/Library/Application Support/AgentSessions/sessions.json
```

No SQLite.
No Core Data.
No SwiftData.
No ORM.

### Preferences

- `UserDefaults`
- `@AppStorage` where convenient

### Logging

- `OSLog.Logger`

### Dependencies

Target dependency budget:

```text
Apple SDKs
libghostty
tmux executable
```

Avoid adding Swift packages unless a concrete need appears.

---

## 4. High-level architecture

```text
┌──────────────────────────────────────────────────────────────┐
│                         macOS App                            │
│                                                              │
│  ┌───────────────────┐   ┌────────────────────────────────┐ │
│  │ Sidebar           │   │ TerminalHost                   │ │
│  │                   │   │                                │ │
│  │ 1 auth       ●    │   │ libghostty / Metal            │ │
│  │ 2 billing    ●    │   │                                │ │
│  │ 3 API        ●    │   │ attached to tmux client       │ │
│  │ 4 tests      ○    │   │                                │ │
│  │                   │   │                                │ │
│  │ Archived          │   │                                │ │
│  └───────────────────┘   └───────────────┬────────────────┘ │
└───────────────────────────────────────────┼──────────────────┘
                                            │ PTY
                                            ▼
                                         tmux
                           ┌────────────────┼─────────────────┐
                           ▼                ▼                 ▼
                        claude            codex            opencode
                           │                │                 │
                     subscription     subscription            Z.ai
```

The GUI should remain disposable.

If the GUI crashes, tmux sessions continue running.

---

## 5. Data model

Keep it intentionally small.

```swift
struct Session: Identifiable, Codable, Hashable {
    let id: UUID

    var title: String
    var workingDirectory: String
    var agentID: String

    var isArchived: Bool
    var sortOrder: Int

    let createdAt: Date
    var lastOpenedAt: Date
}
```

Agent configuration:

```swift
struct AgentDefinition: Identifiable, Codable, Hashable {
    let id: String

    var name: String
    var executable: String
    var arguments: [String]
    var environment: [String: String]
}
```

Initial built-ins:

```text
Claude
  executable: claude

Codex
  executable: codex

Z.ai / OpenCode
  executable: opencode
```

Do not create `ClaudeService`, `CodexService`, or `ZaiService`.

Agents are commands.

---

## 6. Session lifecycle

### Create

User chooses:

- Title
- Working directory
- Agent

The app:

1. Creates session metadata
2. Generates a stable tmux session name
3. Starts tmux in the chosen working directory
4. Starts the selected agent command inside tmux
5. Attaches a terminal surface

Example conceptual command:

```bash
tmux new-session \
  -s agent-550e8400 \
  -c "$HOME/dev/project" \
  claude
```

Use a sanitized UUID-based tmux identifier, not the human title.

### Switch

`⌘1` … `⌘9` changes the selected session.

Do not restart or reconnect unnecessarily.

Where practical, keep terminal hosts alive while hidden so switching feels instantaneous and preserves:

- Scroll position
- Selection
- Terminal modes
- Rendering state

### Archive

Archiving should be intentionally simple:

```text
Archive = hide from active sidebar.
```

Archiving does **not** imply terminating the process.

An archived session may still be running.

### Stop

Separate explicit operation:

```text
Stop session
```

This terminates the tmux session.

### Restore

Restoring only changes UI state.

If the underlying tmux session still exists, reattach.

If it no longer exists, the user can explicitly restart it.

Do not silently infer provider-specific resume behavior in v1.

---

## 7. tmux adapter

All tmux behavior must live behind one small component.

Suggested API:

```swift
protocol SessionBackend {
    func exists(_ session: Session) async throws -> Bool
    func create(_ session: Session, agent: AgentDefinition) async throws
    func stop(_ session: Session) async throws
    func listRunningIDs() async throws -> Set<UUID>
    func attachCommand(for session: Session) throws -> ProcessSpec
}
```

Initial implementation:

```text
TmuxSessionBackend
```

The rest of the application should never know tmux command syntax.

### Why tmux

It already solves:

- Detached process survival
- Terminal session persistence
- Reattachment
- Scrollback
- Long-running subprocesses
- App crashes/restarts
- Multiple concurrent sessions

Do not reimplement these.

---

## 8. Ghostty integration

Create a single isolation layer:

```text
GhosttyTerminalHost
```

Responsibilities:

- Initialize libghostty
- Create/destroy a terminal surface
- Configure Metal-backed rendering
- Connect input/output to the PTY/tmux client
- Resize terminal when the view changes
- Focus management
- Clipboard
- Mouse handling
- IME
- Font configuration
- Theme/background
- Emit minimal lifecycle events to Swift

Everything outside this module should see a tiny interface such as:

```swift
protocol TerminalHost {
    func attach(to process: ProcessSpec)
    func focus()
    func resize(to size: CGSize)
    func close()
}
```

### Important rule

**Never let libghostty API details leak into application state or business logic.**

Ghostty's embedding API is not yet fully version-stable.

Therefore:

```text
Ghostty update
    ↓
GhosttyTerminalHost changes
    ↓
Nothing else should change
```

### Dependency strategy

Pin to an exact Ghostty revision.

For example:

```text
Vendor/Ghostty/
```

or as a Git submodule.

Prefer a reproducible build script that produces:

```text
libghostty.a / XCFramework
```

for the architectures you support.

Do not follow Ghostty `main` automatically in CI.

---

## 9. Project layout

Keep the repository boring.

```text
AgentSessions/
├── AgentSessions.xcodeproj
│
├── App/
│   ├── AgentSessionsApp.swift
│   └── AppCommands.swift
│
├── Models/
│   ├── Session.swift
│   └── AgentDefinition.swift
│
├── State/
│   └── AppModel.swift
│
├── Persistence/
│   └── SessionStore.swift
│
├── Sessions/
│   ├── SessionBackend.swift
│   └── TmuxSessionBackend.swift
│
├── Terminal/
│   ├── TerminalHost.swift
│   ├── GhosttyTerminalHost.swift
│   └── GhosttyBridge/
│
├── UI/
│   ├── ContentView.swift
│   ├── Sidebar/
│   │   ├── SidebarView.swift
│   │   └── SessionRow.swift
│   ├── Terminal/
│   │   └── TerminalContainer.swift
│   └── NewSession/
│       └── NewSessionView.swift
│
├── Support/
│   ├── Logging.swift
│   └── Paths.swift
│
└── Vendor/
    └── Ghostty/
```

Avoid additional architecture folders unless they become necessary.

---

## 10. Application state

Use native Observation.

```swift
@MainActor
@Observable
final class AppModel {
    var sessions: [Session] = []
    var selectedSessionID: Session.ID?

    let store: SessionStore
    let backend: SessionBackend
}
```

No:

- TCA
- Redux
- RxSwift
- Combine-based architecture
- DI container
- Service locator
- Event bus

Use initializer injection.

---

## 11. Main UI

Use a native split view.

```text
┌──────────────────┬───────────────────────────────────────────┐
│ Sessions         │                                           │
│                  │                                           │
│ 1  auth       ●  │                                           │
│ 2  billing    ●  │              TERMINAL                    │
│ 3  API        ●  │                                           │
│ 4  tests      ○  │                                           │
│                  │                                           │
│ Archived         │                                           │
│   prototype   ○  │                                           │
│                  │                                           │
└──────────────────┴───────────────────────────────────────────┘
```

### Session row

Only show information that can be known reliably:

- Numeric shortcut
- Title
- Agent name/icon if desired
- Running/stopped state

Initially:

```text
● running tmux session exists
○ stopped
```

Do **not** attempt:

```text
thinking
waiting for approval
finished
token usage
context %
```

until there is a robust provider-independent mechanism.

---

## 12. Keyboard behavior

Primary interactions:

```text
⌘1 ... ⌘9       select session
⌘N               new session
⌘W               close/hide current UI if appropriate
⌘⇧A              archive/unarchive
⌘K               optional session switcher
⌘,               settings
```

Use standard SwiftUI/AppKit command handling.

Do not add a hotkey dependency unless global shortcuts are later required.

---

## 13. Persistence format

Example:

```json
{
  "version": 1,
  "sessions": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "title": "Auth refactor",
      "workingDirectory": "/Users/me/code/app",
      "agentID": "claude",
      "isArchived": false,
      "sortOrder": 0,
      "createdAt": "2026-09-29T08:00:00Z",
      "lastOpenedAt": "2026-09-29T09:00:00Z"
    }
  ]
}
```

### Storage rules

- Version the top-level file
- Atomic writes
- Keep migrations explicit and tiny
- Never persist ephemeral Ghostty handles or process IDs
- Derive tmux identifiers from stable session UUIDs

---

## 14. No sandboxing

The application should be distributed as a normal signed/notarized macOS app.

Do not enable App Sandbox.

Reasons:

The app intentionally needs normal developer-machine behavior:

- Launch `claude`
- Launch `codex`
- Launch `opencode`
- Launch `tmux`
- Access arbitrary repositories
- Read normal shell environment
- Use SSH/Git credentials as existing CLI tools normally do
- Invoke tools installed by Homebrew/asdf/mise/etc.
- Work with developer configuration under `$HOME`

### Distribution

Eventually:

- Developer ID signing
- Hardened runtime as compatible
- Notarization
- DMG or ZIP
- Sparkle only if automatic updates become worthwhile

Do not target the Mac App Store.

---

## 15. PATH and shell environment

This deserves explicit handling because GUI apps do not inherit the same environment as an interactive terminal.

The app must reliably find:

```text
tmux
claude
codex
opencode
```

Pragmatic initial approach:

Run the user's login shell to resolve commands/environment.

Example conceptually:

```bash
$SHELL -l -c 'command -v claude'
```

Cache resolved executable locations, but allow refresh.

Support common locations:

```text
/opt/homebrew/bin
/usr/local/bin
~/.local/bin
mise/asdf paths
```

Do not hardcode Homebrew as the only installation source.

---

## 16. MVP

### Required

- [ ] Native macOS app launches
- [ ] libghostty terminal renders correctly
- [ ] tmux-backed terminal works
- [ ] Claude can run interactively
- [ ] Codex can run interactively
- [ ] OpenCode/Z.ai can run interactively
- [ ] New session dialog
- [ ] Select working directory
- [ ] Select agent
- [ ] Sidebar
- [ ] `⌘1` … `⌘9`
- [ ] Rename session
- [ ] Reorder sessions
- [ ] Archive/unarchive
- [ ] Stop session
- [ ] Running/stopped indicator
- [ ] JSON persistence
- [ ] App restart reconnects to existing tmux sessions
- [ ] Clipboard works
- [ ] Mouse selection works
- [ ] Unicode/emoji works
- [ ] IME works
- [ ] Terminal resizing works
- [ ] macOS dark/light appearance behaves sensibly

### Explicitly not MVP

- Worktrees
- Git integration
- Diffs
- GitHub
- Provider APIs
- Provider session IDs
- Claude hooks
- Codex APIs
- MCP UI
- Agent status parsing
- Token/quota display
- Browser
- Editor
- Tabs inside sessions
- Split terminals
- Remote machines
- SSH management
- Prompt library
- Agent orchestration
- Notifications
- Cloud sync
- Mobile app
- Team features

---

## 17. Implementation phases

### Phase 0 — Ghostty proof of concept

Goal:

```text
A macOS window containing one libghostty terminal running tmux.
```

Tasks:

- Build/pin libghostty
- Create Swift ↔ C bridge
- Create Metal terminal surface
- Handle resize
- Handle keyboard input
- Run/attach tmux
- Validate Claude/Codex/OpenCode TUIs

Do not proceed until:

- Terminal rendering is correct
- Scrolling is correct
- Selection/copy/paste works
- Resize does not corrupt TUIs
- Claude/Codex interactive prompts work correctly

This is the technical risk spike.

---

### Phase 1 — Minimal session switcher

Add:

- Sidebar
- In-memory `Session`
- 2–4 concurrent tmux sessions
- `⌘1` … `⌘4`
- Session title
- Agent label

Success criterion:

Switching sessions feels instant.

---

### Phase 2 — Persistence

Add:

- JSON `SessionStore`
- Stable UUIDs
- Reconnect after app relaunch
- Detect existing tmux sessions
- Running/stopped state

Success criterion:

Quit GUI while agents run → reopen → reattach without losing them.

---

### Phase 3 — Session management

Add:

- New session sheet
- Directory picker
- Agent picker
- Rename
- Reorder
- Archive
- Restore
- Stop
- Delete metadata

Success criterion:

Daily use no longer requires terminal commands for session management.

---

### Phase 4 — Polish

Only after real usage exposes friction:

- Context menu
- Better focus behavior
- Better window restoration
- Configurable font
- Configurable Ghostty theme
- Sidebar width persistence
- Confirmation for destructive stop/delete
- Search/session switcher if the list grows

---

### Phase 5 — Optional features

Only implement features that survive a real personal-use test.

Candidates:

#### Worktree helper

Optional action:

```text
New session
  ☑ Create Git worktree
```

But a session must remain capable of pointing to any directory.

Never redefine:

```text
session == worktree
```

#### Provider resume adapters

Optional interfaces:

```swift
protocol AgentResumeAdapter {
    func resumeCommand(...)
}
```

Implement only if stopped sessions become a real problem.

#### Notifications/status

Prefer provider-neutral mechanisms before parsing output.

Potential direction:

- tmux events
- terminal bell
- OSC progress sequences
- hooks that explicitly emit state

Avoid regex-parsing terminal text.

---

## 18. Ghostty upgrade strategy

Because libghostty's embedding API is still evolving, treat it as a vendored platform dependency.

### Rules

1. Pin exact revision
2. Upgrade manually
3. Read upstream changes before bumping
4. Build a small smoke-test matrix
5. Keep all adaptation inside `Terminal/GhosttyBridge`
6. Never upgrade Ghostty simultaneously with unrelated app changes

### Smoke tests

For every Ghostty bump:

- [ ] Plain shell
- [ ] tmux attach/detach
- [ ] Claude Code
- [ ] Codex
- [ ] OpenCode
- [ ] Vim/Neovim
- [ ] `htop`
- [ ] Unicode
- [ ] Emoji
- [ ] Mouse selection
- [ ] Clipboard
- [ ] IME
- [ ] Terminal resize
- [ ] Full-screen alternate screen
- [ ] Rapid `⌘1` / `⌘2` switching
- [ ] Mac sleep/wake
- [ ] GUI quit/relaunch while tmux remains alive

---

## 19. Performance rules

The app should be architected so there is almost nothing to optimize.

### Principles

- Ghostty renders terminal content
- tmux owns terminal processes
- SwiftUI renders only ordinary UI
- Hidden terminal hosts may remain alive for a small number of active sessions
- Avoid polling

### Avoid

- Repeated process enumeration
- Parsing terminal scrollback
- Rebuilding terminal surfaces when switching
- Timer-driven status checks faster than needed
- Provider API polling
- Large observable object graphs
- Cross-process JSON RPC daemons

For running-state reconciliation, a lightweight tmux query when:

- app becomes active
- session list changes
- user requests refresh

should be enough initially.

---

## 20. Failure model

Design for boring recovery.

### GUI crashes

tmux survives.

Reopen and attach.

### Agent crashes

Show session as running if tmux remains alive.

The terminal tells the user what happened.

Do not interpret agent failure.

### tmux session disappears

Mark session stopped.

Metadata remains.

### JSON corruption

Keep a previous atomic backup if desired:

```text
sessions.json
sessions.json.prev
```

### Ghostty failure

Terminal host should fail independently without corrupting session metadata.

### Agent executable missing

Show a clear launch error with:

- requested command
- resolved PATH
- working directory

Do not create provider-specific installation flows.

---

## 21. Testing strategy

Keep tests concentrated around code that can actually regress.

### Unit tests

- Session encode/decode
- Persistence migration
- tmux name generation
- tmux command generation
- Session ordering/archive logic
- PATH/executable resolution

### Integration tests

- Create tmux session
- Detect tmux session
- Stop tmux session
- Reattach
- GUI relaunch

### Manual terminal smoke tests

Required for Ghostty interaction.

Do not attempt to automate every TUI behavior.

---

## 22. Maintenance constraints

Use these as architectural guardrails.

### Maximum complexity budget

Before adding a dependency ask:

> Can this reasonably be implemented in less code than the dependency integration will require over the next two years?

Before adding a feature ask:

> Does this improve switching/managing terminal agent sessions?

If no, reject it.

### Desired codebase

Target:

```text
~2k–5k lines of application Swift
```

excluding vendored/generated Ghostty code.

Not a hard metric, but a useful smell detector.

### Desired conceptual model

A new contributor should be able to understand the app in one sentence:

> It stores a list of terminal sessions and attaches Ghostty views to tmux sessions.

If that stops being true, reconsider the architecture.

---

## 23. Non-goals / anti-roadmap

Do not become:

- Cursor
- Warp
- Conductor
- Superset
- an IDE
- an agent runtime
- an MCP manager
- a Git client
- a project-management system
- a cloud service

A useful feature is not automatically a feature this app should contain.

The value is the absence of everything else.

---

## 24. First development milestone

The first milestone should have **no sidebar at all**.

Build only:

```text
macOS Window
    ↓
libghostty terminal
    ↓
PTY
    ↓
tmux
    ↓
claude
```

Then repeat with:

```text
codex
opencode
```

If those three feel indistinguishable from running them in Ghostty itself, the hardest technical question is answered.

Only then build the session UI.

---

## 25. Definition of success

The project succeeds when this workflow is boring:

1. Open app
2. Press `⌘1`
3. Claude session is instantly there
4. Press `⌘2`
5. Codex session is instantly there
6. Press `⌘3`
7. Z.ai/OpenCode session is instantly there
8. Archive something
9. Quit the GUI
10. Agents continue running
11. Reopen the GUI
12. Everything reconnects
13. The app itself requires almost no thought

That is the product.
