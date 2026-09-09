//
//  PiCompactionTests.swift
//  TmuxAgentWatchTests
//
//  Synthetic standalone compaction chrome from the reported screenshot.
//

import Testing

@testable import TmuxAgentWatch

@Suite struct PiCompactionTests {
    private let border =
        "────────────────────────────────────────────────────────────────────────────"
    private let notice = "Compacting context remotely with Codex..."
    private let loader = " ⠇ Compacting context... (escape to cancel)"

    private func screen(status: String, body: String = " ") -> String {
        "\(notice)\n\n\(status)\n\n\(border)\n\(body)\n\(border)\nmodel | context\n"
    }

    private func detect(_ screen: String, agent: Agent = .pi) -> Detection {
        Scanner.detectScreen(agent: agent, rawScreen: screen, paneTitle: "")
    }

    @Test(arguments: Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"), ["esc", "escape"])
    func recognizesStandaloneCompaction(frame: Character, cancelKey: String) {
        let result = detect(
            screen(status: " \(frame) Compacting context... (\(cancelKey) to cancel)"))
        #expect(result.state == .working)
        #expect(result.ruleID == "pi_compaction_status")
        #expect(result.visible)
        #expect(!result.skip)
    }

    @Test func permitsBlankPaddingAndWidgetsBelowEditor() {
        let widget = (1...30).map { "Task \($0): pending" }.joined(separator: "\n")
        let paddedScreen = screen(status: "\(loader)   \n \n") + widget
        #expect(detect(paddedScreen).state == .working)
    }

    @Test(arguments: [
        "Compacting context remotely with Codex...",
        "Compacting context... (escape to cancel)",
        " ⠇ Compacting context...",
        " ⠇ Compacting context... (escape to cancel) is an example",
        " > ⠇ Compacting context... (escape to cancel)",
        "  ⠇ Compacting context... (escape to cancel)",
        "let text = \" ⠇ Compacting context... (escape to cancel)\";",
        " ⠇ Working... (escape to cancel)",
        " ⠇ Retrying (1/3) in 2s... (escape to cancel)",
    ])
    func rejectsProseAndOtherStandaloneLoaders(status: String) {
        #expect(detect(screen(status: status)).state == .idle)
    }

    @Test func rejectsHistoricalLoaderBeforeNewerContentOrEditor() {
        #expect(detect(screen(status: "\(loader)\nDone compacting.")).state == .idle)
        #expect(detect(screen(status: loader) + screen(status: "")).state == .idle)
    }

    @Test func rejectsLoaderInDraftOrWidget() {
        #expect(detect(screen(status: "", body: loader)).state == .idle)
        #expect(detect(screen(status: "") + loader).state == .idle)
    }

    @Test func requiresCurrentEditorBorders() {
        #expect(detect("\(notice)\n\n\(loader)\n").state == .idle)
        #expect(detect("\(loader)\n\(border)\n").state == .idle)
    }

    @Test func completionNoticeAloneIsIdle() {
        #expect(detect(screen(status: "")).state == .idle)
    }

    @Test func askUserOverridesCompaction() {
        let input = screen(
            status: loader, body: " Enter submit • Tab/Shift+Tab navigate • Esc cancel")
        #expect(PiWorking.detect(screen: input)?.ruleID == "pi_compaction_status")
        let result = detect(input)
        #expect(result.state == .blocked)
        #expect(result.ruleID == "pi_ask_user_waiting")
    }

    @Test func doesNotApplyToOtherAgents() {
        let result = detect(screen(status: loader), agent: .claude)
        #expect(result.state != .working)
        #expect(result.ruleID != "pi_compaction_status")
    }
}
