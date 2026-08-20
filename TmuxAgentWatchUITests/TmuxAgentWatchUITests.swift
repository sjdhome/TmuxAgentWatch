//
//  TmuxAgentWatchUITests.swift
//  TmuxAgentWatchUITests
//
//  Created by sjdhome on 2026/8/20.
//

import XCTest

final class TmuxAgentWatchUITests: XCTestCase {
    @MainActor
    func testLaunchShowsMainWindow() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// Double-clicking a row must reach PaneJump. TAW_JUMP_DRY_RUN_LOG makes
    /// the jump write its target to a file instead of touching tmux or the
    /// window server, so this asserts only the activation wiring.
    @MainActor
    func testDoubleClickingARowFiresJump() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("taw-jump-\(UUID().uuidString).log")
        let app = XCUIApplication()
        app.launchEnvironment["TAW_JUMP_DRY_RUN_LOG"] = log.path
        app.launch()

        let row = app.descendants(matching: .any)
            .matching(identifier: "pane-row").firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("no agent panes running on this machine")
        }
        row.doubleClick()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !FileManager.default.fileExists(atPath: log.path) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let target = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(target.contains(":"), "unexpected jump target: \(target)")
    }
}
