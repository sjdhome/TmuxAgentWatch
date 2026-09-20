// Detection regressions ported from Herdr (Apache-2.0; see NOTICE). Sections
// up to Muse track 4b5e9bda; the d59d0603 sync follows.

import Foundation
import Testing

@testable import TmuxAgentWatch

private func upstreamDetection(_ agent: Agent, _ screen: String, title: String = "") -> Detection {
    Scanner.detectScreen(agent: agent, rawScreen: screen, paneTitle: title)
}

// MARK: - Codex current-prompt region

@Test(arguments: ["›", "› Ask Codex", "› Explain\n  [y/N] / esc"])
func currentCodexPromptSuppressesTheEntireWeakBlockerRegion(_ prompt: String) {
    let screen = "• The transcript shows [y/N]\n\n\(prompt)\nfooter"
    let region = "whole_recent_without_current_prompt_marker"
    #expect(regionIsSupported(region))
    #expect(
        regionText(
            input: DetectionInput(screen: screen, oscTitle: "", oscProgress: ""), spec: region)
            == "")
    let detection = upstreamDetection(.codex, screen, title: "project")
    #expect(detection.state == .idle)
    #expect(detection.ruleID == "osc_title_idle")
}

@Test(arguments: ["•", "■", "✗", "✓"])
func laterCodexResponseMakesTheEarlierPromptHistorical(_ marker: String) {
    let screen = "› previous question\n\(marker) Do you want to continue? [y/n]"
    let input = DetectionInput(screen: screen, oscTitle: "", oscProgress: "")
    #expect(regionText(input: input, spec: "whole_recent_without_current_prompt_marker") == screen)
    #expect(upstreamDetection(.codex, screen, title: "project").ruleID == "weak_blocker")
}

@Test(arguments: ["", "[y/n]", "›x\n[y/n]", " › indented\n[y/n]"])
func codexRegionKeepsContentWithoutAnExactPromptMarker(_ screen: String) {
    let input = DetectionInput(screen: screen, oscTitle: "", oscProgress: "")
    #expect(regionText(input: input, spec: "whole_recent_without_current_prompt_marker") == screen)
}

@Test func latestCodexPromptWinsAndIndentedBulletsAreNotResponseBlocks() {
    for screen in [
        "› old\n• response [y/n]\n› new",
        "› wrapped prompt\n  • quoted [y/n]",
    ] {
        let input = DetectionInput(screen: screen, oscTitle: "", oscProgress: "")
        #expect(regionText(input: input, spec: "whole_recent_without_current_prompt_marker") == "")
    }
}

@Test func codexCurrentPromptAllowsWorkingFallbackDespiteWeakBlockerText() {
    let detection = upstreamDetection(
        .codex,
        "• Working (4s • esc to interrupt)\ndo you want to continue? [y/n]\n› Use /skills",
        title: "project")
    #expect(detection.state == .working)
    #expect(detection.ruleID == "screen_working_fallback")
    #expect(detection.visible)
}

@Test func codexLiveStrongBlockerStillWinsWithAPromptMarker() {
    let detection = upstreamDetection(
        .codex,
        "• Working (4s • esc to interrupt)\n› 1. Yes, proceed\nPress enter to confirm or esc to cancel",
        title: "project")
    #expect(detection.state == .blocked)
    #expect(detection.ruleID == "live_strong_blocker")
}

@Test(arguments: [
    "Update available! 0.153.0 -> 9.8.7\n› 1. Update now\n  2. Skip until next version\nPress enter to continue   \n",
    "✨ Update available! 0.153.0\n› 1. Update now (runs `npm\n install -g\n @openai/codex`)\n  2. Skip\n  3. Skip until next\n version\nPress enter to continue\n",
])
func codexStartupUpdateRequiresCompleteLiveChooser(_ chooser: String) {
    let detection = upstreamDetection(.codex, chooser, title: "project")
    #expect(detection.state == .blocked)
    #expect(detection.ruleID == "startup_update")
    #expect(detection.visible)

    for stale in [
        chooser.replacingOccurrences(of: "Update now", with: "Install"),
        chooser + "\n› Ask Codex to do anything\n",
    ] {
        let detection = upstreamDetection(.codex, stale, title: "project")
        #expect(detection.state == .idle)
        #expect(detection.ruleID != "startup_update")
    }
}

// MARK: - Claude foreground state and blockers

@Test func claudeBackgroundShellAloneDoesNotMeanWorking() {
    let footer = "  ⏵⏵ auto mode on · 1 shell · ← for agents"
    #expect(upstreamDetection(.claude, footer) == .knownAgentIdleFallback)

    let screen = "✻ Sautéed for 10s · 1 shell still running\n\n──── WINDOWS ─\n❯\n────\n\(footer)"
    let idle = upstreamDetection(.claude, screen)
    #expect(idle.state == .idle)
    #expect(idle.ruleID == "live_prompt_box")
    #expect(idle.visible)

    let working = upstreamDetection(.claude, screen + " · esc to interrupt")
    #expect(working.state == .working)
    #expect(working.ruleID == "live_turn_working")
}

@Test(arguments: [
    ["1. Yes", "2. No"],
    ["1. Yes", "2. Yes, and don't ask again for: curl *", "3. No"],
])
func claudeBashApprovalMatchesEveryCursorPosition(_ layout: [String]) {
    for selected in layout.indices {
        let options = layout.enumerated().map { index, option in
            "\(index == selected ? " ❯ " : "   ")\(option)"
        }.joined(separator: "\n")
        let screen =
            "Bash command\n\nDo you want to proceed?\n\(options)\nEsc to cancel · Tab to amend · ctrl+e to explain\n⏵⏵ auto mode on · 1 shell · ← for agents"
        let detection = upstreamDetection(.claude, screen)
        #expect(detection.state == .blocked)
        #expect(detection.ruleID == "bash_permission_prompt", "selected=\(selected)")
        #expect(detection.visible)
    }
}

@Test(arguments: ["\"my-server\"", "“my-server”"], ["❯ Accept    Decline", "❯ Decline"])
func claudeMcpElicitationOverridesIdleTitle(_ server: String, _ controls: String) {
    let header = "MCP server \(server) requests your input"
    let footer = "Esc to cancel · ↑/↓ to navigate"
    let detection = upstreamDetection(
        .claude, "\(header)\n\nGrant temporary access?\n\n\(controls)\n\n\(footer)",
        title: "✳ Claude Code")
    #expect(detection.state == .blocked)
    #expect(detection.ruleID == "mcp_elicitation_prompt")
    #expect(detection.visible)

    for incomplete in ["\(header)\n\(controls)", "\(header)\n\(footer)", "\(controls)\n\(footer)"] {
        #expect(upstreamDetection(.claude, incomplete, title: "✳ Claude Code").state == .idle)
    }
}

// MARK: - Copilot background agents

@Test(arguments: ["◎ Waiting for background agents", "  ◎ Waiting for background agents · 2 tasks"])
func copilotWaitingForBackgroundAgentsIsWorking(_ footer: String) {
    let detection = upstreamDetection(.githubCopilot, footer)
    #expect(detection.state == .working)
    #expect(detection.ruleID == "background_agents_working")
    #expect(detection.visible)
}

@Test func copilotBackgroundAgentTextMustBeLiveStatus() {
    for screen in [
        "Quoted: ◎ Waiting for background agents",
        "◎ Waiting for background agentsXYZ",
        "◎ Waiting for background agents\n1\n2\n3\n4\n5\n6",
    ] {
        #expect(upstreamDetection(.githubCopilot, screen).ruleID != "background_agents_working")
    }
}

// MARK: - Muse live controls

@Test(arguments: [
    (
        "⟩ hello\n◆ Working (0s · esc to interrupt)\n────\n⟩\n────\ngpt-5.4 · minimal · /workspace",
        EngineState.working, "working_esc_interrupt"
    ),
    (
        "Which option?\n› 1. Alpha\n  2. Beta\nEnter to select · ↑/↓ to move · Tab for an optional note · Esc to interrupt\n────\n⟩\n────\ngpt-5.4 · minimal · /workspace",
        .blocked, "pick_request_blocked"
    ),
    ("Enter to toggle · Esc to interrupt", .blocked, "pick_request_blocked"),
    ("Do you trust this workspace?\nTrust and continue", .blocked, "workspace_trust_blocked"),
    ("Do you trust this workspace?\nUse Up/Down", .blocked, "workspace_trust_blocked"),
    (
        "› 1. Allow this stage once (y)\n  2. Always allow in this workspace: printf ... (p)\n  3. Abort the entire command (esc)",
        .blocked, "blocked_approval"
    ),
    ("Allow once\nAllow for this session", .blocked, "blocked_approval"),
    (
        "› 1. Yes, proceed (y)\n  2. Yes, don't ask again this session (p)", .blocked,
        "blocked_approval"
    ),
    ("◆ Yes, proceed\n────\n⟩\n────\ngpt-5.4 · minimal · /workspace", .idle, "idle_prompt"),
    ("gpt-5.4 · minimal · /workspace", .idle, "idle_status_fallback"),
])
func museRecognizesLiveState(_ screen: String, _ state: EngineState, _ rule: String) {
    let detection = upstreamDetection(.muse, screen)
    #expect(detection.state == state)
    #expect(detection.ruleID == rule)
    #expect(detection.visible)
}

@Test(arguments: [
    "Theme\n⟩ Default (active)\n↑↓ move · enter save · esc go back",
    "enter confirm · esc go back",
    "space toggle · esc close · type filter",
])
func museMenusKeepPreviousState(_ screen: String) {
    let detection = upstreamDetection(.muse, screen)
    #expect(detection.state == .unknown)
    #expect(detection.ruleID == "menu_overlay")
    #expect(detection.skip)
    #expect(!detection.visible)
}

@Test(arguments: [
    "Do you trust this workspace?", "Enter to select", "Allow once",
    "Allow this stage once", "Yes, proceed", "enter confirm",
])
func museSingleControlPhrasesAreNotBlockers(_ phrase: String) {
    let detection = upstreamDetection(.muse, "\(phrase)\n────\n⟩\n────")
    #expect(detection.state == .idle)
    #expect(!detection.skip)
}

// MARK: - Herdr d59d0603: Codex activity above the current composer

private let codexQueuedInputs = [
    "",
    "\n• Queued follow-up inputs\n  ↳ Follow up after this turn\n    alt + ↑ edit last queued message\n",
    "\n• Messages to be submitted after next tool call\n  (press esc to interrupt and send immediately)\n  ↳ Keep waiting until the sleep finishes.\n",
    "\n• Messages to be submitted after next\n  tool call (press esc to interrupt and\n  send immediately)\n  ↳ Keep waiting until the sleep finishes.\n",
    "\n• Messages to be submitted at end of turn\n  ↳ Follow up after this turn\n",
    "\n• Messages to be submitted after next tool call\n  (press esc to interrupt and send immediately)\n  ↳ Keep waiting.\n\n• Queued follow-up inputs\n  ↳ After this turn reply ok.\n    alt + ↑ edit last queued message\n",
]

@Test(arguments: ["", "• ", "◦ "], ["Working", "Fixing bug in queue region"])
func codexWorkingFallbackHandlesActivityLabelsAndQueuedInputs(_ prefix: String, _ label: String) {
    for queue in codexQueuedInputs {
        let screen =
            "\(prefix)\(label) (1m 16s • esc to interrupt) · 1 background terminal running · /ps to view · /stop to close\n\(queue)\n› Ask Codex to do anything\n\n  model · /work\n"
        let detection = upstreamDetection(.codex, screen, title: "project")
        #expect(detection.state == .working, "\(screen)")
        #expect(detection.ruleID == "screen_working_fallback", "\(screen)")
        #expect(detection.visible)
    }
}

@Test func codexBeforeCurrentPromptRegionStopsAtTheLiveComposer() {
    let region = "before_current_prompt_marker"
    #expect(regionIsSupported(region))
    func text(_ screen: String) -> String {
        regionText(
            input: DetectionInput(screen: screen, oscTitle: "", oscProgress: ""), spec: region)
    }
    #expect(text("status\n\n› draft\nfooter") == "status\n\n")
    #expect(text("› old\nstatus\n› new") == "› old\nstatus\n")
    #expect(text("› draft") == "")
    // No prompt, or a prompt made historical by a later response block.
    #expect(text("status only") == "status only")
    #expect(text("› old\n• response") == "› old\n• response")
}

@Test func codexWorkingFallbackUsesLatestActivityAfterInterruption() {
    let screen =
        "■ Conversation interrupted\n\n› Try again\n\nWorking (4s • esc to interrupt)\n\n› Ask Codex to do anything\n\n  model · /work\n"
    let detection = upstreamDetection(.codex, screen, title: "project")
    #expect(detection.state == .working)
    #expect(detection.visible)
}

@Test(arguments: [
    "Working (1m 16s • esc to interrupt)\n• Finished the task\n› Ask Codex to do anything\n",
    "Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n› Ask Codex to do anything\n",
    "Working (1m 16s • esc to interrupt)\n─ Worked for 1m 16s ─\n› Ask Codex to do anything\n",
    "Working (1m 16s • esc to interrupt)\n•\nMessages to be submitted after next tool call\n› Ask Codex to do anything\n",
    "› Explain this status:\n  Working (1m 16s • esc to interrupt)\n",
    "• Example (press esc to interrupt)\n› Ask Codex to do anything\n",
])
func codexStaleOrQuotedActivityIsNotWorking(_ screen: String) {
    let detection = upstreamDetection(.codex, screen, title: "project")
    #expect(detection.state == .idle, "\(screen)")
    #expect(detection.ruleID != "screen_working_fallback")
}

// MARK: - Herdr d59d0603: Codex composer sparkles

@Test(arguments: ["› ", "›⠁", "›⠂", "›⠄", "›⠈", "›⠐", "›⠠", "›⡀", "›⢀"])
func codexSparklePromptPreservesLiveStates(_ marker: String) {
    let screen = "Do you want to proceed? [y/n]\n\(marker)unsent draft\n"
    #expect(upstreamDetection(.codex, screen, title: "project | Ready").state == .idle)

    let working =
        "Do you want to proceed? [y/n]\n• Working (4s • esc to interrupt)\n\(marker)draft\n"
    #expect(upstreamDetection(.codex, working, title: "project").state == .working)

    let approval = upstreamDetection(
        .codex, screen + "Press enter to confirm or esc to cancel\n", title: "project")
    #expect(approval.state == .blocked)
    #expect(approval.visible)

    for response in ["•", "■", "✗", "✓"] {
        let detection = upstreamDetection(
            .codex, "\(screen)\(response) Do you want to proceed? [y/n]\n", title: "project")
        #expect(detection.state == .blocked, "\(marker) \(response)")
    }
}

@Test(arguments: ["›text", "›⠋draft", "›⠀draft", " ›⠁draft", "quoted ›⠁draft"])
func codexWeakBlockerDoesNotIgnoreArbitraryPromptSuffixes(_ line: String) {
    let detection = upstreamDetection(
        .codex, "Do you want to proceed? [y/n]\n\(line)\n", title: "project")
    #expect(detection.state == .blocked, "\(line)")
}

// MARK: - Herdr d59d0603: Claude unicode spinner

@Test func claudeEightSpokedAsteriskSpinnerIsWorking() {
    for status in ["✳ Pondering… (12s · ↓ 1.2k tokens)", "  ✳ Pondering…"] {
        let detection = upstreamDetection(.claude, "\(status)\n\n────\n❯\n────")
        #expect(detection.state == .working, "\(status)")
        #expect(detection.ruleID == "live_turn_working")
    }
    #expect(upstreamDetection(.claude, "✳ Pondered for 12s").ruleID != "live_turn_working")
}

// MARK: - Herdr d59d0603: Grok configurable titles and visible activity

@Test(arguments: [
    ("project · session · id", EngineState.idle, "prompt_hints_idle"),
    ("grok", .idle, "osc_title_idle"),
    ("⠋ - Waiting for response… - project", .working, "osc_title_working"),
    ("project - ⠹ - session", .working, "osc_title_working"),
    ("⚠ Action Required - project", .blocked, "osc_title_blocked"),
])
func grokTitleActivityRequiresASpinner(_ title: String, _ state: EngineState, _ rule: String) {
    let detection = upstreamDetection(.grok, "Shift+Tab:mode │ Ctrl+.:shortcuts\n", title: title)
    #expect(detection.state == state, "\(title)")
    #expect(detection.ruleID == rule, "\(title)")
}

@Test(arguments: [
    ("⠴ Sleep for 8 … 1.9s 5.0s ⇣19.5k [↓][stop]\n", "spinner_status_working"),
    ("Shift+Tab:mode │ Ctrl+c:cancel │ Ctrl+.:shortcuts\n", "esc_cancel_hints_working"),
    ("Shift+Tab:mode │ Esc:cancel │ Ctrl+.:shortcuts\n", "esc_cancel_hints_working"),
    ("◎ 1 command still running\n", "background_status_working"),
    ("○ 1 command still running\n", "background_status_working"),
    (
        "◎ 2 commands · 1 subagent still running · send a message to interrupt\n",
        "background_status_working"
    ),
])
func grokVisibleActivityOutranksTheIdleTitle(_ screen: String, _ rule: String) {
    let detection = upstreamDetection(.grok, screen, title: "grok")
    #expect(detection.state == .working, "\(screen)")
    #expect(detection.ruleID == rule)

    let blocked = upstreamDetection(.grok, screen, title: "⚠ Action Required - grok")
    #expect(blocked.state == .blocked)
}

@Test(arguments: [
    "1 command still running\n",
    "◎ 0 commands still running\n",
    "Discussed: ◎ 1 command still running\n",
    "◎ 1 command still running\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n",
    "Worked for 3.9s\nShift+Tab:mode │ Ctrl+.:shortcuts\n",
])
func grokBackgroundActivityRequiresALiveNonzeroStatusRow(_ screen: String) {
    #expect(upstreamDetection(.grok, screen, title: "project · session").state == .idle)
}

// MARK: - Herdr d59d0603: Cline inline prompts and composer

@Test(arguments: [
    (
        "Cline needs permission\nApprove tool call?\n  [y] Approve   [n] Deny",
        EngineState.blocked, "inline_tool_permission"
    ),
    (
        "Cline is asking a question\nWhich file?\n> src/main.rs\n────\n(Tab) mode · Shift+Tab auto-approve",
        .blocked, "inline_question"
    ),
    ("⠹ Reading src/main.rs\n────\n❯\n────\n(Tab) mode · Shift+Tab", .working, "active_turn"),
    ("Thinking... (esc to cancel)", .working, "active_turn"),
    ("Done.\n────\n❯ next task\n────\n(Tab) mode · Shift+Tab auto-approve", .idle, "composer_idle"),
])
func clineRecognizesInlineState(_ screen: String, _ state: EngineState, _ rule: String) {
    let detection = upstreamDetection(.cline, screen)
    #expect(detection.state == state, "\(screen)")
    #expect(detection.ruleID == rule, "\(screen)")
    #expect(detection.visible)
}

// MARK: - Herdr d59d0603: Letta Code

@Test(arguments: [
    ("Run this command?\n  ls -la\n❯ Yes\n  No\nEnter to select · Esc to cancel", "", EngineState.blocked, "command_approval"),
    ("›", "[ ! ] Action Required | agent", .blocked, "osc_title_blocked"),
    ("›", "⠹ agent | project", .working, "osc_title_working"),
    ("Memo is thinking… (esc to interrupt · 12s)\n›", "", .working, "active_status"),
    ("Memo is thinking… (interrupting)\n›", "", .working, "active_status"),
    ("● Bash(sleep 5)\n  └ Running... (3s)\n›", "", .working, "running_tool"),
    ("● Done\n\n›", "", .idle, "composer_idle"),
    ("› Try \"fix the failing test\"", "", .idle, "composer_idle"),
])
func lettaRecognizesLiveState(
    _ screen: String, _ title: String, _ state: EngineState, _ rule: String
) {
    let detection = upstreamDetection(.letta, screen, title: title)
    #expect(detection.state == state, "\(screen)")
    #expect(detection.ruleID == rule, "\(screen)")
    #expect(detection.visible)
}

@Test(arguments: [
    ("⠹ transcript spinner without status chrome", "no_live_state_evidence"),
    ("Create a new agent (--new)\nEnter select · Esc exit", "profile_selector"),
    ("› unsent draft", "composer_input"),
])
func lettaAmbiguousScreensAreUnknown(_ screen: String, _ rule: String) {
    let detection = upstreamDetection(.letta, screen)
    #expect(detection.state == .unknown)
    #expect(detection.ruleID == rule)
    #expect(!detection.skip)
}
