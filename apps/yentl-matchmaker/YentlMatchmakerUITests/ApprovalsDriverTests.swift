//
//  ApprovalsDriverTests.swift
//  YentlMatchmakerUITests
//
//  Driver for the Phase 12 Slice 2 hands-on verification: walks the Approvals
//  tab against the LOCAL Supabase stack (seeded with two flagged profiles),
//  capturing screenshots as attachments. Like the other *DriverTests, this is
//  NOT a regression suite — it is invoked manually, expects the local demo
//  seed (Maya: contact-info flag, Daniel: face-check flag, both
//  pending_review), and it *decides* both profiles (approve Maya, reject
//  Daniel), so re-running needs the seed reset.
//

import XCTest

final class ApprovalsDriverTests: XCTestCase {

    private let matchmakerBundleID = "com.yentl.matchmaker"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testApprovalsQueueWalkthrough() throws {
        let app = launchSignedIn()

        // --- The Approvals tab exists and carries the pending-count badge.
        let approvalsTab = app.tabBars.buttons["Approvals"]
        XCTAssertTrue(approvalsTab.waitForExistence(timeout: 30),
                      "Tab bar has no Approvals tab")
        NSLog("APPROVALS-DRIVER tab label: %@ value: %@",
              approvalsTab.label, String(describing: approvalsTab.value))
        approvalsTab.tap()

        // --- Queue list: both flagged profiles, newest-flagged (Maya) first,
        // each with its human-readable flag summary.
        let mayaRow = app.staticTexts["Maya, 30"]
        XCTAssertTrue(mayaRow.waitForExistence(timeout: 30),
                      "Approvals list never showed Maya")
        XCTAssertTrue(app.staticTexts["Daniel, 34"].exists,
                      "Approvals list is missing Daniel")
        XCTAssertTrue(app.staticTexts["Contact info"].exists,
                      "Maya's row is missing the Contact info flag summary")
        XCTAssertTrue(app.staticTexts["Not a single person"].exists,
                      "Daniel's row is missing the face-check flag summary")
        shoot("slice2-approvals-list")

        // --- Maya's detail: profile + readable AI reasons + actions.
        mayaRow.tap()
        XCTAssertTrue(app.staticTexts["Flagged by AI screening"]
                        .waitForExistence(timeout: 20),
                      "Detail screen has no flag panel")
        let contactLine = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Contact info in text'")
        ).firstMatch
        XCTAssertTrue(contactLine.waitForExistence(timeout: 10),
                      "Flag panel does not render the contact-info reasons")
        NSLog("APPROVALS-DRIVER maya reason line: %@", contactLine.label)
        XCTAssertTrue(app.buttons["Approve"].exists)
        XCTAssertTrue(app.buttons["Reject"].exists)
        // The hidden matchmaker fields come from the reused ProfileScreen.
        XCTAssertTrue(app.staticTexts["Matchmaker only"].waitForExistence(timeout: 20),
                      "Detail does not show the hidden matchmaker fields")
        shoot("slice2-detail-maya")

        // --- Approve Maya: confirm → back on the list, Maya gone.
        app.buttons["Approve"].tap()
        let confirmApprove = app.buttons["Approve Maya"]
        XCTAssertTrue(confirmApprove.waitForExistence(timeout: 8),
                      "Approve confirmation did not appear")
        confirmApprove.tap()
        XCTAssertTrue(app.staticTexts["Daniel, 34"].waitForExistence(timeout: 20),
                      "Did not return to the Approvals list after approving")
        XCTAssertFalse(app.staticTexts["Maya, 30"].exists,
                       "Maya should have left the queue after approval")
        shoot("slice2-after-approve")

        // --- Daniel's detail: face-check reasons.
        app.staticTexts["Daniel, 34"].tap()
        let faceLine = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'more than one person'")
        ).firstMatch
        XCTAssertTrue(faceLine.waitForExistence(timeout: 20),
                      "Flag panel does not render the face-check reasons")
        NSLog("APPROVALS-DRIVER daniel reason line: %@", faceLine.label)
        shoot("slice2-detail-daniel")

        // --- Reject Daniel: canned reason required, then back to an empty queue.
        app.buttons["Reject"].tap()
        let rejectSheetTitle = app.navigationBars["Reject profile"]
        XCTAssertTrue(rejectSheetTitle.waitForExistence(timeout: 8),
                      "Reject sheet did not appear")
        // Nothing selected yet — the submit button must be disabled.
        let submit = app.navigationBars["Reject profile"].buttons["Reject"]
        XCTAssertFalse(submit.isEnabled,
                       "Reject must be disabled until a reason is chosen")
        app.buttons["Not a single person"].tap()
        XCTAssertTrue(submit.isEnabled, "Reject should enable once a reason is chosen")
        shoot("slice2-reject-sheet")
        submit.tap()

        XCTAssertTrue(app.staticTexts["No profiles to review"]
                        .waitForExistence(timeout: 20),
                      "Queue should be empty after both decisions")
        XCTAssertFalse(app.staticTexts["Daniel, 34"].exists,
                       "Daniel should have left the queue after rejection")
        shoot("slice2-empty-queue")

        // Hold so the host can grab an independent live screenshot.
        Thread.sleep(forTimeInterval: 10)
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
