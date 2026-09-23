//
//  PiPermissionsTests.swift
//  TmuxAgentWatchTests
//
//  Synthetic screens based on jev-permissions.ts's ApprovalDialog, not
//  captured conversations. Only the TUI approval path is under test.
//

import Foundation
import Testing

@testable import TmuxAgentWatch

@Suite struct PiPermissionsTests {
    private let border = String(repeating: "─", count: 64)
    private let help = " ↑↓ navigate  enter select  esc deny"

    private func dialog(
        danger: Bool = false, preview: String? = nil, selected: Int = 0
    ) -> String {
        var options = ["Allow"]
        if let preview { options.append("\(preview) built-in preview") }
        options.append("Deny")
        let rows = options.enumerated().map { index, label in
            index == selected ? " → \(label)" : "   \(label)"
        }.joined(separator: "\n")
        let title = danger
            ? "DANGER: Jev flagged this tool call as dangerous" : "Approve tool call?"
        return """
            \(border)

             \(title)

             Tool: bash
             Command: example-command
             Approval required

            \(rows)

            \(help)

            \(border)
            model | context
            """
    }

    private func detect(_ screen: String, agent: Agent = .pi) -> Detection {
        Scanner.detectScreen(agent: agent, rawScreen: screen, paneTitle: "")
    }

    @Test(arguments: [false, true], [0, 1])
    func recognizesNormalAndDangerAtEitherSelection(danger: Bool, selected: Int) {
        let result = detect(dialog(danger: danger, selected: selected))
        #expect(result.state == .blocked)
        #expect(result.ruleID == "pi_permissions_waiting")
        #expect(result.visible)
        #expect(!result.skip)
    }

    @Test(arguments: ["Expand", "Collapse"], [0, 1, 2])
    func recognizesPreviewToggleAtEverySelection(preview: String, selected: Int) {
        #expect(detect(dialog(preview: preview, selected: selected)).state == .blocked)
    }

    @Test func recognizesWrappedControlsAndClippedTitle() {
        let screen = """
             Preview continues from above

               Allow
             → Collapse built-in
             preview
               Deny

             ↑↓ navigate  enter
             select  esc deny

            ────────────────────
            model | context
            """
        #expect(detect(screen).state == .blocked)
    }

    @Test func acceptsTmuxPaddingAndTallWidgets() {
        let screen = dialog().replacingOccurrences(of: "\n", with: "   \n")
            + "\n" + (1...30).map { "Task \($0): pending" }.joined(separator: "\n")
            + "\n\n   \n"
        #expect(detect(screen).state == .blocked)
    }

    @Test(arguments: [
        "Approve tool call?",
        "DANGER: Jev flagged this tool call as dangerous",
        "Jev permissions: enabled",
        "Permission denied. Agent turn stopped; explain your reason or next instruction when ready.",
        "bash blocked: approval was not granted",
        "Jev is checking this tool call",
        " ↑↓ navigate  enter select  esc deny",
    ])
    func textAloneIsNotBlocked(text: String) {
        #expect(detect(text).state == .idle)
        #expect(detect(text + "\n" + border + "\n\n" + border).state == .idle)
    }

    @Test(arguments: [
        " ↑↓ navigate  enter select  esc cancel",
        " ↑↓ navigate  enter select",
        " ↑↓ navigate  enter select  esc deny extra",
    ])
    func rejectsDifferentOrIncompleteHelp(replacement: String) {
        let screen = dialog().replacingOccurrences(of: help, with: replacement)
        #expect(!PiPermissions.isWaitingForUser(screen: screen))
    }

    @Test(arguments: [
        "   Allow\n   Deny",
        " → Allow\n → Deny",
        " → Allow\n   Cancel",
        " → Allow\n   Expand something else\n   Deny",
        " → Deny",
    ])
    func requiresCompleteApprovalOptionsWithOneSelection(options: String) {
        let screen = "\(options)\n\n\(help)\n\n\(border)"
        #expect(!PiPermissions.isWaitingForUser(screen: screen))
    }

    @Test func requiresFooterSpacingAndFullWidthBorder() {
        for screen in [
            dialog().replacingOccurrences(of: "\(help)\n\n", with: "\(help)\n"),
            dialog().replacingOccurrences(of: border, with: "────"),
            dialog().replacingOccurrences(of: border, with: "──── ────"),
            dialog().replacingOccurrences(of: border, with: " " + border),
            dialog().replacingOccurrences(of: border, with: ""),
        ] {
            #expect(!PiPermissions.isWaitingForUser(screen: screen))
        }
    }

    @Test func newerIdleOrWorkingEditorSupersedesHistoricalApproval() {
        let old = dialog()
        let idleEditor = "\n\(border)\n\n\(border)\nmodel | context"
        #expect(detect(old + idleEditor).state == .idle)
        let workingEditor = "\n── ⠋ Working ──────────\n\n\(border)\nmodel | context"
        #expect(detect(old + workingEditor).state == .working)
    }

    @Test func rejectsQuotedDialogAndSourceExcerpt() {
        let quoted = dialog().split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        #expect(detect(quoted).state == .idle)
        #expect(detect("new Text(theme.fg(\"dim\", \"↑↓ navigate  enter select  esc deny\"), 1, 0);").state == .idle)
    }

    @Test func approvalOverridesWorkingAndNewestDialogSupersedesHistoricalAsk() {
        // A simultaneous status border must not outrank active approval controls.
        let body = dialog().split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst().joined(separator: "\n")
        let screen = "── ⠋ Working ──────────\n" + body
        #expect(PiWorking.detect(screen: screen)?.state == .working)
        #expect(detect(screen).state == .blocked)
        let askUser = "Question\n Enter submit • Tab/Shift+Tab navigate • Esc cancel\n\(border)\n"
        #expect(detect(askUser + dialog()).ruleID == "pi_permissions_waiting")
        #expect(detect(dialog() + "\n" + askUser).ruleID == "pi_ask_user_waiting")
        let askAI = " ↑↓/PgUp/PgDn scroll • Esc cancel and return\n\(border)\n"
        #expect(detect(askAI + dialog()).ruleID == "pi_permissions_waiting")
        #expect(detect(dialog() + "\n" + askAI).ruleID == "pi_ask_user_clarification_working")
    }

    @Test func doesNotApplyToOtherAgents() {
        #expect(detect(dialog(), agent: .claude).ruleID != "pi_permissions_waiting")
    }

    @Test(arguments: [false, true])
    func enteringAndLeavingApprovalIsNotDebounced(resumesWork: Bool) {
        let store = StateStore()
        let working = detect("── ⠋ Working ──────────\n\n\(border)")
        for _ in 0..<3 {
            store.beginCycle()
            _ = store.apply(paneID: "%99", agent: .pi, detection: working)
        }
        store.beginCycle()
        #expect(store.apply(paneID: "%99", agent: .pi, detection: detect(dialog())).state == .blocked)
        store.beginCycle()
        let next = resumesWork ? working : detect("Permission denied. Agent turn stopped.")
        #expect(store.apply(paneID: "%99", agent: .pi, detection: next).state == next.state)
    }
}
