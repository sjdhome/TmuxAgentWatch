// Detection regressions ported from Herdr 4b5e9bda (Apache-2.0; see NOTICE).

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
