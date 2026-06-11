import XCTest
@testable import AislopdeskClientUI

/// Tests for ``CompactLayoutResolver`` — the pure **compact projection** (docs/30 §6.6) that flattens
/// the SAME canvas of intent into an ordered, swipeable page list. The phone layout must be a lossless
/// *view of the same model*: page order equals the canvas z-order (`canvas.allIDs()`), so a
/// size-class flip never reorders or drops a pane.
///
/// Contract under test:
/// - `pages(for:)` order == `canvas.allIDs()` (z-order), carrying each pane's kind+title.
/// - `selectedIndex(focusedPane:in:)` == the focused pane's index, or `0` if the focused pane is absent.
final class CompactLayoutResolverTests: XCTestCase {

    // MARK: - Fixtures

    /// A 3-pane canvas whose z-order is a, b, c (``Canvas/make`` assigns z = array index), each
    /// pane carrying a distinct kind+title so the projection's payload is checkable.
    private func threePaneCanvas(a: PaneID, b: PaneID, c: PaneID) -> Canvas {
        Canvas.make(panes: [
            (a, PaneSpec(kind: .terminal, title: "Shell")),
            (b, PaneSpec(kind: .claudeCode, title: "Claude")),
            (c, PaneSpec(kind: .remoteGUI, title: "Screen")),
        ])
    }

    // MARK: - pages(): z-order, with payload

    func testPagesAreZOrderWithPayload() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let canvas = threePaneCanvas(a: a, b: b, c: c)

        let pages = CompactLayoutResolver.pages(for: canvas)
        XCTAssertEqual(pages.map(\.id), [a, b, c], "page order == canvas.allIDs() z-order")
        XCTAssertEqual(pages.map(\.id), canvas.allIDs(), "page order tracks the canvas z-order exactly")

        XCTAssertEqual(pages.map(\.kind), [.terminal, .claudeCode, .remoteGUI], "each page carries its pane kind")
        XCTAssertEqual(pages.map(\.title), ["Shell", "Claude", "Screen"], "each page carries its pane title")
    }

    func testSinglePaneCanvasHasOnePage() {
        let only = PaneID()
        let canvas = Canvas.make(panes: [(only, PaneSpec(kind: .terminal, title: "Term"))])

        let pages = CompactLayoutResolver.pages(for: canvas)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.id, only)
        XCTAssertEqual(pages.first?.title, "Term")
    }

    /// `Workspace.defaultWorkspace()` produces a one-page compact projection consistent with its
    /// single focused pane.
    func testDefaultWorkspaceHasSinglePage() {
        let workspace = Workspace.defaultWorkspace()
        let pages = CompactLayoutResolver.pages(for: workspace.canvas)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.id, workspace.focusedPane, "the single page is the focused pane")
        XCTAssertEqual(pages.first?.kind, .terminal)
    }

    // MARK: - selectedIndex(): focused pane's position

    func testSelectedIndexTracksFocusedPane() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let canvas = threePaneCanvas(a: a, b: b, c: c)

        XCTAssertEqual(CompactLayoutResolver.selectedIndex(focusedPane: a, in: canvas), 0)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(focusedPane: b, in: canvas), 1)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(focusedPane: c, in: canvas), 2)
    }

    /// If the focused pane is somehow absent (or nil), selectedIndex defends with 0 (keeps the carousel
    /// on a valid page) — it does NOT return nil.
    func testSelectedIndexDefaultsToZeroWhenFocusAbsent() {
        let a = PaneID(), b = PaneID(), c = PaneID(), ghost = PaneID()
        let canvas = threePaneCanvas(a: a, b: b, c: c)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(focusedPane: ghost, in: canvas), 0, "absent focus → page 0 (defensive)")
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(focusedPane: nil, in: canvas), 0, "nil focus → page 0 (defensive)")
    }
}
