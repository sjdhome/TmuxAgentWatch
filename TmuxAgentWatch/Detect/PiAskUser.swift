//
//  PiAskUser.swift
//  TmuxAgentWatch
//
//  Native observations of ask-user.ts and ask-user/clarification-view.ts.
//  Keep this outside generated manifests. The current dialog's help line
//  immediately precedes its left-aligned bottom border; a newer editor or
//  dialog supersedes historical help text.
//

import Foundation

nonisolated enum PiAskUser {
    /// Keep these synchronized with helpText() in ask-user.ts. Legacy
    /// choice prefixes remain supported; suffixes may be truncated by Pi.
    private static let waitingHelpPrefixes = [
        "Enter save Other",
        "Enter save note",
        "Enter submit • Tab/Shift+Tab",
        "Enter submit answer • Tab/Shift+Tab",
        "↑↓ move • Space toggle • Enter next/edit Other",
        "↑↓ move • Enter choose/edit Other",
        "↑↓ move • Space toggle • n note • Enter next/edit Other",
        "↑↓ move • n note • Enter choose/edit Other",
        "Enter ask AI • Esc back to options",
        "↑↓/PgUp/PgDn scroll • Esc back to options",
    ]
    private static let workingHelpPrefix = "↑↓/PgUp/PgDn scroll • Esc cancel and return"
    private static let minBorderWidth = 8

    /// An active Ask dialog normally waits for human input, including when
    /// an explanation is complete or has failed. Only the clarification
    /// request/streaming footer means work is in progress. Never infer this
    /// from answer text, titles, or a bare "Thinking…" label.
    static func detect(screen: String) -> Detection? {
        let lines = rustLines(screen)
        guard let bottom = lines.lastIndex(where: { $0.hasPrefix("─") }),
            bottom > 0, isHorizontalBorder(lines[bottom])
        else { return nil }

        let help = lines[bottom - 1].trimmingCharacters(in: .whitespaces)
        if help.hasPrefix(workingHelpPrefix) {
            return Detection(
                state: .working, ruleID: "pi_ask_user_clarification_working",
                skip: false, visible: true)
        }
        if waitingHelpPrefixes.contains(where: { help.hasPrefix($0) }) {
            return Detection(
                state: .blocked, ruleID: "pi_ask_user_waiting", skip: false, visible: true)
        }
        return nil
    }

    private static func isHorizontalBorder(_ line: Substring) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.count >= minBorderWidth && line.allSatisfy { $0 == "─" }
    }
}
