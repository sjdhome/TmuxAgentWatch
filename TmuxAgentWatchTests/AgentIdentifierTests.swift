//
//  AgentIdentifierTests.swift
//  TmuxAgentWatchTests
//
//  Ported from tmux-agent-watch's src/detect/mod.rs and
//  src/platform/macos.rs tests.
//

import Foundation
import Testing

@testable import TmuxAgentWatch

private func foregroundProcess(_ pid: UInt32, _ name: String, _ argv: [String])
    -> ForegroundProcess
{
    ForegroundProcess(
        pid: pid, name: name, argv0: nil, argv: argv, cmdline: argv.joined(separator: " "))
}

@Test func identifiesKnownAgentsAndAliases() {
    #expect(Agent.parse(label: "claude") == .claude)
    #expect(Agent.parse(label: "claude-code") == .claude)
    #expect(Agent.parse(label: "CLAUDE") == .claude)
    #expect(Agent.parse(label: "cursor-agent") == .cursor)
    #expect(Agent.parse(label: "ghcs") == .githubCopilot)
    #expect(Agent.parse(label: "opencode.exe") == .openCode)
    #expect(Agent.parse(label: "opencode2") == .openCode)
    #expect(Agent.parse(label: "kiro-cli") == .kiro)
    #expect(Agent.parse(label: "qwen") == .qwen)
    #expect(Agent.parse(label: "Qwen Code") == .qwen)
    #expect(Agent.parse(label: "bash") == nil)
    #expect(Agent.parse(label: "vim") == nil)
    #expect(Agent.parse(label: "node") == nil)
}

@Test func prefersWrappedAgentOverShell() {
    let job = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(1, "node", ["node", "/path/to/bin/codex"]),
            foregroundProcess(2, "bash", ["bash"]),
        ])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .codex)
    #expect(found?.1 == "codex")
}

@Test func prefersRecognizedProcessGroupLeader() {
    let job = ForegroundJob(
        processGroupID: 42,
        processes: [
            foregroundProcess(42, "claude", ["claude"]),
            foregroundProcess(43, "node", ["node", "/tmp/mcp/bin/codex"]),
        ])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .claude)
    #expect(found?.1 == "claude")
}

@Test func evalArgumentsAreNotAgents() {
    var job = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(
                1, "python3", ["python3", "-c", "import time; time.sleep(60)", "/tmp/codex"])
        ])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil)

    job = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(1, "node", ["node", "-e", "setTimeout(() => {}, 60000)", "/tmp/codex"])
        ])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil)
}

@Test func shellWrappedScriptIsDetected() {
    let job = ForegroundJob(
        processGroupID: 123,
        processes: [foregroundProcess(1, "sh", ["/bin/sh", "/tmp/test-bin/pi"])])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .pi)
    #expect(found?.1 == "pi")
}

@Test func piPackageCliPathIsDetected() {
    let job = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(
                123, "node",
                [
                    "node",
                    "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
                ])
        ])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .pi)
    #expect(found?.1 == "pi")
}

@Test func versionedPythonWrapperIsDetected() {
    let job = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(1, "python3.12", ["python3.12", "/usr/local/bin/hermes"])
        ])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .hermes)
    #expect(found?.1 == "hermes")
}

@Test func qwenPackageEntrypointIsDetected() {
    let job = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(
                123, "node",
                ["node", "/usr/local/lib/node_modules/@qwen-code/qwen-code/dist/index.js"])
        ])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .qwen)
    #expect(found?.1 == "qwen")
}

@Test func qwenNodeEntrypointWithNonGenericTitleIsDetected() {
    // Qwen never rewrites its process title; identification must fall back
    // to the node script argument even when argv0 is not a runtime name.
    let process = ForegroundProcess(
        pid: 7, name: "node", argv0: "index.js",
        argv: ["node", "/usr/lib/node_modules/@qwen-code/qwen-code/dist/index.js"],
        cmdline: nil)
    let job = ForegroundJob(processGroupID: 7, processes: [process])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .qwen)
    #expect(found?.1 == "qwen")
}

@Test func plainShellJobIsNotAnAgent() {
    let job = ForegroundJob(
        processGroupID: 9, processes: [foregroundProcess(9, "zsh", ["-zsh"])])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil)
}

@Test func everyAgentWithManifestHasMatchingLabel() {
    #expect(Agent.claude.manifestID == "claude")
    #expect(Agent.githubCopilot.manifestID == "copilot")
    #expect(Agent.antigravity.manifestID == "agy")
    #expect(Agent.omp.manifestID == nil)
    #expect(Agent.mastracode.manifestID == nil)
}

// MARK: - KERN_PROCARGS2 parsing

private func procargs2Buffer(_ argc: Int32, _ execPath: String, _ strings: [String]) -> [UInt8] {
    var buffer = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
    buffer.append(contentsOf: Array(execPath.utf8))
    buffer.append(contentsOf: [0, 0, 0])  // terminator + padding
    for string in strings {
        buffer.append(contentsOf: Array(string.utf8))
        buffer.append(0)
    }
    return buffer
}

@Test func parsesArgvFromProcargs2Layout() {
    let buffer = procargs2Buffer(3, "/usr/bin/node", ["node", "/path/to/codex", "--flag"])
    #expect(
        ProcessInspector.parseProcargs2Argv(buffer) == ["node", "/path/to/codex", "--flag"])
}

@Test func rejectsShortOrEmptyBuffers() {
    #expect(ProcessInspector.parseProcargs2Argv([]) == nil)
    let zeroArgc = withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }
    #expect(ProcessInspector.parseProcargs2Argv(zeroArgc) == nil)
}
