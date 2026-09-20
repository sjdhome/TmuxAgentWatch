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

// MARK: - Herdr 4b5e9bda identification regressions

@Test(arguments: [
    "muse", "muse-code", "muse-cli", "muse-bin-0.1.0-R708.1", "muse-bin-1.2.3",
    "/home/user/.local/bin/muse-bin-0.2.1-R1215.1",
    #"C:\Users\user\muse-bin-0.2.1-R1215.1.exe"#,
])
func museLaunchersAreDetected(_ label: String) {
    #expect(Agent.parse(label: label) == .muse)
    let process = ForegroundProcess(
        pid: 123, name: "muse-bin-0.2.1", argv0: label, argv: [label], cmdline: label)
    let job = ForegroundJob(processGroupID: 123, processes: [process])
    #expect(AgentIdentifier.identifyAgent(in: job)?.0 == .muse)
}

@Test(arguments: [
    "museum", "muse-helper", "muser", "musescore", "muse-bin", "muse-bin-",
    "muse-binary", "muse-bin-preview", "muse-bin-１.0",
])
func unrelatedMuseNamesAreIgnored(_ label: String) {
    #expect(Agent.parse(label: label) == nil)
}

@Test func pathQualifiedAgentLabelsAreDetected() {
    #expect(Agent.parse(label: "/usr/local/bin/claude") == .claude)
    #expect(Agent.parse(label: #"C:\tools\CODEX.EXE"#) == .codex)
    #expect(Agent.parse(label: "/tmp/claude/helper") == nil)
}

@Test(arguments: [
    "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
    #"C:\Users\user\pi-node\current/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"#,
    "/opt/NODE_MODULES/@EARENDIL-WORKS/PI-CODING-AGENT/DIST/BUNDLE/CLI.JS",
])
func piBundledEntrypointIsDetected(_ script: String) {
    let job = ForegroundJob(
        processGroupID: 123,
        processes: [foregroundProcess(123, "node", ["/usr/local/bin/node", script])])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .pi)
    #expect(found?.1 == "pi")
}

@Test(arguments: [
    "/tmp/node_modules/@earendil-works/pi-coding-agent/scripts/build.js",
    "/tmp/node_modules/@earendil-works/pi-coding-agent/dist/bundle/update.js",
    "/tmp/dist/bundle/cli.js",
    "/tmp/node_modules/other-package/dist/bundle/cli.js",
    "/tmp/node_modules/@earendil-works/pi-coding-agent/dist/cli.exe",
    "/tmp/node_modules/@earendil-works/pi-coding-agent/dist/cli.js/other.js",
    "/tmp/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.exe",
    "/tmp/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js/other.js",
])
func nonEntrypointPiPathsAreIgnored(_ script: String) {
    let job = ForegroundJob(
        processGroupID: 123, processes: [foregroundProcess(123, "node", ["node", script])])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil)
}

// MARK: - Herdr d59d0603 identification regressions

@Test(arguments: [
    (".cline", "/home/user/.npm/lib/node_modules/cline/bin/.cline"),
    ("cline", "/usr/local/lib/node_modules/@cline/cli-darwin-arm64/bin/cline"),
])
func clineNativeBinariesAreDetected(_ name: String, _ executable: String) {
    let job = ForegroundJob(
        processGroupID: 123, processes: [foregroundProcess(123, name, [executable, "--tui"])])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .cline)
    #expect(found?.1 == name)
}

@Test(arguments: [
    ("MainThread", ["node", "/home/user/.fnm/bin/cline", "--tui"]),
    ("node", ["node", "/usr/local/lib/node_modules/cline/bin/cline"]),
])
func clineNodeWrapperIsDetected(_ name: String, _ argv: [String]) {
    let job = ForegroundJob(processGroupID: 123, processes: [foregroundProcess(123, name, argv)])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .cline)
    #expect(found?.1 == "cline")
}

@Test(arguments: [
    ["node"],
    ["node", "/path/to/other.js", "cline"],
    ["node", "-e", "cline"],
    ["node", "/path/to/cline-helper"],
    ["/path/to/.cline-helper"],
    ["/path/to/other", "/path/to/cline"],
])
func unrelatedClineMentionsAreIgnored(_ argv: [String]) {
    let job = ForegroundJob(
        processGroupID: 123, processes: [foregroundProcess(123, "MainThread", argv)])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil)
    #expect(Agent.parse(label: "MainThread") == nil)
}

@Test func kimiPackageEntrypointIsDetected() {
    let script = "/usr/local/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"
    let job = ForegroundJob(
        processGroupID: 123, processes: [foregroundProcess(123, "node", ["node", script])])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .kimi)
    #expect(found?.1 == "kimi")

    let helper = ForegroundJob(
        processGroupID: 123,
        processes: [
            foregroundProcess(
                123, "node", ["node", "/tmp/node_modules/@moonshot-ai/kimi-code/dist/worker.mjs"])
        ])
    #expect(AgentIdentifier.identifyAgent(in: helper) == nil)
}

@Test func lettaLabelsAreDetected() {
    #expect(Agent.parse(label: "letta") == .letta)
    #expect(Agent.parse(label: "Letta Code") == .letta)
    #expect(Agent.parse(label: "letta-code") == .letta)
    #expect(Agent.letta.manifestID == "letta")
}

@Test(arguments: [
    ["letta", "--backend", "local"],
    ["node", "/home/user/project/node_modules/.bin/letta", "--conversation", "conversation-id"],
    [
        "node.exe",
        #"C:\Users\user\AppData\Roaming\npm\node_modules\@letta-ai\letta-code\letta.js"#,
        "--agent", "agent-id",
    ],
])
func interactiveLettaEntrypointsAreDetected(_ argv: [String]) {
    let job = ForegroundJob(
        processGroupID: 123, processes: [foregroundProcess(123, "MainThread", argv)])
    let found = AgentIdentifier.identifyAgent(in: job)
    #expect(found?.0 == .letta)
    #expect(found?.1 == "letta")
}

@Test(arguments: [
    ["--prompt", "hello"],
    ["--output-format", "json"],
    ["--input-format=stream-json"],
    ["--ephemeral"],
    ["--max-turns=1"],
    ["server"],
    ["--backend", "local", "server"],
    ["fix this bug"],
    ["agents", "list"],
    ["version"],
])
func nonInteractiveLettaProcessesAreIgnored(_ args: [String]) {
    let argv = ["node", "/home/user/project/node_modules/.bin/letta"] + args
    let job = ForegroundJob(
        processGroupID: 123, processes: [foregroundProcess(123, "MainThread", argv)])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil, "argv: \(argv)")
}

@Test(arguments: [
    ["node", "/tmp/server.js", "letta"],
    ["node", "/home/user/src/letta-code/letta/build.js"],
])
func unrelatedLettaMentionsAreIgnored(_ argv: [String]) {
    let job = ForegroundJob(processGroupID: 123, processes: [foregroundProcess(123, "node", argv)])
    #expect(AgentIdentifier.identifyAgent(in: job) == nil)
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
