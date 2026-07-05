// TabDragPayloadTests — pins FIX 2: the sidebar tab-reorder drag payload encodes the tab IDENTITY (a UUID
// string), NOT the rendered index, so a mid-drag reorder can't drop the wrong tab and a foreign plaintext
// drag is rejected (no reorder, no Sort→Manual flip). Pure + headless (no SwiftUI view) — drives the static
// `TabDragPayload` directly. Each assertion FAILS on the old index-based decode (`String(position)` /
// `Int(payload)`): an id payload is unparseable as an `Int`, and an in-range numeric string is NOT a live
// tab id — exactly the false positive the index path accepted.

import Foundation
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

final class TabDragPayloadTests: XCTestCase {
    /// The payload is the tab id's UUID string (round-trips to the same id).
    func testEncodeIsTheTabIdentity() {
        let id = TabID()
        XCTAssertEqual(TabDragPayload.encode(id), id.raw.uuidString)
        XCTAssertEqual(UUID(uuidString: TabDragPayload.encode(id)), id.raw)
    }

    /// (i) The rendered order CHANGED between drag-start and drop — the move still targets the DRAGGED tab.
    /// The drag grabs `t3` (which was at rendered position 0 of `[t3, t1, t0, t2]`); by drop time an
    /// `.updated` completion shuffled the rows so `t3` now sits at position 2. Resolving the id payload
    /// against the LIVE order yields `t3`'s CURRENT slot (2), not the stale start index (0) — the index-based
    /// payload (a literal `"0"`) would have moved whatever tab is now at position 0 (`t1`), the bug.
    func testResolveFollowsTheDraggedTabAfterTheRenderedOrderChanges() throws {
        let t0 = TabID(), t1 = TabID(), t2 = TabID(), t3 = TabID()
        let payload = TabDragPayload.encode(t3)
        let atDrop = [t1, t0, t3, t2] // the live rendered order at drop time (t3 moved 0 → 2)
        let move = try XCTUnwrap(
            TabDragPayload.resolveMove(payload: payload, onto: t0, in: atDrop),
            "a live tab id resolves to a move",
        )
        XCTAssertEqual(
            move.from,
            2,
            "from follows the dragged tab's identity (its CURRENT slot), not the drag-start index",
        )
        XCTAssertEqual(move.to, 1, "to is the drop target's current rendered slot")
    }

    /// (ii) A foreign / garbage drag string is REJECTED (no move). Covers an in-range NUMERIC string (the
    /// exact false positive the old `Int(payload)` decode accepted → a spurious reorder + Sort→Manual flip),
    /// an unparseable string, and a well-formed UUID that is not a live tab id.
    func testForeignOrGarbagePayloadIsRejected() {
        let t0 = TabID(), t1 = TabID()
        let order = [t0, t1]
        XCTAssertNil(
            TabDragPayload.resolveMove(payload: "1", onto: t0, in: order),
            "an in-range numeric string is not a tab id — dropped (the old Int decode would have reordered)",
        )
        XCTAssertNil(
            TabDragPayload.resolveMove(payload: "not-a-uuid", onto: t0, in: order),
            "an unparseable payload is dropped",
        )
        XCTAssertNil(
            TabDragPayload.resolveMove(payload: TabID().raw.uuidString, onto: t0, in: order),
            "a well-formed UUID that is not a live tab id is dropped",
        )
    }

    /// A self-drop (drag a row onto itself) and a target that is not currently shown are both no-op moves.
    func testSelfDropAndUnshownTargetAreNil() {
        let t0 = TabID(), t1 = TabID()
        let order = [t0, t1]
        XCTAssertNil(
            TabDragPayload.resolveMove(payload: TabDragPayload.encode(t0), onto: t0, in: order),
            "dragging a row onto itself is a no-op",
        )
        XCTAssertNil(
            TabDragPayload.resolveMove(payload: TabDragPayload.encode(t0), onto: TabID(), in: order),
            "a drop target that is not in the rendered order is dropped",
        )
    }

    // MARK: - E18 WI-7: tab-reorder insertion-line indicator (targeted-row resolution)

    /// The insertion line — a thin indicator for the landing position between tabs —
    /// anchors on the TOP edge of the row a reorder drag is hovering: ``TabReorderInsertionLine/anchorIndex``
    /// resolves the TARGETED row to its CURRENT rendered slot, so the rule tracks the row the cursor is over
    /// (a different target ⇒ a different anchor), not a fixed position. Fails to compile on the un-WI-7 code
    /// (the model does not exist), so it pins the new placement behaviour.
    func testInsertionLineAnchorsOnTheTargetedRow() {
        let t0 = TabID(), t1 = TabID(), t2 = TabID(), t3 = TabID()
        let order = [t0, t1, t2, t3]
        XCTAssertEqual(
            TabReorderInsertionLine.anchorIndex(hovering: t2, reorderEnabled: true, in: order),
            2,
            "the line anchors on the targeted row's current rendered slot",
        )
        XCTAssertEqual(
            TabReorderInsertionLine.anchorIndex(hovering: t0, reorderEnabled: true, in: order),
            0,
            "targeting a different row moves the anchor to that row's slot",
        )
    }

    /// The insertion line is SUPPRESSED (resolves to `nil` ⇒ no rule drawn) when no row is hovered, when
    /// manual reorder is gated off (an active grouping / search filter — no hand landing slot to promise), or
    /// when the targeted row is not shown in the live order (a stale / filtered-out target). Each case would
    /// otherwise paint a stray rule.
    func testInsertionLineSuppressedWhenNotTargetableOrGatedOff() {
        let t0 = TabID(), t1 = TabID()
        let order = [t0, t1]
        XCTAssertNil(
            TabReorderInsertionLine.anchorIndex(hovering: nil, reorderEnabled: true, in: order),
            "no row hovered ⇒ no insertion line",
        )
        XCTAssertNil(
            TabReorderInsertionLine.anchorIndex(hovering: t1, reorderEnabled: false, in: order),
            "manual reorder gated off (grouping / search) ⇒ no insertion line",
        )
        XCTAssertNil(
            TabReorderInsertionLine.anchorIndex(hovering: TabID(), reorderEnabled: true, in: order),
            "a target that is not shown in the live order ⇒ no insertion line",
        )
    }
}
