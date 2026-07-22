//
//  ReviewStatesDriverTests.swift
//  YentlUITests
//
//  Driver for the Phase 12 Slice 3 hands-on verification: walks the consumer
//  approval states against the LOCAL Supabase stack, capturing screenshots.
//  Like the other *DriverTests, this is NOT a regression suite — it is invoked
//  manually and expects the local demo seed:
//    - seed-f-02 (Maya)   review_state = pending_review
//    - seed-m-05 (Daniel) review_state = rejected, with a profile_moderation
//      row whose decision_reason is
//      "contact_info_in_bio: Please remove the Instagram handle from your bio."
//
//  testFlagOnStates expects profile_approval_enabled = true (resubmit parks
//  Daniel in pending_ai). testFlagOffResubmitGoesLive expects the flag OFF and
//  Daniel reset to rejected — resubmit must land straight in the normal app,
//  proving today's flag-OFF behavior is preserved.
//

import XCTest

final class ReviewStatesDriverTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Flag ON: under-review screen, needs-changes screen (reason + note),
    /// edit-prefill, resubmit → back to under review; a live seed still gets
    /// the normal app.
    @MainActor
    func testFlagOnStates() throws {
        let app = XCUIApplication()
        app.launch()

        // --- Maya (pending_review) → "Under review" holding screen.
        signIn(app, as: "Maya")
        let underReviewTitle = app.staticTexts["Your profile is being reviewed"]
        XCTAssertTrue(underReviewTitle.waitForExistence(timeout: 60),
                      "Maya (pending_review) did not land on the under-review screen")
        XCTAssertTrue(app.buttons["Check status"].exists)
        XCTAssertFalse(app.tabBars.buttons["Discover"].exists,
                       "An under-review user must not reach discovery")
        saveScreenshot("slice3-1-under-review")

        // --- Daniel (rejected) → "Needs changes" with friendly reason + note.
        switchAccount(app, to: "Daniel")
        let needsChangesTitle = app.staticTexts["Your profile needs a few changes"]
        XCTAssertTrue(needsChangesTitle.waitForExistence(timeout: 60),
                      "Daniel (rejected) did not land on the needs-changes screen")
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS 'contact details'")
            ).firstMatch.exists,
            "Friendly contact-info copy missing"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS 'Please remove the Instagram handle'")
            ).firstMatch.exists,
            "Matchmaker note missing"
        )
        // The raw token must never be on screen.
        XCTAssertFalse(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS 'contact_info_in_bio'")
            ).firstMatch.exists,
            "Internal rejection token leaked to the UI"
        )
        saveScreenshot("slice3-2-needs-changes")

        // --- Edit & resubmit → prefilled editor.
        app.buttons["Edit & resubmit"].tap()
        XCTAssertTrue(app.navigationBars["Edit profile"].waitForExistence(timeout: 30),
                      "Edit sheet did not open")
        let nameField = app.textFields["Display name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20))
        XCTAssertEqual(nameField.value as? String, "Daniel",
                       "Editor is not prefilled with the existing profile")
        saveScreenshot("slice3-3-edit-prefilled")

        // --- Save → resubmit: completion is coerced to pending_ai (flag ON),
        // screening is best-effort (no OPENAI key locally) → under review.
        app.navigationBars["Edit profile"].buttons["Save"].tap()
        XCTAssertTrue(underReviewTitle.waitForExistence(timeout: 90),
                      "Resubmit did not route Daniel to the under-review screen")
        saveScreenshot("slice3-4-after-resubmit-under-review")

        // --- A live profile still gets the normal app (flag ON, state live).
        switchAccount(app, to: "Olivia")
        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 60),
                      "A live profile should land in the normal app")
        saveScreenshot("slice3-5-live-normal-app")

        Thread.sleep(forTimeInterval: 5)  // hold for host screenshots
    }

    /// Flag OFF (today's production state): a rejected Daniel resubmitting
    /// lands straight in the normal app — completion's 'live' write sticks.
    @MainActor
    func testFlagOffResubmitGoesLive() throws {
        let app = XCUIApplication()
        app.launch()

        signIn(app, as: "Daniel")
        XCTAssertTrue(app.staticTexts["Your profile needs a few changes"]
                        .waitForExistence(timeout: 60),
                      "Daniel was not reset to rejected before the flag-OFF run")
        app.buttons["Edit & resubmit"].tap()
        XCTAssertTrue(app.navigationBars["Edit profile"].waitForExistence(timeout: 30))
        app.navigationBars["Edit profile"].buttons["Save"].tap()

        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 90),
                      "Flag OFF: completion should go straight to live → normal app")
        saveScreenshot("slice3-6-flagoff-resubmit-normal-app")

        Thread.sleep(forTimeInterval: 5)
    }

    // MARK: - Helpers (mirrors MatchChatUITests)

    /// Signs in via the DEBUG ladybug from wherever the app currently is:
    /// the signed-out overlay, the tab bar's Profile tab, or the review
    /// status screens (which carry their own ladybug).
    @MainActor
    private func signIn(_ app: XCUIApplication, as name: String) {
        let tabBar = app.tabBars.buttons["Profile"]
        let ladybug = app.buttons["debug-test-login"].firstMatch

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !tabBar.exists && !ladybug.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if tabBar.exists && !ladybug.exists {
            tabBar.tap()
        }
        XCTAssertTrue(ladybug.waitForExistence(timeout: 15),
                      "No DEBUG login button found")
        ladybug.tap()
        pickAccount(app, name: name)
    }

    /// From any signed-in screen that shows a ladybug (tab bar Profile, or
    /// the review status toolbars).
    @MainActor
    private func switchAccount(_ app: XCUIApplication, to name: String) {
        if app.tabBars.buttons["Profile"].exists {
            app.tabBars.buttons["Profile"].tap()
        }
        let ladybug = app.buttons["debug-test-login"].firstMatch
        XCTAssertTrue(ladybug.waitForExistence(timeout: 15))
        ladybug.tap()
        pickAccount(app, name: name)
    }

    @MainActor
    private func pickAccount(_ app: XCUIApplication, name: String) {
        let row = app.buttons[name].firstMatch
        _ = row.waitForExistence(timeout: 10)
        var attempts = 0
        while !row.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Account \(name) not in the picker")
        row.tap()
        // Destination is asserted by the caller (each state routes elsewhere);
        // just wait for the picker sheet to close.
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Log in as… (DEBUG)"],
                                           timeout: 60),
                      "Test-login picker did not close after picking \(name)")
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return !element.exists
    }

    @MainActor
    private func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["YENTL_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? shot.pngRepresentation.write(to: url)
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
