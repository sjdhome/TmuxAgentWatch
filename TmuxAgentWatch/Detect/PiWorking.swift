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

    static func isWorking(screen: String) -> Bool {
        let lines = rustLines(screen)
        // Inspect only the last pair of left-aligned border-like lines, not
        // every historical status in the transcript. Below-editor widgets
        // can be arbitrarily tall, so a fixed bottom-N region is insufficient.
        // Keep leading whitespace significant: editor input and quoted tool
        // output are padded and must not become candidate editor borders.
        let borders = lines.indices.reversed().lazy.filter { lines[$0].hasPrefix("─") }.prefix(2)
        var indices = borders.makeIterator()
        guard let bottom = indices.next(), let top = indices.next(), bottom > top + 1 else {
            return false
        }
        let bottomLine = lines[bottom].trimmingCharacters(in: .whitespaces)
        guard bottomLine.range(of: bottomBorder, options: .regularExpression) != nil else {
            return false
        }
        let topLine = lines[top].trimmingCharacters(in: .whitespaces)
        return topLine.range(of: statusBorder, options: .regularExpression) != nil
            || topLine.range(of: compactStatusBorder, options: .regularExpression) != nil
    }
}
