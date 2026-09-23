import Foundation
import Testing

@testable import TmuxAgentWatch

nonisolated private func framed(_ values: [String?]) -> String {
    values.enumerated().map { index, value in
        let id = "123 \(index + 1) 0"
        return "%begin \(id)\n" + (value ?? "missing pane\n")
            + (value == nil ? "%error \(id)\n" : "%end \(id)\n")
    }.joined() + "%exit\n"
}

@Test func controlBlocksPreserveScreensAndGuardLikePayload() {
    let screen = "synthetic 中文\n%begin 999 9 0\n%end 999 9 0\n%exit\n\n"
    #expect(
        ControlModeOutput.parse(framed([screen, "", nil])) == [
            .output(screen), .output(""), .failure,
        ])
}

@Test(arguments: [
    "", "%exit\n", "%begin 1 2 0\nbody\n", "%begin 1 2 0\n%end 1 3 0\n%exit\n",
    "%begin 1 2 0\n%end 1 2 0\n", "%begin x 2 0\n%end x 2 0\n%exit\n",
    "%begin 1 2 0\n%end 1 2 0\n%exit\nextra\n",
])
func malformedControlBlocksAreRejected(_ output: String) {
    #expect(ControlModeOutput.parse(output) == nil)
}

private actor CaptureFixture {
    var calls: [[String]] = []
    var malformed = false
    var missing: Set<String> = []

    init(malformed: Bool = false, missing: Set<String> = []) {
        self.malformed = malformed
        self.missing = missing
    }

    func run(_ path: String, _ args: [String]) throws -> SubprocessResult {
        calls.append(args)
        if args.contains("list-panes") {
            return SubprocessResult(exitCode: 0, stdout: "s\t0\tw\t%0\t1\tt\tpi\n", stderr: "")
        }
        let ids = args.indices.filter { args[$0] == "-t" }.map { args[$0 + 1] }
        if args.contains("-C") {
            if malformed { return SubprocessResult(exitCode: 1, stdout: "", stderr: "unsupported") }
            var outputs: [String?] = []
            for id in ids {
                if missing.contains(id) {
                    outputs.append(nil)
                    break
                }
                outputs.append("screen \(id)\n")
            }
            return SubprocessResult(
                exitCode: outputs.last! == nil ? 1 : 0, stdout: framed(outputs), stderr: "")
        }
        return SubprocessResult(exitCode: 0, stdout: "plain \(ids[0])\n", stderr: "")
    }
}

@Test func normalPollUsesTwoChildrenAndDeduplicatesLinkedPanes() async throws {
    let fixture = CaptureFixture()
    let client = TmuxClient(executable: "/fixture", run: { try await fixture.run($0, $1) })
    _ = try await client.listPanes()
    let screens = try await client.capturePanes(paneIDs: ["%0", "%1", "%0"])
    #expect(screens == ["%0": "screen %0\n", "%1": "screen %1\n"])
    let calls = await fixture.calls
    #expect(calls.count == 2)
    #expect(
        calls[1] == [
            "-N", "-C", "capture-pane", "-p", "-t", "%0", ";", "capture-pane", "-p", "-t", "%1",
        ])
}

@Test func failedPaneRetriesOnlyUnexecutedSuffix() async throws {
    let fixture = CaptureFixture(missing: ["%1", "%2"])
    let client = TmuxClient(executable: "/fixture", run: { try await fixture.run($0, $1) })
    let screens = try await client.capturePanes(paneIDs: ["%0", "%1", "%2", "%3"])
    #expect(screens == ["%0": "screen %0\n", "%3": "screen %3\n"])
    let calls = await fixture.calls
    #expect(calls.count == 3)
    #expect(!calls[1].contains("%0") && !calls[1].contains("%1"))
    #expect(calls[2].last == "%3")
}

@Test func unsupportedFramingFallsBackOnlyOncePerClient() async throws {
    let fixture = CaptureFixture(malformed: true)
    let client = TmuxClient(executable: "/fixture", run: { try await fixture.run($0, $1) })
    #expect(
        try await client.capturePanes(paneIDs: ["%0", "%1"]) == [
            "%0": "plain %0\n", "%1": "plain %1\n",
        ])
    _ = try await client.capturePanes(paneIDs: ["%0"])
    let calls = await fixture.calls
    #expect(calls.count == 4)
    #expect(calls.filter { $0.contains("-C") }.count == 1)
}

@Test func emptyAndLargePaneSetsHaveBoundedLaunchCounts() async throws {
    let fixture = CaptureFixture()
    let client = TmuxClient(executable: "/fixture", run: { try await fixture.run($0, $1) })
    #expect(try await client.capturePanes(paneIDs: []).isEmpty)
    #expect(await fixture.calls.isEmpty)
    let screens = try await client.capturePanes(paneIDs: (0..<65).map { "%\($0)" })
    #expect(screens.count == 65)
    #expect(await fixture.calls.count == 3)
}

@Test func failedExecutionDoesNotTriggerExpensiveFallback() async {
    let client = TmuxClient(
        executable: "/fixture", run: { _, _ in throw SubprocessFailure.timedOut })
    await #expect(throws: SubprocessFailure.timedOut) {
        try await client.capturePanes(paneIDs: ["%0"])
    }
}

@Test func invalidTargetCannotEnterTmuxCommandParser() async {
    let fixture = CaptureFixture()
    let client = TmuxClient(executable: "/fixture", run: { try await fixture.run($0, $1) })
    await #expect(throws: TmuxUnavailable.self) {
        try await client.capturePanes(paneIDs: ["%0; new-session"])
    }
    #expect(await fixture.calls.isEmpty)
}

@Test func argvAndEffectiveNameShareOneBufferWithoutLosingPartialNames() {
    var argc: Int32 = 2
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/bin/zsh\0\0-zsh\0arg\0".utf8)
    #expect(ProcessInspector.parseProcargs2Argv(bytes) == ["-zsh", "arg"])
    #expect(ProcessInspector.parseProcargs2Argv0(bytes) == "zsh")
    let partial = Array(bytes.dropLast(4))
    #expect(ProcessInspector.parseProcargs2Argv(partial) == nil)
    #expect(ProcessInspector.parseProcargs2Argv0(partial) == "zsh")
}

@Test func hostedTestsDisableAutomaticScanning() {
    #expect(ProcessInfo.processInfo.environment["TAW_DISABLE_SCANNING"] == "1")
}
