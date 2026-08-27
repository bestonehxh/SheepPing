//
//  SheepPingUITests.swift
//  SheepPingUITests
//
//  Created by Bestchaan on 2/5/2569 BE.
//

import AppKit
import XCTest

final class SheepPingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Launches the app with the argument domain overriding saved state, so every
    // test starts from a known host list without touching the user's real
    // UserDefaults. Values use the old-style plist syntax NSArgumentDomain parses.
    @MainActor
    private func launchApp(hosts: [String], interval: Double = 1.0) -> XCUIApplication {
        let app = XCUIApplication()
        let plistArray = "(" + hosts.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
        app.launchArguments += [
            "-savedHosts", plistArray,
            "-pingInterval", String(interval),
            "-pingTimeout", "3.0",
            "-appTheme", "system",
        ]
        app.launch()
        // Toolbar clicks fired before the window finishes loading miss silently
        // (flaky under a full-suite run's rapid relaunches), so hold until the
        // table header — present in every state — is on screen.
        _ = app.staticTexts["HOST"].waitForExistence(timeout: 10)
        return app
    }

    // MARK: - Empty state

    @MainActor
    func testEmptyStateShowsPlaceholder() throws {
        let app = launchApp(hosts: [])
        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Select a host to view its log"].exists)
    }

    // MARK: - Add host and live ping

    @MainActor
    func testAddHostShowsRowAndPingsSuccessfully() throws {
        let app = launchApp(hosts: [])

        // The sheet is a single multi-line editor now — no single-host mode.
        app.buttons["Add Host"].firstMatch.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add"].firstMatch.isEnabled,
                       "Add must stay disabled while the editor is empty")

        let sheetShot = XCTAttachment(screenshot: app.screenshot())
        sheetShot.name = "add-host-sheet"
        sheetShot.lifetime = .keepAlways
        add(sheetShot)

        editor.click()
        editor.typeText("127.0.0.1")
        app.buttons["Add"].firstMatch.click()

        // Row appears and loopback answers within a couple of intervals.
        XCTAssertTrue(app.staticTexts["127.0.0.1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OK"].firstMatch.waitForExistence(timeout: 15),
                      "loopback ping should report OK")
        XCTAssertTrue(app.staticTexts["1 active"].firstMatch.exists)
    }

    @MainActor
    func testUnreachableHostShowsFail() throws {
        // TEST-NET-3: guaranteed to never answer.
        let app = launchApp(hosts: ["203.0.113.99"])
        XCTAssertTrue(app.staticTexts["203.0.113.99"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fail"].firstMatch.waitForExistence(timeout: 20),
                      "black-hole host should report Fail")
    }

    // MARK: - Log section

    @MainActor
    func testSelectingHostShowsItsLog() throws {
        let app = launchApp(hosts: ["127.0.0.1"])
        let row = app.staticTexts["127.0.0.1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OK"].firstMatch.waitForExistence(timeout: 15))
        row.click()
        // The log header's action buttons only exist once the selected host has
        // log entries, so their appearance proves both selection and streaming.
        XCTAssertTrue(app.buttons["Save…"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Clear"].firstMatch.exists)
    }

    // MARK: - Stop / Resume / Restart

    @MainActor
    func testStopAllThenResume() throws {
        let app = launchApp(hosts: ["127.0.0.1"])
        XCTAssertTrue(app.staticTexts["1 active"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["Stop All"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Stopped"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Idle"].firstMatch.waitForExistence(timeout: 5))

        app.buttons["Resume"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["1 active"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OK"].firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    func testRestartAllResetsCounters() throws {
        let app = launchApp(hosts: ["127.0.0.1"])
        XCTAssertTrue(app.staticTexts["OK"].firstMatch.waitForExistence(timeout: 15))

        app.buttons["Restart All"].firstMatch.click()
        // Counters clear and pinging continues.
        XCTAssertTrue(app.staticTexts["1 active"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OK"].firstMatch.waitForExistence(timeout: 15))
    }

    // MARK: - Settings sheet

    @MainActor
    func testSettingsSheetOpensAndCloses() throws {
        let app = launchApp(hosts: [])
        app.buttons["Settings"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Ping Interval"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Reply Timeout"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Appearance"].firstMatch.exists)
        XCTAssertEqual(app.sliders.count, 2)
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 5))
    }

    // MARK: - Remove

    @MainActor
    func testRemoveSelectedHost() throws {
        let app = launchApp(hosts: ["127.0.0.1", "203.0.113.99"])
        let row = app.staticTexts["203.0.113.99"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        app.buttons["Remove"].firstMatch.click()
        XCTAssertFalse(app.staticTexts["203.0.113.99"].firstMatch
            .waitForExistence(timeout: 2), "removed host row should disappear")
        XCTAssertTrue(app.staticTexts["127.0.0.1"].firstMatch.exists)
    }

    // MARK: - Bulk add

    @MainActor
    func testMultipleHostsAndSheetCancel() throws {
        // Two hosts prove the table and the active-count chip handle more than
        // one row. They arrive via launch state: typing can't be synthesized
        // once a row is pinging (the running dot's repeatForever pulse keeps
        // the app from ever reporting idle, and typeText times out waiting).
        let app = launchApp(hosts: ["127.0.0.1", "localhost"])
        XCTAssertTrue(app.staticTexts["127.0.0.1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["localhost"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["2 active"].firstMatch.waitForExistence(timeout: 5))

        // The sheet opens straight into the multi-line editor and Cancel backs
        // out without touching the host list.
        app.buttons["Add Host"].firstMatch.click()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add"].firstMatch.isEnabled)
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["2 active"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - Launch performance

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
