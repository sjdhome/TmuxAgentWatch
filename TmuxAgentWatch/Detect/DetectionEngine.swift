//
//  DetectionEngine.swift
//  TmuxAgentWatch
//
//  Manifest rule engine, ported from tmux-agent-watch's Rust engine, which is
//  itself compatible with herdr's detection engine version 3 (Apache-2.0; see
//  NOTICE). The bundled manifests (Resources/manifests.json) are converted
//  verbatim from herdr's TOMLs, so every semantic here — region slicing, gate
//  combination, winner selection — must match herdr's behavior exactly.
//

import Foundation

nonisolated let manifestEngineVersion = 3

/// Screen-derived agent state as resolved by manifest rules.
nonisolated enum EngineState: String, Codable, Sendable {
    case idle
    case working
    case blocked
    case unknown
}

/// Input to the engine: the pane's visible screen text plus OSC-derived
/// strings. Pass "" when a source is unavailable.
nonisolated struct DetectionInput: Sendable {
    var screen: String
    var oscTitle: String
    var oscProgress: String
}

/// Result of evaluating a manifest against one input.
nonisolated struct Detection: Equatable, Sendable {
    var state: EngineState
    /// Id of the winning rule; `nil` means the known-agent Idle fallback.
    var ruleID: String?
    /// Winning rule was `skip_state_update`: discard this detection and keep
    /// the pane's previous state.
    var skip: Bool
    /// The winning rule carried the visible flag matching its state.
    var visible: Bool

    static let knownAgentIdleFallback = Detection(
        state: .idle, ruleID: nil, skip: false, visible: false)
}

// MARK: - JSON schema (converted from herdr's TOML manifests)

nonisolated struct ManifestGateJSON: Codable, Sendable {
    var contains: [String]?
    var regex: [String]?
    var lineRegex: [String]?
    var all: [ManifestGateJSON]?
    var any: [ManifestGateJSON]?
    var not: [ManifestGateJSON]?

    enum CodingKeys: String, CodingKey {
        case contains, regex, all, any, not
        case lineRegex = "line_regex"
    }
}

nonisolated struct ManifestRuleJSON: Codable, Sendable {
    var id: String
    var state: String
    var priority: Int?
    var region: String?
    var skipStateUpdate: Bool?
    var visibleIdle: Bool?
    var visibleBlocker: Bool?
    var visibleWorking: Bool?
    var contains: [String]?
    var regex: [String]?
    var lineRegex: [String]?
    var all: [ManifestGateJSON]?
    var any: [ManifestGateJSON]?
    var not: [ManifestGateJSON]?

    enum CodingKeys: String, CodingKey {
        case id, state, priority, region, contains, regex, all, any, not
        case skipStateUpdate = "skip_state_update"
        case visibleIdle = "visible_idle"
        case visibleBlocker = "visible_blocker"
        case visibleWorking = "visible_working"
        case lineRegex = "line_regex"
    }
}

nonisolated struct ManifestJSON: Codable, Sendable {
    var id: String
    var minEngineVersion: Int?
    var rules: [ManifestRuleJSON]

    enum CodingKeys: String, CodingKey {
        case id, rules
        case minEngineVersion = "min_engine_version"
    }
}

// MARK: - Compilation

nonisolated struct CompiledManifest: Sendable {
    let id: String
    let rules: [CompiledRule]
}

nonisolated struct CompiledRule: Sendable {
    let id: String
    let state: EngineState
    let priority: Int
    let region: String
    let skipStateUpdate: Bool
    let visibleIdle: Bool
    let visibleBlocker: Bool
    let visibleWorking: Bool
    let gate: CompiledGate
}

nonisolated struct CompiledGate: Sendable {
    let containsLower: [String]
    let regex: [NSRegularExpression]
    let lineRegex: [NSRegularExpression]
    let all: [CompiledGate]
    let any: [CompiledGate]
    let not: [CompiledGate]
}

nonisolated enum ManifestError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

nonisolated func compileManifest(_ manifest: ManifestJSON) throws -> CompiledManifest {
    if let minEngine = manifest.minEngineVersion, minEngine > manifestEngineVersion {
        throw ManifestError.message(
            "manifest \(manifest.id) requires engine version \(minEngine), this engine is \(manifestEngineVersion)"
        )
    }

    var rules: [CompiledRule] = []
    rules.reserveCapacity(manifest.rules.count)
    for rule in manifest.rules {
        guard let state = EngineState(rawValue: rule.state) else {
            throw ManifestError.message("rule \(rule.id): unknown state \"\(rule.state)\"")
        }
        let skip = rule.skipStateUpdate ?? false
        let visibleIdle = rule.visibleIdle ?? false
        let visibleBlocker = rule.visibleBlocker ?? false
        let visibleWorking = rule.visibleWorking ?? false
        if skip {
            if state != .unknown {
                throw ManifestError.message(
                    "rule \(rule.id): skip_state_update requires state \"unknown\"")
            }
            if visibleIdle || visibleBlocker || visibleWorking {
                throw ManifestError.message(
                    "rule \(rule.id): skip_state_update cannot combine with visible flags")
            }
        }
        let gate = ManifestGateJSON(
            contains: rule.contains, regex: rule.regex, lineRegex: rule.lineRegex,
            all: rule.all, any: rule.any, not: rule.not)
        do {
            rules.append(
                CompiledRule(
                    id: rule.id,
                    state: state,
                    priority: rule.priority ?? 0,
                    region: rule.region ?? "whole_recent",
                    skipStateUpdate: skip,
                    visibleIdle: visibleIdle,
                    visibleBlocker: visibleBlocker,
                    visibleWorking: visibleWorking,
                    gate: try compileGate(gate)))
        } catch ManifestError.message(let text) {
            throw ManifestError.message("rule \(rule.id): \(text)")
        }
    }

    return CompiledManifest(id: manifest.id, rules: rules)
}

nonisolated private func compileGate(_ gate: ManifestGateJSON) throws -> CompiledGate {
    func compilePatterns(_ patterns: [String]?) throws -> [NSRegularExpression] {
        try (patterns ?? []).map { pattern in
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                throw ManifestError.message("bad regex: \(error.localizedDescription)")
            }
        }
    }
    return CompiledGate(
        containsLower: (gate.contains ?? []).map { $0.lowercased() },
        regex: try compilePatterns(gate.regex),
        lineRegex: try compilePatterns(gate.lineRegex),
        all: try (gate.all ?? []).map(compileGate),
        any: try (gate.any ?? []).map(compileGate),
        not: try (gate.not ?? []).map(compileGate))
}

// MARK: - Evaluation

nonisolated func evaluate(manifest: CompiledManifest, input: DetectionInput) -> Detection {
    var winner: CompiledRule?

    for rule in manifest.rules {
        let text = regionText(input: input, spec: rule.region)
        guard ruleMatches(rule, text: text) else { continue }
        // Strictly-greater replacement: on a tie the earliest rule wins.
        if let previous = winner, previous.priority >= rule.priority { continue }
        winner = rule
    }

    guard let rule = winner else { return .knownAgentIdleFallback }

    let visible: Bool
    switch rule.state {
    case .idle: visible = rule.visibleIdle
    case .blocked: visible = rule.visibleBlocker
    case .working: visible = rule.visibleWorking
    case .unknown: visible = false
    }

    return Detection(
        state: rule.state, ruleID: rule.id, skip: rule.skipStateUpdate, visible: visible)
}

nonisolated private func ruleMatches(_ rule: CompiledRule, text: String) -> Bool {
    // Lowercased and split once per rule evaluation; nested gates share the
    // region.
    let lowerText = text.lowercased()
    let lines = rustLines(text).map(String.init)
    return gateMatches(rule.gate, text: text, lowerText: lowerText, lines: lines)
}

nonisolated private func regexIsMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}

nonisolated private func gateMatches(
    _ gate: CompiledGate, text: String, lowerText: String, lines: [String]
) -> Bool {
    gate.containsLower.allSatisfy { lowerText.contains($0) }
        && gate.regex.allSatisfy { regexIsMatch($0, text) }
        && gate.lineRegex.allSatisfy { regex in lines.contains { regexIsMatch(regex, $0) } }
        && gate.all.allSatisfy { gateMatches($0, text: text, lowerText: lowerText, lines: lines) }
        && (gate.any.isEmpty
            || gate.any.contains { gateMatches($0, text: text, lowerText: lowerText, lines: lines) })
        && !gate.not.contains { gateMatches($0, text: text, lowerText: lowerText, lines: lines) }
}

// MARK: - Line handling (Rust `str::lines()` semantics)

/// Split like Rust's `lines()`: separators are `\n`, a trailing newline does
/// not produce a final empty line, and the empty string has no lines.
nonisolated func rustLines(_ content: String) -> [Substring] {
    var lines: [Substring] = []
    var start = content.startIndex
    var index = content.startIndex
    while index < content.endIndex {
        if content[index] == "\n" {
            lines.append(content[start..<index])
            start = content.index(after: index)
        }
        index = content.index(after: index)
    }
    if start < content.endIndex {
        lines.append(content[start...])
    }
    return lines
}

/// Start index of line `index`, or `endIndex` past the last line — the exact
/// equivalent of the Rust engine's byte-offset arithmetic.
nonisolated private func lineStart(
    _ content: String, _ lines: [Substring], _ index: Int
) -> String.Index {
    index < lines.count ? lines[index].startIndex : content.endIndex
}

nonisolated private func sliceFromLine(
    _ content: String, _ lines: [Substring], _ index: Int
) -> String {
    String(content[lineStart(content, lines, index)...])
}

// MARK: - Regions

nonisolated func regionText(input: DetectionInput, spec: String) -> String {
    let trimmed = spec.trimmingCharacters(in: .whitespaces)
    // OSC regions source from their dedicated fields, not the screen.
    switch trimmed {
    case "osc_title": return input.oscTitle
    case "osc_progress": return input.oscProgress
    default: break
    }
    let content = input.screen
    switch trimmed {
    case "whole_recent": return content
    case "after_last_prompt_marker": return afterLastPromptMarker(content)
    case "whole_recent_without_current_prompt_marker":
        return wholeRecentWithoutCurrentPromptMarker(content)
    case "prompt_box_body": return promptBoxBody(content) ?? ""
    case "above_prompt_box": return abovePromptBox(content)
    case "last_non_empty_above_prompt_box": return lastNonEmptyLine(abovePromptBox(content))
    case "after_last_horizontal_rule": return afterLastHorizontalRule(content)
    default:
        if let count = regionCount(trimmed, "bottom_lines") {
            return bottomLines(content, count)
        }
        if let count = regionCount(trimmed, "bottom_non_empty_lines") {
            return bottomNonEmptyLines(content, count)
        }
        if let count = regionCount(trimmed, "top_non_empty_lines") {
            return topNonEmptyLines(content, count)
        }
        return ""
    }
}

/// Region specs implemented by this engine. The manifest coverage test
/// asserts every region used by the bundled manifests appears here, so a
/// manifest refresh cannot silently dead-letter rules.
nonisolated func regionIsSupported(_ spec: String) -> Bool {
    let trimmed = spec.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "osc_title", "osc_progress", "whole_recent", "after_last_prompt_marker",
        "whole_recent_without_current_prompt_marker",
        "prompt_box_body", "above_prompt_box", "last_non_empty_above_prompt_box",
        "after_last_horizontal_rule":
        return true
    default:
        return regionCount(trimmed, "bottom_lines") != nil
            || regionCount(trimmed, "bottom_non_empty_lines") != nil
            || regionCount(trimmed, "top_non_empty_lines") != nil
    }
}

nonisolated private func regionCount(_ spec: String, _ name: String) -> Int? {
    guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
    let inner = spec.dropFirst(name.count + 1).dropLast()
    return Int(inner)
}

nonisolated private func bottomLines(_ content: String, _ count: Int) -> String {
    let lines = rustLines(content)
    let start = max(0, lines.count - count)
    return sliceFromLine(content, lines, start)
}

nonisolated private func bottomNonEmptyLines(_ content: String, _ count: Int) -> String {
    let lines = rustLines(content)
    var found = 0
    var startIndex: Int?
    for index in stride(from: lines.count - 1, through: 0, by: -1) {
        if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            found += 1
            startIndex = index
            if found == count { break }
        }
    }
    guard let startIndex else { return "" }
    return sliceFromLine(content, lines, startIndex)
}

nonisolated private func topNonEmptyLines(_ content: String, _ count: Int) -> String {
    let lines = rustLines(content)
    var found = 0
    var endIndex: Int?
    for (index, line) in lines.enumerated() {
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            found += 1
            endIndex = index
            if found == count { break }
        }
    }
    guard let endIndex else { return "" }
    return String(content[..<lineStart(content, lines, endIndex + 1)])
}

nonisolated private func codexPromptLine(_ line: Substring) -> Bool {
    line == "›" || line.hasPrefix("› ")
}

nonisolated private func afterLastPromptMarker(_ content: String) -> String {
    let lines = rustLines(content)
    guard let index = lines.lastIndex(where: codexPromptLine) else { return content }
    return sliceFromLine(content, lines, index + 1)
}

/// Suppress weak blocker text when Codex has a current composer. This is
/// intentionally all-or-nothing, not a slice removing just the prompt line.
/// A later response block means the prompt was historical instead.
nonisolated private func wholeRecentWithoutCurrentPromptMarker(_ content: String) -> String {
    let lines = rustLines(content)
    guard let promptIndex = lines.lastIndex(where: codexPromptLine) else { return content }
    let hasLaterBlock = lines.dropFirst(promptIndex + 1).contains { line in
        line.hasPrefix("•") || line.hasPrefix("■")
            || line.hasPrefix("✗") || line.hasPrefix("✓")
    }
    return hasLaterBlock ? content : ""
}

nonisolated private func afterLastHorizontalRule(_ content: String) -> String {
    let lines = rustLines(content)
    var lastRuleEnd = content.startIndex
    for (index, line) in lines.enumerated() where isHorizontalRule(line) {
        lastRuleEnd = lineStart(content, lines, index + 1)
    }
    return String(content[lastRuleEnd...])
}

/// Everything before the prompt box's top border; whole content when no
/// prompt box is on screen.
nonisolated private func abovePromptBox(_ content: String) -> String {
    let lines = rustLines(content)
    guard let top = promptBoxTopBorderIndex(lines) else { return content }
    return String(content[..<lineStart(content, lines, top)])
}

nonisolated private func lastNonEmptyLine(_ content: String) -> String {
    rustLines(content)
        .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map(String.init) ?? ""
}

nonisolated private func promptBoxBody(_ content: String) -> String? {
    let lines = rustLines(content)
    guard let top = promptBoxTopBorderIndex(lines) else { return nil }
    let start = lineStart(content, lines, top + 1)
    var endLine = lines.count
    for index in (top + 1)..<lines.count where isHorizontalRule(lines[index]) {
        endLine = index
        break
    }
    let end = lineStart(content, lines, endLine)
    return String(content[start..<max(end, start)])
}

nonisolated private func promptBoxTopBorderIndex(_ lines: [Substring]) -> Int? {
    var borderCount = 0
    for index in stride(from: lines.count - 1, through: 0, by: -1) {
        if isHorizontalRule(lines[index]) {
            borderCount += 1
            if borderCount == 2 { return index }
        }
    }
    return nil
}

nonisolated func isHorizontalRule<S: StringProtocol>(_ line: S) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return false }

    let ruleChars = trimmed.prefix { $0 == "─" }.count
    if ruleChars == 0 { return false }

    let suffix = trimmed.dropFirst(ruleChars).drop { $0.isWhitespace }
    return suffix.isEmpty || ruleChars >= 3
}
