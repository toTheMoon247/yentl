//
//  MatchExpiryDriverTests.swift
//  YentlMatchmakerUITests
//
//  Driver for the hands-on match-expiry test (autonomous build brief §2).
//  NOT a normal regression suite: the three steps are invoked one at a time
//  via -only-testing:, with database work (forced expiry / cron observation)
//  happening between steps outside the tests. Step 2 and 3 drive the *consumer*
//  app (com.yentl.app), which must already be installed on the simulator.
//
//  Step 2/3 pick the accepting user by display name from the DEBUG test-login
//  picker; pass it with TEST_RUNNER_A_NAME (defaults to "Caleb").
//

import XCTest

final class MatchExpiryDriverTests: XCTestCase {

    private let matchmakerBundleID = "com.yentl.matchmaker"
    private let consumerBundleID = "com.yentl.app"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Step 1 — matchmaker creates a match for the pinned user

    func testStep1_CreateMatch() throws {
        let app = XCUIApplication(bundleIdentifier: matchmakerBundleID)
        app.launch()

        // Sign in with the DEBUG staff shortcut if the auth screen is up.
        let debugSignIn = app.buttons["Sign in as test staff (DEBUG)"]
        if debugSignIn.waitForExistence(timeout: 6) {
            debugSignIn.tap()
        }

        // Review tab is the default tab; wait for the pinned card to load.
        let pinnedBadge = app.staticTexts["PINNED USER"]
        XCTAssertTrue(pinnedBadge.waitForExistence(timeout: 30),
                      "Decision Panel never showed a pinned user")

        let matchButton = app.buttons["Match"]
        XCTAssertTrue(matchButton.waitForExistence(timeout: 10))
        XCTAssertTrue(matchButton.isEnabled,
                      "Match button disabled — pinned user has no candidates")
        shoot("step1-decision-panel")
        matchButton.tap()

        // Confirmation dialog button label is "Match <A> with <B>" — record it.
        let confirm = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Match ' AND label CONTAINS ' with '")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8),
                      "Create-match confirmation dialog did not appear")
        NSLog("MATCH-DRIVER pairing: %@", confirm.label)
        shoot("step1-confirm-dialog")
        confirm.tap()

        // Failure surfaces as an alert; success reloads the panel.
        let errorAlert = app.alerts["Couldn't create match"]
        if errorAlert.waitForExistence(timeout: 8) {
            shoot("step1-create-failed")
            XCTFail("create_match failed: \(errorAlert.label)")
        }
        shoot("step1-after-match")
    }

    // MARK: Step 2 — consumer app: accept as user A (one side only)

    func testStep2_AcceptAsA() throws {
        let aName = ProcessInfo.processInfo.environment["A_NAME"] ?? "Caleb"
        let app = XCUIApplication(bundleIdentifier: consumerBundleID)
        app.launch()

        try signIn(as: aName, in: app)

        let matchesTab = app.tabBars.buttons["Matches"]
        XCTAssertTrue(matchesTab.waitForExistence(timeout: 30),
                      "Tab bar never appeared after switching to \(aName)")
        matchesTab.tap()

        // The pending, unanswered match row. Matched on the stable prefix: the
        // window is derived from AppConfig, so it reads "5m" in DEBUG and "24h"
        // in Release. Asserting the whole literal broke when it stopped being
        // hardcoded.
        let newRow = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "New match — respond within")
        ).firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 20),
                      "No pending match row for \(aName)")
        shoot("step2-matches-list")
        newRow.tap()

        let accept = app.buttons["Accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 20),
                      "Match detail sheet did not show Accept")
        shoot("step2-match-detail")
        accept.tap()

        // On success the sheet dismisses and the list reloads to "Waiting for them".
        let waitingRow = app.staticTexts["Waiting for them"]
        XCTAssertTrue(waitingRow.waitForExistence(timeout: 20),
                      "Accept did not register (no 'Waiting for them' row)")
        shoot("step2-accepted")
    }

    // MARK: Step 3 — consumer app as A: the match shows as expired

    func testStep3_VerifyExpired() throws {
        let aName = ProcessInfo.processInfo.environment["A_NAME"] ?? "Caleb"
        let app = XCUIApplication(bundleIdentifier: consumerBundleID)
        app.launch()

        // Session should still be A's from step 2; if the app is signed out
        // (fresh state), sign back in as A.
        let matchesTab = app.tabBars.buttons["Matches"]
        if !matchesTab.waitForExistence(timeout: 10) {
            try signIn(as: aName, in: app)
            XCTAssertTrue(matchesTab.waitForExistence(timeout: 30))
        }
        matchesTab.tap()

        let expiredRow = app.staticTexts["Expired"]
        XCTAssertTrue(expiredRow.waitForExistence(timeout: 20),
                      "Matches list has no 'Expired' row for \(aName)")
        shoot("step3-matches-list-expired")
        expiredRow.tap()

        let banner = app.staticTexts["This match expired."]
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "Match detail did not show 'This match expired.'")
        shoot("step3-this-match-expired")

        // Also confirm there is no Accept/Pass bar on an expired match.
        XCTAssertFalse(app.buttons["Accept"].exists,
                       "Expired match still offers Accept")

        // Hold the screen so the host can grab an independent live screenshot.
        Thread.sleep(forTimeInterval: 25)
    }

    // MARK: Helpers

    /// Opens the DEBUG test-login picker (works from the signed-out screen or
    /// the Profile tab) and switches to the seed account labeled `name`.
    private func signIn(as name: String, in app: XCUIApplication) throws {
        let tabBar = app.tabBars.buttons["Profile"]
        if tabBar.waitForExistence(timeout: 8) {
            tabBar.tap()
        }
        let debugButton = app.buttons["debug-test-login"]
        XCTAssertTrue(debugButton.waitForExistence(timeout: 20),
                      "No debug test-login entry point on screen")
        debugButton.tap()

        // The picker is a lazy List (20 women above the men) — scroll until
        // the wanted row is on screen.
        let row = app.buttons[name]
        var attempts = 0
        while !row.exists && attempts < 12 {
            app.swipeUp(velocity: .fast)
            attempts += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Test-login picker has no row named \(name)")
        row.tap()

        // The picker sheet dismisses itself once the switch succeeds.
        let picker = app.navigationBars["Log in as… (DEBUG)"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: picker)
        waitForExpectations(timeout: 30)
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
