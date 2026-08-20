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
Rows are selectable; selection carries no behavior yet.

The UI is localized to Simplified Chinese via a String Catalog
(`TmuxAgentWatch/Localizable.xcstrings`); durations use the system's
localized formatting in every language.

Next to the state, each row shows how long the pane has been in it,
rendered with the system's localized duration formatting (`45s`, `1h 5m` in
English), measured from the moment this app observed the state change. State changes appear within ~5 seconds (2s polling plus up to
one debounce cycle). The app never sends control commands to tmux — it only
runs `list-panes` and `capture-pane` — and never touches your agents'
configs.

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

## Refreshing detection manifests

The manifests are converted from the sibling `tmux-agent-watch` repository
(vendored there verbatim from [herdr](https://github.com/ogulcancelik/herdr),
Apache-2.0; see NOTICE):

```sh
python3 scripts/convert-manifests.py            # from ../tmux-agent-watch
python3 scripts/convert-manifests.py <src-dir>  # custom manifest dir
```

Re-run the unit tests afterwards; they gate manifest count, agent-label
mapping, and region coverage.

## Rejected features

Inherited from the TUI's scope:

- **Jump-to-pane / any tmux control** — this app stays strictly read-only.
- **Hook-based state reporting** — requires installing hook scripts into
  each agent's config; out of scope.
