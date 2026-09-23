import Foundation
import Observation
import Testing

@testable import TmuxAgentWatch

private actor ScanGate {
    var starts = 0
    private var release: CheckedContinuation<Void, Never>?

    func scan() async -> Snapshot {
        starts += 1
        if starts == 1 {
            // Deliberately ignore cancellation to simulate in-flight cleanup.
            await withCheckedContinuation { release = $0 }
            return .tmuxUnavailable(message: "old generation")
        }
        return .tree([])
    }

    func unblock() {
        release?.resume()
        release = nil
    }
}

@Test @MainActor func restartWaitsForOldScanAndRejectsItsSnapshot() async throws {
    let gate = ScanGate()
    let model = WatchModel(interval: .seconds(60), scan: { _ in await gate.scan() })
    model.start()
    for _ in 0..<100 where await gate.starts == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await gate.starts == 1)
    model.stop()
    model.start()
    model.start()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await gate.starts == 1)
    #expect(model.snapshot == nil)
    await gate.unblock()
    defer { model.stop() }
    for _ in 0..<100 where model.snapshot == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await gate.starts == 2)
    #expect(model.snapshot == .tree([]))
}

@Test @MainActor func unchangedSnapshotDoesNotNotifyObservers() async throws {
    let model = WatchModel(interval: .milliseconds(10), scan: { _ in .tree([]) })
    model.start()
    defer { model.stop() }
    for _ in 0..<100 where model.snapshot == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.snapshot == .tree([]))
    // Observation tracking below is kept on the main actor, like production UI.
    let changed = ChangeFlag()
    withObservationTracking {
        _ = model.snapshot
    } onChange: {
        changed.mark()
    }
    try await Task.sleep(for: .milliseconds(70))
    #expect(!changed.value)
}

nonisolated private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func mark() { lock.withLock { storage = true } }
}
