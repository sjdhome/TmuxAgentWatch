//
//  PiAskUserTests.swift
//  TmuxAgentWatchTests
//
//  Synthetic screens based on ask-user.ts and clarification-view.ts.
//  No captured conversation content is retained here.
//

import Foundation
import Testing

@testable import TmuxAgentWatch

@Suite struct PiAskUserTests {
    private let border = String(repeating: "─", count: 96)
    private let choiceHelp =
        "↑↓ move • n note • Enter choose/edit Other • ? ask AI • Tab navigate • Esc cancel"
    private let inputHelp = "Enter ask AI • Esc back to options"
    private let workingHelp = "↑↓/PgUp/PgDn scroll • Esc cancel and return"
    private let resultHelp = "↑↓/PgUp/PgDn scroll • Esc back to options"

    private func dialog(_ help: String, body: String = " Choose an option.") -> String {
        "\(border)\n Custom dialog title\n\n\(body)\n\n \(help)\n\(border)\nmodel | context\n"
    }

    private func detect(_ screen: String, agent: Agent = .pi) -> Detection {
        Scanner.detectScreen(agent: agent, rawScreen: screen, paneTitle: "")
    }

    @Test(arguments: [
        "Enter save Other • Esc back to options",
        "Enter save note • Shift+Enter new line • Esc discard changes",
        "Enter submit • Tab/Shift+Tab navigate • Esc cancel",
        "Enter submit answer • Tab/Shift+Tab navigate • Esc cancel",
        "↑↓ move • Space toggle • Enter next/edit Other • Tab navigate • Esc cancel",
        "↑↓ move • Enter choose/edit Other • Tab navigate • Esc cancel",
        "↑↓ move • Space toggle • n note • Enter next/edit Other • ? ask AI • Tab navigate • Esc cancel",
        "↑↓ move • n note • Enter choose/edit Other • ? ask AI • Tab navigate • Esc cancel",
        "Enter ask AI • Esc back to options",
        "↑↓/PgUp/PgDn scroll • Esc back to options",
        "↑↓/PgUp/PgDn scroll • Esc back to options • 11-20/100",
    ])
    func recognizesEveryWaitingHelpState(help: String) {
        let result = detect(dialog(help))
        #expect(result.state == .blocked)
        #expect(result.ruleID == "pi_ask_user_waiting")
        #expect(result.visible)
        #expect(!result.skip)
    }

    @Test func currentChoiceDialogIsBlockedThroughScanner() {
        // Sanitized layout from the reported pane, including the task widget.
        let screen = """
             ask_user Questions for you (1 question)

            \(border)
             Questions for you

             Choose an option.

            > ○ 1. Keep current behavior
                   A description of the first option.
              ○ 2. Change behavior
              ○ 3. Other

             ↑↓ move • n note • Enter choose/edit Other • ? ask AI • Tab navigate • Esc cancel
            \(border)
             Task progress: 1/2 complete
             [x] Inspect the current behavior
             [ ] Plan the change
            model | context
            """
        #expect(detect(screen).state == .blocked)
        #expect(detect(screen).ruleID == "pi_ask_user_waiting")
    }

    @Test(arguments: [
        "Enter submit • Tab/Shift+Tab…",
        "Enter save Other • Esc…",
        "Enter save note • Shift…",
        "↑↓ move • n note • Enter choose/edit Other…",
        "↑↓ move • Space toggle • n note • Enter next/edit Other…",
        "↑↓/PgUp/PgDn scroll • Esc back to options • 1-…",
    ])
    func recognizesTruncatedSuffixAfterDistinctivePrefix(help: String) {
        #expect(detect(dialog(help)).state == .blocked)
    }

    @Test(arguments: [
        " Q1: please choose one option.",
        " Q1: choose at least 2 options.",
        " Q1: maximum 2 selected.",
        " Q1: please type the Other answer.",
        " Review your answers\n Q1: (no answer)\n Some required questions are unanswered.",
        " Review your answers\n Q1: Example\n Press Enter to submit",
        " AI clarification is unavailable because no model is selected.",
        " AI clarification is unavailable because no runtime provider exists for example/model.",
        " AI clarification is unavailable because the pre-question context could not be isolated safely.",
    ])
    func validationAndAvailabilityMessagesDoNotChangeWaitingState(body: String) {
        #expect(detect(dialog(choiceHelp, body: body)).state == .blocked)
    }

    @Test(arguments: ["Enter save Other", "Enter save note", "Enter submit answer • Tab/Shift+Tab"])
    func nestedInputBordersDoNotHideDialogFooter(help: String) {
        let body = " What would you like to enter?\n       \(border)\n       Draft text\n       \(border)"
        #expect(detect(dialog(help, body: body)).state == .blocked)
    }

    @Test func emptyClarificationInputRemainsBlocked() {
        #expect(detect(dialog(inputHelp, body: " Please type a clarification question.")).state == .blocked)
    }

    @Test(arguments: [" Thinking…", " First part of the explanation.", "", " An explanation containing Esc back to options."],
        ["", " • 1-10/80", " • 1-…"])
    func clarificationLoadingAndStreamingAreWorking(body: String, position: String) {
        let result = detect(dialog(workingHelp + position, body: body))
        #expect(result.state == .working)
        #expect(result.ruleID == "pi_ask_user_clarification_working")
        #expect(result.visible)
        #expect(!result.skip)
    }

    @Test(arguments: [
        " Explanation completed.",
        " Request failed: connection unavailable.",
        " Thinking…",  // The renderer also uses this for a completed empty response.
        " ↑↓/PgUp/PgDn scroll • Esc cancel and return",
    ])
    func completedAndFailedClarificationsWaitRegardlessOfBody(body: String) {
        #expect(detect(dialog(resultHelp, body: body)).state == .blocked)
    }

    @Test func paddingClippedTitleAndTallWidgetsAreSupported() {
        for help in [choiceHelp, inputHelp, workingHelp, resultHelp] {
            let footerOnly = " \(help)   \n\(border)   \n"
            let widgets = (1...30).map { " Task \($0): pending" }.joined(separator: "\n")
            #expect(detect(footerOnly + widgets + "\n\n   \n") == detect(dialog(help)))
        }
    }

    @Test(arguments: [
        "Enter save Other",
        "Enter save note",
        "Enter ask AI • Esc back to options",
        "↑↓/PgUp/PgDn scroll • Esc cancel and return",
        "↑↓/PgUp/PgDn scroll • Esc back to options",
    ])
    func requiresAdjacentLeftAlignedFullBorder(help: String) {
        for screen in [
            help,
            "\(help)\n\n\(border)",
            "\(help)\n────",
            "\(help)\n──── ────",
            "\(help)\n \(border)",
            "\(help)\n\(border) extra",
            "return \" \(help)\";\n}",
        ] {
            #expect(PiAskUser.detect(screen: screen) == nil)
        }
    }

    @Test(arguments: [
        "Press Enter to submit",
        "↑↓ move",
        "↑↓ move • n note • Enter…",
        "↑↓/PgUp/PgDn scroll • Esc…",
        "↑↓/PgUp/PgDn scroll • Esc cancel…",
        "↑↓/PgUp/PgDn scroll • Esc back…",
        "↑↓/PgUp/PgDn scroll • Esc close",
        "Ask about Example",
        "Thinking…",
    ])
    func ambiguousOrUnrelatedTextDoesNotIdentifyAsk(help: String) {
        #expect(PiAskUser.detect(screen: dialog(help)) == nil)
    }

    @Test func quotedDialogIsNotActive() {
        for prefix in ["> ", " ", "    "] {
            let quoted = dialog(workingHelp).split(separator: "\n", omittingEmptySubsequences: false)
                .map { prefix + $0 }.joined(separator: "\n")
            #expect(detect(quoted).state == .idle)
        }
    }

    @Test func newestDialogFooterDeterminesState() {
        #expect(detect(dialog(choiceHelp) + dialog(workingHelp)).state == .working)
        #expect(detect(dialog(workingHelp) + dialog(resultHelp)).state == .blocked)
        #expect(detect(dialog(workingHelp) + dialog(choiceHelp)).state == .blocked)
    }

    @Test func newerEditorsSupersedeAllHistoricalAskStates() {
        for help in [choiceHelp, inputHelp, workingHelp, resultHelp] {
            let historical = dialog(help)
            let idle = "\(border)\n\n\(border)\nmodel | context"
            let working = "── ⠋ Working ──────────\n\n\(border)\nmodel | context"
            #expect(detect(historical + idle) == .knownAgentIdleFallback)
            #expect(detect(historical + working).ruleID == "pi_status_border")
        }
    }

    @Test func askClarificationOverridesGenericEditorActivity() {
        for help in [inputHelp, workingHelp, resultHelp] {
            let screen = "── ⠋ Working ──────────\n Explanation\n \(help)\n\(border)"
            #expect(PiWorking.detect(screen: screen)?.state == .working)
            #expect(detect(screen) == detect(dialog(help)))
        }
    }

    @Test func completedToolResultsAreNotActiveDialogs() {
        for text in [
            "ask_user Questions for you (1 question)\n✓ Answered 1/1\nscope: Example",
            "Questions cancelled",
            "Ask user error: questions must contain at least one question.",
        ] {
            #expect(detect(text) == .knownAgentIdleFallback)
        }
    }

    @Test func askObservationsDoNotApplyToOtherAgents() {
        for help in [choiceHelp, inputHelp, workingHelp, resultHelp] {
            let result = detect(dialog(help), agent: .claude)
            #expect(result.ruleID != "pi_ask_user_waiting")
            #expect(result.ruleID != "pi_ask_user_clarification_working")
        }
    }

    @Test(arguments: [" Explanation completed.", " Request failed."])
    func clarificationRoundTripPublishesWithoutExtraDebounce(resultBody: String) {
        let store = StateStore()
        func observe(_ screen: String) -> EngineState {
            store.beginCycle()
            return store.apply(paneID: "%99", agent: .pi, detection: detect(screen)).state
        }
        // Preserve the two startup observations before testing established-pane transitions.
        #expect(observe(dialog(choiceHelp)) == .idle)
        #expect(observe(dialog(choiceHelp)) == .idle)
        #expect(observe(dialog(choiceHelp)) == .blocked)
        #expect(observe(dialog(inputHelp)) == .blocked)
        #expect(observe(dialog(workingHelp, body: " Thinking…")) == .working)
        #expect(observe(dialog(workingHelp, body: " Partial answer")) == .working)
        #expect(observe(dialog(resultHelp, body: resultBody)) == .blocked)
        #expect(observe(dialog(choiceHelp)) == .blocked)
        #expect(observe(dialog("Enter submit • Tab/Shift+Tab navigate • Esc cancel")) == .blocked)
        #expect(observe("✓ Answered 1/1") == .idle)
    }

    @Test func cancellingClarificationReturnsToBlockedOptions() {
        let store = StateStore()
        for _ in 0..<3 {
            store.beginCycle()
            _ = store.apply(paneID: "%99", agent: .pi, detection: detect(dialog(workingHelp)))
        }
        store.beginCycle()
        #expect(store.apply(paneID: "%99", agent: .pi, detection: detect(dialog(choiceHelp))).state == .blocked)
        store.beginCycle()
        #expect(store.apply(paneID: "%99", agent: .pi, detection: detect("Questions cancelled")).state == .idle)
        store.beginCycle()
        let working = detect("── ⠋ Working ──────────\n\n\(border)")
        #expect(store.apply(paneID: "%99", agent: .pi, detection: working).state == .working)
    }
}
