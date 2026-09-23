import Foundation
import Testing

@testable import TmuxAgentWatch

private actor LaunchRecorder {
    var calls: [[String]] = []
    func record(_ arguments: [String]) { calls.append(arguments) }
}

/// Opt-in because this test creates and destroys its own tmux server. Never
/// targets the user's default socket. Fixture panes expire even if the test host
/// is killed, and normal/error paths explicitly kill only this fixture server.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TAW_RUN_ISOLATED_TMUX_TESTS"] == "1"))
func isolatedTmuxBatchMatchesIndividualScreensWithoutAttaching() async throws {
    let executable = try #require(TmuxClient.tmuxPath)
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(
        "taw-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prefix = ["-S", directory.appendingPathComponent("socket").path, "-f", "/dev/null"]
    var environment = TmuxClient.subprocessEnvironment
    environment.removeValue(forKey: "TMUX")
    let fixtureEnvironment = environment

    func command(_ arguments: [String]) async throws -> SubprocessResult {
        try await SubprocessRunner.run(
            executable, prefix + arguments, environment: fixtureEnvironment)
    }
    func requireCommand(_ arguments: [String]) async throws -> String {
        let result = try await command(arguments)
        try #require(result.exitCode == 0, "fixture tmux command failed")
        return result.stdout
    }

    do {
        let blocked =
            "Questions for you\\n\\n Enter submit • Tab/Shift+Tab navigate • Esc cancel\\n────────────────────────────────────────────────────────────────\\n"
        _ = try await requireCommand([
            "new-session", "-d", "-s", "fixture", "-x", "100", "-y", "40",
            "printf '\(blocked)'; exec /bin/sleep 30",
        ])
        _ = try await requireCommand([
            "split-window", "-d", "-t", "fixture",
            "printf 'synthetic 中文\\n%%begin 999 9 0\\n%%end 999 9 0\\n%%exit\\n'; exec /bin/sleep 30",
        ])
        _ = try await requireCommand(["set-option", "-g", "@attached-hook", "untouched"])
        _ = try await requireCommand(["set-option", "-g", "@detached-hook", "untouched"])
        _ = try await requireCommand([
            "set-hook", "-g", "client-detached", "set-option -g @detached-hook fired",
        ])
        _ = try await requireCommand([
            "set-hook", "-g", "client-attached", "set-option -g @attached-hook fired",
        ])
        // Give the synthetic shells a chance to produce their initial screens.
        try await Task.sleep(for: .milliseconds(100))
        let stateArguments = [
            "list-panes", "-a", "-F",
            "#{pane_id}:#{pane_width}:#{pane_height}:#{pane_active}:#{session_attached}",
        ]
        let before = try await requireCommand(stateArguments)
        let first = try await requireCommand(["capture-pane", "-p", "-t", "%0"])
        let second = try await requireCommand(["capture-pane", "-p", "-t", "%1"])
        #expect(first.contains("Questions for you"))
        #expect(second.contains("synthetic 中文"))

        let recorder = LaunchRecorder()
        let client = TmuxClient(
            executable: executable, globalArguments: prefix,
            run: { path, args in
                await recorder.record(args)
                return try await SubprocessRunner.run(path, args, environment: fixtureEnvironment)
            })
        let screens = try await client.capturePanes(paneIDs: ["%0", "%1"])
        #expect(screens == ["%0": first, "%1": second])
        #expect(await recorder.calls.count == 1)

        // A vanished target stops tmux's sequence. The last existing pane must
        // still be recovered, not silently dropped or assigned the wrong screen.
        let withMissing = try await client.capturePanes(paneIDs: ["%0", "%999999", "%1"])
        #expect(withMissing == screens)
        #expect(await recorder.calls.count == 3)

        // Real transport -> scanner -> detection -> state store -> UI snapshot.
        // Only agent identification is synthetic; no real agent or transcript is read.
        let store = StateStore()
        var snapshot: Snapshot = .tree([])
        for _ in 0..<3 {
            snapshot = try await Scanner.scanDebounced(
                store: store, client: client,
                identify: { _ in (.pi, "pi") })
        }
        guard case .tree(let sessions) = snapshot else {
            Issue.record("expected a fixture snapshot")
            throw TmuxUnavailable(message: "fixture snapshot missing")
        }
        let counts = StateCounts(sessions: sessions)
        #expect(counts.blocked == 1 && counts.idle == 1)
        #expect(await recorder.calls.count == 9)
        #expect(try await requireCommand(stateArguments) == before)
        #expect(try await requireCommand(["list-clients"]).isEmpty)
        #expect(
            try await requireCommand(["show-options", "-gv", "@attached-hook"]) == "untouched\n")

        #expect(
            try await requireCommand(["show-options", "-gv", "@detached-hook"]) == "untouched\n")
        _ = try await requireCommand(["kill-server"])
        let unavailable = try await client.listPanes()
        guard case .failure = unavailable else {
            Issue.record("client should not restart a missing server")
            return
        }
    } catch {
        _ = try? await command(["kill-server"])
        throw error
    }
}
