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
English), measured from the moment this app observed the state change.
The scanner waits 2 seconds **after** each completed scan; this is not a fixed
2-second deadline. Established panes update on the next observation, with up to
one extra confirming observation for Working→Idle. New panes retain the existing
startup grace: the first two observations display idle. Apart from the
double-click jump's `select-window` +
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

The shared test scheme sets `TAW_DISABLE_SCANNING=1`: the hosted unit-test app
does not scan the user's tmux server. Transport unit tests use synthetic results.
The real tmux integration test is opt-in because it creates a temporary server;
obtain permission before running it:

```sh
TEST_RUNNER_TAW_RUN_ISOLATED_TMUX_TESTS=1 xcodebuild \
  -project TmuxAgentWatch.xcodeproj -scheme TmuxAgentWatch \
  -destination 'platform=macOS' test -only-testing:TmuxAgentWatchTests
```

This uses a unique socket under `/tmp`, an empty tmux configuration, and synthetic
pane content. It cleans up its own server on success and failure; fixture panes
also expire after 30 seconds if the test host is interrupted. It never targets
the user's socket. `TEST_RUNNER_` is required for forwarding the opt-in variable
through xcodebuild; a build setting of the same name does not enable the test.
The existing UI jump test still depends on real agent panes and is not part of
these commands; running it requires separate permission for live tmux access.

### Install Release in Applications

Added on **2026-09-21 (Asia/Shanghai)** to install the optimized build without
running it under Xcode's debugger:

```sh
./scripts/install-release.sh
open "/Applications/Tmux Agent Watch.app"
```

Run the script as your normal user, from any working directory. First quit all
copies of Tmux Agent Watch, including the Xcode run; the script refuses to install
while one is running. It does not stop processes, launch the app, or access tmux.
The `open` command above is a separate, optional step after successful installation.

The script builds Release in
`~/Library/Developer/Xcode/DerivedData/TmuxAgentWatch-ReleaseInstaller`, preserves
the project's automatic signing settings, and verifies the built and staged
bundles before replacing `/Applications/Tmux Agent Watch.app`. It honors
`DEVELOPER_DIR`, otherwise uses the selected full Xcode or falls back to
`/Applications/Xcode.app/Contents/Developer` without changing `xcode-select`.
A usable signing identity for the project's team must already be configured;
this is a local installation, not a notarized distribution workflow.

Replacing an existing installation requires confirmation. Only installation
commands request sudo when `/Applications` is not writable. The previous app is
retained as `previous.app` inside a unique hidden
`/Applications/.TmuxAgentWatch-install.*` directory, whose exact path is printed.
If placement fails after moving the old app aside, the script attempts to restore
it. Keep the backup until the new app works, then optionally remove that printed
directory to reclaim space; elevated installs may require sudo for backup access.
Backups are retained on each replacement, not automatically pruned. App settings
are not deleted; macOS may ask you to reauthorize Accessibility after a signing
change.

Script validation: Bash syntax, ShellCheck, help/argument handling, and the
missing-Xcode preflight are checked without installing or launching the app.
Actual replacement and rollback have not been exercised against `/Applications`.

### Build warning cleanup

On **2026-09-10 (Asia/Shanghai)**, the Pi blocker rule ID was moved into
`Scanner` as a private static constant so it shares the scanner's
`nonisolated` context rather than inheriting the project's default
`MainActor` isolation. `Info.plist` was also excluded from synchronized
folder target membership: `INFOPLIST_FILE` still supplies the processed
bundle metadata, without copying the source plist as an ordinary resource.
Neither change alters detection behavior or requires a settings migration.

Validation: the documented unit-test command passed (126 tests, 243 runs
including parameterized cases, no failures), and a fresh Release build
succeeded. The actor-isolation and resource-copy warnings are resolved.
The harmless AppIntents metadata-extraction warning remains intentionally:
the app does not use AppIntents, so no unused framework dependency was added.

## How it works

The pipeline is a faithful port of the Rust implementation (see its README
for the full design rationale):

1. **Process identification** (`Detect/ProcessInspector.swift`,
   `Detect/AgentIdentifier.swift`) — from each pane's `#{pane_pid}`, the
   foreground process group of the pane's terminal is resolved via
   `proc_pidinfo`/`proc_listpids`, unwrapping runtime wrappers (`node`,
   `python`, shells) and nested-PTY wrapper shells to find the agent process.
2. **Native Pi observations** (`Detect/PiAskUser.swift`,
   `Detect/PiPermissions.swift`, `Detect/PiWorking.swift`) — the active
   `ask_user` or Jev permissions approval UI takes precedence as **blocked**;
   otherwise a built-in spinner in the current editor border or the standalone
   compaction loader immediately above it means **working**. Pi falls back to
   **idle**, never to the legacy full-screen literal rule.
3. **Screen detection** (`Detect/DetectionEngine.swift`) — for other agent panes,
   `capture-pane -p` plus `#{pane_title}` are
   matched against per-agent rule manifests (regions, AND/OR/NOT gates,
   priority winner selection) bundled as `Resources/manifests.json`.
4. **Debounce** (`Detect/StateStore.swift`) — Working→Idle needs two
   consecutive confirming polls unless the screen shows explicit idle
   chrome; new panes display idle for their first two observations; agent-owned
   viewer screens keep the previous state. After startup grace, transitions
   into/out of Blocked are never delayed.

One deliberate addition over the TUI: the tmux subprocess environment is
forced to a UTF-8 `LC_CTYPE` when the app inherits none (GUI apps launch
without one), because tmux otherwise sanitizes tabs and non-ASCII format
output to `_`, breaking field parsing and pane titles
(`TmuxClient.swift`).

### Bounded batch polling

Changed on **2026-09-21 (Asia/Shanghai)** after profiling showed substantial CPU
charged to short-lived tmux children rather than the app's main process. The
scanner formerly launched one discovery command plus one capture per agent pane.
For N distinct agent panes, the normal path now launches
`1 + ceil(N / 32)` children per scan (one child when N is zero). Only capture
startup is amortized: tmux still reads every requested visible screen, and process
identification still runs each scan. No detection rules or settings are migrated.

- `TmuxClient.swift` batches `capture-pane -p` commands using **short-lived**
  `tmux -N -C` invocations. It never runs `attach-session`, creates a session,
  changes pane size/focus, or installs hooks. Unlike a resident attached control
  client, it preserves detached-session lifecycle semantics. The protocol's
  `%begin`/`%end`/`%error` blocks are parsed in `ControlModeOutput.swift`; see the
  [tmux control-mode documentation](https://github.com/tmux/tmux/wiki/Control-Mode).
- A missing pane aborts tmux's remaining command sequence. Completed results
  are retained; only the unexecuted suffix is retried. Retries must consume a
  target, so even a batch of vanished panes cannot loop forever. Vanished panes
  retain the old drop-for-this-cycle behavior. Malformed/unsupported framing
  switches that scanner instance to individual captures and logs one content-free
  warning. This compatibility path costs the original per-pane startup overhead;
  remove it only after establishing and testing a supported tmux baseline.
- `SubprocessRunner.swift` drains both pipes concurrently with nonblocking read
  sources. Each direct child has a 5-second deadline and an 8 MiB combined stdout/
  stderr limit. Cancellation, timeout, or overflow terminates the child, escalates
  to SIGKILL after 250 ms if necessary, and waits for reaping. The runner owns only
  its direct child, not arbitrary descendant processes. Execution failures surface
  as a scan error, not a fabricated idle screen; they do not trigger batch fallback.
- `WatchModel.swift` cancels an in-flight scan when stopped, waits for its cleanup
  before restarting, and rejects old-generation results. Equal snapshots are not
  republished. `ContentView.swift` limits one-second clock updates to elapsed-time
  labels instead of rebuilding and sorting the entire list.
- `ProcessInspector.swift` derives argv and the effective process name from one
  kernel buffer read, preserving partial argv[0] handling. No cross-scan identity
  cache is used: foreground jobs, runtime titles, and reused PIDs remain fresh.

The boundaries remain small: the scanner composes process identification,
transport, detection, and the existing state store; only transport execution and
identification have injection seams for tests. User-initiated pane jumps keep
separate, infrequent commands and the existing behavior.

Validation: the opt-in unit/integration command passed (180 tests, 391 runs
including parameterized cases, no failures or skips), and the Release build
succeeded. The pre-existing AppIntents metadata-extraction warning remains.

Coverage and limitations: unit tests cover framing, bounded launch counts,
failed-target recovery, compatibility fallback, concurrent pipe draining, output
limits, cancellation/reaping, restart isolation, unchanged-snapshot publication,
and shared argument parsing. The opt-in integration test compares batch and
individual screens on a real isolated server, checks attached/detached hooks,
client count, dimensions and active panes, and exercises transport through the
scanner and debounce to a UI snapshot. Agent identification is synthetic in that
test; it does not validate a live agent UI. Real-workload Release CPU and power
comparison remains follow-up, not a measured improvement claim. Compare the app,
its short-lived children **and the tmux server** under the same workload, with
separate authorization for live pane access and power sampling; do not suspend an
Xcode-debugged app to measure it.

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

To convert a pinned revision without moving the sibling checkout's working
tree, export it first and pass the exported directory:

```sh
git -C ../herdr fetch origin
git -C ../herdr archive <commit> src/detect/manifests | tar -x -C <tmp-dir>
python3 scripts/convert-manifests.py <tmp-dir>/src/detect/manifests
```

Re-run the unit tests afterwards; they gate manifest count, agent-label
mapping, and region coverage. If a manifest starts using a region this
engine does not implement, port it in `Detect/DetectionEngine.swift`
(mirroring herdr's `src/detect/manifest.rs`) and extend
`regionIsSupported`. New agents also need a case in `Detect/Agent.swift`
and any identification quirks ported into `Detect/AgentIdentifier.swift`
from herdr's `src/detect/mod.rs`.

### Upstream sync baseline

Synced on **2026-09-20 (Asia/Shanghai)** to Herdr
[`d59d0603d53bb88c5320ea508a4fb9858b61af68`](https://github.com/ogulcancelik/herdr/commit/d59d0603d53bb88c5320ea508a4fb9858b61af68),
from `4b5e9bda`, to incorporate upstream recognition fixes:

- 24 recognized agents, 22 bundled manifests: adds Letta Code (`letta`,
  `letta-code`, the `@letta-ai/letta-code` package entrypoint). Only the
  interactive TUI counts: headless flags (`--prompt`, `--output-format`, …),
  subcommands, and positional prompts are rejected, with `--backend` skipped
  before that check. Its manifest prefers the pane title and status chrome
  over transcript spinners, and reports ambiguous screens as unknown (shown
  as idle).
- Codex `screen_working_fallback` now reads the new
  `before_current_prompt_marker` region, everything above the current composer,
  rather than the bottom three lines. It accepts dynamic activity labels,
  hidden bullets, and queued-input blocks below the status, and rejects status
  text followed by a response, interruption, or `─ Worked for … ─` marker. Weak
  blockers are also ignored when a composer sparkle (`›⠁` …) replaces the
  space after `›`.
- Grok no longer treats any non-idle title as working: the title needs a
  braille spinner, since title items are configurable. Visible spinner rows,
  `esc:cancel` / `ctrl+c:cancel` hints, and the 1.0.34 `N commands still
  running` status row outrank the idle title.
- Cline recognizes inline tool approvals and questions, the active-turn
  spinner, and the idle composer. Its `.cline` native binary and
  `node …/cline` launchers are identified; the latter uses the same script
  argument unwrapping as Qwen, which Letta also needs.
- Claude's active-turn spinner accepts `✳` (U+2733).
- Kimi is identified from `@moonshot-ai/kimi-code/dist/main.mjs`.
- Pi gained an upstream `working_border` rule. It is bundled for source parity
  but still not evaluated: it covers only the exact `Working` label, and the
  manifest keeps the full-screen `Working...` literal that the native shim
  below exists to avoid.

No settings migration is needed. The manifest engine remains version 3, and
polling, debounce, and Pi precedence are unchanged. tmux exposes no OSC 9;4
progress, so Grok and Letta `osc_progress` rules never match here; their title
and screen rules carry detection. The Codex pattern is a multiline regex that
Rust runs in linear time and ICU by backtracking; the manifest's `contains`
pre-filter runs first, and every test case exercising it (up to six screens
each) finished within 10 ms.

Not part of this sync, and still unported from before the previous baseline:
the `node_modules/mastracode/dist/cli` package path and Cursor's bundled-node
launcher. Windows-only launcher handling (`cmd`, PowerShell) is out of scope.

Validation: the documented Xcode unit-test command passed on Xcode 27.0
(macOS 26.6.2): 147 tests, 331 runs including parameterized cases, no failures.
The `d59d0603` sections of `UpstreamDetectionTests.swift` and
`AgentIdentifierTests.swift` port upstream's Codex, Grok, Cline, Kimi, and
Letta identification cases. Upstream ships no Letta or Cline screen tests, so
those screens are synthetic, written from the manifest rules, and are not
validated against live agent UIs.

#### Previous sync

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
changing the system-wide selection. At that baseline, hosted tests could briefly
run the app's normal tmux scan; the current shared scheme disables that scan as
described above. These tests do not validate live agent UI versions.

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

### Native Jev permissions approval compatibility

Added on **2026-09-20 (Asia/Shanghai)** because Pi's Jev approval dialog was
not covered by the existing `ask_user` blocker. The reference is
`ApprovalDialog` in `../pi-agent-extensions/src/jev-permissions.ts`.
`PiPermissions` recognizes the complete Allow / optional Expand or Collapse
built-in preview / Deny controls with one selected arrow, followed by the
`↑↓ navigate  enter select  esc deny` help, blank spacer, and left-aligned
bottom border. Both normal and DANGER approvals produce
`pi_permissions_waiting`; color and the tool's name do not affect detection.

The title may be offscreen; the complete options and footer must remain
visible. Word-boundary wrapping and trailing padding are supported, but
truncated controls, words split across rows, borders narrower than eight
columns, and later widgets adding left-aligned borders are not. Only the
last left-aligned border is considered, so a newer editor supersedes old
approval text. Exact imitation of the controls and border remains ambiguous:
this is a screen heuristic, not a runtime permission signal.

`ask_user` retains first priority, followed by Jev approval, then Pi activity
and idle fallback. Automatic checks and denial notifications alone are not
blockers. Polling, startup grace, and debounce are unchanged; no settings
migration or extension changes are needed. The non-TUI selector is not
covered. Keep this rule outside generated manifests and recheck it when
`ApprovalDialog` changes; replace it only when upstream detection covers the
same active and negative cases.

Validation: the documented Xcode unit-test command passed on Xcode 27.0 /
macOS 26.6.2: 160 tests, 365 runs including parameterized cases, no failures.
`PiPermissionsTests.swift` adds 34 synthetic-screen runs covering selections,
preview toggles, wrapping, false positives, precedence, and transitions.
No live Jev approval UI was validated. The existing AppIntents metadata
warning remains.

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
