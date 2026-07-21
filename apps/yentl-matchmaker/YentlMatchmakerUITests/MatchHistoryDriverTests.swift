//
//  MatchHistoryDriverTests.swift
//  YentlMatchmakerUITests
//
//  Driver for the Phase 6 Slice 3 hands-on verification (matchmaker app):
//  walks the Recent Matches dashboard and the per-user Match History screens
//  against the live seed data, capturing screenshots as attachments. Like
//  MatchExpiryDriverTests, this is NOT a regression suite — it is invoked
//  manually and the walkthrough test also *creates a real match* (allowed for
//  this verification) so the pending countdown can be seen live.
//

import XCTest

final class MatchHistoryDriverTests: XCTestCase {

    private let matchmakerBundleID = "com.yentl.matchmaker"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Dashboard (resolved row) → per-user history → empty state.
    /// Read-only: creates nothing.
    func testStep1_HistoryScreens() throws {
        let app = launchSignedIn()

        // --- Recent Matches dashboard: the one expired Caleb–Chloe match.
        app.tabBars.buttons["Matches"].tap()
        let pairRow = app.staticTexts["Caleb & Chloe"]
        XCTAssertTrue(pairRow.waitForExistence(timeout: 30),
                      "Dashboard never showed the Caleb & Chloe row")
        XCTAssertTrue(app.staticTexts["EXPIRED"].exists, "Row is missing its EXPIRED badge")
        shoot("slice3-dashboard")

        // --- Row tap offers each participant's history.
        pairRow.tap()
        let calebChoice = app.buttons["Caleb"]
        XCTAssertTrue(calebChoice.waitForExistence(timeout: 8),
                      "History chooser dialog did not appear")
        shoot("slice3-dashboard-chooser")
        calebChoice.tap()

        // --- Caleb's history: one row, other participant Chloe, expired.
        let title = app.navigationBars["Caleb's matches"]
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "Per-user history screen did not open")
        XCTAssertTrue(app.staticTexts["Chloe"].waitForExistence(timeout: 20),
                      "Caleb's history does not list Chloe")
        XCTAssertTrue(app.staticTexts["EXPIRED"].exists)
        XCTAssertTrue(app.staticTexts["Caleb: accepted · Chloe: no reply"].exists,
                      "Responses line missing or misworded")
        shoot("slice3-history-caleb")

        // --- Empty state: someone who has never been in a match (Sofia),
        // reached the way a matchmaker would — Queue → Decision Panel → history.
        app.tabBars.buttons["Queue"].tap()
        let sofiaRow = app.cells.containing(NSPredicate(format: "label CONTAINS 'Sofia'")).firstMatch
        XCTAssertTrue(sofiaRow.waitForExistence(timeout: 20), "Queue has no Sofia row")
        sofiaRow.tap()

        let historyButton = app.buttons["Match history"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 20),
                      "Decision Panel has no Match history toolbar button")
        historyButton.tap()

        XCTAssertTrue(app.staticTexts["No matches yet"].waitForExistence(timeout: 20),
                      "Sofia's history should be empty")
        shoot("slice3-history-empty")

        // Hold so the host can grab an independent live screenshot.
        Thread.sleep(forTimeInterval: 15)
    }

    /// Creates a real match from the Review tab (allowed for this
    /// verification), then shows the pending countdown on the dashboard and
    /// in per-user history. Run after step 1.
    func testStep2_PendingCountdown() throws {
        let app = launchSignedIn()

        // --- Create a match for the pinned (front-of-queue) user.
        let pinnedBadge = app.staticTexts["PINNED USER"]
        XCTAssertTrue(pinnedBadge.waitForExistence(timeout: 30),
                      "Decision Panel never showed a pinned user")
        let matchButton = app.buttons["Match"]
        XCTAssertTrue(matchButton.waitForExistence(timeout: 10))
        XCTAssertTrue(matchButton.isEnabled,
                      "Match button disabled — pinned user has no candidates")
        matchButton.tap()

        let confirm = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Match ' AND label CONTAINS ' with '")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8),
                      "Create-match confirmation dialog did not appear")
        NSLog("MATCH-DRIVER pairing: %@", confirm.label)
        confirm.tap()

        let errorAlert = app.alerts["Couldn't create match"]
        if errorAlert.waitForExistence(timeout: 8) {
            shoot("slice3-create-failed")
            XCTFail("create_match failed: \(errorAlert.label)")
        }

        // --- Dashboard now has a PENDING row with a live countdown.
        app.tabBars.buttons["Matches"].tap()
        let pendingBadge = app.staticTexts["PENDING"]
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: 30),
                      "Dashboard shows no PENDING row after creating a match")
        let countdown = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS ' left'")
        ).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 10),
                      "Pending row shows no time-remaining countdown")
        NSLog("MATCH-DRIVER countdown: %@", countdown.label)
        shoot("slice3-dashboard-pending")

        // --- The same countdown from a participant's history.
        let pendingCell = app.cells.containing(
            NSPredicate(format: "label CONTAINS 'PENDING'")
        ).firstMatch
        pendingCell.tap()
        let firstChoice = app.sheets.buttons.element(boundBy: 0)
        XCTAssertTrue(firstChoice.waitForExistence(timeout: 8),
                      "History chooser dialog did not appear for the pending row")
        firstChoice.tap()

        let historyCountdown = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS ' left'")
        ).firstMatch
        XCTAssertTrue(historyCountdown.waitForExistence(timeout: 20),
                      "Per-user history shows no countdown for the pending match")
        shoot("slice3-history-pending")

        // Hold so the host can grab an independent live screenshot.
        Thread.sleep(forTimeInterval: 15)
    }

    // MARK: - Helpers

    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: matchmakerBundleID)
        app.launch()
        let debugSignIn = app.buttons["Sign in as test staff (DEBUG)"]
        if debugSignIn.waitForExistence(timeout: 6) {
            debugSignIn.tap()
        }
        return app
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
