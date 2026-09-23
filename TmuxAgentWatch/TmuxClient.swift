// The tmux boundary. Polling uses only list-panes and capture-pane; navigation
// additionally uses list-clients and user-initiated select-window/select-pane.
// Control mode is short-lived and never attaches or creates a session.

import Foundation

nonisolated struct PaneInfo: Sendable, Equatable {
    var session: String
    var windowIndex: UInt32
    var windowName: String
    var paneID: String
    var panePid: UInt32
    var paneTitle: String
    /// Cheap hint only; PID-based identification stays authoritative.
    var currentCommand: String
}

nonisolated struct TmuxClientInfo: Sendable, Equatable {
    var pid: UInt32
    var tty: String
    var session: String
}

nonisolated struct TmuxUnavailable: Error, Sendable {
    var message: String
}

/// One scanner owns one client, including its compatibility fallback decision.
/// There is no resident tmux process. Calls run through a bounded subprocess port.
actor TmuxClient {
    typealias Run = @Sendable (String, [String]) async throws -> SubprocessResult
    private let executable: String?
    private let globalArguments: [String]
    private let run: Run
    private var supportsBatch = true
    private static let batchSize = 32
    private static let listPanesFormat =
        "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{pane_pid}\t#{pane_title}\t#{pane_current_command}"

    nonisolated static let tmuxPath: String? = {
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/tmux" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// GUI launches often lack a UTF-8 locale, which otherwise makes tmux
    /// sanitize tabs and non-ASCII titles, breaking field parsing.
    nonisolated static let subprocessEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let locales = [environment["LC_ALL"], environment["LC_CTYPE"], environment["LANG"]]
            .compactMap { $0 }
        if !locales.contains(where: { $0.uppercased().contains("UTF-8") }) {
            environment["LC_CTYPE"] = "en_US.UTF-8"
        }
        return environment
    }()

    init(
        executable: String? = TmuxClient.tmuxPath, globalArguments: [String] = [],
        run: @escaping Run = { path, arguments in
            try await SubprocessRunner.run(
                path, arguments, environment: TmuxClient.subprocessEnvironment)
        }
    ) {
        self.executable = executable
        self.globalArguments = globalArguments
        self.run = run
    }

    private func execute(_ arguments: [String]) async throws -> SubprocessResult {
        try Task.checkCancellation()
        guard let executable else { throw TmuxUnavailable(message: "tmux binary not found") }
        return try await run(executable, globalArguments + arguments)
    }

    func listPanes() async throws -> Result<[PaneInfo], TmuxUnavailable> {
        do {
            let result = try await execute(["list-panes", "-a", "-F", Self.listPanesFormat])
            guard result.exitCode == 0 else {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(
                    TmuxUnavailable(
                        message: message.isEmpty ? "tmux exited with \(result.exitCode)" : message))
            }
            return .success(Self.parseListPanes(result.stdout))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TmuxUnavailable {
            return .failure(error)
        } catch {
            return .failure(TmuxUnavailable(message: "failed to query tmux: \(error)"))
        }
    }

    /// Normal case: one process for up to 32 screens. A failed target aborts
    /// tmux's command queue; preserve completed blocks and retry only the
    /// unexecuted suffix. Each retry consumes at least one requested target.
    func capturePanes(paneIDs: [String]) async throws -> [String: String] {
        // Linked windows can report the same pane in multiple sessions.
        var seen: Set<String> = []
        let ids = paneIDs.filter { seen.insert($0).inserted }
        guard ids.allSatisfy(Self.isPaneID) else {
            throw TmuxUnavailable(message: "invalid pane ID")
        }
        var screens: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            var remaining = Array(ids[start..<min(start + Self.batchSize, ids.count)])
            while !remaining.isEmpty {
                try Task.checkCancellation()
                if !supportsBatch {
                    for id in remaining {
                        let result = try await execute(["capture-pane", "-p", "-t", id])
                        if result.exitCode == 0 { screens[id] = result.stdout }
                    }
                    break
                }
                var arguments = ["-N", "-C"]
                for (index, id) in remaining.enumerated() {
                    if index > 0 { arguments.append(";") }
                    arguments += ["capture-pane", "-p", "-t", id]
                }
                let result = try await execute(arguments)
                guard let blocks = ControlModeOutput.parse(result.stdout),
                    blocks.count <= remaining.count,
                    blocks.dropLast().allSatisfy({
                        if case .output = $0 { return true }
                        return false
                    }),
                    (result.exitCode == 0 && blocks.count == remaining.count
                        && blocks.last != .failure)
                        || (result.exitCode != 0 && blocks.last == .failure)
                else {
                    // Remember incompatibility for this scanner lifetime; do not
                    // pay for a failed capability probe every two seconds.
                    supportsBatch = false
                    NSLog("tmux batch framing unavailable; using individual captures")
                    continue
                }
                for (id, block) in zip(remaining, blocks) {
                    if case .output(let screen) = block { screens[id] = screen }
                }
                remaining.removeFirst(blocks.count)
            }
        }
        return screens
    }

    nonisolated private static func isPaneID(_ value: String) -> Bool {
        value.first == "%" && value.count > 1
            && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Navigation is rare and intentionally stays separate from polling.
    static func listClients() async -> [TmuxClientInfo] {
        guard
            let result = try? await TmuxClient().execute(
                ["list-clients", "-F", "#{client_pid}\t#{client_tty}\t#{client_session}"]),
            result.exitCode == 0
        else { return [] }
        return rustLines(result.stdout).compactMap { parseClientLine(String($0)) }
    }

    @discardableResult
    static func selectPane(paneID: String) async -> Bool {
        guard isPaneID(paneID),
            let result = try? await TmuxClient().execute(
                ["select-window", "-t", paneID, ";", "select-pane", "-t", paneID])
        else { return false }
        return result.exitCode == 0
    }

    nonisolated static func parseListPanes(_ stdout: String) -> [PaneInfo] {
        rustLines(stdout).compactMap { parsePaneLine(String($0)) }
    }

    nonisolated static func parsePaneLine(_ line: String) -> PaneInfo? {
        let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
        guard fields.count == 7,
            let windowIndex = UInt32(fields[1]), let panePid = UInt32(fields[4])
        else { return nil }
        return PaneInfo(
            session: String(fields[0]), windowIndex: windowIndex, windowName: String(fields[2]),
            paneID: String(fields[3]), panePid: panePid, paneTitle: String(fields[5]),
            currentCommand: String(fields[6]))
    }

    nonisolated static func parseClientLine(_ line: String) -> TmuxClientInfo? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let pid = UInt32(fields[0]) else { return nil }
        return TmuxClientInfo(pid: pid, tty: String(fields[1]), session: String(fields[2]))
    }
}
