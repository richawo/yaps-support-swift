import XCTest
@testable import YapsSupport

final class SmokeTests: XCTestCase {
    func testVersion() { XCTAssertEqual(YapsSupport.version, "1.0.0") }
}
