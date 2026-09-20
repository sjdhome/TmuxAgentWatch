//
//  AgentIdentifier.swift
//  TmuxAgentWatch
//
//  Agent identification from a pane's foreground job, ported from
//  tmux-agent-watch's src/detect/mod.rs (in turn from herdr, Apache-2.0; see
//  NOTICE). Unix subset only.
//

import Foundation

nonisolated enum AgentIdentifier {
    /// Total anchors examined while descending through nested PTYs.
    private static let paneResolutionBudget = 8

    /// Identify the agent for a tmux pane, descending through nested-PTY
    /// wrapper shells (e.g. koshell spawning zsh on an inner tty) when the
    /// pane's own foreground job contains no agent.
    static func identifyPaneAgent(panePid: UInt32) -> (Agent, String)? {
        var anchors: [UInt32] = [panePid]
        var seen: Set<UInt32> = []
        var budget = paneResolutionBudget

        while !anchors.isEmpty {
            let anchor = anchors.removeFirst()
            if budget == 0 || !seen.insert(anchor).inserted { break }
            budget -= 1

            guard let job = ProcessInspector.foregroundJob(panePid: anchor) else { continue }
            if let found = identifyAgent(in: job) {
                return found
            }
            anchors.append(contentsOf: ProcessInspector.nestedPtyChildren(of: job))
        }

        return nil
    }

    /// Identify the agent running in a pane's foreground job. Prefers the
    /// process group leader when it maps to an agent; otherwise the
    /// best-scoring match across the job's processes.
    static func identifyAgent(in job: ForegroundJob) -> (Agent, String)? {
        if let process = job.processes.first(where: { $0.pid == job.processGroupID }) {
            let candidate = normalizedProcessName(process)
            if let agent = Agent.parse(label: candidate),
                agent != .letta || isInteractiveLettaProcess(process)
            {
                return (agent, candidate)
            }
        }

        var best: (score: Int, agent: Agent, name: String)?

        for process in job.processes {
            let candidate = normalizedProcessName(process)
            guard let agent = Agent.parse(label: candidate) else { continue }
            if agent == .letta && !isInteractiveLettaProcess(process) { continue }
            let score = processPriority(process, normalizedName: candidate)
            if let current = best, current.score >= score { continue }
            best = (score, agent, candidate)
        }

        return best.map { ($0.agent, $0.name) }
    }

    static func normalizedProcessName(_ process: ForegroundProcess) -> String {
        let effective = process.argv0 ?? process.name
        let lowerEffective = effective.lowercased()

        if isGenericRuntimeOrShell(lowerEffective),
            let wrappedAgent = wrappedAgentNameFromRuntimeArgv(
                runtime: lowerEffective, argv: process.argv)
        {
            return wrappedAgent
        }

        if Agent.parse(label: effective) != nil {
            return effective
        }

        // Qwen Code never rewrites its process title, so a plain `node
        // …/qwen.js` invocation is only identifiable through its script
        // argument even when argv[0] is not a generic runtime name. Cline
        // and Letta launchers need the same unwrapping.
        if let runtime = process.argv?.first {
            let runtimeName = normalizedAgentLookupName(pathBasename(runtime))
            if runtimeName == "node" || runtimeName == "bun",
                let wrappedAgent = wrappedAgentNameFromRuntimeArgv(
                    runtime: runtime, argv: process.argv),
                let agent = Agent.parse(label: wrappedAgent),
                [.qwen, .cline, .letta].contains(agent)
            {
                return wrappedAgent
            }
        }

        if let wrappedAgent = argv0AgentName(process.argv)
            ?? cmdlineArgv0AgentName(process.cmdline ?? "")
        {
            return wrappedAgent
        }

        return effective
    }

    private static func wrappedAgentNameFromRuntimeArgv(
        runtime: String, argv: [String]?
    ) -> String? {
        guard let argv else { return nil }
        let runtime = normalizedAgentLookupName(pathBasename(runtime))

        switch runtime {
        case "node", "bun":
            return scriptArgAgentName(argv, evalFlags: ["-e", "--eval", "-p", "--print"], moduleFlags: [])
        case let name where isPythonRuntime(name):
            return scriptArgAgentName(argv, evalFlags: ["-c"], moduleFlags: ["-m"])
        case "sh", "bash", "zsh", "fish":
            return scriptArgAgentName(argv, evalFlags: ["-c"], moduleFlags: [])
        default:
            return nil
        }
    }

    private static func scriptArgAgentName(
        _ argv: [String], evalFlags: [String], moduleFlags: [String]
    ) -> String? {
        var iterator = argv.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg == "--" {
                return iterator.next().flatMap(agentNameFromPathToken)
            }

            if flagMatches(arg, evalFlags) || flagMatches(arg, moduleFlags) {
                return nil
            }

            if arg.hasPrefix("-") {
                if optionTakesValue(arg) {
                    _ = iterator.next()
                }
                continue
            }

            return agentNameFromPathToken(arg)
        }

        return nil
    }

    private static func flagMatches(_ arg: String, _ flags: [String]) -> Bool {
        flags.contains { flag in
            arg == flag || shortFlagPayload(arg, flag) || longFlagValue(arg, flag)
        }
    }

    private static func shortFlagPayload(_ arg: String, _ flag: String) -> Bool {
        flag.hasPrefix("-") && !flag.hasPrefix("--") && arg.hasPrefix(flag)
            && arg.count > flag.count
    }

    private static func longFlagValue(_ arg: String, _ flag: String) -> Bool {
        guard flag.hasPrefix("--"), arg.hasPrefix(flag) else { return false }
        return arg.dropFirst(flag.count).hasPrefix("=")
    }

    private static func optionTakesValue(_ arg: String) -> Bool {
        [
            "-r", "--require", "--loader", "--import", "--experimental-loader",
            "--inspect-port", "-W", "-X", "-S", "-L", "-o",
        ].contains(arg)
    }

    private static func argv0AgentName(_ argv: [String]?) -> String? {
        argv?.first.flatMap(agentNameFromPathToken)
    }

    private static func cmdlineArgv0AgentName(_ cmdline: String) -> String? {
        cmdline.split(whereSeparator: \.isWhitespace).first
            .flatMap { agentNameFromPathToken(String($0)) }
    }

    static func agentNameFromPathToken(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if trimmed.isEmpty || trimmed.hasPrefix("-") {
            return nil
        }

        return agentNameFromBasename(pathBasename(trimmed))
            ?? agentNameFromKnownPackagePath(trimmed)
            ?? resolvedAgentNameFromPathToken(trimmed)
    }

    private static func agentNameFromKnownPackagePath(_ path: String) -> String? {
        let rawComponents = path.split { $0 == "/" || $0 == "\\" }
            .map { $0.lowercased() }
        let piPackage = ["node_modules", "@earendil-works", "pi-coding-agent", "dist"]
        // Match only the actual entrypoints, not cli.exe or descendants of cli.js.
        if rawComponents.suffix(piPackage.count + 1).elementsEqual(piPackage + ["cli.js"])
            || rawComponents.suffix(piPackage.count + 2).elementsEqual(
                piPackage + ["bundle", "cli.js"])
        {
            return Agent.pi.label
        }
        let kimiEntrypoint = ["node_modules", "@moonshot-ai", "kimi-code", "dist", "main.mjs"]
        if rawComponents.suffix(kimiEntrypoint.count).elementsEqual(kimiEntrypoint) {
            return Agent.kimi.label
        }

        let components = rawComponents.map(normalizedAgentLookupName)
        let needles: [(needle: [String], agent: Agent)] = [
            (["node_modules", "@qwen-code", "qwen-code", "dist", "index"], .qwen),
            (["node_modules", "@letta-ai", "letta-code", "letta"], .letta),
        ]

        for (needle, agent) in needles {
            guard components.count >= needle.count else { continue }
            for start in 0...(components.count - needle.count)
            where Array(components[start..<(start + needle.count)]) == needle {
                return agent.label
            }
        }
        return nil
    }

    // MARK: - Letta interactive sessions

    /// Letta's CLI also runs headless prompts, servers, and subcommands under
    /// the same entrypoint; only the interactive TUI counts as an agent pane.
    private static func isInteractiveLettaProcess(_ process: ForegroundProcess) -> Bool {
        let argv: [String]
        if let processArgv = process.argv {
            argv = processArgv
        } else {
            argv = (process.cmdline ?? "").split(whereSeparator: \.isWhitespace).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if argv.isEmpty { return true }
        }

        let cliArgs = lettaEntrypointIndex(argv).map { Array(argv[($0 + 1)...]) } ?? argv
        let headless = cliArgs.contains { arg in
            let option = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? arg
            return lettaNonInteractiveOptions.contains(option)
        }
        if headless { return false }

        guard let first = lettaFirstArgAfterBackendSelection(cliArgs) else { return true }
        return first.hasPrefix("-")
    }

    private static let lettaNonInteractiveOptions: Set<String> = [
        "-p", "--print", "--prompt", "--json", "--stream-json", "--run",
        "--disable-memory-guard", "--output-format", "--input-format",
        "--include-partial-messages", "--from-agent", "--environment", "--env",
        "--pre-load-skills", "--tags", "--ephemeral", "--stateless", "--max-turns",
        "--memfs-startup", "-h", "--help", "-v", "--version", "--info", "--update",
        "--upgrade",
    ]

    private static func lettaEntrypointIndex(_ argv: [String]) -> Int? {
        func isLetta(_ arg: String) -> Bool {
            agentNameFromPathToken(arg) == Agent.letta.label
        }
        guard let first = argv.first else { return nil }
        if isLetta(first) { return 0 }

        let runtime = normalizedAgentLookupName(pathBasename(first))
        guard runtime == "node" || runtime == "bun" else { return nil }

        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" {
                return index + 1 < argv.count && isLetta(argv[index + 1]) ? index + 1 : nil
            }
            if flagMatches(arg, ["-e", "--eval", "-p", "--print"]) {
                return nil
            }
            if arg.hasPrefix("-") {
                index += optionTakesValue(arg) ? 2 : 1
                continue
            }
            return isLetta(arg) ? index : nil
        }
        return nil
    }

    private static func lettaFirstArgAfterBackendSelection(_ args: [String]) -> String? {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "--backend" {
                _ = iterator.next()
                continue
            }
            if arg.hasPrefix("--backend=") { continue }
            return arg
        }
        return nil
    }

    private static func resolvedAgentNameFromPathToken(_ token: String) -> String? {
        // Mirror of Rust's `path.components().count() < 2` bail-out: bare
        // names never hit the filesystem.
        let componentCount = token.split { $0 == "/" }.count + (token.hasPrefix("/") ? 1 : 0)
        guard componentCount >= 2 else { return nil }

        guard let resolved = realpath(token, nil) else { return nil }
        defer { free(resolved) }
        let basename = URL(fileURLWithPath: String(cString: resolved)).lastPathComponent
        guard !basename.isEmpty else { return nil }
        return agentNameFromBasename(basename)
    }

    private static func agentNameFromBasename(_ basename: String) -> String? {
        Agent.parse(label: basename)?.label
    }

    private static func processPriority(
        _ process: ForegroundProcess, normalizedName: String
    ) -> Int {
        let lowerName = normalizedName.lowercased()
        if lowerName != process.name.lowercased() {
            return 3
        }
        if !isGenericRuntimeOrShell(lowerName) {
            return 2
        }
        return 1
    }

    private static func isGenericRuntimeOrShell(_ name: String) -> Bool {
        let name = normalizedAgentLookupName(pathBasename(name))
        return isPythonRuntime(name)
            || ["sh", "bash", "zsh", "fish", "tmux", "node", "bun"].contains(name)
    }

    /// "python", or "python" followed by a dotted version ("python3",
    /// "python3.12"), each dot-separated part all-digits.
    private static func isPythonRuntime(_ name: String) -> Bool {
        guard name.hasPrefix("python") else { return false }
        let version = name.dropFirst("python".count)
        if version.isEmpty { return true }
        return version.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private static func pathBasename(_ path: String) -> String {
        path.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? path
    }
}
