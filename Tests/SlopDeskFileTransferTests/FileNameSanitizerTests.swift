import XCTest
@testable import SlopDeskFileTransfer

final class FileNameSanitizerTests: XCTestCase {
    func testPlainName() {
        XCTAssertEqual(FileNameSanitizer.sanitize("report.pdf"), "report.pdf")
    }

    func testStripsLeadingPath() {
        XCTAssertEqual(FileNameSanitizer.sanitize("Users/me/report.pdf"), "report.pdf")
    }

    func testTraversalCollapsesToLeaf() {
        XCTAssertEqual(FileNameSanitizer.sanitize("../../etc/passwd"), "passwd")
    }

    func testAbsolutePathCollapsesToLeaf() {
        XCTAssertEqual(FileNameSanitizer.sanitize("/etc/passwd"), "passwd")
    }

    func testBackslashSeparators() {
        XCTAssertEqual(FileNameSanitizer.sanitize("C:\\Windows\\evil.dll"), "evil.dll")
    }

    func testDotDotRejected() {
        XCTAssertNil(FileNameSanitizer.sanitize(".."))
    }

    func testSingleDotRejected() {
        XCTAssertNil(FileNameSanitizer.sanitize("."))
    }

    func testEmptyRejected() {
        XCTAssertNil(FileNameSanitizer.sanitize(""))
        XCTAssertNil(FileNameSanitizer.sanitize("   "))
    }

    func testTrailingSlashTakesLeaf() {
        // Empty split components are dropped, so "dir/foo/" → leaf "foo".
        XCTAssertEqual(FileNameSanitizer.sanitize("dir/foo/"), "foo")
    }

    func testNulRejected() {
        XCTAssertNil(FileNameSanitizer.sanitize("evil\0.txt"))
    }

    func testDotfileKept() {
        XCTAssertEqual(FileNameSanitizer.sanitize(".gitignore"), ".gitignore")
    }
}
