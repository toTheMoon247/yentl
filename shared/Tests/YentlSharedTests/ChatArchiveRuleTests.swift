import XCTest
@testable import YentlShared

final class ChatArchiveRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var hours: (Double) -> TimeInterval { { $0 * 3600 } }

    func testRecentMessageIsActive() {
        XCTAssertFalse(ChatArchiveRule.isArchived(
            lastMessageAt: now.addingTimeInterval(-hours(1)),
            createdAt: now.addingTimeInterval(-hours(400)),
            now: now
        ))
    }

    func testMessageOlderThan48hIsArchived() {
        XCTAssertTrue(ChatArchiveRule.isArchived(
            lastMessageAt: now.addingTimeInterval(-hours(49)),
            createdAt: now.addingTimeInterval(-hours(400)),
            now: now
        ))
    }

    func testExactly48hIsArchived() {
        XCTAssertTrue(ChatArchiveRule.isArchived(
            lastMessageAt: now.addingTimeInterval(-hours(48)),
            createdAt: now.addingTimeInterval(-hours(400)),
            now: now
        ))
    }

    func testJustUnder48hIsActive() {
        XCTAssertFalse(ChatArchiveRule.isArchived(
            lastMessageAt: now.addingTimeInterval(-hours(48) + 1),
            createdAt: now.addingTimeInterval(-hours(400)),
            now: now
        ))
    }

    /// A never-messaged chat runs the same clock from channel creation.
    func testNeverMessagedFallsBackToCreation() {
        XCTAssertFalse(ChatArchiveRule.isArchived(
            lastMessageAt: nil,
            createdAt: now.addingTimeInterval(-hours(47)),
            now: now
        ))
        XCTAssertTrue(ChatArchiveRule.isArchived(
            lastMessageAt: nil,
            createdAt: now.addingTimeInterval(-hours(49)),
            now: now
        ))
    }

    /// A new message on an old channel restores the chat to active —
    /// last_message_at wins over creation age.
    func testNewMessageOnOldChannelIsActive() {
        XCTAssertFalse(ChatArchiveRule.isArchived(
            lastMessageAt: now.addingTimeInterval(-hours(0.5)),
            createdAt: now.addingTimeInterval(-hours(1000)),
            now: now
        ))
    }

    func testWindowIs48Hours() {
        XCTAssertEqual(ChatArchiveRule.inactivityWindow, 48 * 3600)
    }
}
