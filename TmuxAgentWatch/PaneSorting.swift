//
//  PaneSorting.swift
//  TmuxAgentWatch
//
//  Flattening and user-selectable ordering of agent panes for the list UI.
//

import Foundation

/// User-selectable ordering of the agent list.
nonisolated enum PaneSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// Display name, alphabetically.
    case name
    /// Blocked first, then idle, then working; longer time in the current
    /// state wins ties, then the display name.
    case state

    var id: Self { self }
}

extension AgentPane {
    /// What the row leads with: the agent's terminal (OSC) title, falling
    /// back to the pane's current command, then the agent label.
    nonisolated var displayName: String {
        if !info.paneTitle.isEmpty { return info.paneTitle }
        if !info.currentCommand.isEmpty { return info.currentCommand }
        return agent.label
    }
}

/// Flatten the session tree into one row per agent pane, preserving tmux
/// order.
nonisolated func flattenPanes(_ sessions: [SessionNode]) -> [AgentPane] {
    sessions.flatMap { session in
        session.windows.flatMap(\.panes)
    }
}

/// Blocked needs attention now, idle is ready for new work, working can be
/// left alone.
nonisolated private func stateRank(_ state: EngineState) -> Int {
    switch state {
    case .blocked: return 0
    // Unknown renders as idle in the UI.
    case .idle, .unknown: return 1
    case .working: return 2
    }
}

nonisolated private func nameOrdering(_ lhs: AgentPane, _ rhs: AgentPane) -> ComparisonResult {
    lhs.displayName.localizedStandardCompare(rhs.displayName)
}

/// Sort panes for display. Ties always fall back to tmux order so the list
/// is stable across refreshes.
nonisolated func sortPanes(_ panes: [AgentPane], by order: PaneSortOrder) -> [AgentPane] {
    switch order {
    case .name:
        return panes.enumerated().sorted { lhs, rhs in
            switch nameOrdering(lhs.element, rhs.element) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    case .state:
        return panes.enumerated().sorted { lhs, rhs in
            let left = stateRank(lhs.element.detection.state)
            let right = stateRank(rhs.element.detection.state)
            if left != right { return left < right }
            // Longer in the current state first.
            if lhs.element.stateSince != rhs.element.stateSince {
                return lhs.element.stateSince < rhs.element.stateSince
            }
            switch nameOrdering(lhs.element, rhs.element) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
