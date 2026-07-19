// SidebarRowTooltipTests — pins `SidebarRowTooltip.text(cwd:scent:)`, the sidebar row `.help()` text
// builder. A raw `\(cwd)` interpolation of a `String?` renders the literal `Optional(...)` wrapper — this
// pins the unwrapped form instead.

import XCTest
@testable import SlopDeskClientUI

final class SidebarRowTooltipTests: XCTestCase {
    /// The scent line present + a real cwd: two lines, cwd first, NEVER `Optional(...)`.
    func testScentPresentUnwrapsCwd() {
        let text = SidebarRowTooltip.text(cwd: "/Users/me/project", scent: "writing tests")
        XCTAssertEqual(text, "/Users/me/project\nwriting tests")
    }

    /// A cwd-less pane with a live scent line: the cwd line is blank, not the literal "nil".
    func testScentPresentWithNilCwdOmitsLiteralNil() {
        let text = SidebarRowTooltip.text(cwd: nil, scent: "writing tests")
        XCTAssertEqual(text, "\nwriting tests")
    }

    /// No scent: the tooltip is the plain cwd, unchanged from today's cwd-only behaviour.
    func testNoScentFallsBackToPlainCwd() {
        let text = SidebarRowTooltip.text(cwd: "/Users/me/project", scent: nil)
        XCTAssertEqual(text, "/Users/me/project")
    }

    /// No scent and no cwd: `nil` (the caller's `.help(helpText ?? "")` renders no tooltip).
    func testNoScentNoCwdIsNil() {
        XCTAssertNil(SidebarRowTooltip.text(cwd: nil, scent: nil))
    }
}
