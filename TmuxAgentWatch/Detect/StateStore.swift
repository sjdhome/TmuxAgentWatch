//
//  StateStore.swift
//  TmuxAgentWatch
//
//  Per-pane state machine, ported from tmux-agent-watch's src/state.rs.
//  Adapts herdr's detection debounce to a 2s poll cadence:
//
//  - A newly appeared agent pane gets one cycle of startup grace, published
//    as Idle, to absorb noisy startup screens.
//  - Working → Idle without visible idle evidence needs 2 consecutive
//    confirming polls (≈4s); visible evidence flips immediately.
//  - Transitions into Blocked are never delayed, and neither are transitions
//    out of it: the state the user must act on stays honest.
//  - `skip` detections (agent-owned viewer screens) keep the prior state.
//

import Foundation

/// A debounced state together with when it last changed *as displayed*:
/// `since` restarts only when the user-visible bucket (blocked / working /
/// idle) changes, so engine Idle↔Unknown flips do not reset the clock.
nonisolated struct PublishedState: Sendable {
    var state: EngineState
    var since: Date
}

/// Engine Unknown renders as idle everywhere user-facing; fold it before
/// deciding whether the displayed state actually changed.
nonisolated private func displayState(_ state: EngineState) -> EngineState {
    state == .unknown ? .idle : state
}

nonisolated final class StateStore {
    private static let pendingIdleConfirmations = 2

    private struct PaneTracker {
        var agent: Agent
        var published: EngineState
        var publishedSince: Date
        var pendingIdle: Int
        var startupGrace: Bool
        var lastSeenCycle: UInt64

        var publishedState: PublishedState {
            PublishedState(state: published, since: publishedSince)
        }
    }

    private var trackers: [String: PaneTracker] = [:]
    private var cycle: UInt64 = 0

    /// Start a poll cycle; call `prune` after applying every pane.
    func beginCycle() {
        cycle += 1
    }

    /// Fold one raw detection into the pane's published state.
    func apply(
        paneID: String, agent: Agent, detection: Detection, now: Date = Date()
    ) -> PublishedState {
        guard var tracker = trackers[paneID], tracker.agent == agent else {
            // New pane, or a different agent took the pane over.
            trackers[paneID] = PaneTracker(
                agent: agent,
                published: .idle,
                publishedSince: now,
                pendingIdle: 0,
                startupGrace: true,
                lastSeenCycle: cycle)
            return PublishedState(state: .idle, since: now)
        }
        tracker.lastSeenCycle = cycle
        defer { trackers[paneID] = tracker }

        if tracker.startupGrace {
            tracker.startupGrace = false
            tracker.published = .idle
            return tracker.publishedState
        }

        if detection.skip {
            tracker.pendingIdle = 0
            return tracker.publishedState
        }

        let next = detection.state
        let holdsWorkingToIdle =
            tracker.published == .working
            && (next == .idle || next == .unknown)
            && !detection.visible

        if holdsWorkingToIdle {
            tracker.pendingIdle += 1
            if tracker.pendingIdle < Self.pendingIdleConfirmations {
                return tracker.publishedState
            }
        }
        tracker.pendingIdle = 0
        if displayState(tracker.published) != displayState(next) {
            tracker.publishedSince = now
        }
        tracker.published = next
        return tracker.publishedState
    }

    /// Drop trackers for panes not seen this cycle (pane closed). A pane id
    /// that reappears later starts fresh with startup grace.
    func prune() {
        trackers = trackers.filter { $0.value.lastSeenCycle == cycle }
    }
}
