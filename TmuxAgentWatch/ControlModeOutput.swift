import Foundation

/// A command's stdout or an error block. Error text is deliberately not retained.
nonisolated enum ControlModeBlock: Equatable, Sendable {
    case output(String)
    case failure
}

/// Parses a completed, unattached `tmux -C` command sequence. Payload lines are
/// never treated as notifications. Only a matching guard closes the current block;
/// unexpected/truncated framing rejects the batch so callers can use plain capture.
nonisolated enum ControlModeOutput {
    static func parse(_ text: String) -> [ControlModeBlock]? {
        guard text.hasSuffix("\n") else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        var blocks: [ControlModeBlock] = []
        var guardID: String?
        var payload = ""
        var exited = false
        for line in lines {
            guard !exited else { return nil }
            if let id = guardID {
                if line == "%end \(id)" || line == "%error \(id)" {
                    blocks.append(line.hasPrefix("%end ") ? .output(payload) : .failure)
                    guardID = nil
                    payload = ""
                } else {
                    payload += line + "\n"
                }
            } else if line == "%exit" || line.hasPrefix("%exit ") {
                exited = true
            } else {
                let fields = line.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 4, fields[0] == "%begin",
                    fields.dropFirst().allSatisfy({ UInt64($0) != nil })
                else { return nil }
                guardID = fields.dropFirst().joined(separator: " ")
            }
        }
        guard exited, guardID == nil, !blocks.isEmpty else { return nil }
        return blocks
    }
}
