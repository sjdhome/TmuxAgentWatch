import Foundation
import Observation

@MainActor
@Observable
final class WatchModel {
    nonisolated static let pollInterval: Duration = .seconds(2)
    typealias Scan = @Sendable (StateStore) async throws -> Snapshot

    private(set) var snapshot: Snapshot?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let scan: Scan
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = WatchModel.pollInterval, scan: Scan? = nil) {
        self.interval = interval
        let client = TmuxClient()
        self.scan =
            scan ?? { store in try await Scanner.scanDebounced(store: store, client: client) }
    }

    func start() {
        if let scanTask, !scanTask.isCancelled { return }
        let previous = scanTask
        generation &+= 1
        let generation = generation
        let scan = scan
        let interval = interval
        scanTask = Task.detached(priority: .utility) { [weak self] in
            // A reopened window waits for cancellation/reaping of the old child.
            // It never starts a second scan while the old one is still stopping.
            await previous?.value
            let store = StateStore()
            while !Task.isCancelled {
                let snapshot: Snapshot
                do {
                    let scanned = try await scan(store)
                    try Task.checkCancellation()
                    snapshot = scanned
                } catch is CancellationError {
                    return
                } catch {
                    snapshot = .tmuxUnavailable(message: "failed to scan tmux: \(error)")
                }
                guard !Task.isCancelled,
                    await self?.publish(snapshot, generation: generation) == true
                else { return }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() {
        generation &+= 1
        scanTask?.cancel()
        // Retain the task until the next start can await its cleanup.
    }

    private func publish(_ snapshot: Snapshot, generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        if self.snapshot != snapshot { self.snapshot = snapshot }
        return true
    }
}
