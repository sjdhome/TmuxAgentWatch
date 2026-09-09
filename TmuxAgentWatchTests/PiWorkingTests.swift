//
//  PiWorkingTests.swift
//  TmuxAgentWatchTests
//
//  Synthetic editor chrome based on Pi's CustomEditor and StatusIndicator.
//  No captured conversation content is retained here.
//

import Testing

@testable import TmuxAgentWatch

@Suite struct PiWorkingTests {
    private let border = "────────────────────────────────────────────────────────────────"

    private func editor(_ top: String, body: String = "", bottom: String? = nil) -> String {
        let lowerBorder = bottom ?? String(repeating: "─", count: top.count)
        return "Response text\n\n\(top)\n\(body)\n\(lowerBorder)\nmodel | context\n"
    }

    private func detect(_ screen: String, agent: Agent = .pi) -> Detection {
        Scanner.detectScreen(agent: agent, rawScreen: screen, paneTitle: "")
    }

    @Test(arguments: Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"))
    func recognizesEveryDefaultSpinnerFrame(frame: Character) {
        let result = detect(editor("── \(frame) Working ────────────────────"))
        #expect(result.state == .working)
        #expect(result.ruleID == "pi_status_border")
        #expect(result.visible)
        #expect(!result.skip)
    }

    @Test(arguments: [
        "── ⠋ Working... ─────",
        "── ⠋ Work ─",
        "── ⠋ W ─",
        "── ⠋ ─",
        "───⠋",
        "──⠋",
        "─⠋",
        "── ⠋ ───── ↑ 12 more ─────",
        "── ⠋ Working ───── ↑ 12 more ─────",
        "── ⠋ Compacting context... (esc to cancel) ─────",
        "── ⠋ Auto-compacting... (esc to cancel) ─────",
        "── ⠋ Context overflow detected, Auto-compacting... (esc to cancel) ─────",
        "── ⠋ Summarizing branch... (esc to cancel) ─────",
        "── ⠋ Retrying (1/3) in 2s... (esc to cancel) ─────",
    ])
    func recognizesBuiltInActiveStatusVariants(top: String) {
        #expect(detect(editor(top)).state == .working)
    }

    @Test func recognizesEditorWithBottomScrollIndicator() {
        let screen = editor(
            "── ⠧ Working ────────────────────",
            body: " queued message",
            bottom: "────────── ↓ 3 more ──────────")
        #expect(detect(screen).state == .working)
    }

    @Test func widgetsBelowEditorDoNotPushStatusOutOfSearchRegion() {
        let widget = (1...30).map { "Task \($0): pending" }.joined(separator: "\n")
        let screen = editor("── ⠧ Working ────────────────────") + widget + "\n\n"
        #expect(detect(screen).state == .working)
    }

    @Test(arguments: [
        "Working",
        "The agent is Working on a fix",
        "⠧ Working",
        "── Working ──────────",
        "── x Working ──────────",
        "── ⠧ Working",
        "── ⠧ Working ───── quoted text",
        "> ── ⠧ Working ──────────",
        " ── ⠧ Working ──────────",
        "let status = \"── ⠧ Working ──────────\"",
        "⠧",
    ])
    func rejectsTextWithoutBuiltInStatusBorder(top: String) {
        #expect(detect(editor(top)).state == .idle)
    }

    @Test func requiresAnEditorBottomBorder() {
        #expect(detect("── ⠧ Working ──────────\nresponse text\n").state == .idle)
        #expect(detect("── ⠧ Working ──────────\n\(border)\n").state == .idle)
    }

    @Test func historicalStatusDoesNotOverrideCurrentIdleEditor() {
        let screen = editor("── ⠧ Working ────────────────────") + editor(border)
        #expect(detect(screen).state == .idle)
    }

    @Test func quotedStatusInEditorDoesNotOverrideIdleBorder() {
        let screen = editor(border, body: " ── ⠧ Working ────────────────────")
        #expect(detect(screen).state == .idle)
    }

    @Test func idleScrollBordersAreNotActivity() {
        let screen = editor("──────── ↑ 12 more ────────", bottom: "──────── ↓ 3 more ────────")
        #expect(detect(screen).state == .idle)
    }

    @Test(arguments: [
        "Working",
        "Working...",
        "The old status text is `Working...`.",
        "let message = \"Working...\";",
        "── ⠧ Working ────────────────────",
        " ⠧ Working...\nThis is a quoted example, not a live loader.",
    ])
    func transcriptMentionsDoNotOverrideIdleEditor(transcript: String) {
        #expect(detect(transcript + "\n" + editor(border)).state == .idle)
    }

    @Test func promptAndWidgetMentionsDoNotOverrideIdleEditor() {
        #expect(detect(editor(border, body: " Explain Working...")).state == .idle)
        #expect(detect(editor(border) + "Task: explain Working...\n").state == .idle)
    }

    @Test func legacyStandaloneLoaderIsNoLongerSupported() {
        let screen = " ⠧ Working...\n\n\(border)\n\n\(border)\nmodel | context\n"
        #expect(detect(screen) == .knownAgentIdleFallback)
        #expect(detect("Working...") == .knownAgentIdleFallback)
    }

    @Test func askUserStillOverridesWorkingStatus() {
        let screen = editor(
            "── ⠧ Working ─────────────────────────────────────────────────────────────",
            body: "Question\n Enter submit • Tab/Shift+Tab navigate • Esc cancel")
        #expect(PiWorking.isWorking(screen: screen))
        let result = detect(screen)
        #expect(result.state == .blocked)
        #expect(result.ruleID == "pi_ask_user_waiting")
    }

    @Test func doesNotApplyToOtherAgents() {
        let result = detect(editor("── ⠧ Working ────────────────────"), agent: .claude)
        #expect(result.state != .working)
        #expect(result.ruleID != "pi_status_border")
    }

    @Test func completedStatusUsesExistingIdleDebounce() {
        let store = StateStore()
        let working = detect(editor("── ⠧ Working ────────────────────"))
        let idle = detect("The old status text is Working...\n" + editor(border))
        for _ in 0..<3 {
            store.beginCycle()
            _ = store.apply(paneID: "%99", agent: .pi, detection: working)
        }
        store.beginCycle()
        #expect(store.apply(paneID: "%99", agent: .pi, detection: idle).state == .working)
        store.beginCycle()
        #expect(store.apply(paneID: "%99", agent: .pi, detection: idle).state == .idle)
    }
}
