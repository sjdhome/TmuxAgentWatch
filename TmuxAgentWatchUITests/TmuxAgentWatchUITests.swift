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
}
