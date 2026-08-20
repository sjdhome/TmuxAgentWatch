# TmuxAgentWatch

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
prompts on the first jump; grant TmuxAgentWatch under Privacy & Security →
Accessibility). Among multiple terminal windows, the hosting one is
identified by writing an OSC 2 set-title escape carrying a one-shot token
directly to the client's tty — only the window rendering that tty picks it
up — and the previous title is restored right after. Without the
permission, or if the terminal ignores OSC 2, the app is activated without
raising a specific window. Terminals that put several sessions in tabs of
one window get the right window, not the right tab.

The UI is localized to Simplified Chinese via a String Catalog
(`TmuxAgentWatch/Localizable.xcstrings`); durations use the system's
localized formatting in every language.

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
2. **Native blockers** (`Detect/PiAskUser.swift`) — Pi panes are checked for
   the active `ask_user` extension UI, which takes precedence as **blocked**.
3. **Screen detection** (`Detect/DetectionEngine.swift`) — for agent panes
   without a native blocker, `capture-pane -p` plus `#{pane_title}` are
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
[herdr](https://github.com/ogulcancelik/herdr) (Apache-2.0; see NOTICE):

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
