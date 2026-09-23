//
//  ProcessInspector.swift
//  TmuxAgentWatch
//
//  macOS foreground-process discovery, ported from tmux-agent-watch's
//  src/platform/macos.rs (in turn from herdr, Apache-2.0; see NOTICE).
//
//  Everything here is PID-based (`proc_pidinfo`, `proc_listpids`,
//  `sysctl(KERN_PROCARGS2)`) and works for same-uid processes without owning
//  the pane's PTY, so a tmux `#{pane_pid}` is a sufficient starting point.
//

import Darwin
import Foundation

/// One process inside a pane's foreground job.
nonisolated struct ForegroundProcess: Sendable, Equatable {
    var pid: UInt32
    /// Kernel-reported command name (`pbi_comm`, truncated to 16 bytes).
    var name: String
    /// Basename of argv[0]; reflects runtime title changes.
    var argv0: String?
    var argv: [String]?
    var cmdline: String?
}

/// The foreground process group of a pane's controlling terminal.
nonisolated struct ForegroundJob: Sendable, Equatable {
    var processGroupID: UInt32
    var processes: [ForegroundProcess]
}

nonisolated enum ProcessInspector {
    private static let procPgrpOnly: UInt32 = 2
    private static let procPpidOnly: UInt32 = 6

    /// `e_tdev` value meaning "no controlling terminal".
    private static let noDev = UInt32.max

    /// Collect the foreground terminal job for a pane's shell PID.
    static func foregroundJob(panePid: UInt32) -> ForegroundJob? {
        guard panePid != 0 else { return nil }
        guard let fgPgid = foregroundProcessGroupID(pid: panePid) else { return nil }

        var processes: [ForegroundProcess] = []
        for pid in listPids(type: procPgrpOnly, argument: fgPgid) {
            guard let info = bsdInfo(pid: pid), info.pbi_pgid == fgPgid,
                let name = comm(from: info)
            else { continue }
            let arguments = kernProcargs2(pid: pid)
            let argv = arguments.flatMap(parseProcargs2Argv)
            processes.append(
                ForegroundProcess(
                    pid: pid,
                    name: name,
                    argv0: arguments.flatMap(parseProcargs2Argv0),
                    argv: argv,
                    cmdline: argv.map { $0.joined(separator: " ") }))
        }

        guard !processes.isEmpty else { return nil }
        return ForegroundJob(processGroupID: fgPgid, processes: processes)
    }

    /// PIDs of direct children of the job's processes that live on a
    /// different controlling terminal than their parent.
    ///
    /// Wrapper shells (e.g. koshell) allocate a nested PTY and run the real
    /// interactive shell inside it; the agent then runs on that inner tty,
    /// where the pane pid's own `e_tpgid` cannot see it. Callers descend
    /// through these children to resolve the innermost foreground job.
    static func nestedPtyChildren(of job: ForegroundJob) -> [UInt32] {
        var children: [UInt32] = []
        for process in job.processes {
            guard let parentInfo = bsdInfo(pid: process.pid) else { continue }
            for childPid in listPids(type: procPpidOnly, argument: process.pid) {
                guard let childInfo = bsdInfo(pid: childPid) else { continue }
                if childInfo.e_tdev != noDev && childInfo.e_tdev != parentInfo.e_tdev {
                    children.append(childPid)
                }
            }
        }
        return children
    }

    /// Parent PID of `pid`, or nil when the process is gone or has none.
    ///
    /// Uses `sysctl(KERN_PROC_PID)` rather than `proc_pidinfo`: ancestry
    /// chains cross setuid-root processes (`/usr/bin/login` between a
    /// terminal app and its shell), on which `proc_pidinfo` fails with EPERM
    /// for a non-root caller while the sysctl works for any process.
    static func parentPid(of pid: UInt32) -> UInt32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
            info.kp_eproc.e_ppid > 0
        else { return nil }
        return UInt32(info.kp_eproc.e_ppid)
    }

    /// Read `e_tpgid` (foreground process group of the controlling terminal).
    private static func foregroundProcessGroupID(pid: UInt32) -> UInt32? {
        guard let info = bsdInfo(pid: pid), info.e_tpgid > 0 else { return nil }
        return info.e_tpgid
    }

    private static func listPids(type: UInt32, argument: UInt32) -> [UInt32] {
        var capacity = 16
        for _ in 0..<8 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bufferBytes = pids.count * MemoryLayout<pid_t>.size
            let returnedBytes = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(type, argument, buffer.baseAddress, Int32(bufferBytes))
            }
            if returnedBytes <= 0 { return [] }

            let count = Int(returnedBytes) / MemoryLayout<pid_t>.size
            if Int(returnedBytes) < bufferBytes {
                return pids.prefix(count).filter { $0 > 0 }.map { UInt32($0) }
            }
            capacity *= 2
        }
        return []
    }

    private static func bsdInfo(pid: UInt32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, pointer, size)
        }
        return ret == size ? info : nil
    }

    private static func comm(from info: proc_bsdinfo) -> String? {
        var comm = info.pbi_comm
        let name = withUnsafeBytes(of: &comm) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    /// Effective name from the same buffer used for argv. Keep this parser
    /// independent: a truncated later argument must not discard a valid argv[0].
    static func parseProcargs2Argv0(_ buffer: [UInt8]) -> String? {
        guard buffer.count >= 4 else { return nil }
        let argc = buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 1 else { return nil }

        let rest = Array(buffer.dropFirst(4))
        guard let position = procargs2ArgvStart(rest) else { return nil }
        let argv0End = rest[position...].firstIndex(of: 0) ?? rest.count
        guard let argv0 = String(bytes: rest[position..<argv0End], encoding: .utf8),
            !argv0.isEmpty
        else { return nil }

        guard let basename = URL(fileURLWithPath: argv0).lastPathComponent.nilIfEmpty else {
            return nil
        }
        // Login shells report as "-zsh".
        let name = basename.hasPrefix("-") ? String(basename.dropFirst()) : basename
        return name.isEmpty ? nil : name
    }

    /// Raw `sysctl(KERN_PROCARGS2)` buffer:
    /// `[argc: i32] [exec_path\0] [padding\0...] [argv[0]\0] ... [env\0] ...`
    private static func kernProcargs2(pid: UInt32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        let ret = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard ret == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    private static func procargs2ArgvStart(_ rest: [UInt8]) -> Int? {
        guard let execEnd = rest.firstIndex(of: 0) else { return nil }
        var position = execEnd
        while position < rest.count && rest[position] == 0 {
            position += 1
        }
        return position < rest.count ? position : nil
    }

    static func parseProcargs2Argv(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count >= 4 else { return nil }
        let argc = buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 1 else { return nil }

        let rest = Array(buffer.dropFirst(4))
        guard var current = procargs2ArgvStart(rest) else { return nil }
        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard current < rest.count else { return nil }
            let end = rest[current...].firstIndex(of: 0) ?? rest.count
            guard end != current else { return nil }
            argv.append(String(decoding: rest[current..<end], as: UTF8.self))
            current = end + 1
        }
        return argv
    }
}

extension String {
    nonisolated fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
