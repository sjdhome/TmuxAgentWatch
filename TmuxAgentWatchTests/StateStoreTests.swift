//
//  StateStoreTests.swift
//  TmuxAgentWatchTests
//
//  Ported from tmux-agent-watch's src/state.rs tests.
//

import Foundation
import Testing

@testable import TmuxAgentWatch

private func detection(_ state: EngineState, visible: Bool) -> Detection {
    Detection(state: state, ruleID: "test", skip: false, visible: visible)
}

private func skipDetection() -> Detection {
    Detection(state: .unknown, ruleID: "viewer", skip: true, visible: false)
}

private func cycle(_ store: StateStore, _ pane: String, _ det: Detection) -> EngineState {
    store.beginCycle()
    let state = store.apply(paneID: pane, agent: .claude, detection: det).state
    store.prune()
    return state
}

private func cycleAt(
    _ store: StateStore, _ pane: String, _ det: Detection, _ now: Date
) -> PublishedState {
    store.beginCycle()
    let published = store.apply(paneID: pane, agent: .claude, detection: det, now: now)
    store.prune()
    return published
}

private func warmedStore(_ pane: String, _ state: EngineState) -> StateStore {
    let store = StateStore()
    _ = cycle(store, pane, detection(state, visible: true))
    _ = cycle(store, pane, detection(state, visible: true))
    _ = cycle(store, pane, detection(state, visible: true))
    return store
}

@Test func newPaneGetsOneCycleStartupGrace() {
    let store = StateStore()
    // First sighting: grace, forced Idle even though screen says working.
    #expect(cycle(store, "%1", detection(.working, visible: true)) == .idle)
    // Second sighting consumes grace, still Idle for this cycle.
    #expect(cycle(store, "%1", detection(.working, visible: true)) == .idle)
    // Third: live.
    #expect(cycle(store, "%1", detection(.working, visible: true)) == .working)
}

@Test func workingToPlainIdleNeedsTwoConfirmations() {
    let store = warmedStore("%1", .working)
    #expect(
        cycle(store, "%1", detection(.idle, visible: false)) == .working,
        "first plain idle poll is held")
    #expect(
        cycle(store, "%1", detection(.idle, visible: false)) == .idle,
        "second consecutive idle poll flips")
}

@Test func visibleIdleFlipsImmediately() {
    let store = warmedStore("%1", .working)
    #expect(cycle(store, "%1", detection(.idle, visible: true)) == .idle)
}

@Test func workingResumptionResetsPendingIdle() {
    let store = warmedStore("%1", .working)
    _ = cycle(store, "%1", detection(.idle, visible: false))
    _ = cycle(store, "%1", detection(.working, visible: true))
    #expect(
        cycle(store, "%1", detection(.idle, visible: false)) == .working,
        "pending idle must restart after working resumed")
}

@Test func blockedIsImmediateInBothDirections() {
    let store = warmedStore("%1", .working)
    #expect(cycle(store, "%1", detection(.blocked, visible: true)) == .blocked)
    #expect(
        cycle(store, "%1", detection(.idle, visible: false)) == .idle,
        "leaving blocked is not debounced")
}

@Test func skipKeepsPriorState() {
    let store = warmedStore("%1", .working)
    #expect(cycle(store, "%1", skipDetection()) == .working)
}

@Test func vanishedPaneRestartsWithGrace() {
    let store = warmedStore("%1", .working)
    // Pane absent for one cycle: begin + prune without apply.
    store.beginCycle()
    store.prune()
    #expect(
        cycle(store, "%1", detection(.working, visible: true)) == .idle,
        "reappearing pane starts with startup grace")
}

@Test func agentChangeRestartsTracking() {
    let store = warmedStore("%1", .working)
    store.beginCycle()
    let state = store.apply(
        paneID: "%1", agent: .codex, detection: detection(.working, visible: true)
    ).state
    store.prune()
    #expect(state == .idle, "new agent gets startup grace")
}

private func secs(_ n: TimeInterval) -> TimeInterval { n }

@Test func sinceRestartsOnlyOnDisplayStateChange() {
    let store = StateStore()
    let t0 = Date()
    // t0: new pane (grace forces Idle), clock starts.
    #expect(cycleAt(store, "%1", detection(.working, visible: true), t0).since == t0)
    // t0+2s: grace consumed, still displayed idle — clock keeps t0.
    var published = cycleAt(store, "%1", detection(.working, visible: true), t0 + secs(2))
    #expect(published.state == .idle)
    #expect(published.since == t0)
    // t0+4s: flips to working — clock restarts.
    published = cycleAt(store, "%1", detection(.working, visible: true), t0 + secs(4))
    #expect(published.state == .working)
    #expect(published.since == t0 + secs(4))
    // t0+6s: still working — clock unchanged.
    published = cycleAt(store, "%1", detection(.working, visible: true), t0 + secs(6))
    #expect(published.since == t0 + secs(4))
}

@Test func idleUnknownFlipsKeepSince() {
    let store = StateStore()
    let t0 = Date()
    _ = cycleAt(store, "%1", detection(.idle, visible: true), t0)
    _ = cycleAt(store, "%1", detection(.idle, visible: true), t0 + secs(2))
    // Unknown displays as idle: no reset even though the engine state
    // differs.
    var published = cycleAt(store, "%1", detection(.unknown, visible: false), t0 + secs(4))
    #expect(published.since == t0)
    published = cycleAt(store, "%1", detection(.idle, visible: false), t0 + secs(6))
    #expect(published.since == t0)
}

@Test func heldAndSkippedPollsKeepSince() {
    let store = StateStore()
    let t0 = Date()
    _ = cycleAt(store, "%1", detection(.working, visible: true), t0)
    _ = cycleAt(store, "%1", detection(.working, visible: true), t0 + secs(2))
    let working = cycleAt(store, "%1", detection(.working, visible: true), t0 + secs(4))
    #expect(working.state == .working)
    // Skip detection keeps state and clock.
    var published = cycleAt(store, "%1", skipDetection(), t0 + secs(6))
    #expect(published.state == .working)
    #expect(published.since == working.since)
    // First plain idle poll is held: still working, clock untouched.
    published = cycleAt(store, "%1", detection(.idle, visible: false), t0 + secs(8))
    #expect(published.state == .working)
    #expect(published.since == working.since)
    // Second confirming poll flips; clock restarts at the flip.
    published = cycleAt(store, "%1", detection(.idle, visible: false), t0 + secs(10))
    #expect(published.state == .idle)
    #expect(published.since == t0 + secs(10))
}
