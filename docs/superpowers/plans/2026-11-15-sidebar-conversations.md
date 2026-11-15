# Sidebar conversations implementation plan

**Status:** The user preferred the original flat sidebar with its launch-folder
line. Project headings, activity subtitles and project lookup were removed.
Automatic naming remains in State/AppModel+Naming.swift, with tests in
Tests/SessionNameTests.swift. The implementation history below is superseded
for layout and project metadata.

Restoration verification: 234/234 remaining tests pass. The native build and
idle smoke pass (0.0% CPU), and the restored preview is open. Removed the
project model, background Git lookup and heading-aware drag offsets; retained
the existing folder ordering and drag behaviour.

**Goal:** Keep the current roomy rows while making conversations identifiable by
their work and activity, with project context above them and paths on demand.

**Design:** The user accepted useful names for unnamed sessions, project context,
details on demand and stable order. They explicitly rejected compact rows.
Keep the 36-point icon space, 20-point logo, 10-point vertical padding and the
existing manual folder and drag behaviour. Project headings label consecutive
groups in the saved order; they never sort or move sessions.

**Architecture:** Session owns title provenance. Legacy names default to user
provided. A first prompt names a placeholder once; a provider title may replace
that fallback, and a manual name always wins. Project resolution runs off-main
and publishes a cached batch. Linked Git worktrees share the main repository's
identity. The sidebar only reads metadata and live model state.

**Tech stack:** Swift 6, Foundation, SwiftUI/AppKit and the installed Git CLI.
No model requests, dependencies, settings changes, commits or installation.

## Invariants

- A supplied or manually renamed title is never replaced automatically.
- Metadata callbacks cannot change another conversation or a closed generation.
- Project lookup performs no I/O in a view body and never changes saved order.
- Existing custom folders remain whole, including ones spanning projects.
- Activity updates keep row height, identity, selection and position stable.

## Tasks

- [x] Add failing model tests for title precedence, bounded prompt names and
  conservative legacy decoding. Add project tests with real Git worktrees and
  sidebar grouping tests that preserve order and manual folders.
- [x] Implement title provenance in Models/Session.swift. Add
  Models/SessionSidebar.swift for cached project values and sidebar items, and
  Sessions/SessionProjects.swift for read-only project resolution.
- [x] Carry provider titles through ChatAgentEvent and ChatState. Test Codex's
  thread name notification and Claude's ai-title/custom-title records. Update
  unnamed sessions from accepted/imported prompts and provider titles.
- [x] Add State/AppModel+Sidebar.swift for project refresh and naming. Update
  setup, rename and launch hooks; include new files in both build surfaces.
- [x] Add project headings and activity subtitles without shrinking rows.
  Include heading height in drag offsets. Expose working folder and branch in
  tooltips, with Copy Folder Path and Show in Finder in the session menu.
- [x] Update the sidebar setting label, FEATURES.md, DESIGN.md and CHANGELOG.md.
  Run the full logic suite, native viewport checks, native build and idle smoke.
  Check named/unnamed sessions, project/worktree context and stable reading in
  the isolated preview.

## Verification

- 237/237 model/protocol tests pass, including real Git linked worktrees,
  legacy title provenance, provider title events and active-folder transitions.
- 15 native viewport/input checks pass.
- The extended native AppModel sidebar check passes naming, six activity states,
  stable order and wake/archive/unarchive without cycling focus.
- Independent source review found a project-refresh gap on wake/unarchive.
  Active-folder invalidation now belongs to AppModel.sessions, and a stale batch
  is cancelled before returning with no pending lookup. Review cleared the fix.
- The final native build and idle smoke pass (0.0% CPU). The separate preview
  is open on the verified binary. No commit, release or installation was made.
