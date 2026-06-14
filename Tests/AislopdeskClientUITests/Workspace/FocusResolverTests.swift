import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Tests for ``FocusResolver`` — geometric, tmux-style focus movement resolved against the
/// **solved rects the user actually sees** (docs/22 §1.3, §2.1). To make the directional logic
/// deterministic and independent of the solver, every test builds a ``SolvedLayout`` *by hand*
/// with explicit rects, then asserts which pane a direction lands on.
///
/// Resolver contract under test (read from `FocusResolver`):
/// - A candidate must be **strictly on the requested side** (midpoint vs the source's edge,
///   +0.5 epsilon) AND share **> 0 cross-axis overlap** (disjoint panes are skipped).
/// - Tie-break: MORE cross-axis overlap wins first, then SMALLER axial distance.
/// - Edges return `nil`. `up == smaller y`, `down == larger y` (y grows down).
/// - `.next/.previous` cycle the frames in **reading order** (top-to-bottom, then left-to-right),
///   wrapping. For pre-order cycling, call `cycle(allLeafIDs(), …)` directly.
/// - `cycle(_:from:forward:)` returns an **optional** (nil if `from` absent / list empty).
final class FocusResolverTests: XCTestCase {
    // MARK: - Helpers

    private func layout(_ pairs: [(PaneID, CGRect)]) -> SolvedLayout {
        var frames: [PaneID: CGRect] = [:]
        for (id, rect) in pairs { frames[id] = rect }
        return SolvedLayout(frames: frames)
    }

    // MARK: - Directional neighbour: simple 2x1 horizontal layout

    /// Two side-by-side panes (left | right), full height. left↔right resolve; up/down are edges.
    func testHorizontalPairLeftRight() {
        let l = PaneID(), r = PaneID()
        let solved = layout([
            (l, CGRect(x: 0, y: 0, width: 400, height: 600)),
            (r, CGRect(x: 400, y: 0, width: 400, height: 600)),
        ])

        XCTAssertEqual(FocusResolver.neighbor(of: l, .right, in: solved), r, "right of left → right")
        XCTAssertEqual(FocusResolver.neighbor(of: r, .left, in: solved), l, "left of right → left")
        XCTAssertNil(FocusResolver.neighbor(of: l, .left, in: solved), "no pane left of the leftmost")
        XCTAssertNil(FocusResolver.neighbor(of: r, .right, in: solved), "no pane right of the rightmost")
        XCTAssertNil(FocusResolver.neighbor(of: l, .up, in: solved), "full-height panes have no up/down neighbour")
        XCTAssertNil(FocusResolver.neighbor(of: l, .down, in: solved), "full-height panes have no up/down neighbour")
    }

    // MARK: - Directional neighbour: simple 1x2 vertical layout

    /// Two stacked panes (top / bottom), full width. up↔down resolve (up == smaller y);
    /// left/right are edges.
    func testVerticalPairUpDown() {
        let top = PaneID(), bottom = PaneID()
        let solved = layout([
            (top, CGRect(x: 0, y: 0, width: 800, height: 300)),
            (bottom, CGRect(x: 0, y: 300, width: 800, height: 300)),
        ])

        XCTAssertEqual(FocusResolver.neighbor(of: top, .down, in: solved), bottom, "down == larger y")
        XCTAssertEqual(FocusResolver.neighbor(of: bottom, .up, in: solved), top, "up == smaller y")
        XCTAssertNil(FocusResolver.neighbor(of: top, .up, in: solved), "top edge")
        XCTAssertNil(FocusResolver.neighbor(of: bottom, .down, in: solved), "bottom edge")
        XCTAssertNil(
            FocusResolver.neighbor(of: top, .left, in: solved),
            "full-width panes have no left/right neighbour",
        )
    }

    // MARK: - Cross-axis overlap gating (disjoint panes are skipped)

    /// A pane is only a directional candidate if it shares cross-axis span. Layout:
    /// - A: left column, top half     (0,0,   400,300)
    /// - B: right column, full height (400,0, 400,600)
    /// - C: left column, bottom half  (0,300, 400,300)
    /// From A, `.right` must land on B (B overlaps A's y-span). From C, `.right` also lands on B.
    /// From A, `.down` lands on C (same x-column). B is NOT a `.down` candidate of A (no x-overlap
    /// beyond the seam — its x-span is disjoint from A's).
    func testCrossAxisOverlapGatesCandidates() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let solved = layout([
            (a, CGRect(x: 0, y: 0, width: 400, height: 300)),
            (b, CGRect(x: 400, y: 0, width: 400, height: 600)),
            (c, CGRect(x: 0, y: 300, width: 400, height: 300)),
        ])

        XCTAssertEqual(FocusResolver.neighbor(of: a, .right, in: solved), b, "right of top-left → tall right pane")
        XCTAssertEqual(FocusResolver.neighbor(of: c, .right, in: solved), b, "right of bottom-left → tall right pane")
        XCTAssertEqual(FocusResolver.neighbor(of: a, .down, in: solved), c, "down of top-left → bottom-left (shares x)")
        XCTAssertNil(FocusResolver.neighbor(of: a, .left, in: solved), "nothing left of column 0")
        // From B moving left: both A and C overlap B's y-span; A overlaps [0,300], C overlaps
        // [300,600], each 300 tall, abutting B's left edge → equal overlap & distance, a tie.
        let leftOfB = FocusResolver.neighbor(of: b, .left, in: solved)
        XCTAssertTrue(leftOfB == a || leftOfB == c, "left of the tall pane resolves to one of the abutting left panes")
    }

    // MARK: - Tie-break: more overlap wins, then nearer

    /// Overlap beats distance. Source S on the left; two right candidates:
    /// - BIG: fully overlaps S's height, but farther away (x starts at 600).
    /// - SMALL: only partially overlaps S's height, nearer (x starts at 400).
    /// The resolver prefers MORE cross-axis overlap first → BIG wins despite being farther.
    func testTieBreakPrefersMoreOverlapOverDistance() {
        let s = PaneID(), big = PaneID(), small = PaneID()
        let solved = layout([
            (s, CGRect(x: 0, y: 0, width: 400, height: 400)), // S spans y 0..400
            (small, CGRect(x: 400, y: 0, width: 150, height: 100)), // overlaps only y 0..100, nearer
            (big, CGRect(x: 600, y: 0, width: 150, height: 400)), // overlaps y 0..400, farther
        ])
        XCTAssertEqual(
            FocusResolver.neighbor(of: s, .right, in: solved),
            big,
            "more cross-axis overlap wins over a nearer but lesser-overlap pane",
        )
    }

    /// With overlap tied, the NEARER pane wins. Source S on the left; two right candidates that
    /// both fully overlap S's height — NEAR (x=400) and FAR (x=600). Equal overlap → smaller axial
    /// distance breaks the tie → NEAR.
    func testTieBreakPrefersNearerWhenOverlapEqual() {
        let s = PaneID(), near = PaneID(), far = PaneID()
        let solved = layout([
            (s, CGRect(x: 0, y: 0, width: 400, height: 400)),
            (near, CGRect(x: 400, y: 0, width: 150, height: 400)), // abuts S, full overlap
            (far, CGRect(x: 600, y: 0, width: 150, height: 400)), // farther, full overlap
        ])
        XCTAssertEqual(
            FocusResolver.neighbor(of: s, .right, in: solved),
            near,
            "equal overlap → nearer pane wins",
        )
    }

    // MARK: - "Strictly on the requested side" gating

    /// A pane that is not strictly on the requested side is not a candidate. Source S; a pane T
    /// whose midpoint is to S's LEFT must not be returned for `.right` (even though it overlaps).
    func testStrictlyOnSideRejectsWrongSide() {
        let s = PaneID(), t = PaneID()
        let solved = layout([
            (s, CGRect(x: 400, y: 0, width: 400, height: 600)),
            (t, CGRect(x: 0, y: 0, width: 400, height: 600)), // entirely to the left
        ])
        XCTAssertNil(FocusResolver.neighbor(of: s, .right, in: solved), "a left pane is never a right neighbour")
        XCTAssertEqual(FocusResolver.neighbor(of: s, .left, in: solved), t, "…but it IS the left neighbour")
    }

    // MARK: - Empty / unknown source

    /// A source not present in the layout (or an empty layout) yields nil for every direction.
    func testUnknownOrEmptySourceReturnsNil() {
        let ghost = PaneID()
        let present = PaneID()
        let solved = layout([(present, CGRect(x: 0, y: 0, width: 100, height: 100))])

        for dir: FocusDirection in [.left, .right, .up, .down, .next, .previous] {
            XCTAssertNil(FocusResolver.neighbor(of: ghost, dir, in: solved), "unknown source → nil (\(dir))")
        }
        XCTAssertNil(FocusResolver.neighbor(of: ghost, .right, in: SolvedLayout.empty), "empty layout → nil")
    }

    /// A lone pane has no directional neighbour, but `.next/.previous` cycle back to itself.
    func testLonePaneDirectionalNilButCycleSelf() {
        let only = PaneID()
        let solved = layout([(only, CGRect(x: 0, y: 0, width: 800, height: 600))])

        XCTAssertNil(FocusResolver.neighbor(of: only, .left, in: solved))
        XCTAssertNil(FocusResolver.neighbor(of: only, .up, in: solved))
        XCTAssertEqual(FocusResolver.neighbor(of: only, .next, in: solved), only, "single pane cycles to itself")
        XCTAssertEqual(FocusResolver.neighbor(of: only, .previous, in: solved), only)
    }

    // MARK: - .next / .previous via neighbor (reading-order cycle, wraps)

    /// `.next/.previous` cycle in **reading order** (top-to-bottom, then left-to-right) and wrap.
    /// Layout (reading order = A, B, C):
    /// - A: top-left      (0,0,   400,300)
    /// - B: top-right     (400,0, 400,300)
    /// - C: bottom strip  (0,300, 800,300)
    func testNextPreviousReadingOrderWraps() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let solved = layout([
            (a, CGRect(x: 0, y: 0, width: 400, height: 300)),
            (b, CGRect(x: 400, y: 0, width: 400, height: 300)),
            (c, CGRect(x: 0, y: 300, width: 800, height: 300)),
        ])

        // forward: A → B → C → A
        XCTAssertEqual(FocusResolver.neighbor(of: a, .next, in: solved), b)
        XCTAssertEqual(FocusResolver.neighbor(of: b, .next, in: solved), c)
        XCTAssertEqual(FocusResolver.neighbor(of: c, .next, in: solved), a, "wraps at the end")

        // backward: A → C → B → A
        XCTAssertEqual(FocusResolver.neighbor(of: a, .previous, in: solved), c, "wraps at the start")
        XCTAssertEqual(FocusResolver.neighbor(of: c, .previous, in: solved), b)
        XCTAssertEqual(FocusResolver.neighbor(of: b, .previous, in: solved), a)
    }

    // MARK: - cycle(_:from:forward:) directly (the explicit pre-order API)

    /// Forward cycle wraps past the end of the list.
    func testCycleForwardWraps() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let leaves = [a, b, c]
        XCTAssertEqual(FocusResolver.cycle(leaves, from: a, forward: true), b)
        XCTAssertEqual(FocusResolver.cycle(leaves, from: b, forward: true), c)
        XCTAssertEqual(FocusResolver.cycle(leaves, from: c, forward: true), a, "wraps to the front")
    }

    /// Backward cycle wraps past the start of the list.
    func testCycleBackwardWraps() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let leaves = [a, b, c]
        XCTAssertEqual(FocusResolver.cycle(leaves, from: a, forward: false), c, "wraps to the back")
        XCTAssertEqual(FocusResolver.cycle(leaves, from: c, forward: false), b)
        XCTAssertEqual(FocusResolver.cycle(leaves, from: b, forward: false), a)
    }

    /// A single-element list cycles to itself in both directions.
    func testCycleSingleElement() {
        let only = PaneID()
        XCTAssertEqual(FocusResolver.cycle([only], from: only, forward: true), only)
        XCTAssertEqual(FocusResolver.cycle([only], from: only, forward: false), only)
    }

    /// `cycle` returns nil (it is OPTIONAL) when `from` is absent or the list is empty.
    func testCycleReturnsNilForMissingOrEmpty() {
        let a = PaneID(), b = PaneID(), ghost = PaneID()
        XCTAssertNil(FocusResolver.cycle([a, b], from: ghost, forward: true), "from not in list → nil")
        XCTAssertNil(FocusResolver.cycle([], from: a, forward: true), "empty list → nil")
    }

    // MARK: - Determinism for coincident panes (no Dictionary-iteration-order dependence)

    /// A `PaneID` with a controlled, ascending uuid so the total tie-break order is known.
    private func pid(_ n: Int) -> PaneID {
        PaneID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!)
    }

    func testCycleOverCoincidentPanesIsDeterministicByID() {
        // Stacked panes (the SAME canvas position — reachable via the ⌘ overlap bypass, or an
        // Align/Distribute op that does not run the non-overlap solver) share minY AND minX, so the
        // reading-order sort can only tie-break on the stable id. Without that tie-break the comparator
        // returned "equal" and the stable sort preserved the Dictionary's per-process-randomized iteration
        // order, so ⌘]/⌘[ could visit coincident panes in a different order each launch.
        let ids = (1...8).map { pid($0) } // ascending by uuidString
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let solved = layout(ids.map { ($0, frame) })
        for i in ids.indices {
            XCTAssertEqual(
                FocusResolver.neighbor(of: ids[i], .next, in: solved),
                ids[(i + 1) % ids.count],
                "next cycles coincident panes in ascending-id order, deterministically",
            )
            XCTAssertEqual(
                FocusResolver.neighbor(of: ids[i], .previous, in: solved),
                ids[(i - 1 + ids.count) % ids.count],
                "previous is the exact inverse",
            )
        }
    }

    func testDirectionalPickAmongExactTiesIsDeterministicByID() {
        // A source with several COINCIDENT candidates to its right: all share the same cross-axis overlap
        // and axial distance — an exact tie. The pick must resolve to the smallest id, not whichever the
        // Dictionary happened to enumerate first.
        let source = pid(1000)
        let rightStack = (1...8).map { pid($0) }
        let srcRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let candRect = CGRect(x: 400, y: 0, width: 200, height: 200) // all to the right, all the same rect
        let solved = layout([(source, srcRect)] + rightStack.map { ($0, candRect) })
        XCTAssertEqual(
            FocusResolver.neighbor(of: source, .right, in: solved),
            rightStack.min(by: { $0.raw.uuidString < $1.raw.uuidString }),
            "an exact directional tie resolves to the smallest id, deterministically",
        )
    }
}
