//
//  PaneJump.swift
//  TmuxAgentWatch
//
//  Double-click navigation: bring the exact GUI terminal window hosting a
//  pane's tmux client to the front and give the pane itself focus — its
//  window becomes the session's current window and the pane its active pane.
//

import AppKit
import ApplicationServices
import Foundation
import os

@MainActor
enum PaneJump {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TmuxAgentWatch", category: "PaneJump")

    /// Reveal a pane in an attached GUI terminal.
    ///
    /// Picks a tmux client attached to `session` whose process ancestry
    /// leads to a regular GUI app (Ghostty, Kitty, Terminal.app, iTerm2, … —
    /// anything with a Dock presence, so SSH or headless clients never
    /// match), focuses `paneID` inside the session (window switch plus
    /// active-pane switch), and focuses the specific terminal window
    /// rendering that client's tty. Window-precise focus needs the
    /// Accessibility permission; without it the whole app is activated
    /// instead. When no attached client leads to a GUI terminal (nothing
    /// attached at all, or only SSH/headless clients) an error alert is
    /// shown instead of failing silently.
    static func reveal(session: String, paneID: String) async {
        // Test seam: UI tests verify the double-click wiring without
        // stealing focus or mutating tmux.
        if let dryRunLog = ProcessInfo.processInfo.environment["TAW_JUMP_DRY_RUN_LOG"] {
            try? "\(session):\(paneID)".write(
                toFile: dryRunLog, atomically: true, encoding: .utf8)
            return
        }

        let candidates = await Task.detached(priority: .userInitiated) {
            TmuxClient.listClients()
                .filter { $0.session == session }
                .map { (client: $0, chain: ancestry(of: $0.pid)) }
        }.value

        var hosting: (client: TmuxClientInfo, app: NSRunningApplication)?
        for candidate in candidates {
            if let app = guiApplication(hosting: candidate.chain) {
                hosting = (candidate.client, app)
                break
            }
        }
        guard let (client, app) = hosting else {
            logger.info("no GUI terminal client attached to \(session, privacy: .public)")
            presentNoTerminalAlert(session: session)
            return
        }

        // Locate the hosting window before the pane switch: locating may
        // inject a title change on the client tty, which must not race with
        // tmux's own title updates triggered by the window/pane switch.
        let window = await locateWindow(of: app, clientTTY: client.tty)

        let switched = await Task.detached(priority: .userInitiated) {
            TmuxClient.selectPane(paneID: paneID)
        }.value
        guard switched else {
            logger.error("select-pane failed for \(paneID, privacy: .public)")
            NSSound.beep()
            return
        }

        if let window {
            unminimizeAndRaise(window)
        } else {
            logger.info("window-precise focus unavailable; activating the app only")
        }
        NSApplication.shared.yieldActivation(to: app)
        app.activate()
    }

    /// Error alert for the one failure the user needs to know about:
    /// nothing to focus, because no client attached to the session traces
    /// back to a GUI terminal app — the session has no attached client at
    /// all, or only SSH/headless ones.
    private static func presentNoTerminalAlert(session: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Cannot Find a Terminal Window")
        alert.informativeText = String(
            localized:
                "No GUI terminal on this Mac is attached to tmux session “\(session)” — the session may be detached, or attached only from SSH. Attach to it from a local terminal app first."
        )
        NSApplication.shared.activate()
        alert.runModal()
    }

    // MARK: - Finding the hosting terminal app

    /// `pid` plus its ancestors, innermost first, stopping at launchd.
    nonisolated private static func ancestry(of pid: UInt32) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        for _ in 0..<16 where current > 1 {
            chain.append(pid_t(current))
            guard let parent = ProcessInspector.parentPid(of: current) else { break }
            current = parent
        }
        return chain
    }

    /// The innermost process in the chain that is a regular GUI application
    /// — for a tmux client, the terminal app hosting its tty. Plain unix
    /// ancestors (shells, login) have no NSRunningApplication.
    private static func guiApplication(hosting chain: [pid_t]) -> NSRunningApplication? {
        for pid in chain {
            if let app = NSRunningApplication(processIdentifier: pid),
                app.activationPolicy == .regular
            {
                return app
            }
        }
        return nil
    }

    // MARK: - Finding the hosting window (Accessibility)

    /// The AX window of `app` rendering `clientTTY`, or nil when the
    /// Accessibility permission is missing or the window cannot be told
    /// apart.
    ///
    /// With multiple windows the hosting one is identified by writing an
    /// OSC 2 (set window title) escape with a unique token straight to the
    /// client tty — the terminal applies it to exactly the window rendering
    /// that tty — then restoring the previous title. tmux may be drawing to
    /// the same tty concurrently; the OSC bytes are invisible and any torn
    /// frame is repaired on the next redraw.
    private static func locateWindow(of app: NSRunningApplication, clientTTY: String) async
        -> AXUIElement?
    {
        guard ensureAccessibilityPermission() else {
            logger.info("Accessibility not granted; cannot pick the exact window")
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = axWindows(of: appElement)
        guard windows.count > 1 else { return windows.first }

        let previousTitles = windows.map { (window: $0, title: axTitle(of: $0)) }
        let token = "tmux-agent-watch-\(UUID().uuidString)"
        guard writeTitle(token, toTTY: clientTTY) else {
            logger.error("cannot write to client tty \(clientTTY, privacy: .public)")
            return nil
        }

        // The terminal needs a moment to consume the escape and republish
        // its window title to the accessibility tree.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let match = axWindows(of: appElement).first(where: { axTitle(of: $0) == token })
            else { continue }
            let previous = previousTitles.first { CFEqual($0.window, match) }?.title
            _ = writeTitle(previous ?? "", toTTY: clientTTY)
            return match
        }
        _ = writeTitle("", toTTY: clientTTY)
        logger.error("no window picked up the title token; terminal may ignore OSC 2")
        return nil
    }

    /// Asks the system to show the grant prompt on first use.
    private static func ensureAccessibilityPermission() -> Bool {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func axWindows(of appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func axTitle(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
                == .success
        else { return nil }
        return value as? String
    }

    private static func unminimizeAndRaise(_ window: AXUIElement) {
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            == .success, (minimized as? Bool) == true
        {
            _ = AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// OSC 2 — set the terminal window's title, written straight to the
    /// client tty, bypassing tmux.
    nonisolated private static func writeTitle(_ title: String, toTTY tty: String) -> Bool {
        let fd = open(tty, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array("\u{1B}]2;\(title)\u{07}".utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count) == buffer.count
        }
    }
}
