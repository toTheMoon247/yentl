//
//  MatchRejectDriverTests.swift
//  YentlMatchmakerUITests
//
//  Driver for the hands-on EXPLICIT-REJECT test — the third and last untested
//  scenario of Phase 6's exit criteria (both-accept and expiry were verified
//  earlier). Like MatchExpiryDriverTests this is NOT a regression suite: steps
//  are invoked one at a time via -only-testing:, with read-only DB verification
//  happening between steps outside the tests.
//
//  DEBUG matches expire after 5 minutes and pg_cron sweeps every minute, so
//  each ordering's create-match + respond flow lives in ONE test method and
//  runs well inside the window. A rejection resolves the match immediately,
//  after which the sweep can no longer touch it.
//
//  The pair's names are parsed from the matchmaker confirmation dialog
//  ("Match <A> with <B>") and logged as MATCH-DRIVER lines for the host.
//

import XCTest

final class MatchRejectDriverTests: XCTestCase {

    private let matchmakerBundleID = "com.yentl.matchmaker"
    private let consumerBundleID = "com.yentl.app"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Ordering 1 — A (pinned) accepts, then B explicitly rejects

    func testO1_AcceptThenReject() throws {
        let (aName, bName) = try createMatchViaMatchmaker(tag: "o1")

        let app = XCUIApplication(bundleIdentifier: consumerBundleID)
        app.launch()

        // A accepts.
        try signIn(as: aName, in: app)
        openPendingMatch(in: app, tag: "o1-\(aName)")
        let accept = app.buttons["Accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 20),
                      "Match detail sheet did not show Accept for \(aName)")
        accept.tap()
        XCTAssertTrue(app.staticTexts["Waiting for them"].waitForExistence(timeout: 20),
                      "Accept did not register for \(aName)")
        shoot("o1-a-accepted")

        // B explicitly rejects (Pass).
        try signIn(as: bName, in: app)
        openPendingMatch(in: app, tag: "o1-\(bName)")
        let pass = app.buttons["Pass"]
        XCTAssertTrue(pass.waitForExistence(timeout: 20),
                      "Match detail sheet did not show Pass for \(bName)")
        shoot("o1-b-before-pass")
        pass.tap()

        // On success the sheet dismisses and the list reloads to "Not a match".
        XCTAssertTrue(app.staticTexts["Not a match"].waitForExistence(timeout: 20),
                      "Pass did not register (no 'Not a match' row for \(bName))")
        shoot("o1-b-rejected-list")
        NSLog("MATCH-DRIVER o1 done: A=%@ accepted, B=%@ rejected", aName, bName)
    }

    // MARK: Ordering 2 — B rejects first; A never responds

    func testO2_RejectImmediately() throws {
        let (aName, bName) = try createMatchViaMatchmaker(tag: "o2")

        let app = XCUIApplication(bundleIdentifier: consumerBundleID)
        app.launch()

        // B rejects straight away; A is never touched.
        try signIn(as: bName, in: app)
        openPendingMatch(in: app, tag: "o2-\(bName)")
        let pass = app.buttons["Pass"]
        XCTAssertTrue(pass.waitForExistence(timeout: 20),
                      "Match detail sheet did not show Pass for \(bName)")
        shoot("o2-b-before-pass")
        pass.tap()

        XCTAssertTrue(app.staticTexts["Not a match"].waitForExistence(timeout: 20),
                      "Pass did not register (no 'Not a match' row for \(bName))")
        shoot("o2-b-rejected-list")
        NSLog("MATCH-DRIVER o2 done: A=%@ never responded, B=%@ rejected", aName, bName)
    }

    // MARK: What a rejected-upon user sees (run with TEST_RUNNER_USER_NAME)

    func testViewAsUser() throws {
        let name = ProcessInfo.processInfo.environment["USER_NAME"] ?? "Sofia"
        let app = XCUIApplication(bundleIdentifier: consumerBundleID)
        app.launch()

        try signIn(as: name, in: app)
        let matchesTab = app.tabBars.buttons["Matches"]
        XCTAssertTrue(matchesTab.waitForExistence(timeout: 30))
        matchesTab.tap()

        let rejectedRow = app.staticTexts["Not a match"].firstMatch
        XCTAssertTrue(rejectedRow.waitForExistence(timeout: 20),
                      "Matches list has no 'Not a match' row for \(name)")
        shoot("view-\(name)-matches-list")
        rejectedRow.tap()

        let banner = app.staticTexts["Not a match."]
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "Match detail did not show the 'Not a match.' banner")
        XCTAssertFalse(app.buttons["Accept"].exists,
                       "Rejected match still offers Accept")
        XCTAssertFalse(app.buttons["Pass"].exists,
                       "Rejected match still offers Pass")
        shoot("view-\(name)-not-a-match-detail")

        // Hold the screen so the host can grab an independent live screenshot.
        Thread.sleep(forTimeInterval: 25)
    }

    // MARK: Matchmaker dashboard + per-user history show the rejected match
    // Run with TEST_RUNNER_EXPECT_PAIR ("Sofia & Leo"),
    // TEST_RUNNER_EXPECT_LINE ("Sofia: accepted · Leo: rejected") and
    // TEST_RUNNER_HIST_NAME (participant whose history to open).

    func testMatchmakerHistory() throws {
        let env = ProcessInfo.processInfo.environment
        let expectPair = env["EXPECT_PAIR"] ?? "Sofia & Leo"
        let expectLine = env["EXPECT_LINE"] ?? ""
        let histName = env["HIST_NAME"] ?? "Sofia"

        let app = XCUIApplication(bundleIdentifier: matchmakerBundleID)
        app.launch()
        let debugSignIn = app.buttons["Sign in as test staff (DEBUG)"]
        if debugSignIn.waitForExistence(timeout: 6) {
            debugSignIn.tap()
        }

        app.tabBars.buttons["Matches"].tap()
        let pairRow = app.staticTexts[expectPair].firstMatch
        XCTAssertTrue(pairRow.waitForExistence(timeout: 30),
                      "Dashboard never showed the \(expectPair) row")
        XCTAssertTrue(app.staticTexts["REJECTED"].firstMatch.exists,
                      "Dashboard has no REJECTED badge")
        if !expectLine.isEmpty {
            XCTAssertTrue(app.staticTexts[expectLine].firstMatch.waitForExistence(timeout: 10),
                          "Dashboard responses line '\(expectLine)' not found")
        }
        let resolvedLine = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS ' · resolved '")
        ).firstMatch
        XCTAssertTrue(resolvedLine.exists, "Dashboard shows no 'resolved' timestamp line")
        shoot("mm-dashboard-rejected")

        // Row tap → participant chooser → per-user history.
        pairRow.tap()
        let choice = app.buttons[histName].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 8),
                      "History chooser dialog did not offer \(histName)")
        choice.tap()

        let title = app.navigationBars["\(histName)'s matches"]
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "Per-user history screen did not open for \(histName)")
        XCTAssertTrue(app.staticTexts["REJECTED"].firstMatch.waitForExistence(timeout: 20),
                      "\(histName)'s history has no REJECTED badge")
        if !expectLine.isEmpty {
            XCTAssertTrue(app.staticTexts[expectLine].firstMatch.waitForExistence(timeout: 10),
                          "History responses line '\(expectLine)' not found")
        }
        let histResolved = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS ' · resolved '")
        ).firstMatch
        XCTAssertTrue(histResolved.exists, "History shows no 'resolved' timestamp line")
        shoot("mm-history-rejected")

        // Hold the screen so the host can grab an independent live screenshot.
        Thread.sleep(forTimeInterval: 25)
    }

    // MARK: - Helpers

    /// Matchmaker app: sign in (DEBUG), create a match for the pinned user,
    /// and return (pinned, candidate) parsed from the confirmation label
    /// "Match <A> with <B>".
    private func createMatchViaMatchmaker(tag: String) throws -> (String, String) {
        let app = XCUIApplication(bundleIdentifier: matchmakerBundleID)
        app.launch()

        let debugSignIn = app.buttons["Sign in as test staff (DEBUG)"]
        if debugSignIn.waitForExistence(timeout: 6) {
            debugSignIn.tap()
        }

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
        let label = confirm.label
        NSLog("MATCH-DRIVER %@ pairing: %@", tag, label)
        shoot("\(tag)-confirm-dialog")
        confirm.tap()

        let errorAlert = app.alerts["Couldn't create match"]
        if errorAlert.waitForExistence(timeout: 5) {
            shoot("\(tag)-create-failed")
            XCTFail("create_match failed: \(errorAlert.label)")
        }

        // "Match <A> with <B>" → (A, B).
        let trimmed = String(label.dropFirst("Match ".count))
        let parts = trimmed.components(separatedBy: " with ")
        XCTAssertEqual(parts.count, 2, "Could not parse pair from '\(label)'")
        return (parts[0], parts[1])
    }

    /// Consumer app: open the Matches tab and the single pending match row.
    private func openPendingMatch(in app: XCUIApplication, tag: String) {
        let matchesTab = app.tabBars.buttons["Matches"]
        XCTAssertTrue(matchesTab.waitForExistence(timeout: 30),
                      "Tab bar never appeared (\(tag))")
        matchesTab.tap()

        let newRow = app.staticTexts["New match — respond within 24h"]
        XCTAssertTrue(newRow.waitForExistence(timeout: 20),
                      "No pending match row (\(tag))")
        shoot("\(tag)-matches-list")
        newRow.tap()
    }

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
