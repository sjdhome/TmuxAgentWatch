# Tmux Agent Watch

A native macOS app that watches your existing tmux server and shows every
pane running an AI coding agent (Claude Code, Codex, Gemini CLI, pi, and ~20
others) as a flat list — one row per agent process, carrying its tmux
location (session › window — pane title) — with a traffic-light state
indicator:

- 🔴 **blocked**: the agent is waiting for human input (permission prompt,
  question)
- 🟢 **working**: the agent is actively doing something
- ⚪ **idle**: finished, prompt visible

This is a Swift/SwiftUI port of the
[tmux-agent-watch](../tmux-agent-watch) TUI with the same functionality,
styled to follow the
[macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines):
system semantic colors (automatic Dark Mode), a standard selectable list
with alternating row backgrounds, `ContentUnavailableView` empty states, and
a window subtitle carrying the blocked/working/idle counts.

The toolbar's sort menu offers two orders (`PaneSorting.swift`): by state —
blocked, then idle, then working, ties broken by longer time in the current
state, then by name — or by name alone; the choice persists across launches.

**Double-clicking a row — or pressing Return on the selection — jumps to
the pane** (`PaneJump.swift`; also in the row's context menu as "Show in
Terminal"): if a tmux client attached to the
pane's session is hosted by a GUI terminal on this machine (Ghostty, Kitty,
Terminal.app, iTerm2, … — found by walking the client process's ancestry to
the nearest Dock-visible app, so SSH or headless clients never match), the
session is switched to the pane's window and the pane is made active
(`select-window` + `select-pane`), and the exact terminal window hosting
that client is raised and focused. When no GUI client is attached, the
double-click just beeps.

Window-precise focus needs the **Accessibility permission** (the system
prompts on the first jump; grant Tmux Agent Watch under Privacy & Security →
Accessibility). Among multiple terminal windows, the hosting one is
identified by writing an OSC 2 set-title escape carrying a one-shot token
directly to the client's tty — only the window rendering that tty picks it
up — and the previous title is restored right after. Without the
permission, or if the terminal ignores OSC 2, the app is activated without
raising a specific window. Terminals that put several sessions in tabs of
one window get the right window, not the right tab.

The UI is localized to Simplified Chinese via String Catalogs
(`TmuxAgentWatch/Localizable.xcstrings`, plus
`TmuxAgentWatch/InfoPlist.xcstrings` for the app's display name — "Tmux
Agent Watch" / "Tmux Agent 监视器"); durations use the system's localized
formatting in every language.

Next to the state, each row shows how long the pane has been in it,
rendered with the system's localized duration formatting (`45s`, `1h 5m` in
English), measured from the moment this app observed the state change. State changes appear within ~5 seconds (2s polling plus up to
one debounce cycle). Apart from the double-click jump's `select-window` +
`select-pane`, the app only reads from tmux (`list-panes`, `capture-pane`,
`list-clients`) — it never writes to panes, sends input to agents, or
touches their configs.

## Requirements

- macOS with Xcode 26+
- tmux (looked up in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then
  `PATH`)

## Build and run

Open `TmuxAgentWatch.xcodeproj` in Xcode and run, or:

```sh
xcodebuild -project TmuxAgentWatch.xcodeproj -scheme TmuxAgentWatch build
xcodebuild -project TmuxAgentWatch.xcodeproj -scheme TmuxAgentWatch \
  -destination 'platform=macOS' test -only-testing:TmuxAgentWatchTests
```

The app target has App Sandbox **disabled**: it must spawn the `tmux` binary
and inspect other processes of the same user via `libproc`, neither of which
a sandboxed app can do.

## How it works

The pipeline is a faithful port of the Rust implementation (see its README
for the full design rationale):

1. **Process identification** (`Detect/ProcessInspector.swift`,
   `Detect/AgentIdentifier.swift`) — from each pane's `#{pane_pid}`, the
   foreground process group of the pane's terminal is resolved via
   `proc_pidinfo`/`proc_listpids`, unwrapping runtime wrappers (`node`,
   `python`, shells) and nested-PTY wrapper shells to find the agent process.
2. **Native Pi observations** (`Detect/PiAskUser.swift`, `Detect/PiWorking.swift`)
   — the active `ask_user` extension UI takes precedence as **blocked**;
   otherwise a built-in spinner in the current editor border or the standalone
   compaction loader immediately above it means **working**. Pi falls back to
   **idle**, never to the legacy full-screen literal rule.
3. **Screen detection** (`Detect/DetectionEngine.swift`) — for other agent panes,
   `capture-pane -p` plus `#{pane_title}` are
   matched against per-agent rule manifests (regions, AND/OR/NOT gates,
   priority winner selection) bundled as `Resources/manifests.json`.
4. **Debounce** (`Detect/StateStore.swift`) — Working→Idle needs two
   consecutive confirming polls unless the screen shows explicit idle
   chrome; new panes get one cycle of startup grace; agent-owned viewer
   screens keep the previous state. Transitions into/out of Blocked are
   never delayed.

One deliberate addition over the TUI: the tmux subprocess environment is
forced to a UTF-8 `LC_CTYPE` when the app inherits none (GUI apps launch
without one), because tmux otherwise sanitizes tabs and non-ASCII format
output to `_`, breaking field parsing and pane titles
(`TmuxClient.swift`).

## Regenerating the app icon

The icon (a tmux split-pane terminal with the app's three state dots and
the green status bar) is drawn programmatically; to re-render all sizes
into the asset catalog after tweaking `scripts/generate-app-icon.swift`:

```sh
xcrun swift scripts/generate-app-icon.swift   # from the project root
```

Sizes at or below 64 px use a simplified composition (dots and status bar
only) so the icon still reads at Dock-menu sizes.

## Refreshing detection manifests

The manifests are converted straight from a sibling checkout of
[herdr](https://github.com/ogulcancelik/herdr) (Apache-2.0; see NOTICE).
Use `src/detect/manifests`, the built-in rules paired with the source engine;
`distribution/agent-detection` is a separate publication set and may lag behind.
Verify the checkout revision before regenerating; conversion does not fetch upstream:

```sh
python3 scripts/convert-manifests.py            # reads ../herdr/src/detect/manifests
python3 scripts/convert-manifests.py <src-dir>  # custom manifest dir
```

Re-run the unit tests afterwards; they gate manifest count, agent-label
mapping, and region coverage. If a manifest starts using a region this
engine does not implement, port it in `Detect/DetectionEngine.swift`
(mirroring herdr's `src/detect/manifest.rs`) and extend
`regionIsSupported`. New agents also need a case in `Detect/Agent.swift`
and any identification quirks ported into `Detect/AgentIdentifier.swift`
from herdr's `src/detect/mod.rs`.

### Upstream sync baseline

Synced on **2026-09-07 (Asia/Shanghai)** to Herdr
[`4b5e9bda239a0b6903889062d756424578e94691`](https://github.com/ogulcancelik/herdr/commit/4b5e9bda239a0b6903889062d756424578e94691),
from `6e8b138d`, to incorporate upstream recognition fixes:

- 23 recognized agents, 21 bundled manifests: adds Muse aliases and versioned
  launchers, live state/approval controls, and state-preserving menu overlays.
- Agent labels accept path-qualified executables. Pi recognizes both
  `dist/cli.js` and `dist/bundle/cli.js` under its package, rejecting similarly
  named non-entrypoint files and nested paths.
- Claude recognizes MCP elicitation and Bash approvals at every cursor position.
  A background shell alone no longer implies working; live foreground work,
  background agents, and background MCP tasks still do.
- Codex recognizes the startup update chooser. Weak blocker phrases are ignored
  while a current composer is visible, including wrapped prompt text and quoted
  transcript text. The `whole_recent_without_current_prompt_marker` region
  returns **empty content**, not just content minus the prompt line; a subsequent
  response block makes that prompt historical and restores whole-screen matching.
- Copilot recognizes its waiting-for-background-agents status line.

No settings migration is needed. The manifest engine remains version 3;
macOS process inspection, the 2-second polling/debounce policy, and the local
Pi `ask_user` blocker precedence are unchanged. Only the newly referenced
Codex region was added; the region coverage test remains the gate for future
manifest changes, not a claim that every unused upstream region is implemented.

Validation: the documented Xcode unit-test command passed on Xcode 26.6
(macOS 26.6.2): 102 tests, 155 runs including parameterized cases, no failures.
`UpstreamDetectionTests.swift` covers new screen behavior and negative cases;
`AgentIdentifierTests.swift` covers launcher paths and false positives.
Existing actor-isolation and Info.plist build warnings remain outside this sync.
If `xcode-select` points at Command Line Tools, prefix the build/test commands
with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` rather than
changing the system-wide selection. Hosted unit tests may briefly run the
app's normal read-only tmux scan; they do not validate live agent UI versions.

### Native Pi editor-status compatibility

Added on **2026-09-09 (Asia/Shanghai)** after a live pane showed
`── ⠧ Working ──…`, which the unchanged Herdr Pi rule (`Working...`) misses.
The reference is Pi
[`6160683a`](https://github.com/earendil-works/pi/commit/6160683a4a8012f0d1cd30c145df18b4ca6f5176):
`packages/coding-agent/src/modes/interactive/components/custom-editor.ts`,
`status-indicator.ts` in the same directory, and
`packages/tui/src/components/loader.ts`.

`PiWorking` recognizes the default spinner frames in the last pair of
left-aligned editor-like borders, with an input row between them. It supports
truncated labels, narrow spinner-only borders, and full scroll-count labels.
Compaction, branch summaries, and retries share this active-status structure
and also count as working. Matching is not limited to the bottom few lines:
below-editor task widgets may be tall. Plain `Working` text, indented quotes,
and historical status above a newer idle editor do not trigger this addition.
Pi support is explicitly limited to structural status evidence: the initial
legacy fallback also matched `Working...` in ordinary transcript, draft, and
widget text. Pi returns idle when neither its native blocker nor a supported
active status is visible. Its bundled Herdr manifest is retained unchanged
for source parity but is **not evaluated by the scanner**. Old standalone
`Working...` rows remain unsupported. `ask_user` still wins, and the polling
and debounce policies are unchanged. No settings migration is needed.

A screenshot-reported standalone compaction layout was added on the same date
as a narrow exception, not a return to full-screen text matching. The last
non-empty line before the current plain editor must be exactly a default
spinner followed by `Compacting context... (esc to cancel)` or the `escape`
variant, with the loader's one-space left padding. Only blank rows may separate
it from the editor. The result is `pi_compaction_status`; border-embedded
activity remains `pi_status_border`. The remote Codex notification alone does
not count as activity. Wrapped/truncated loaders or widgets inserted between
the loader and editor are not covered.

This is a screen heuristic, not Pi runtime integration: arbitrary custom
spinner frames/editors, one-column panes, truncated bottom scroll labels,
and widgets adding their own left-aligned borders below the editor are not
covered. An exact imitation of editor chrome in output can still be ambiguous.
Keep the shim outside generated manifests so regeneration cannot erase it;
recheck it when Pi changes the referenced renderers. Re-enable upstream Pi
rules and remove the shim only when they cover the active-status and negative
transcript/draft/widget cases through this engine; do not restore the old
full-screen literal fallback.

Validation: the new tests reproduced the idle fallback before the fix; the
standard Xcode unit-test command then passed on Xcode 26.6/macOS 26.6.2:
126 tests, 243 runs including parameterized cases, no failures.
`PiWorkingTests.swift` and `PiCompactionTests.swift` use synthetic chrome only
and cover all default spinner frames, narrow/scrolling layouts, tall widgets,
standalone compaction with both cancel hints, rejection of transcript/draft/
widget text and legacy literals, blocker precedence, and return-to-idle
behavior. Existing actor-isolation, Info.plist, and AppIntents metadata
warnings remain unchanged.

## Rejected features

Inherited from the TUI's scope:

- **Hook-based state reporting** — requires installing hook scripts into
  each agent's config; out of scope.
- **Sending input to agents / pane content control** — the double-click
  jump's `select-window` + `select-pane` is the only tmux write verb;
  nothing else may mutate tmux state.
- **Selecting the exact terminal *tab*** — the jump raises the hosting
  window via Accessibility; picking a tab inside it would need per-terminal
  scripting APIs.
