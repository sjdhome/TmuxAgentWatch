//
//  PiPermissions.swift
//  TmuxAgentWatch
//
//  Native observation of jev-permissions.ts's ApprovalDialog. Keep this
//  outside generated manifests, like PiAskUser. Color is not captured by tmux.
//

import Foundation

nonisolated enum PiPermissions {
    private static let helpText = "↑↓ navigate enter select esc deny"
    private static let optionsPattern =
        "^(?:→ )?Allow (?:(?:→ )?(?:Expand|Collapse) built-in preview )?(?:→ )?Deny$"

    static func isWaitingForUser(screen: String) -> Bool {
        let lines = rustLines(screen)
        // A newer editor/dialog border makes an earlier approval historical.
        // The title may have scrolled offscreen with a tall built-in preview;
        // use the distinctive footer and complete option list instead.
        guard let bottom = lines.lastIndex(where: { $0.hasPrefix("─") }),
            isBorder(lines[bottom]),
            bottom > 0, isBlank(lines[bottom - 1])
        else { return false }

        var cursor = bottom - 1
        guard let help = precedingBlock(lines, cursor: &cursor),
            normalized(help) == helpText,
            let options = precedingBlock(lines, cursor: &cursor)
        else { return false }
        let optionText = normalized(options)
        return optionText.filter { $0 == "→" }.count == 1
            && optionText.range(of: optionsPattern, options: .regularExpression) != nil
    }

    /// Text rows are padded; Spacer rows delimit the options and footer.
    /// Joining wrapped rows supports narrow panes without accepting prefixes
    /// shared by unrelated selectors or incomplete captured controls.
    private static func precedingBlock(_ lines: [Substring], cursor: inout Int) -> [Substring]? {
        guard cursor > 0, isBlank(lines[cursor]) else { return nil }
        let end = cursor
        cursor -= 1
        while cursor >= 0, !isBlank(lines[cursor]) {
            guard lines[cursor].hasPrefix(" ") else { return nil }
            cursor -= 1
        }
        guard cursor < end - 1 else { return nil }
        return Array(lines[(cursor + 1)..<end])
    }

    private static func normalized(_ lines: [Substring]) -> String {
        lines.flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }.joined(separator: " ")
    }

    private static func isBorder(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 8 && trimmed.allSatisfy { $0 == "─" }
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0.isWhitespace }
    }
}
