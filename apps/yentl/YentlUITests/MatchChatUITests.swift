//
//  MatchChatUITests.swift
//  YentlUITests
//
//  Phase 7 Slice 2 verification: drives the real app against the live
//  backend — sign in as a seed (DEBUG ladybug picker), open the confirmed
//  match, send a message through Stream, then switch to the other seed and
//  verify the message arrived and reply.
//
//  Prerequisite: a confirmed match between the two seeds named below (the
//  dev SQL that creates one mirrors respond_as_seed.sql). Screenshots are
//  written to $YENTL_SCREENSHOT_DIR (passed via TEST_RUNNER_… env) and also
//  attached to the xcresult.
//

import XCTest

final class MatchChatUITests: XCTestCase {

    // The two sides of the confirmed match this test expects.
    private let userA = "Daniel" // seed-m-05
    private let userB = "Kanyin" // seed-f-05

    private let messageFromA = "Hi Kanyin! Great to match with you."
    private let messageFromB = "Hey Daniel! Likewise."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConfirmedMatchChat() throws {
        let app = XCUIApplication()
        app.launch()

        // ---- Pre-step: connect Kanyin to Stream once ----
        // In the real flow both users have signed in (to accept the match), so
        // both Stream users exist by the time a chat opens. The SQL-created
        // match skipped that, and client-side channel creation cannot
        // reference a Stream user that has never connected.
        signIn(app, as: userB)
        waitForChatConnected(app)

        // ---- Side A: Daniel opens the confirmed match and says hello ----
        switchAccount(app, to: userA)
        waitForChatConnected(app)

        app.tabBars.buttons["Matches"].tap()
        let matchRow = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", userB)
        ).firstMatch
        XCTAssertTrue(matchRow.waitForExistence(timeout: 30), "Confirmed match with \(userB) not in Matches")
        matchRow.tap()

        let openChat = app.buttons["Open chat"].firstMatch
        XCTAssertTrue(openChat.waitForExistence(timeout: 30), "'Open chat' missing — match not confirmed?")
        openChat.tap()

        sendMessage(app, text: messageFromA)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", messageFromA))
                .firstMatch.waitForExistence(timeout: 30),
            "Sent message did not appear in the message list"
        )
        saveScreenshot("1-conversation-daniel")

        leaveMatchSheet(app)

        // Inbox should now show the channel with the sent message.
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", messageFromA))
                .firstMatch.waitForExistence(timeout: 30),
            "Chat inbox does not show the new conversation"
        )
        saveScreenshot("2-inbox-daniel")

        // ---- Side B: Kanyin sees the message and replies ----
        switchAccount(app, to: userB)

        app.tabBars.buttons["Chat"].tap()
        let preview = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", messageFromA)
        ).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 60), "Kanyin's inbox does not show Daniel's message")
        saveScreenshot("3-inbox-kanyin")
        preview.tap()

        sendMessage(app, text: messageFromB)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", messageFromB))
                .firstMatch.waitForExistence(timeout: 30),
            "Reply did not appear in the message list"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", messageFromA))
                .firstMatch.exists,
            "Original message not visible alongside the reply"
        )
        saveScreenshot("4-conversation-kanyin")
    }

    // MARK: - Helpers

    /// Signs in via the DEBUG ladybug, from either the signed-out overlay or
    /// (if a previous session survived) the Profile tab.
    @MainActor
    private func signIn(_ app: XCUIApplication, as name: String) {
        let tabBar = app.tabBars.buttons["Matches"]
        let ladybug = app.buttons["debug-test-login"].firstMatch

        // Wait for either the signed-in tab bar or the signed-out ladybug.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !tabBar.exists && !ladybug.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if tabBar.exists {
            switchAccount(app, to: name)
            return
        }
        XCTAssertTrue(ladybug.exists, "Neither signed-in UI nor the DEBUG login button appeared")
        ladybug.tap()
        pickAccount(app, name: name)
    }

    /// From a signed-in state: Profile tab → ladybug → pick the account.
    @MainActor
    private func switchAccount(_ app: XCUIApplication, to name: String) {
        app.tabBars.buttons["Profile"].tap()
        let ladybug = app.buttons["debug-test-login"].firstMatch
        XCTAssertTrue(ladybug.waitForExistence(timeout: 15))
        ladybug.tap()
        pickAccount(app, name: name)
    }

    @MainActor
    private func pickAccount(_ app: XCUIApplication, name: String) {
        let row = app.buttons[name].firstMatch
        // The picker list is long (20 women, then 20 men) and SwiftUI Lists
        // only materialize visible rows — scroll until the account appears.
        _ = row.waitForExistence(timeout: 10)
        var attempts = 0
        while !row.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Account \(name) not in the picker")
        row.tap()
        // Sign-in + stage check are network round-trips.
        XCTAssertTrue(app.tabBars.buttons["Matches"].waitForExistence(timeout: 60),
                      "Signed-in home did not appear after picking \(name)")
    }

    /// Opens the Chat tab and waits until the Stream connection is up (the
    /// inbox swaps its "Connecting to chat…" spinner for the channel list).
    @MainActor
    private func waitForChatConnected(_ app: XCUIApplication) {
        app.tabBars.buttons["Chat"].tap()
        // Stream renders the inbox title as plain text, not a UINavigationBar.
        let connected = app.staticTexts["Messages"].firstMatch
        let didConnect = connected.waitForExistence(timeout: 60)
        if !didConnect { saveScreenshot("debug-not-connected") }
        XCTAssertTrue(didConnect,
                      "Stream did not connect (inbox never showed the channel list)")
    }

    /// Types into Stream's composer and taps its send button.
    @MainActor
    private func sendMessage(_ app: XCUIApplication, text: String) {
        let composer = app.descendants(matching: .any)
            .matching(identifier: "ComposerTextInputView").firstMatch
        let composerAppeared = composer.waitForExistence(timeout: 45)
        if !composerAppeared { saveScreenshot("debug-no-composer") }
        XCTAssertTrue(composerAppeared, "Message composer not found")
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["SendMessageButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button not found")
        send.tap()
    }

    /// Backs out of the conversation and closes the match detail sheet.
    @MainActor
    private func leaveMatchSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if !close.exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 5) { back.tap() }
        }
        if close.waitForExistence(timeout: 10) {
            close.tap()
        } else {
            // Fallback: drag the sheet down.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 15),
                      "Did not return to the tab bar after closing the match sheet")
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
