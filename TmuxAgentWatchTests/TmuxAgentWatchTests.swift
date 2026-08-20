//
//  TmuxAgentWatchTests.swift
//  TmuxAgentWatchTests
//
//  Tmux output parsing, snapshot pipeline, and formatting tests, ported from
//  tmux-agent-watch's src/tmux.rs, src/snapshot.rs, and src/ui.rs tests.
//

import Foundation
import Testing

@testable import TmuxAgentWatch

// MARK: - list-panes parsing

@Test func parsesARegularLine() throws {
    let line = "work\t1\tapi\t%3\t4242\tmy-host\tzsh"
    let pane = try #require(TmuxClient.parsePaneLine(line))
    #expect(pane.session == "work")
    #expect(pane.windowIndex == 1)
    #expect(pane.windowName == "api")
    #expect(pane.paneID == "%3")
    #expect(pane.panePid == 4242)
    #expect(pane.paneTitle == "my-host")
    #expect(pane.currentCommand == "zsh")
}

@Test func sessionNamesWithSpacesSurvive() throws {
    let line = "my project\t0\tmain\t%0\t100\ttitle\tclaude"
    let pane = try #require(TmuxClient.parsePaneLine(line))
    #expect(pane.session == "my project")
    #expect(pane.currentCommand == "claude")
}

@Test func malformedLinesAreSkipped() {
    #expect(TmuxClient.parsePaneLine("") == nil)
    #expect(TmuxClient.parsePaneLine("only\tfour\tfields\there") == nil)
    #expect(TmuxClient.parsePaneLine("s\tNaN\tw\t%1\t10\tt\tcmd") == nil)
    #expect(TmuxClient.parsePaneLine("s\t0\tw\t%1\tNaN\tt\tcmd") == nil)
}

@Test func parseListPanesKeepsGoodLines() {
    let stdout = "a\t0\tw\t%0\t1\tt\tzsh\nbroken line\nb\t2\tw2\t%5\t9\tt2\tclaude\n"
    let panes = TmuxClient.parseListPanes(stdout)
    #expect(panes.count == 2)
    #expect(panes[0].paneID == "%0")
    #expect(panes[1].paneID == "%5")
}

// MARK: - Snapshot pipeline

private func pane(_ session: String, _ window: UInt32, _ id: String) -> AgentPane {
    AgentPane(
        info: PaneInfo(
            session: session,
            windowIndex: window,
            windowName: "w\(window)",
            paneID: id,
            panePid: 1,
            paneTitle: "",
            currentCommand: ""),
        agent: .claude,
        detection: .knownAgentIdleFallback,
        stateSince: Date())
}

@Test func detectionScreenTrimsOnlyTrailingBlankLines() {
    #expect(Scanner.detectionScreen("a\n\nb\n\n\n") == "a\n\nb")
    #expect(Scanner.detectionScreen("\n\n") == "")
    #expect(Scanner.detectionScreen("x") == "x")
}

@Test func piAskUserObservationOverridesManifestDetection() {
    let screen =
        "Questions for you\n\n Enter submit • Tab/Shift+Tab navigate • Esc cancel\n────────────────────────────────────────────────────────────────\n"
    let detection = Scanner.detectScreen(agent: .pi, rawScreen: screen, paneTitle: "")
    #expect(detection.state == .blocked)
    #expect(detection.ruleID == "pi_ask_user_waiting")
    #expect(detection.visible)
}

@Test func piAskUserObservationDoesNotApplyToOtherAgents() {
    let screen =
        "Questions for you\n\n Enter submit • Tab/Shift+Tab navigate • Esc cancel\n────────────────────────────────────────────────────────────────\n"
    let detection = Scanner.detectScreen(agent: .claude, rawScreen: screen, paneTitle: "")
    #expect(detection.ruleID != "pi_ask_user_waiting")
}

@Test func treeGroupsBySessionThenWindowPreservingOrder() {
    let tree = Scanner.buildTree([
        pane("s1", 1, "%1"),
        pane("s1", 1, "%2"),
        pane("s2", 0, "%3"),
        pane("s1", 3, "%4"),
    ])
    #expect(tree.count == 2)
    #expect(tree[0].name == "s1")
    #expect(tree[0].windows.count == 2)
    #expect(tree[0].windows[0].panes.count == 2)
    #expect(tree[1].name == "s2")
}

@Test func stateCountsFoldUnknownIntoIdle() {
    var blocked = pane("s", 0, "%1")
    blocked.detection.state = .blocked
    var working = pane("s", 0, "%2")
    working.detection.state = .working
    var unknown = pane("s", 0, "%3")
    unknown.detection.state = .unknown
    let counts = StateCounts(sessions: Scanner.buildTree([blocked, working, unknown]))
    #expect(counts.blocked == 1)
    #expect(counts.working == 1)
    #expect(counts.idle == 1)
}

// MARK: - Duration formatting

@Test func durationUsesLocalizedSystemFormatting() {
    let en = Locale(identifier: "en_US")
    #expect(formatStateDuration(0, locale: en) == "0s")
    #expect(formatStateDuration(45, locale: en) == "45s")
    #expect(formatStateDuration(60, locale: en) == "1m")
    #expect(formatStateDuration(3600 + 5 * 60, locale: en) == "1h 5m")
    #expect(formatStateDuration(2 * 86400 + 3600, locale: en) == "2d 1h")
    // Negative clock skew clamps to zero rather than showing "-3s".
    #expect(formatStateDuration(-3, locale: en) == "0s")

    let zh = Locale(identifier: "zh_CN")
    #expect(formatStateDuration(45, locale: zh) != "45s", "must localize unit names")
}
