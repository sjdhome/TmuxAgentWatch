import Darwin
import Foundation
import Testing

@testable import TmuxAgentWatch

@Test func subprocessDrainsBothPipesBeyondPipeCapacity() async throws {
    let result = try await SubprocessRunner.run(
        "/usr/bin/awk",
        [
            "BEGIN { for (i=0; i<20000; i++) { print \"stdout\"; print \"stderr\" > \"/dev/stderr\" } }"
        ])
    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == 140000)
    #expect(result.stderr.utf8.count == 140000)
}

@Test func subprocessPreservesUnicodeAndNonzeroExit() async throws {
    let result = try await SubprocessRunner.run(
        "/bin/sh", ["-c", "printf 'synthetic 中文\\n'; printf 'failure\\n' >&2; exit 7"])
    #expect(result.exitCode == 7)
    #expect(result.stdout == "synthetic 中文\n")
    #expect(result.stderr == "failure\n")
}

@Test func subprocessEnforcesCombinedOutputLimit() async {
    await #expect(throws: SubprocessFailure.outputLimitExceeded) {
        try await SubprocessRunner.run(
            "/usr/bin/awk", ["BEGIN { for (i=0; i<10000; i++) print \"payload\" }"],
            outputLimit: 1024)
    }
}

@Test func subprocessReapsTermIgnoringChildOnTimeout() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "taw-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect(throws: SubprocessFailure.timedOut) {
        try await SubprocessRunner.run(
            "/bin/sh", ["-c", "echo $$ > '\(file.path)'; trap '' TERM; exec /bin/sleep 10"],
            timeout: 0.3)
    }
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    let pid = try #require(Int32(text))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test func subprocessCancellationReapsChild() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "taw-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    let task = Task.detached {
        try await SubprocessRunner.run(
            "/bin/sh", ["-c", "echo $$ > '\(file.path)'; exec /bin/sleep 10"])
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    let pid = try #require(Int32(text))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test func cancellingBeforeLaunchNeverRunsTheCommand() async throws {
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SubprocessRunner.run("/usr/bin/true", [])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func missingExecutableReturnsWithoutHanging() async {
    await #expect(throws: (any Error).self) {
        try await SubprocessRunner.run("/nonexistent/taw-test-executable", [])
    }
}
