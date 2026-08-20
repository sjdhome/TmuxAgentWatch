//
//  PiAskUserTests.swift
//  TmuxAgentWatchTests
//
//  Ported from tmux-agent-watch's src/pi_ask_user.rs tests.
//

import Testing

@testable import TmuxAgentWatch

private let border = "────────────────────────────────────────────────────────────────"

@Test func recognizesEveryCurrentHelpState() {
    for help in [
        "Enter save Other • Esc back to options",
        "Enter submit • Tab/Shift+Tab navigate • Esc cancel",
        "Enter submit answer • Tab/Shift+Tab navigate • Esc cancel",
        "↑↓ move • Space toggle • Enter next/edit Other • Tab navigate • Esc cancel",
        "↑↓ move • Enter choose/edit Other • Tab navigate • Esc cancel",
    ] {
        let screen = "Questions for you\n\n \(help)\n\(border)\n"
        #expect(PiAskUser.isWaitingForUser(screen: screen), "missed help line: \(help)")
    }
}

@Test func recognizesATruncatedHelpLine() {
    let screen = "Question\n Enter submit • Tab/Shift+Tab\n\(border)\n"
    #expect(PiAskUser.isWaitingForUser(screen: screen))
}

@Test func rejectsHelpTextWithoutAdjacentComponentBorder() {
    let sourceExcerpt = """

        return " Enter submit • Tab/Shift+Tab navigate • Esc cancel";
        }
        """
    #expect(!PiAskUser.isWaitingForUser(screen: sourceExcerpt))
}

@Test func rejectsUnrelatedHelpAboveABorder() {
    let screen = "Press Enter to submit\n\(border)\n"
    #expect(!PiAskUser.isWaitingForUser(screen: screen))
}

@Test func rejectsShortRuleLikeText() {
    #expect(!PiAskUser.isWaitingForUser(screen: "Enter save Other\n────\n"))
}
