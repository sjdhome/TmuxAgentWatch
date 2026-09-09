//
//  Scanner.swift
//  TmuxAgentWatch
//
//  One poll cycle: tmux discovery → process identification → screen
//  detection → tree building. Ported from tmux-agent-watch's src/snapshot.rs.
//

import Foundation

private let piAskUserRuleID = "pi_ask_user_waiting"

/// A pane with a detected agent, carrying the debounced detection.
nonisolated struct AgentPane: Sendable, Identifiable {
    var info: PaneInfo
    var agent: Agent
    var detection: Detection
    /// When the debounced state last changed, from the scanner's state store.
    var stateSince: Date

    var id: String { info.paneID }
}

nonisolated struct WindowNode: Sendable, Identifiable {
    var index: UInt32
    var name: String
    var panes: [AgentPane]

    var id: UInt32 { index }
}

nonisolated struct SessionNode: Sendable, Identifiable {
    var name: String
    var windows: [WindowNode]

    var id: String { name }
}

/// What one scan produced; the UI renders this without further tmux access.
nonisolated enum Snapshot: Sendable {
    case tmuxUnavailable(message: String)
    case tree([SessionNode])
}

/// Count of panes per engine state, for the summary line.
nonisolated struct StateCounts: Sendable, Equatable {
    var working = 0
    var blocked = 0
    var idle = 0

    init() {}

    init(sessions: [SessionNode]) {
        self.init()
        for session in sessions {
            for window in session.windows {
                for pane in window.panes {
                    switch pane.detection.state {
                    case .working: working += 1
                    case .blocked: blocked += 1
                    // Unknown renders as idle in the UI.
                    case .idle, .unknown: idle += 1
                    }
                }
            }
        }
    }
}

nonisolated enum Scanner {
    /// Run one scan with debounced states folded through the store.
    static func scanDebounced(store: StateStore) -> Snapshot {
        let panes: [PaneInfo]
        switch TmuxClient.listPanes() {
        case .failure(let unavailable):
            return .tmuxUnavailable(message: unavailable.message)
        case .success(let listed):
            panes = listed
        }

        store.beginCycle()

        var agentPanes: [AgentPane] = []
        for pane in panes {
            guard let (agent, _) = AgentIdentifier.identifyPaneAgent(panePid: pane.panePid)
            else { continue }
            // Pane may vanish between list and capture; drop it for this cycle.
            guard let rawScreen = TmuxClient.capturePane(paneID: pane.paneID) else { continue }
            var detection = detectScreen(agent: agent, rawScreen: rawScreen, paneTitle: pane.paneTitle)
            let published = store.apply(paneID: pane.paneID, agent: agent, detection: detection)
            detection.state = published.state
            agentPanes.append(
                AgentPane(
                    info: pane, agent: agent, detection: detection, stateSince: published.since))
        }

        store.prune()

        return .tree(buildTree(agentPanes))
    }

    /// Resolve one pane's captured screen. Project-native observations take
    /// precedence over the herdr-derived manifest result.
    static func detectScreen(agent: Agent, rawScreen: String, paneTitle: String) -> Detection {
        let screen = detectionScreen(rawScreen)
        if let detection = nativeBlocker(agent: agent, screen: screen) {
            return detection
        }
        if agent == .pi {
            if PiWorking.isWorking(screen: screen) {
                return Detection(
                    state: .working, ruleID: "pi_status_border", skip: false, visible: true)
            }
            // Only modern Pi editor chrome is supported. The upstream legacy
            // literal matches transcript, draft, and widget text as well as work.
            return .knownAgentIdleFallback
        }

        let input = DetectionInput(
            screen: screen,
            oscTitle: paneTitle,
            // tmux does not track OSC 9;4 progress sequences.
            oscProgress: "")
        guard let manifestID = agent.manifestID, let manifest = Manifests.get(manifestID) else {
            return .knownAgentIdleFallback
        }
        return evaluate(manifest: manifest, input: input)
    }

    private static func nativeBlocker(agent: Agent, screen: String) -> Detection? {
        guard agent == .pi, PiAskUser.isWaitingForUser(screen: screen) else { return nil }
        return Detection(state: .blocked, ruleID: piAskUserRuleID, skip: false, visible: true)
    }

    /// The engine input is the visible screen with trailing blank rows
    /// trimmed, matching herdr's detection text semantics.
    static func detectionScreen(_ raw: String) -> String {
        let lines = rustLines(raw)
        guard
            let lastNonEmpty = lines.lastIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            })
        else { return "" }
        return lines[...lastNonEmpty].joined(separator: "\n")
    }

    /// Group agent panes into session → window → pane, preserving tmux
    /// order. Branches without agent panes never appear.
    static func buildTree(_ panes: [AgentPane]) -> [SessionNode] {
        var sessions: [SessionNode] = []
        for pane in panes {
            let sessionIndex: Int
            if let existing = sessions.firstIndex(where: { $0.name == pane.info.session }) {
                sessionIndex = existing
            } else {
                sessions.append(SessionNode(name: pane.info.session, windows: []))
                sessionIndex = sessions.count - 1
            }
            let windowIndex: Int
            if let existing = sessions[sessionIndex].windows.firstIndex(where: {
                $0.index == pane.info.windowIndex
            }) {
                windowIndex = existing
            } else {
                sessions[sessionIndex].windows.append(
                    WindowNode(index: pane.info.windowIndex, name: pane.info.windowName, panes: []))
                windowIndex = sessions[sessionIndex].windows.count - 1
            }
            sessions[sessionIndex].windows[windowIndex].panes.append(pane)
        }
        return sessions
    }
}
