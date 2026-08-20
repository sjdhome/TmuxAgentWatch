//
//  PaneSortingTests.swift
//  TmuxAgentWatchTests
//

import Foundation
import Testing

@testable import TmuxAgentWatch

private func pane(
    _ id: String, session: String = "s", title: String = "", command: String = "",
    agent: Agent = .claude, state: EngineState = .idle,
    since: Date = Date(timeIntervalSinceReferenceDate: 0)
) -> AgentPane {
    AgentPane(
        info: PaneInfo(
            session: session,
            windowIndex: 0,
            windowName: "w",
            paneID: id,
            panePid: 1,
            paneTitle: title,
            currentCommand: command),
        agent: agent,
        detection: Detection(state: state, ruleID: nil, skip: false, visible: false),
        stateSince: since)
}

@Test func flattenPreservesTmuxOrder() {
    let tree = Scanner.buildTree([
        pane("%1", session: "s1"),
        pane("%2", session: "s1"),
        pane("%3", session: "s2"),
    ])
    #expect(flattenPanes(tree).map(\.id) == ["%1", "%2", "%3"])
}

@Test func displayNameFallsBackFromTitleToCommandToAgent() {
    #expect(pane("%1", title: "the title", command: "vim").displayName == "the title")
    #expect(pane("%1", command: "vim").displayName == "vim")
    #expect(pane("%1", agent: .pi).displayName == "pi")
}

@Test func nameSortIsAlphabeticalAndStable() {
    let panes = [
        pane("%1", title: "beta"),
        pane("%2", title: "alpha"),
        pane("%3", title: "beta"),
    ]
    #expect(sortPanes(panes, by: .name).map(\.id) == ["%2", "%1", "%3"])
}

@Test func stateSortRanksBlockedThenIdleThenWorking() {
    let panes = [
        pane("%1", state: .working),
        pane("%2", state: .idle),
        pane("%3", state: .blocked),
        pane("%4", state: .unknown),
    ]
    #expect(sortPanes(panes, by: .state).map(\.id) == ["%3", "%2", "%4", "%1"])
}

@Test func stateSortBreaksTiesByLongerTimeInState() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let panes = [
        pane("%1", state: .blocked, since: t0 + 60),
        pane("%2", state: .blocked, since: t0),
        pane("%3", state: .idle, since: t0 + 60),
        pane("%4", state: .idle, since: t0),
    ]
    #expect(sortPanes(panes, by: .state).map(\.id) == ["%2", "%1", "%4", "%3"])
}

@Test func stateSortBreaksRemainingTiesByName() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let panes = [
        pane("%1", title: "beta", state: .idle, since: t0),
        pane("%2", title: "alpha", state: .idle, since: t0),
        pane("%3", title: "alpha", state: .idle, since: t0),
    ]
    #expect(sortPanes(panes, by: .state).map(\.id) == ["%2", "%3", "%1"])
}
