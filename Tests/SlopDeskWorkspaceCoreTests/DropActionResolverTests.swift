import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``DropActionResolver`` — the full (zone × content) policy table from
/// `docs/ui-shell/spec/user-interface__drag-and-drop.md`, including the disabled green-half cells (file/URL on New
/// Tab). Each expected ``DropAction`` is hand-specified from the spec, independent of the resolver's
/// own derivation (no tautology).
final class DropActionResolverTests: XCTestCase {
    private let folder = DroppedContent.folder("/Users/me/proj")
    private let file = DroppedContent.file("/Users/me/proj/README.md")
    private let url = DroppedContent.url("https://example.com")
    private let text = DroppedContent.text("echo hi")

    private func resolve(_ zone: DropZone, _ content: DroppedContent) -> DropAction? {
        DropActionResolver.resolve(zone: zone, content: content)
    }

    // MARK: - New Tab (green / terminal half)

    func testNewTabFolderOpensTerminalRootedAtFolder() {
        XCTAssertEqual(resolve(.newTab, folder), .newTabCd("/Users/me/proj"))
    }

    func testNewTabFileIsDisabled() {
        // No "open as terminal" semantic for a file — the disabled green-half cell.
        XCTAssertNil(resolve(.newTab, file))
    }

    func testNewTabURLIsDisabled() {
        XCTAssertNil(resolve(.newTab, url))
    }

    func testNewTabTextPastes() {
        XCTAssertEqual(resolve(.newTab, text), .injectText("echo hi"))
    }

    // MARK: - Insert Path (green / terminal half) — pastes the value verbatim

    func testInsertPathFolderInjectsPath() {
        XCTAssertEqual(resolve(.insertPath, folder), .injectText("/Users/me/proj"))
    }

    func testInsertPathFileInjectsPath() {
        XCTAssertEqual(resolve(.insertPath, file), .injectText("/Users/me/proj/README.md"))
    }

    func testInsertPathURLInjectsURL() {
        XCTAssertEqual(resolve(.insertPath, url), .injectText("https://example.com"))
    }

    func testInsertPathTextPastes() {
        XCTAssertEqual(resolve(.insertPath, text), .injectText("echo hi"))
    }

    // MARK: - Open In-Place (blue / pane half)

    func testOpenInPlaceFolderHostOpens() {
        XCTAssertEqual(resolve(.openInPlace, folder), .hostOpen("/Users/me/proj"))
    }

    func testOpenInPlaceFileHostOpens() {
        XCTAssertEqual(resolve(.openInPlace, file), .hostOpen("/Users/me/proj/README.md"))
    }

    func testOpenInPlaceURLIsDisabled() {
        // The local web pane is retired — a URL has no in-place viewer (Insert Path still pastes it).
        XCTAssertNil(resolve(.openInPlace, url))
    }

    func testOpenInPlaceTextPastes() {
        XCTAssertEqual(resolve(.openInPlace, text), .injectText("echo hi"))
    }

    // MARK: - Split Left (blue / pane half, leading = true)

    func testSplitLeftFolderSplitsAtPath() {
        XCTAssertEqual(resolve(.splitLeft, folder), .splitInjectPath("/Users/me/proj", leading: true))
    }

    func testSplitLeftFileSplitsAtPath() {
        XCTAssertEqual(resolve(.splitLeft, file), .splitInjectPath("/Users/me/proj/README.md", leading: true))
    }

    func testSplitLeftURLIsDisabled() {
        // No split-to-browser cell any more (the local web pane is retired).
        XCTAssertNil(resolve(.splitLeft, url))
    }

    func testSplitLeftTextPastes() {
        XCTAssertEqual(resolve(.splitLeft, text), .injectText("echo hi"))
    }

    // MARK: - Split Right (blue / pane half, leading = false)

    func testSplitRightFolderSplitsAtPath() {
        XCTAssertEqual(resolve(.splitRight, folder), .splitInjectPath("/Users/me/proj", leading: false))
    }

    func testSplitRightFileSplitsAtPath() {
        XCTAssertEqual(resolve(.splitRight, file), .splitInjectPath("/Users/me/proj/README.md", leading: false))
    }

    func testSplitRightURLIsDisabled() {
        XCTAssertNil(resolve(.splitRight, url))
    }

    func testSplitRightTextPastes() {
        XCTAssertEqual(resolve(.splitRight, text), .injectText("echo hi"))
    }

    // MARK: - allowedZones (the overlay-gating contract)

    // The set of zones the drop overlay lights up / lets the cursor target for each content kind. Hand-
    // specified from the spec table (NOT derived from the resolver inside the assert), so a regression that
    // (e.g.) let a FILE land on the green New-Tab half would FAIL here.

    func testAllowedZonesFolderEnablesAllFive() {
        // A folder is the only content with a New-Tab semantic, so all five zones are live.
        XCTAssertEqual(
            DropActionResolver.allowedZones(for: folder),
            [.newTab, .insertPath, .openInPlace, .splitLeft, .splitRight],
        )
    }

    func testAllowedZonesFileDisablesNewTab() {
        // No "open as terminal" for a file → the green New-Tab half is disabled, the other four are live.
        XCTAssertEqual(
            DropActionResolver.allowedZones(for: file),
            [.insertPath, .openInPlace, .splitLeft, .splitRight],
        )
        XCTAssertFalse(DropActionResolver.allowedZones(for: file).contains(.newTab))
    }

    func testAllowedZonesURLIsInsertPathOnly() {
        // With the local web pane retired, a URL's only live cell is the verbatim paste (Insert Path).
        XCTAssertEqual(DropActionResolver.allowedZones(for: url), [.insertPath])
        XCTAssertFalse(DropActionResolver.allowedZones(for: url).contains(.newTab))
    }

    func testAllowedZonesTextEnablesAllFive() {
        // Text pastes in every zone ("Same" for both halves), so all five are live.
        XCTAssertEqual(
            DropActionResolver.allowedZones(for: text),
            [.newTab, .insertPath, .openInPlace, .splitLeft, .splitRight],
        )
    }

    // MARK: - No drop mints a video pane

    /// `DropActionResolver`'s own doc claims no `(zone × content)` cell can spawn a streamed host
    /// window — a video pane is minted ONLY by the picker / connect overlay. The claim named a test
    /// that did not exist; this is it.
    ///
    /// The assert that matters is the `switch`, not the count: it is EXHAUSTIVE over ``DropAction``,
    /// so adding a fifth case stops this file compiling. A `XCTAssertNotEqual` against a video case
    /// would pass forever by being written before the case it is supposed to catch.
    func testEveryLiveCellResolvesToATerminalAction() {
        var live = 0
        for zone in DropZone.allCases {
            for content in [folder, file, url, text] {
                guard let action = resolve(zone, content) else { continue }
                live += 1
                switch action {
                case .injectText,
                     .newTabCd,
                     .hostOpen,
                     .splitInjectPath:
                    break // every arm targets a TERMINAL pane; there is no video-pane creator
                }
            }
        }
        // 5 zones × 4 contents = 20 cells; the spec disables 5 of them (file and URL on New Tab, URL
        // on Open-In-Place, URL on each split half). Asserted so a table that lost a live cell to a
        // typo cannot pass this test by resolving nothing at all.
        XCTAssertEqual(live, 15, "the spec's table has 15 live cells out of 20")
    }
}
