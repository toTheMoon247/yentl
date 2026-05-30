import XCTest
@testable import YentlShared

final class YentlSharedTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(YentlShared.version.isEmpty)
    }
}
