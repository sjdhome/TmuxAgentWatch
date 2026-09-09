//
//  PiWorking.swift
//  TmuxAgentWatch
//
//  Native Pi editor-status observation, separate from the Herdr manifests.
//  See Pi's CustomEditor.renderTopBorder and StatusIndicator (README baseline).
//

import Foundation

nonisolated enum PiWorking {
    // Pi's built-in Loader frames. A default spinner in the editor border
    // means active work, including compaction, branch summaries, and retries.
    // Labels may be truncated or customized; they are not the state signal.
    private static let spinner = "[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"
    private static let statusBorder =
        "^── \(spinner)(?: [^─]*)? ─+(?: ↑ [0-9]+ more ─+)?$"
    private static let compactStatusBorder = "^─{1,3}\(spinner)─*$"
    private static let bottomBorder = "^─+(?: ↓ [0-9]+ more ─+)?$"
    private static let plainTopBorder = "^─+(?: ↑ [0-9]+ more ─+)?$"
    private static let compactionStatus =
        "^ \(spinner) Compacting context\\.\\.\\. \\((?:esc|escape) to cancel\\) *$"

    static func detect(screen: String) -> Detection? {
        let lines = rustLines(screen)
        // Inspect only the last pair of left-aligned border-like lines, not
        // every historical status in the transcript. Below-editor widgets
        // can be arbitrarily tall, so a fixed bottom-N region is insufficient.
        // Keep leading whitespace significant: editor input and quoted tool
        // output are padded and must not become candidate editor borders.
        let borders = lines.indices.reversed().lazy.filter { lines[$0].hasPrefix("─") }.prefix(2)
        var indices = borders.makeIterator()
        guard let bottom = indices.next(), let top = indices.next(), bottom > top + 1 else {
            return nil
        }
        let bottomLine = lines[bottom].trimmingCharacters(in: .whitespaces)
        guard bottomLine.range(of: bottomBorder, options: .regularExpression) != nil else {
            return nil
        }
        let topLine = lines[top].trimmingCharacters(in: .whitespaces)
        if topLine.range(of: statusBorder, options: .regularExpression) != nil
            || topLine.range(of: compactStatusBorder, options: .regularExpression) != nil
        {
            return Detection(
                state: .working, ruleID: "pi_status_border", skip: false, visible: true)
        }

        // The standalone compaction loader sits directly above a plain editor.
        // Require its entire padded line, default spinner, and cancel hint.
        // Never search transcript text or treat the persistent remote notice
        // as activity; only blank rows may separate the loader from the editor.
        guard topLine.range(of: plainTopBorder, options: .regularExpression) != nil,
            let precedingLine = lines[..<top].last(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }),
            String(precedingLine).range(of: compactionStatus, options: .regularExpression) != nil
        else { return nil }
        return Detection(
            state: .working, ruleID: "pi_compaction_status", skip: false, visible: true)
    }
}
