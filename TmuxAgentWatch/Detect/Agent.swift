//
//  Agent.swift
//  TmuxAgentWatch
//
//  Known agents and label/alias resolution, ported from tmux-agent-watch's
//  src/detect/mod.rs (in turn from herdr, Apache-2.0; see NOTICE).
//

import Foundation

/// Which agent we detected running in a pane.
nonisolated enum Agent: String, CaseIterable, Sendable {
    case pi
    case claude
    case codex
    case gemini
    case cursor
    case devin
    case antigravity = "agy"
    case cline
    case omp
    case mastracode
    case openCode = "opencode"
    case githubCopilot = "copilot"
    case kimi
    case kiro
    case droid
    case amp
    case grok
    case hermes
    case kilo
    case qodercli
    case qwen
    case letta
    case maki
    case muse

    /// Canonical label, matching the manifest `id` fields.
    var label: String { rawValue }

    /// Manifest id for an agent, where one exists. `omp` and `mastracode`
    /// have no screen manifest in herdr; they fall back to known-agent-Idle.
    var manifestID: String? {
        switch self {
        case .omp, .mastracode: return nil
        default: return label
        }
    }

    static func parse(label: String) -> Agent? {
        lookup(normalizedAgentLookupName(label))
    }

    private static func lookup(_ name: String) -> Agent? {
        let name = name.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? name
        switch name {
        case "pi": return .pi
        case "claude", "claude-code": return .claude
        case "codex": return .codex
        case "gemini": return .gemini
        case "cursor", "cursor-agent": return .cursor
        case "devin", "devin-cli", "devin cli": return .devin
        case "agy", "antigravity", "antigravity-cli": return .antigravity
        case "cline", ".cline": return .cline
        case "omp": return .omp
        case "mastracode", "mastra-code", "mastra code": return .mastracode
        case "opencode", "opencode2", "open-code": return .openCode
        case "copilot", "github-copilot", "ghcs": return .githubCopilot
        case "kimi", "kimi-code", "kimi code": return .kimi
        case "kiro", "kiro-cli": return .kiro
        case "droid": return .droid
        case "amp", "amp-local": return .amp
        case "grok", "grok-build": return .grok
        case "hermes", "hermes-agent": return .hermes
        case "kilo", "kilo-code", "kilo code": return .kilo
        case "qodercli", "qoderclicn", "qoder", "qodercn": return .qodercli
        case "qwen", "qwen-code", "qwen code": return .qwen
        case "letta", "letta-code", "letta code": return .letta
        case "maki": return .maki
        case "muse", "muse-code", "muse-cli": return .muse
        default:
            // Muse's launcher execs muse-bin-<version>, not a bare alias.
            if name.hasPrefix("muse-bin-"),
                let first = name.dropFirst("muse-bin-".count).first,
                first.isASCII && first.isNumber
            {
                return .muse
            }
            return nil
        }
    }
}

nonisolated func normalizedAgentLookupName(_ name: String) -> String {
    var name = name.trimmingCharacters(in: .whitespaces).lowercased()
    for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] where name.hasSuffix(suffix) {
        name.removeLast(suffix.count)
        break
    }
    return name
}
