//
//  DetectionEngineTests.swift
//  TmuxAgentWatchTests
//
//  Ported from tmux-agent-watch's src/detect/engine.rs tests.
//

import Foundation
import Testing

@testable import TmuxAgentWatch

private func screenInput(_ screen: String) -> DetectionInput {
    DetectionInput(screen: screen, oscTitle: "", oscProgress: "")
}

private func compileJSON(_ json: String) throws -> CompiledManifest {
    let manifest = try JSONDecoder().decode(ManifestJSON.self, from: Data(json.utf8))
    return try compileManifest(manifest)
}

// MARK: - Regions

@Test func wholeRecentIsTheEntireScreen() {
    #expect(regionText(input: screenInput("a\nb\nc"), spec: "whole_recent") == "a\nb\nc")
}

@Test func oscRegionsReadDedicatedFields() {
    let input = DetectionInput(screen: "screen", oscTitle: "the title", oscProgress: "4;0")
    #expect(regionText(input: input, spec: "osc_title") == "the title")
    #expect(regionText(input: input, spec: "osc_progress") == "4;0")
}

@Test func bottomNonEmptyLinesIncludesInterleavedBlanks() {
    let content = "top\nsecond\n\nthird\n\nlast"
    #expect(
        regionText(input: screenInput(content), spec: "bottom_non_empty_lines(2)")
            == "third\n\nlast")
}

@Test func bottomNonEmptyLinesOfBlankContentIsEmpty() {
    #expect(regionText(input: screenInput("\n\n \n"), spec: "bottom_non_empty_lines(3)") == "")
}

@Test func bottomLinesCountsPhysicalLines() {
    #expect(regionText(input: screenInput("a\nb\nc\nd"), spec: "bottom_lines(2)") == "c\nd")
}

@Test func topNonEmptyLinesSlicesFromStart() {
    let content = "\nfirst\nsecond\nthird"
    #expect(regionText(input: screenInput(content), spec: "top_non_empty_lines(1)") == "\nfirst\n")
}

@Test func topNonEmptyLinesOfBlankContentIsEmpty() {
    #expect(regionText(input: screenInput("\n \n"), spec: "top_non_empty_lines(1)") == "")
}

@Test func afterLastPromptMarkerVariants() {
    #expect(
        regionText(input: screenInput("out\n› command\ntail"), spec: "after_last_prompt_marker")
            == "tail")
    #expect(
        regionText(input: screenInput("out\n›\ntail"), spec: "after_last_prompt_marker") == "tail")
    // "›x" without a space is NOT a prompt marker.
    #expect(
        regionText(input: screenInput("out\n›x\ntail"), spec: "after_last_prompt_marker")
            == "out\n›x\ntail")
}

@Test func horizontalRuleDetectionPaths() {
    #expect(isHorizontalRule("───"))
    #expect(isHorizontalRule("  ─  "))
    #expect(isHorizontalRule("──── some label"))
    #expect(!isHorizontalRule("── label"))  // run < 3 with suffix
    #expect(!isHorizontalRule(""))
    #expect(!isHorizontalRule("text"))
}

@Test func afterLastHorizontalRuleSlicesAfterRuleLine() {
    let content = "before\n────\nafter\nmore"
    #expect(
        regionText(input: screenInput(content), spec: "after_last_horizontal_rule")
            == "after\nmore")
    // No rule: whole content.
    #expect(regionText(input: screenInput("a\nb"), spec: "after_last_horizontal_rule") == "a\nb")
}

@Test func promptBoxBodyIsBetweenTheTwoBottomRules() {
    let content = "history\n────\n❯ type here\n────\nhints"
    #expect(regionText(input: screenInput(content), spec: "prompt_box_body") == "❯ type here\n")
}

@Test func promptBoxBodyRequiresTwoRules() {
    #expect(regionText(input: screenInput("a\n────\nb"), spec: "prompt_box_body") == "")
}

@Test func abovePromptBoxSlicesBeforeTheTopRule() {
    let content = "history\n✻ note\n\n────\n❯ hi\n────"
    #expect(
        regionText(input: screenInput(content), spec: "above_prompt_box")
            == "history\n✻ note\n\n")
    #expect(
        regionText(input: screenInput(content), spec: "last_non_empty_above_prompt_box")
            == "✻ note")
    // No prompt box: whole content / its last non-empty line.
    #expect(regionText(input: screenInput("a\nb\n"), spec: "above_prompt_box") == "a\nb\n")
    #expect(
        regionText(input: screenInput("a\nb\n"), spec: "last_non_empty_above_prompt_box") == "b")
}

@Test func unknownRegionIsEmpty() {
    #expect(regionText(input: screenInput("content"), spec: "no_such_region") == "")
    #expect(!regionIsSupported("no_such_region"))
    #expect(regionIsSupported("bottom_non_empty_lines(5)"))
}

// MARK: - Gate combination

private let gateManifest = #"""
    {
      "id": "test",
      "rules": [
        {
          "id": "combo",
          "state": "blocked",
          "contains": ["Do You Want"],
          "regex": ["esc to \\w+"],
          "any": [{"contains": ["yes"]}, {"contains": ["ok"]}],
          "not": [{"contains": ["forbidden"]}]
        }
      ]
    }
    """#

@Test func containsIsCaseInsensitiveAndRegexIsNot() throws {
    let manifest = try compileJSON(gateManifest)
    // "DO YOU WANT" matches case-insensitively; regex needs exact case.
    let hit = evaluate(manifest: manifest, input: screenInput("DO YOU WANT? esc to cancel yes"))
    #expect(hit.state == .blocked)
    #expect(hit.ruleID == "combo")

    let miss = evaluate(manifest: manifest, input: screenInput("DO YOU WANT? ESC TO CANCEL yes"))
    #expect(miss.ruleID == nil, "regex must be case-sensitive")
}

@Test func anyGateRequiresOneHitAndNotGateVetoes() throws {
    let manifest = try compileJSON(gateManifest)
    let noAny = evaluate(manifest: manifest, input: screenInput("do you want? esc to cancel"))
    #expect(noAny.ruleID == nil, "empty any candidates must miss")

    let vetoed = evaluate(
        manifest: manifest, input: screenInput("do you want? esc to cancel yes forbidden"))
    #expect(vetoed.ruleID == nil, "not gate must veto")
}

@Test func nestedGatesCombine() throws {
    let manifest = try compileJSON(
        #"""
        {
          "id": "test",
          "rules": [
            {
              "id": "nested",
              "state": "working",
              "all": [{"any": [{"contains": ["alpha"], "not": [{"contains": ["beta"]}]}]}]
            }
          ]
        }
        """#)
    #expect(evaluate(manifest: manifest, input: screenInput("alpha")).ruleID == "nested")
    #expect(evaluate(manifest: manifest, input: screenInput("alpha beta")).ruleID == nil)
}

@Test func lineRegexMatchesAnySingleLine() throws {
    let manifest = try compileJSON(
        #"""
        {
          "id": "test",
          "rules": [
            {"id": "lined", "state": "idle", "line_regex": ["^\\s*❯"]}
          ]
        }
        """#)
    #expect(evaluate(manifest: manifest, input: screenInput("text\n  ❯ prompt")).ruleID == "lined")
    // Anchored pattern must not match mid-line across the whole blob.
    #expect(evaluate(manifest: manifest, input: screenInput("text ❯ prompt")).ruleID == nil)
}

// MARK: - Winner selection

private let priorityManifest = #"""
    {
      "id": "test",
      "rules": [
        {"id": "first_low", "state": "idle", "priority": 10, "contains": ["x"]},
        {"id": "second_same", "state": "working", "priority": 10, "contains": ["x"]},
        {"id": "third_high", "state": "blocked", "priority": 20, "contains": ["y"]}
      ]
    }
    """#

@Test func tieGoesToEarliestRule() throws {
    let manifest = try compileJSON(priorityManifest)
    let detection = evaluate(manifest: manifest, input: screenInput("x"))
    #expect(detection.ruleID == "first_low")
    #expect(detection.state == .idle)
}

@Test func strictlyHigherPriorityWinsRegardlessOfOrder() throws {
    let manifest = try compileJSON(priorityManifest)
    let detection = evaluate(manifest: manifest, input: screenInput("x y"))
    #expect(detection.ruleID == "third_high")
    #expect(detection.state == .blocked)
}

@Test func noMatchFallsBackToKnownAgentIdle() throws {
    let manifest = try compileJSON(priorityManifest)
    let detection = evaluate(manifest: manifest, input: screenInput("nothing relevant"))
    #expect(detection == .knownAgentIdleFallback)
}

// MARK: - skip_state_update & visible flags

@Test func skipStateUpdateWinnerReportsSkip() throws {
    let manifest = try compileJSON(
        #"""
        {
          "id": "test",
          "rules": [
            {
              "id": "viewer", "state": "unknown", "priority": 100,
              "skip_state_update": true, "contains": ["transcript"]
            },
            {"id": "idle", "state": "idle", "visible_idle": true, "contains": ["transcript"]}
          ]
        }
        """#)
    let detection = evaluate(manifest: manifest, input: screenInput("showing transcript"))
    #expect(detection.skip)
    #expect(detection.ruleID == "viewer")
}

@Test func skipStateUpdateValidationRejectsNonUnknownState() throws {
    let manifest = try JSONDecoder().decode(
        ManifestJSON.self,
        from: Data(
            #"""
            {
              "id": "test",
              "rules": [
                {"id": "bad", "state": "idle", "skip_state_update": true, "contains": ["x"]}
              ]
            }
            """#.utf8))
    #expect(throws: ManifestError.self) {
        _ = try compileManifest(manifest)
    }
}

@Test func visibleFlagPropagatesOnlyForMatchingState() throws {
    let manifest = try compileJSON(
        #"""
        {
          "id": "test",
          "rules": [
            {"id": "vis", "state": "working", "visible_working": true, "contains": ["spin"]},
            {"id": "novis", "state": "blocked", "visible_working": true, "contains": ["blocked"]}
          ]
        }
        """#)
    #expect(evaluate(manifest: manifest, input: screenInput("spin")).visible)
    #expect(!evaluate(manifest: manifest, input: screenInput("blocked")).visible)
}

// MARK: - Bundled manifests

@Test func allBundledManifestsParseAndCompile() {
    let bundled = Manifests.loadBundled()
    #expect(bundled.count == 21)
    #expect(Set(bundled.map(\.id)) == Set(Agent.allCases.compactMap(\.manifestID)))
    for manifest in bundled {
        let agent = Agent.parse(label: manifest.id)
        #expect(agent != nil, "manifest id \(manifest.id) is not a known agent")
        #expect(
            agent?.manifestID == manifest.id,
            "manifest \(manifest.id): id must be the agent's canonical label")
    }
    #expect(Manifests.compiled.count == 21)
}

@Test func everyUsedRegionIsImplemented() {
    for manifest in Manifests.loadBundled() {
        for rule in manifest.rules {
            let region = rule.region ?? "whole_recent"
            #expect(
                regionIsSupported(region),
                "manifest \(manifest.id) uses unimplemented region \(region)")
        }
    }
}

// MARK: - Claude busy-screen fallbacks (herdr 2026.08.19.1)
//
// Claude Code 2.1.228 replaced the braille OSC-title spinner with half
// circles, so a busy pane without the new rules fell through to the
// prompt-box idle rule. These screens must resolve as working.

@Test func claudeHalfCircleSpinnerTitleIsWorking() throws {
    let claude = try #require(Manifests.get("claude"))
    let input = DetectionInput(screen: "", oscTitle: "◐ Cogitating", oscProgress: "")
    let detection = evaluate(manifest: claude, input: input)
    #expect(detection.state == .working)
    #expect(detection.ruleID == "osc_title_working")
}

@Test func claudeBusyTurnBeatsVisiblePromptBox() throws {
    let claude = try #require(Manifests.get("claude"))
    let screen = """
        ⏺ Reading files

        ✻ Cogitating… (12s · ↓ 2.1k tokens · esc to interrupt)

        ────────────────────────────
        ❯
        ────────────────────────────
          ? for shortcuts
        """
    let detection = evaluate(manifest: claude, input: screenInput(screen))
    #expect(detection.state == .working)
    #expect(detection.ruleID == "live_turn_working")
}

@Test func claudeWaitingForBackgroundAgentsIsWorking() throws {
    let claude = try #require(Manifests.get("claude"))
    let screen = """
        ⏺ Spawned 2 agents

        ✽ Waiting for 2 background agents to finish

        ────────────────────────────
        ❯
        ────────────────────────────
        """
    let detection = evaluate(manifest: claude, input: screenInput(screen))
    #expect(detection.state == .working)
    #expect(detection.ruleID == "background_agents_working")
}

@Test func claudeIdlePromptBoxStaysIdle() throws {
    let claude = try #require(Manifests.get("claude"))
    let screen = """
        ⏺ Done.

        ────────────────────────────
        ❯
        ────────────────────────────
          ? for shortcuts
        """
    let detection = evaluate(manifest: claude, input: screenInput(screen))
    #expect(detection.state == .idle)
    #expect(detection.ruleID == "live_prompt_box")
}

// MARK: - Claude background MCP tasks (herdr 2026.08.21.1)
//
// Claude Code moves MCP calls longer than 120s to a background task and
// ends the turn: the OSC title and prompt box return to their idle shapes
// while the task keeps running. The activity summary line is the only
// stable signal, so it must keep the pane working (herdr #3090).

@Test func claudeBackgroundMcpTaskIsWorking() throws {
    let claude = try #require(Manifests.get("claude"))
    // Screen from herdr issue #3090, captured while the task was still alive.
    let screen = """
          Thought for 13s, called codex (ctrl+o to expand)

        ● Review started.

        ✻ Baked for 4m 9s · 1 MCP task still running

        ────────────────────────────
        ❯
        ────────────────────────────
          ⏵⏵ bypass permissions on · 1 MCP task · ← for agents
        """
    let detection = evaluate(manifest: claude, input: screenInput(screen))
    #expect(detection.state == .working)
    #expect(detection.ruleID == "background_mcp_task_working")
    #expect(detection.visible)
}

@Test func claudeBackgroundMcpTaskWrappedSummaryIsWorking() throws {
    let claude = try #require(Manifests.get("claude"))
    // Narrow panes wrap the summary; continuations are indented.
    let screen = """
        ✻ Baked for 4m 9s ·
          3 MCP tasks still running

        ────────────────────────────
        ❯
        ────────────────────────────
        """
    let detection = evaluate(manifest: claude, input: screenInput(screen))
    #expect(detection.state == .working)
    #expect(detection.ruleID == "background_mcp_task_working")
}

@Test func claudeFinishedMcpTasksStayIdle() throws {
    let claude = try #require(Manifests.get("claude"))
    // Zero-count summaries and prompt text quoting the summary are not
    // activity: the pane is idle at its prompt box.
    for line in [
        "✻ Baked for 4m 9s · 0 MCP tasks still running",
        "❯ ✻ Baked for 4m 9s · 1 MCP task still running",
    ] {
        let screen = """
            \(line)

            ────────────────────────────
            ❯
            ────────────────────────────
            """
        let detection = evaluate(manifest: claude, input: screenInput(screen))
        #expect(detection.state == .idle, "line: \(line)")
        #expect(detection.ruleID == "live_prompt_box", "line: \(line)")
    }
}

@Test func claudeMcpTaskSummaryYieldsToPermissionPrompt() throws {
    let claude = try #require(Manifests.get("claude"))
    let screen = """
        ✻ Baked for 4m 9s · 1 MCP task still running

        Do you want to proceed?
        ❯ 1. Yes
          2. No

        Esc to cancel
        """
    let detection = evaluate(manifest: claude, input: screenInput(screen))
    #expect(detection.state == .blocked)
}
