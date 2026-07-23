import XCTest
@testable import YentlShared

final class ModerationTests: XCTestCase {
    // MARK: - AccountStatus.isBlocked (mirrors SQL account_is_blocked)

    func testBannedIsAlwaysBlocked() {
        let status = AccountStatus(kind: .banned, moderationReason: "Fake profile")
        XCTAssertTrue(status.isBlocked(at: Date()))
    }

    func testActiveIsNeverBlocked() {
        XCTAssertFalse(AccountStatus(kind: .active).isBlocked(at: Date()))
    }

    func testRunningSuspensionIsBlocked() {
        let now = Date()
        let status = AccountStatus(
            kind: .suspended,
            suspendedUntil: now.addingTimeInterval(3600),
            moderationReason: "Harassment"
        )
        XCTAssertTrue(status.isBlocked(at: now))
    }

    func testLapsedSuspensionIsNotBlocked() {
        let now = Date()
        let status = AccountStatus(
            kind: .suspended,
            suspendedUntil: now.addingTimeInterval(-60),
            moderationReason: "Harassment"
        )
        XCTAssertFalse(status.isBlocked(at: now))
    }

    /// Suspended with no end date cannot happen via suspend_user (until is
    /// required + future), so a missing date must not lock anyone out.
    func testSuspendedWithoutUntilIsNotBlocked() {
        XCTAssertFalse(AccountStatus(kind: .suspended).isBlocked(at: Date()))
    }

    // MARK: - AccountStatus decoding (users-row shapes from PostgREST)

    func testDecodesSuspendedRowWithFractionalSeconds() throws {
        let json = """
        {
            "account_status": "suspended",
            "suspended_until": "2026-07-30T12:00:00.123456+00:00",
            "moderation_reason": "Repeated harassment reports"
        }
        """
        let status = try JSONDecoder().decode(AccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.kind, .suspended)
        XCTAssertEqual(status.moderationReason, "Repeated harassment reports")
        let until = try XCTUnwrap(status.suspendedUntil)
        // ISO8601DateFormatter keeps millisecond precision; the date must land
        // within the right second regardless of the trailing microseconds.
        XCTAssertEqual(
            until.timeIntervalSince1970,
            Date(timeIntervalSince1970: 1785412800.123).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertTrue(status.isBlocked(at: Date(timeIntervalSince1970: 1785412000)))
        XCTAssertFalse(status.isBlocked(at: Date(timeIntervalSince1970: 1785413000)))
    }

    func testDecodesTimestampWithoutFractionalSeconds() throws {
        let json = """
        {
            "account_status": "suspended",
            "suspended_until": "2026-07-30T12:00:00+00:00",
            "moderation_reason": null
        }
        """
        let status = try JSONDecoder().decode(AccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.suspendedUntil, Date(timeIntervalSince1970: 1785412800))
        XCTAssertNil(status.moderationReason)
    }

    func testDecodesActiveRowWithNulls() throws {
        let json = """
        {"account_status": "active", "suspended_until": null, "moderation_reason": null}
        """
        let status = try JSONDecoder().decode(AccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.kind, .active)
        XCTAssertNil(status.suspendedUntil)
        XCTAssertFalse(status.isBlocked)
    }

    /// An account_status value this build doesn't know must degrade to
    /// active/no-gate (an app update can never lock users out), not throw.
    func testUnknownStatusDegradesToActive() throws {
        let json = """
        {"account_status": "shadow_banned", "suspended_until": null, "moderation_reason": null}
        """
        let status = try JSONDecoder().decode(AccountStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.kind, .active)
        XCTAssertFalse(status.isBlocked)
    }

    // MARK: - ModerationReport decoding (moderation_open_reports row)

    func testModerationReportDecodesFullRow() throws {
        let json = """
        {
            "report_id": "11111111-2222-3333-4444-555555555555",
            "reason": "harassment",
            "note": "Sent hostile messages.",
            "created_at_epoch": 1753257600.25,
            "match_id": "66666666-7777-8888-9999-000000000000",
            "reporter_id": "aaaaaaaa-0000-0000-0000-000000000001",
            "reporter_display_name": "Adam",
            "reported_id": "aaaaaaaa-0000-0000-0000-000000000002",
            "reported_display_name": "Beth",
            "reported_account_status": "active",
            "reports_against_reported": 3
        }
        """
        let report = try JSONDecoder().decode(ModerationReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.id, report.reportID)
        XCTAssertEqual(report.reasonKind, .harassment)
        XCTAssertEqual(report.reasonLabel, "Harassment or bullying")
        XCTAssertEqual(report.note, "Sent hostile messages.")
        XCTAssertEqual(report.createdAt, Date(timeIntervalSince1970: 1753257600.25))
        XCTAssertNotNil(report.matchID)
        XCTAssertEqual(report.reporterDisplayName, "Adam")
        XCTAssertEqual(report.reportedDisplayName, "Beth")
        XCTAssertEqual(report.reportedStatusKind, .active)
        XCTAssertEqual(report.reportsAgainstReported, 3)
    }

    /// Nulls (no note, no match, missing profiles) and an unknown reason
    /// token must decode, with the label falling back to the raw token.
    func testModerationReportDecodesSparseRow() throws {
        let json = """
        {
            "report_id": "11111111-2222-3333-4444-555555555555",
            "reason": "future_reason",
            "note": null,
            "created_at_epoch": 1753257600,
            "match_id": null,
            "reporter_id": "aaaaaaaa-0000-0000-0000-000000000001",
            "reporter_display_name": null,
            "reported_id": "aaaaaaaa-0000-0000-0000-000000000002",
            "reported_display_name": null,
            "reported_account_status": "suspended",
            "reports_against_reported": 1
        }
        """
        let report = try JSONDecoder().decode(ModerationReport.self, from: Data(json.utf8))
        XCTAssertNil(report.note)
        XCTAssertNil(report.matchID)
        XCTAssertNil(report.reporterDisplayName)
        XCTAssertNil(report.reportedDisplayName)
        XCTAssertNil(report.reasonKind)
        XCTAssertEqual(report.reasonLabel, "future_reason")
        XCTAssertEqual(report.reportedStatusKind, .suspended)
    }

    // MARK: - Suspension durations

    func testSuspensionDurationsProduceFutureDates() {
        let now = Date(timeIntervalSince1970: 1_753_257_600)
        XCTAssertEqual(SuspensionDuration.day.until(from: now),
                       now.addingTimeInterval(86_400))
        XCTAssertEqual(SuspensionDuration.week.until(from: now),
                       now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(SuspensionDuration.month.until(from: now),
                       now.addingTimeInterval(30 * 86_400))
    }

    // MARK: - RPC param encodings

    /// Params must serialise to the exact snake_case arg names the RPCs
    /// declare; a drifted key fails the call. A nil report_id must OMIT the
    /// key so the server-side default applies.
    func testSuspendParamsEncodeKeysAndOmitNilReportID() throws {
        let target = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let report = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!

        let linked = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SuspendParams(
                target: target, until: "2026-07-30T12:00:00.000Z",
                reason: "Harassment", reportId: report
            ))
        ) as? [String: Any])
        XCTAssertEqual(Set(linked.keys), ["target", "until", "reason", "report_id"])
        XCTAssertEqual(linked["until"] as? String, "2026-07-30T12:00:00.000Z")

        let unlinked = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SuspendParams(
                target: target, until: "2026-07-30T12:00:00.000Z",
                reason: "Harassment", reportId: nil
            ))
        ) as? [String: Any])
        XCTAssertEqual(Set(unlinked.keys), ["target", "until", "reason"])
    }

    func testBanAndResolveParamsEncodeKeys() throws {
        let target = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let ban = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BanParams(
                target: target, reason: "Fake profile", reportId: nil
            ))
        ) as? [String: Any])
        XCTAssertEqual(Set(ban.keys), ["target", "reason"])

        let resolve = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ResolveParams(
                reportId: target, dismiss: true
            ))
        ) as? [String: Any])
        XCTAssertEqual(Set(resolve.keys), ["report_id", "dismiss"])
        XCTAssertEqual(resolve["dismiss"] as? Bool, true)
    }
}
