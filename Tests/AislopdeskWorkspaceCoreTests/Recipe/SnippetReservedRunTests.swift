import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// E16 WI-10 — the reserved-snippet-var + caret wiring in `runSnippet`. The app injects
/// `{{clipboard}}` / `{{date}}` / `{{time}}` through ``WorkspaceStore/snippetReservedValues`` (read off the
/// real pasteboard / clock on the app side); `{{cursor}}` repositions the caret with cursor-left (`ESC [ D`),
/// NEVER an Enter.
///
/// REVERT-TO-CONFIRM-FAIL: before WI-10 routed `runSnippet` through `ReservedSnippetVars`, `{{clipboard}}`
/// was injected into the terminal VERBATIM (`echo {{clipboard}}`) and `{{cursor}}` produced no caret move.
@MainActor
final class SnippetReservedRunTests: XCTestCase {
    private func store(_ items: [CanvasItem], focus: PaneID) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func term(_ x: CGFloat) -> CanvasItem {
        CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: "t"),
            frame: CGRect(x: x, y: 0, width: 300, height: 200),
            z: 0,
        )
    }

    private func bytes(_ store: WorkspaceStore, _ id: PaneID) -> [[UInt8]] {
        (store.handle(for: id) as? FakePaneSession)?.sentBytes ?? []
    }

    // MARK: - Reserved string vars (clipboard / date / time)

    func testRunSnippetInjectsClipboardFromSeam() {
        let a = term(0)
        let st = store([a], focus: a.id)
        st.snippetReservedValues = { ReservedSnippetValues(clipboard: "PASTED", date: "2026-06-28", time: "09:41") }
        let s = st.addSnippet(name: "p", body: "echo {{clipboard}}<Enter>")
        XCTAssertEqual(st.runSnippet(s.id), 1)
        XCTAssertEqual(
            bytes(st, a.id), [Array("echo PASTED".utf8) + [0x0D]],
            "the app-injected clipboard is substituted, NOT left literal",
        )
    }

    func testRunSnippetResolvesDateAndTime() {
        let a = term(0)
        let st = store([a], focus: a.id)
        st.snippetReservedValues = { ReservedSnippetValues(clipboard: "", date: "2026-06-28", time: "09:41") }
        let s = st.addSnippet(name: "now", body: "{{date}} {{time}}")
        XCTAssertEqual(st.runSnippet(s.id), 1)
        XCTAssertEqual(bytes(st, a.id), [Array("2026-06-28 09:41".utf8)])
    }

    func testRunSnippetWithoutSeamResolvesReservedToEmptyNotLiteral() {
        // With no app seam, the store reads no clock/pasteboard, so reserved vars resolve to EMPTY — proving
        // the resolver runs even headless (the OLD `runSnippet` left `{{date}}` literal).
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "now", body: "echo {{date}}<Enter>")
        XCTAssertEqual(st.runSnippet(s.id), 1)
        XCTAssertEqual(bytes(st, a.id), [Array("echo ".utf8) + [0x0D]])
    }

    func testRunSnippetStillResolvesUserPlaceholdersAlongsideReserved() {
        let a = term(0)
        let st = store([a], focus: a.id)
        st.snippetReservedValues = { ReservedSnippetValues(date: "2026-06-28") }
        let s = st.addSnippet(name: "x", body: "ssh {{user}} on {{date}}<Enter>")
        XCTAssertEqual(st.runSnippet(s.id, values: ["user": "ada"]), 1)
        XCTAssertEqual(bytes(st, a.id), [Array("ssh ada on 2026-06-28".utf8) + [0x0D]])
    }

    // MARK: - {{cursor}} caret reposition

    func testCursorMarkerAtEndSendsNoCaretMove() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "gco", body: "git checkout {{cursor}}")
        XCTAssertEqual(st.runSnippet(s.id), 1)
        XCTAssertEqual(
            bytes(st, a.id), [Array("git checkout ".utf8)],
            "a caret at end-of-line sends no cursor-left and NEVER an Enter",
        )
    }

    func testCursorMarkerInMiddleRepositionsWithCursorLeft() {
        let a = term(0)
        let st = store([a], focus: a.id)
        let s = st.addSnippet(name: "commit", body: "git commit -m \"{{cursor}}\"")
        XCTAssertEqual(st.runSnippet(s.id), 1)
        // Typed `git commit -m ""`, then ONE cursor-left (the single trailing `"`) to land between the quotes.
        let expected = Array("git commit -m \"\"".utf8) + [0x1B, 0x5B, 0x44]
        XCTAssertEqual(bytes(st, a.id), [expected])
    }

    func testCursorLeftBytesHelperIsTotalOverGraphemes() {
        XCTAssertEqual(
            WorkspaceStore.snippetCursorLeftBytes(text: "ab", byteOffset: 2), [], "offset at end → no move",
        )
        XCTAssertEqual(
            WorkspaceStore.snippetCursorLeftBytes(text: "ab", byteOffset: 0),
            [0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x44],
            "two trailing graphemes → two cursor-lefts",
        )
        XCTAssertEqual(
            WorkspaceStore.snippetCursorLeftBytes(text: "ab", byteOffset: 99), [],
            "an out-of-range offset is total (no trap, no move)",
        )
    }
}
