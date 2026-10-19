//
//  ClaudeBackgroundAgentsTests.swift
//  TmuxAgentWatchTests
//
//  Synthetic Claude Code chrome modeled on a wide pane waiting for several
//  background agents. No captured conversation content is retained here.
//

import Testing

@testable import TmuxAgentWatch

@Suite struct ClaudeBackgroundAgentsTests {
    private let rule = String(repeating: "─", count: 60)
    private let counter = String(repeating: " ", count: 40) + "128552 tokens"

    private func screen(above: [String], belowPrompt: [String] = []) -> String {
        (["⏺ Agent(Scan sources)", "  ⎿  Backgrounded agent", ""] + above
            + [rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)", ""] + belowPrompt)
            .joined(separator: "\n")
    }

    private func detect(_ screen: String, agent: Agent = .claude) -> Detection {
        Scanner.detectScreen(agent: agent, rawScreen: screen, paneTitle: "")
    }

    @Test func waitingLineBelowTokenCounterIsWorking() {
        let result = detect(
            screen(
                above: ["✻ Waiting for 3 background agents to finish", counter],
                belowPrompt: [
                    "  ⏺ main",
                    "  ◯ general-purpose  Searching sources      3m 23s · ↓ 82.8k tokens",
                ]))
        #expect(result.state == .working)
        #expect(result.ruleID == ClaudeBackgroundAgents.ruleID)
        #expect(result.visible)
    }

    @Test func waitingLineWithoutCounterKeepsUpstreamRule() {
        let result = detect(screen(above: ["✻ Waiting for 1 background agent to finish"]))
        #expect(result.state == .working)
        #expect(result.ruleID == "background_agents_working")
    }

    @Test(arguments: [
        ["✻ Waiting for 0 background agents to finish", "      128552 tokens"],
        ["✻ Waiting for 3 background agents to finish", "⏺ Done.", "      128552 tokens"],
        ["✻ Waiting for 3 background agents to finish", "128552 tokens"],
        ["❯ ✻ Waiting for 3 background agents to finish", "      128552 tokens"],
    ])
    func otherScreensStayIdle(above: [String]) {
        let result = detect(screen(above: above))
        #expect(result.state == .idle)
        #expect(result.ruleID == "live_prompt_box")
    }

    @Test func waitingLineWithoutPromptBoxIsIgnored() {
        #expect(ClaudeBackgroundAgents.detect(
            screen: "✻ Waiting for 3 background agents to finish\n      128552 tokens") == nil)
    }

    @Test func permissionPromptKeepsPrecedence() {
        // The permission dialog replaces the prompt box while it is shown.
        let result = detect(
            [
                "✻ Waiting for 3 background agents to finish", counter, rule,
                " Bash command", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. No",
                "", " Esc to cancel",
            ].joined(separator: "\n"))
        #expect(result.state == .blocked)
    }

    @Test func otherAgentsAreUnaffected() {
        let result = detect(
            screen(above: ["✻ Waiting for 3 background agents to finish", counter]),
            agent: .codex)
        #expect(result.ruleID != ClaudeBackgroundAgents.ruleID)
    }
}
