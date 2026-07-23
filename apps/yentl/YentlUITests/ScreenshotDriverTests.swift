//
//  ScreenshotDriverTests.swift
//  YentlUITests
//
//  One-off driver for capturing full-resolution App Store screenshots of the
//  consumer app against the LIVE Supabase project's seed profiles. NOT a
//  regression suite — invoked manually, writes PNGs to $YENTL_SCREENSHOT_DIR
//  (see saveScreenshot, mirrored from ReviewStatesDriverTests /
//  MatchChatUITests) and also attaches them to the xcresult as a fallback.
//
//  Signs in as Olivia (seed-f-01, live review_state) so Discovery shows the
//  male seed pool with real photos.
//

import XCTest

final class ScreenshotDriverTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        signIn(app, as: "Olivia")

        // --- Discovery feed ---
        let discoverTab = app.tabBars.buttons["Discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 60),
                      "Olivia did not land in the normal app (Discover tab missing)")
        discoverTab.tap()

        // Wait for a candidate card to render (its name/age text contains a comma).
        let cardLabel = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS ','")
        ).firstMatch
        let hasCandidate = cardLabel.waitForExistence(timeout: 30)
        // Give the photo a moment to finish downloading/decoding before capture.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        saveScreenshot("02-discovery")

        // --- Profile detail (tap the card to open CandidateDetailView) ---
        if hasCandidate {
            cardLabel.tap()
            let closeButton = app.buttons["Close"].firstMatch
            let opened = closeButton.waitForExistence(timeout: 20)
            if opened {
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                saveScreenshot("03-profile")
                closeButton.tap()
            } else {
                saveScreenshot("03-profile-MISSING-detail-did-not-open")
            }
        } else {
            saveScreenshot("03-profile-MISSING-no-candidate")
        }

        // --- Your profile (Profile tab) ---
        let profileTab = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()
        _ = app.navigationBars["Your profile"].waitForExistence(timeout: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        saveScreenshot("04-your-profile")

        // --- Matches ---
        let matchesTab = app.tabBars.buttons["Matches"]
        XCTAssertTrue(matchesTab.waitForExistence(timeout: 15))
        matchesTab.tap()
        _ = app.navigationBars["Matches"].waitForExistence(timeout: 20)
        let noMatches = app.staticTexts["No matches yet"]
        let matchesEmpty = noMatches.waitForExistence(timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        saveScreenshot(matchesEmpty ? "05-matches-EMPTY" : "05-matches")

        // --- Chat ---
        let chatTab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 15))
        chatTab.tap()
        _ = app.staticTexts["Messages"].waitForExistence(timeout: 45)
        let noConversations = app.staticTexts["No conversations yet"]
        let chatEmpty = noConversations.waitForExistence(timeout: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        saveScreenshot(chatEmpty ? "06-chat-EMPTY" : "06-chat")

        // --- Best-effort: Daniel/Kanyin previously had a confirmed match
        // (Phase 7 verification, MatchChatUITests) — check read-only whether
        // it's still around for richer Matches/Chat screenshots. No writes.
        switchAccount(app, to: "Daniel")
        matchesTab.tap()
        _ = app.navigationBars["Matches"].waitForExistence(timeout: 20)
        let danielMatchesEmpty = noMatches.waitForExistence(timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        saveScreenshot(danielMatchesEmpty ? "05-matches-daniel-EMPTY" : "05-matches-daniel")

        chatTab.tap()
        _ = app.staticTexts["Messages"].waitForExistence(timeout: 45)
        let danielChatEmpty = app.staticTexts["No conversations yet"].waitForExistence(timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        saveScreenshot(danielChatEmpty ? "06-chat-daniel-EMPTY" : "06-chat-daniel")

        Thread.sleep(forTimeInterval: 3)  // hold for host screenshots
    }

    @MainActor
    private func switchAccount(_ app: XCUIApplication, to name: String) {
        app.tabBars.buttons["Profile"].tap()
        let ladybug = app.buttons["debug-test-login"].firstMatch
        XCTAssertTrue(ladybug.waitForExistence(timeout: 15))
        ladybug.tap()
        pickAccount(app, name: name)
    }

    // MARK: - Helpers (mirrors ReviewStatesDriverTests / MatchChatUITests)

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
