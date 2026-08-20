//
//  ContentView.swift
//  TmuxAgentWatch
//
//  Created by sjdhome on 2026/8/20.
//

import SwiftUI

struct ContentView: View {
    @State private var model = WatchModel()
    @State private var selection: AgentPane.ID?
    @AppStorage("paneSortOrder") private var sortOrder: PaneSortOrder = .state

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Tmux Agent Watch")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        Text("State").tag(PaneSortOrder.state)
                        Text("Name").tag(PaneSortOrder.name)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Change how agents are sorted")
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var subtitle: String {
        guard case .tree(let sessions)? = model.snapshot else { return "" }
        let counts = StateCounts(sessions: sessions)
        return String(
            localized: "\(counts.blocked) blocked · \(counts.working) working · \(counts.idle) idle"
        )
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch model.snapshot {
        case nil:
            ProgressView("Scanning…")
        case .tmuxUnavailable(let message):
            ContentUnavailableView {
                Label("tmux Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
                Text("Retrying every 2 seconds.")
            }
        case .tree(let sessions) where sessions.isEmpty:
            ContentUnavailableView {
                Label("No Agent Panes", systemImage: "rectangle.dashed")
            } description: {
                Text("No tmux pane is currently running a known AI coding agent.")
            }
        case .tree(let sessions):
            paneList(sessions, now: now)
        }
    }

    private func paneList(_ sessions: [SessionNode], now: Date) -> some View {
        let panes = sortPanes(flattenPanes(sessions), by: sortOrder)
        return List(selection: $selection) {
            ForEach(panes) { pane in
                PaneRow(pane: pane, now: now)
                    // Fix the row height so the alternating stripes drawn
                    // below the content share the same rhythm (they are
                    // sized by defaultMinListRowHeight, not by the rows).
                    .frame(height: PaneRow.rowHeight)
                    .listRowInsets(
                        EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                    .accessibilityIdentifier("pane-row")
                    .tag(pane.id)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, PaneRow.rowHeight)
        // primaryAction is the list's native row activation: double-click.
        .contextMenu(forSelectionType: AgentPane.ID.self) { ids in
            if !ids.isEmpty {
                Button("Show in Terminal") { jump(toID: ids.first, in: panes) }
            }
        } primaryAction: { ids in
            jump(toID: ids.first, in: panes)
        }
        // Return activates the selected row, like Finder.
        .onKeyPress(.return) {
            guard selection != nil else { return .ignored }
            jump(toID: selection, in: panes)
            return .handled
        }
    }

    private func jump(toID id: AgentPane.ID?, in panes: [AgentPane]) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        selection = pane.id
        let session = pane.info.session
        let paneID = pane.info.paneID
        Task { await PaneJump.reveal(session: session, paneID: paneID) }
    }
}

/// One agent process. The pane's terminal title leads, the tmux window
/// context comes second, and the agent identity is a small tag; state and
/// time in state sit on the trailing side.
private struct PaneRow: View {
    static let rowHeight: CGFloat = 44

    let pane: AgentPane
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateTint)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pane.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(pane.agent.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Text(pane.info.paneID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text(windowContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(stateName)
                    .fontWeight(pane.detection.state == .blocked ? .semibold : .regular)
                    .foregroundStyle(stateLabelStyle)
                Text(formatStateDuration(now.timeIntervalSince(pane.stateSince)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var windowContext: String {
        "\(pane.info.session) › \(pane.info.windowIndex): \(pane.info.windowName)"
    }

    private var stateName: LocalizedStringKey {
        switch pane.detection.state {
        case .blocked: return "blocked"
        case .working: return "working"
        case .idle, .unknown: return "idle"
        }
    }

    private var stateTint: Color {
        switch pane.detection.state {
        case .blocked: return .red
        case .working: return .green
        case .idle, .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var stateLabelStyle: Color {
        switch pane.detection.state {
        case .blocked: return .red
        case .working: return .green
        case .idle, .unknown: return .secondary
        }
    }
}

/// Compact elapsed time via the system's localized duration formatting
/// (e.g. "45s", "1h 5m" in English; localized unit names elsewhere).
nonisolated func formatStateDuration(
    _ interval: TimeInterval, locale: Locale = .current
) -> String {
    Duration.seconds(max(0, interval)).formatted(
        .units(
            allowed: [.days, .hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 2
        )
        .locale(locale))
}

#Preview {
    ContentView()
}
