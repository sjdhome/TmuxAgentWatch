//
//  ClaudeBackgroundAgents.swift
//  TmuxAgentWatch
//
//  Native Claude Code background-agent observation, separate from the Herdr
//  manifests. Herdr's background_agents_working rule only inspects the last
//  non-empty line above the prompt box; wide panes put a right-aligned token
//  counter there, so the waiting line is missed and the pane reads idle.
//

import Foundation

nonisolated enum ClaudeBackgroundAgents {
    static let ruleID = "claude_background_agents_waiting"

    // Same shape as Herdr's background_agents_working line.
    private static let waitingLine =
        "^\\s*[\\x{002A}\\x{00B7}\\x{2722}\\x{2736}\\x{273B}\\x{273D}]\\s+Waiting for [1-9]\\d* background agents? to finish\\s*$"
    // Right-aligned counter such as "      128552 tokens". The leading padding
    // keeps left-aligned transcript text from being skipped.
    private static let tokenCounterLine = "^\\s{2,}[0-9][0-9.,]*[kKmM]? tokens\\s*$"

    static func detect(screen: String) -> Detection? {
        let above = regionText(
            input: DetectionInput(screen: screen, oscTitle: "", oscProgress: ""),
            spec: "above_prompt_box")
        // No prompt box means the region is the whole screen; do not guess.
        guard above.count < screen.count else { return nil }
        let candidate = rustLines(above).reversed().first { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
                && line.range(of: tokenCounterLine, options: .regularExpression) == nil
        }
        guard let candidate,
            candidate.range(of: waitingLine, options: .regularExpression) != nil
        else { return nil }
        return Detection(state: .working, ruleID: ruleID, skip: false, visible: true)
    }
}
