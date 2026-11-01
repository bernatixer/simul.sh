#!/bin/bash
# Compiles the app and produces Build/Simul.app.
# Uses swiftc + the CommandLineTools SDK — no xcodeproj, no Xcode.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_OUT="$HERE/Vendor/Ghostty/zig-out"
BRIDGE_INCLUDE="$HERE/Terminal/GhosttyBridge/include"
APP="$HERE/Build/Simul.app"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
TS="$HERE/Vendor/tree-sitter"
TS_OBJ="$HERE/Build/tree-sitter"
CONTENTS="$APP/Contents"

if [ ! -f "$GHOSTTY_OUT/lib/libghostty.a" ]; then
  echo "error: libghostty.a missing — run scripts/build-ghostty.sh first" >&2
  exit 1
fi

# Prepare the Swift<->C bridge header + module map.
mkdir -p "$BRIDGE_INCLUDE"
cp "$GHOSTTY_OUT/include/ghostty.h" "$BRIDGE_INCLUDE/ghostty.h"
cat > "$BRIDGE_INCLUDE/module.modulemap" <<'EOF'
module Ghostty {
    umbrella header "ghostty.h"
    export *
}
EOF

# tree-sitter core + grammars (scripts/fetch-tree-sitter.sh). Each grammar
# gets only its own src dir on -I: their tree_sitter/*.h differ by ABI.
rm -rf "$TS_OBJ"
mkdir -p "$TS_OBJ"
ts_cc() { # ts_cc <object name> <source> [clang flags...]
  local out="$TS_OBJ/$1.o" src="$2"
  shift 2
  clang -O2 -c -w -target arm64-apple-macos14.0 -isysroot "$SDK" "$@" "$src" -o "$out"
  TS_OBJECTS+=("$out")
}
TS_OBJECTS=()
ts_cc core "$TS/core/lib/src/lib.c" -I "$TS/core/lib/src" -I "$TS/core/lib/include" \
  -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE
for grammar in python javascript typescript/typescript typescript/tsx; do
  dir="$TS/$grammar/src"
  for file in parser scanner; do
    ts_cc "${grammar//\//-}-$file" "$dir/$file.c" -I "$dir"
  done
done

# App bundle skeleton.
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$HERE/Support/Info.plist" "$CONTENTS/Info.plist"

# Version: SIMUL_VERSION (set by release.sh), else the latest vX.Y.Z tag,
# else what Info.plist says. Build number: commit count, always increasing.
VERSION="${SIMUL_VERSION:-$(git -C "$HERE" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
PLIST=/usr/libexec/PlistBuddy
[ -n "$VERSION" ] && "$PLIST" -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :CFBundleVersion $(git -C "$HERE" rev-list --count HEAD)" "$CONTENTS/Info.plist"

# Simul's and Ghostty's licenses ship with every build (Ghostty's MIT
# license requires it).
cp "$HERE/LICENSE" "$CONTENTS/Resources/LICENSE"
cp "$HERE/Vendor/Ghostty/LICENSE" "$CONTENTS/Resources/LICENSE-Ghostty"
mkdir -p "$CONTENTS/Resources/licenses"
for name in core python javascript typescript; do
  cp "$TS/$name/LICENSE" "$CONTENTS/Resources/licenses/tree-sitter-$name"
done
cp "$TS/core/lib/src/unicode/LICENSE" "$CONTENTS/Resources/licenses/tree-sitter-core-icu"

# Highlight queries (TypeScript's build on JavaScript's; tsx uses TypeScript's).
for lang in python javascript typescript; do
  mkdir -p "$CONTENTS/Resources/tree-sitter-queries/$lang"
  cp "$TS/$lang"/queries/*.scm "$CONTENTS/Resources/tree-sitter-queries/$lang/"
done

# Ghostty resources (terminfo, shell-integration, themes).
# Layout matches zig-out: share/ghostty + share/terminfo (sibling).
if [ -d "$GHOSTTY_OUT/share/ghostty" ]; then
  mkdir -p "$CONTENTS/Resources/share"
  cp -R "$GHOSTTY_OUT/share/ghostty" "$CONTENTS/Resources/share/ghostty"
  if [ -d "$GHOSTTY_OUT/share/terminfo" ]; then
    cp -R "$GHOSTTY_OUT/share/terminfo" "$CONTENTS/Resources/share/terminfo"
  fi
fi

# App icon (regenerate with scripts/make-icon.sh).
cp "$HERE/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Provider icons.
if [ -d "$HERE/Resources/icons" ]; then
  cp -R "$HERE/Resources/icons" "$CONTENTS/Resources/icons"
fi

SOURCES=(
  App/SimulApp.swift
  App/AppCommands.swift
  App/DevHooks.swift
  App/SmokeMode.swift
  Models/Session.swift
  Models/AgentDefinition.swift
  Models/Workflow.swift
  Models/WorkflowRun.swift
  Models/WorkflowRun+Codable.swift
  Models/WorkflowTemplates.swift
  Models/WorkflowReports.swift
  Models/FindingLedger.swift
  State/AppModel.swift
  State/Notifier.swift
  State/ReviewCenter.swift
  State/ReviewCenter+Sources.swift
  State/ReviewCenter+Drafts.swift
  State/ReviewInsights.swift
  State/WorkflowEngine.swift
  State/WorkflowEngine+Stages.swift
  State/AppModel+Workflows.swift
  Models/ReviewDiff.swift
  Models/ReviewAnalysis.swift
  Models/SymbolDiff.swift
  Models/DiffRows.swift
  Models/WordDiff.swift
  Models/Review.swift
  Models/GitHubReview.swift
  Models/ReviewSource.swift
  Models/AgentDrafts.swift
  Models/AgentOverview.swift
  Models/ChangeMapLayout.swift
  Models/FileTree.swift
  Models/ReviewNavigation.swift
  Support/ReviewPrompt.swift
  Support/WorkflowPrompt.swift
  Support/PromptBox.swift
  Support/CodeLanguage.swift
  Support/CodeParser.swift
  Sessions/ReviewGit.swift
  Sessions/ReviewSources.swift
  Persistence/ReviewStore.swift
  Persistence/SessionStore.swift
  Persistence/RunStore.swift
  Sessions/SessionBackend.swift
  Sessions/ExecutableResolver.swift
  Sessions/TmuxSessionBackend.swift
  Sessions/DirectSessionBackend.swift
  Sessions/AgentConversations.swift
  Sessions/UsageRefresher.swift
  Sessions/WorkflowTools.swift
  Terminal/TerminalHost.swift
  Terminal/GhosttyTerminalHost.swift
  Terminal/GhosttyBridge/GhosttyInput.swift
  Terminal/GhosttyBridge/GhosttyRuntime.swift
  Terminal/GhosttyBridge/GhosttySurfaceView.swift
  UI/ContentView.swift
  UI/Sidebar/SidebarView.swift
  UI/Terminal/TerminalContainer.swift
  UI/Review/ReviewPanel.swift
  UI/Review/SourcePicker.swift
  UI/Review/DiffStatBar.swift
  UI/Review/ReviewDiffView.swift
  UI/Review/FileHeader.swift
  UI/Review/FileTreeView.swift
  UI/Review/ReviewDiffView+Jump.swift
  UI/Review/ReviewDiffRows.swift
  UI/Review/SplitDiffRow.swift
  UI/Review/DiffFoldRow.swift
  UI/Review/HunkHeaderRow.swift
  UI/Review/ReviewDiffView+Expand.swift
  UI/Review/SymbolStrip.swift
  UI/Review/NameUsesList.swift
  UI/Review/ReviewPalette.swift
  UI/Review/SubmitReviewSheet.swift
  UI/Review/OverviewPane.swift
  UI/Review/ConcernList.swift
  UI/Review/ChangeMap.swift
  UI/Review/ReviewDiffView+Keys.swift
  UI/Review/ReviewKeys.swift
  UI/Review/SuggestionDiff.swift
  UI/NewSession/NewSessionView.swift
  UI/Runs/RunParts.swift
  UI/Runs/RunDetail.swift
  UI/Runs/RunsView.swift
  UI/Runs/WorkflowEditor.swift
  UI/Components/DotMatrix.swift
  UI/Components/SimulMenu.swift
  UI/Components/SimulButtonStyle.swift
  UI/Components/Theme.swift
  UI/Settings/SettingsView.swift
  UI/MenuBar/MenuBarExtraView.swift
  Support/Logging.swift
  Support/Paths.swift
  Support/ClipboardPaste.swift
  Support/ImageTokens.swift
  Support/TerminalLinks.swift
  Support/ProviderIcon.swift
  Support/LaunchEnvironment.swift
  Support/ClickTracker.swift
  Support/RelativeAge.swift
  Support/UsageLimits.swift
  Support/Preferences.swift
)

cd "$HERE"
# The macOS 27 SDK ships @State/@Environment as SwiftUIMacros whose plugin
# is Xcode-only; the 26.5 SDK still has classic property wrappers and works
# with bare swiftc from Command Line Tools.
swiftc \
  -swift-version 6 \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -I "$BRIDGE_INCLUDE" \
  -I "$HERE/Support/TreeSitter" \
  "${SOURCES[@]}" \
  "${TS_OBJECTS[@]}" \
  -Xlinker "$GHOSTTY_OUT/lib/libghostty.a" \
  -framework AppKit \
  -framework SwiftUI \
  -framework UserNotifications \
  -framework Metal \
  -framework MetalKit \
  -framework QuartzCore \
  -framework CoreText \
  -framework CoreFoundation \
  -framework IOKit \
  -framework AudioToolbox \
  -framework Carbon \
  -lobjc -lz -lc++ \
  -o "$CONTENTS/MacOS/Simul"

# Ad-hoc signing so the bundle launches locally.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "ok: $APP"

"$HERE/scripts/smoke.sh" "$APP"
