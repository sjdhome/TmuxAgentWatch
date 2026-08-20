//
//  TmuxClient.swift
//  TmuxAgentWatch
//
//  The single tmux boundary of the program, ported from tmux-agent-watch's
//  src/tmux.rs.
//
//  Only read-only tmux verbs (`list-panes`, `capture-pane`) may ever appear
//  in this file. The app must never send control commands to tmux.
//

import Foundation

/// One tmux pane as reported by `list-panes -a`.
nonisolated struct PaneInfo: Sendable, Equatable {
    var session: String
    var windowIndex: UInt32
    var windowName: String
    /// Stable pane id, e.g. "%3". Used as the tracking key.
    var paneID: String
    var panePid: UInt32
    /// Maps to the detection engine's `osc_title` input.
    var paneTitle: String
    /// Cheap hint only; pid-based identification stays authoritative.
    var currentCommand: String
}

/// tmux could not be queried (server not running, binary missing, ...).
nonisolated struct TmuxUnavailable: Error, Sendable {
    var message: String
}

nonisolated enum TmuxClient {
    private static let listPanesFormat =
        "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{pane_pid}\t#{pane_title}\t#{pane_current_command}"

    /// GUI apps inherit a minimal PATH, so the tmux binary is resolved from
    /// the usual install locations plus whatever PATH does carry.
    static let tmuxPath: String? = {
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/tmux" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func listPanes() -> Result<[PaneInfo], TmuxUnavailable> {
        guard let tmuxPath else {
            return .failure(TmuxUnavailable(message: "tmux binary not found"))
        }
        let result: SubprocessResult
        do {
            result = try runSubprocess(tmuxPath, ["list-panes", "-a", "-F", listPanesFormat])
        } catch {
            return .failure(TmuxUnavailable(message: "failed to run tmux: \(error.localizedDescription)"))
        }

        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? "tmux exited with \(result.exitCode)" : stderr
            return .failure(TmuxUnavailable(message: message))
        }

        return .success(parseListPanes(result.stdout))
    }

    /// Visible screen text of a pane. `nil` when the pane vanished between
    /// `list-panes` and the capture, or capture failed for any other reason.
    static func capturePane(paneID: String) -> String? {
        guard let tmuxPath,
            let result = try? runSubprocess(tmuxPath, ["capture-pane", "-p", "-t", paneID]),
            result.exitCode == 0
        else { return nil }
        return result.stdout
    }

    static func parseListPanes(_ stdout: String) -> [PaneInfo] {
        rustLines(stdout).compactMap { parsePaneLine(String($0)) }
    }

    /// Parse one `list-panes` line. Session/window names cannot contain tabs,
    /// and the title is the second-to-last field, so a fixed 7-way split is
    /// safe; malformed lines are skipped rather than aborting the cycle.
    static func parsePaneLine(_ line: String) -> PaneInfo? {
        let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
        guard fields.count == 7,
            let windowIndex = UInt32(fields[1]),
            let panePid = UInt32(fields[4])
        else { return nil }
        return PaneInfo(
            session: String(fields[0]),
            windowIndex: windowIndex,
            windowName: String(fields[2]),
            paneID: String(fields[3]),
            panePid: panePid,
            paneTitle: String(fields[5]),
            currentCommand: String(fields[6]))
    }

    // MARK: - Subprocess plumbing

    private struct SubprocessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static func runSubprocess(_ path: String, _ arguments: [String]) throws
        -> SubprocessResult
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // GUI apps launch without a UTF-8 locale; tmux then sanitizes tabs
        // and non-ASCII characters in format output to "_", breaking both
        // field splitting and pane titles.
        var environment = ProcessInfo.processInfo.environment
        let localeValues = [
            environment["LC_ALL"], environment["LC_CTYPE"], environment["LANG"],
        ].compactMap { $0 }
        if !localeValues.contains(where: { $0.uppercased().contains("UTF-8") }) {
            environment["LC_CTYPE"] = "en_US.UTF-8"
        }
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Drain both pipes before waiting so large output cannot deadlock.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return SubprocessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self))
    }
}
