import XCTest
@testable import YentlShared

final class AppConfigTests: XCTestCase {
    /// The match-expiry window is build-switched: a short, testable window in
    /// Debug; the real 24h in Release. This guards against the #if branches
    /// drifting (e.g. a release build accidentally shipping the 5-minute value).
    func testMatchExpiryWindowMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(AppConfig.matchExpirySeconds, 5 * 60,
                       "Debug builds should use the 5-minute test window")
        #else
        XCTAssertEqual(AppConfig.matchExpirySeconds, 24 * 60 * 60,
                       "Release builds must use the real 24h window")
        #endif
    }
}
