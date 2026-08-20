//
//  WatchModel.swift
//  TmuxAgentWatch
//
//  Owns the background scan loop and publishes snapshots to the UI, taking
//  the role of tmux-agent-watch's scanner thread + mpsc channel.
//

import Foundation
import Observation

@MainActor
@Observable
final class WatchModel {
    static let pollInterval: Duration = .seconds(2)

    private(set) var snapshot: Snapshot?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Start the poll loop; safe to call repeatedly.
    func start() {
        guard scanTask == nil else { return }
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let store = StateStore()
            while !Task.isCancelled {
                let snapshot = Scanner.scanDebounced(store: store)
                guard let self else { return }
                await self.publish(snapshot)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func publish(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}
