// L0 placeholder — the old Warp-clone view + design-system tests were deleted with their views (REBUILD-V2
// L0). The native-SwiftUI rewrite re-adds view-logic tests per layer (L1+). This keeps the test target
// with ≥1 test so it compiles + passes; it asserts nothing about the (rebuilding) UI.

import XCTest
@testable import SlopDeskClientUI

final class L0Placeholder: XCTestCase {
    func testBuilds() {
        XCTAssertTrue(true)
    }
}
