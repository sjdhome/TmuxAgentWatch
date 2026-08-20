//
//  PiAskUser.swift
//  TmuxAgentWatch
//
//  Native observation of the Pi `ask_user` extension's active custom UI,
//  ported from tmux-agent-watch's src/pi_ask_user.rs. This deliberately
//  lives outside the manifest engine, which tracks Herdr. While the
//  extension's tool is waiting, its help line sits immediately above a
//  full-width `─` bottom border; once the user answers or cancels, that
//  component (and therefore this marker) disappears.
//

import Foundation

nonisolated enum PiAskUser {
    /// Prefixes of every help line rendered by the active `ask_user`
    /// component. Prefix matching preserves detection when Pi truncates the
    /// line in a narrow pane. Keep these synchronized with `helpText()` in
    /// the extension.
    private static let helpPrefixes = [
        "Enter save Other",
        "Enter submit • Tab/Shift+Tab",
        "Enter submit answer • Tab/Shift+Tab",
        "↑↓ move • Space toggle • Enter next/edit Other",
        "↑↓ move • Enter choose/edit Other",
    ]

    private static let minBorderWidth = 8

    /// Whether the visible screen contains the active `ask_user` custom UI.
    ///
    /// A help prefix alone is insufficient because source code or old
    /// transcript text may contain it. Requiring the component's bottom
    /// border on the very next line makes the observation structural and
    /// avoids stale completed tool calls.
    static func isWaitingForUser(screen: String) -> Bool {
        let lines = rustLines(screen)
        guard lines.count >= 2 else { return false }
        for index in 0..<(lines.count - 1)
        where isHelpLine(lines[index]) && isHorizontalBorder(lines[index + 1]) {
            return true
        }
        return false
    }

    private static func isHelpLine(_ line: Substring) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return helpPrefixes.contains { line.hasPrefix($0) }
    }

    private static func isHorizontalBorder(_ line: Substring) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.count >= minBorderWidth && line.allSatisfy { $0 == "─" }
    }
}
