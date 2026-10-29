import XCTest
import YACWSelfTest

/// Runs the project's full check list (see Sources/YACWSelfTest). Needs XCTest, i.e. Xcode or a CI macOS runner.
final class SelfTestTests: XCTestCase {
    func testAllChecksPass() throws {
        XCTAssertEqual(try SelfTest.run(), 0, "see the FAIL lines in the test log")
    }
}
