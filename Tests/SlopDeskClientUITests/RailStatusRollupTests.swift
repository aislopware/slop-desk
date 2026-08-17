// RailStatusRollupTests — pins the sidebar band's aggregate reading (``RailStatusRollup``): PRESENCE
// only (≥1 pane lights a state, and the cluster never counts), a FIXED drawing order, and — the pin
// that matters most — that every branch borrows a predicate the ROW already renders by, so a mark
// can never appear in the band that the rail underneath would not draw.
//
// Headless VALUE assertions — no render. Ink/mark identity is asserted SELF-consistently against the
// presentation maps (never absolute colours — `Color` equality is provider-fragile), the same
// contract `StatusDotTests` keeps.

import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI

#if os(macOS)
final class RailStatusRollupTests: XCTestCase {
    private typealias Rollup = RailStatusRollup

    private func reading(
        _ status: ClaudeStatus = .none, badge: TabBadgeKind? = nil, unseenDone: Bool = false,
    ) -> Rollup.Reading {
        Rollup.Reading(status: status, badge: badge, unseenDone: unseenDone)
    }

    /// Nothing happening LIGHTS nothing — the derivation's own answer, which is separate from what
    /// gets drawn (all three slots, always: ``testEverySlotIsDrawnLitOrNot``).
    func testNothingHappeningLightsNothing() {
        XCTAssertEqual(Rollup.kinds([]), [], "no panes, no lit marks")
        XCTAssertEqual(
            Rollup.kinds([reading(.idle), reading(badge: .commandBusy), reading(badge: .sudo)]), [],
            "a resting agent, a busy shell and a privilege modifier are not the band's news",
        )
    }

    /// ⚠️ THE SLOTS ARE FIXED (user-directed 2026-08-11, reversing the collapsing cluster this view
    /// shipped as). Every state in ``RailStatusRollup/order`` resolves to a drawable mark whether or
    /// not it is happening, so the cluster never changes width and a mark never changes place — the
    /// property that lets the reader learn the three positions once instead of re-identifying them
    /// on every arrival.
    @MainActor
    func testEverySlotIsDrawnLitOrNot() {
        for kind in Rollup.order {
            for active in [true, false] {
                XCTAssertNotNil(
                    Rollup.style(for: kind, active: active),
                    "\(kind) must draw whether or not it is happening (active: \(active))",
                )
            }
        }
    }

    /// An UNLIT slot keeps the SILHOUETTE and gives up everything that carries state: the hue goes
    /// neutral and the one mark that moves is frozen. Losing either half is how a legend turns back
    /// into three states all half-happening.
    @MainActor
    func testAnUnlitSlotKeepsItsShapeAndGivesUpHueAndMotion() {
        for kind in Rollup.order {
            let lit = Rollup.style(for: kind, active: true)
            let unlit = Rollup.style(for: kind, active: false)
            XCTAssertEqual(unlit?.mark, lit?.mark, "\(kind) must not change silhouette when unlit")
            XCTAssertEqual(unlit?.ink, Rollup.disabledInk, "\(kind) unlit spends no hue")
            XCTAssertNotEqual(unlit?.ink, lit?.ink, "\(kind) lit and unlit must not be one colour")
            XCTAssertTrue(unlit?.frozen == true, "\(kind) unlit must not animate")
            XCTAssertFalse(lit?.frozen == true, "\(kind) lit keeps its own motion")
        }
    }

    /// ⚠️ EACH MARK JUMPS INTO ITS OWN STATE (user-reported 2026-08-11: clicking the spinner or the
    /// check landed on the BLOCKED pane, because one tap target ran the attention walk, which ranks
    /// needs-permission first). The pane list per mark is derived from the SAME predicate that
    /// decides whether the mark is lit, so a lit mark always has somewhere to go and an unlit one
    /// never does.
    func testEachMarksPaneListIsTheStateItIsLitFor() {
        let readings: [(String, Rollup.Reading)] = [
            ("blocked", reading(badge: .awaitingInput)),
            ("thinking", reading(.working)),
            ("finished", reading(.done, badge: .finished, unseenDone: true)),
            ("quiet", reading(.idle)),
        ]
        let lit = Rollup.kinds(readings.map(\.1))
        XCTAssertEqual(lit, [.waiting, .working, .done])
        for kind in Rollup.order {
            let panes = readings.filter { Rollup.matches(kind, $0.1) }.map(\.0)
            XCTAssertEqual(panes.count, 1, "\(kind) must claim exactly the one pane in that state")
        }
        XCTAssertEqual(readings.filter { Rollup.matches(.waiting, $0.1) }.map(\.0), ["blocked"])
        XCTAssertEqual(readings.filter { Rollup.matches(.working, $0.1) }.map(\.0), ["thinking"])
        XCTAssertEqual(readings.filter { Rollup.matches(.done, $0.1) }.map(\.0), ["finished"])
        // …and a state nothing is in gives its mark nothing to jump to, which is why it is inert.
        XCTAssertFalse(readings.contains { Rollup.matches(.waiting, reading(.idle)) && $0.0 == "x" })
    }

    /// Repeated clicks WALK the state instead of pinning its first pane, and a focus outside the
    /// list restarts at its head.
    func testAMarksClickWalksItsOwnList() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        XCTAssertEqual(Rollup.nextPane(in: [a, b, c], focused: nil), a, "focus elsewhere → the head")
        XCTAssertEqual(Rollup.nextPane(in: [a, b, c], focused: c), a, "…and the walk wraps")
        XCTAssertEqual(Rollup.nextPane(in: [a, b, c], focused: a), b)
        XCTAssertEqual(Rollup.nextPane(in: [a], focused: a), a, "one pane is its own next")
        XCTAssertNil(Rollup.nextPane(in: [], focused: a), "an unlit mark has nowhere to go")
    }

    /// The two parking spots the cluster travels between, and the clamp that keeps it out of the
    /// traffic lights. Expanded it ENDS on the navigator's gutter; collapsed it stands one gap right
    /// of the sidebar toggle's plate.
    @MainActor
    func testTheClusterParksOnTheGutterAndFallsBackToTheToggle() {
        let width = Slate.Metric.sidebarWidth
        let expanded = RailStatusRollupMount.lead(collapsed: false, navigatorWidth: width)
        XCTAssertEqual(
            expanded + RailStatusMarks.width + RailStatusRollup.trailingInset, width,
            "expanded, the cluster's TRAILING edge lands on the column's gutter",
        )
        XCTAssertEqual(
            RailStatusRollupMount.lead(collapsed: true, navigatorWidth: width),
            Slate.Metric.windowControlsLead + Slate.Metric.plate + Slate.Metric.space2,
            "collapsed, it parks one gap right of the toggle's plate",
        )
        // A wider column carries it further out — the reason the width is published at all.
        XCTAssertGreaterThan(
            RailStatusRollupMount.lead(collapsed: false, navigatorWidth: width + 100), expanded,
        )
        // …and a column narrower than the toggle's own row can never push it left of the toggle.
        XCTAssertEqual(
            RailStatusRollupMount.lead(collapsed: false, navigatorWidth: 0),
            RailStatusRollupMount.lead(collapsed: true, navigatorWidth: 0),
        )
    }

    /// ⚠️ Nothing else on that band may start under the parked cluster (user-reported 2026-08-11:
    /// the marks sat ON the first horizontal tab). The strip's inset and the cluster's parking spot
    /// are ONE sum — this pins that the sum actually clears the marks, and that ``SlateTitlebar``
    /// spends it rather than re-deriving the toggle's slot on its own.
    @MainActor
    func testTheCollapsedBandLeavesRoomBeforeTheTabsBegin() {
        XCTAssertEqual(
            RailStatusRollupMount.collapsedTrailingEdge,
            RailStatusRollupMount.collapsedLead + RailStatusMarks.width + Slate.Metric.space2,
        )
        XCTAssertGreaterThanOrEqual(
            RailStatusRollupMount.collapsedTrailingEdge - RailStatusMarks.width,
            RailStatusRollupMount.lead(collapsed: true, navigatorWidth: 0),
            "the tabs may not begin before the cluster ENDS",
        )
        // The old inset — the toggle's slot alone — is exactly what the marks now overlap.
        XCTAssertLessThan(
            Slate.Metric.windowControlsLead + Slate.Metric.plate + Slate.Metric.space2,
            RailStatusRollupMount.collapsedTrailingEdge,
        )
    }

    /// The marks stand APART — one footprint each, one `space2` gap between (user-reported: the
    /// three read as one object and the pointer missed). The gap is dead space by construction,
    /// because a mark's hit box is its own footprint and never the half-gap beside it.
    @MainActor
    func testTheMarksStandOneGapApart() {
        XCTAssertEqual(RailStatusMarks.markGap, Slate.Metric.space2)
        XCTAssertGreaterThan(RailStatusMarks.markGap, Slate.Metric.space1, "space1 was the miss")
        XCTAssertEqual(
            RailStatusMarks.width,
            StatusDot.footprint * 3 + RailStatusMarks.markGap * 2,
            "three slots and two gaps — the width the mount positions by",
        )
    }

    /// The cluster always speaks, because three marks are always on screen: a VoiceOver reader who
    /// lands on a resting band must be told it is resting rather than find an unlabelled element.
    @MainActor
    func testTheClusterSpeaksEvenWhenNothingIsLit() {
        XCTAssertFalse(Rollup.summary([]).isEmpty, "a resting cluster still has to say so")
        XCTAssertEqual(
            Rollup.summary(Rollup.order),
            Rollup.order.map(Rollup.label(for:)).joined(separator: ", "),
            "and a lit one names exactly the states that are lit, in the drawing order",
        )
    }

    /// ONE pane is enough, and TEN are no more — presence, never a count. This is the user's own
    /// spec ("≥1 thì sáng, không cần số") and it is what keeps the cluster from becoming a dashboard.
    func testPresenceNotCount() {
        let one = Rollup.kinds([reading(.working)])
        let many = Rollup.kinds(Array(repeating: reading(.working), count: 10))
        XCTAssertEqual(one, [.working])
        XCTAssertEqual(many, one, "ten thinking agents say exactly what one says")
    }

    /// The drawing order is PINNED BY VALUE, and pinned again through the derivation: urgency first,
    /// the same rank the unseen-attention queue sorts by. Deriving it from the enum's declaration
    /// would let a reorder silently rewrite the band.
    func testOrderIsUrgencyFirstAndFixed() {
        XCTAssertEqual(Rollup.order, [.waiting, .working, .done])
        // Fed in the REVERSE order, the cluster still draws waiting → working → done.
        XCTAssertEqual(
            Rollup.kinds([
                reading(.done, badge: .finished, unseenDone: true),
                reading(.working),
                reading(badge: .awaitingInput),
            ]),
            [.waiting, .working, .done],
            "input order never reaches the band",
        )
    }

    /// ⚠️ The working state keys on the RAW status, NOT the gated badge. "Badge while processing" is
    /// OFF by default and masks `.working` out of the badge — reading the badge here would leave a
    /// whole workspace of thinking agents dark for every default install. The badge-routed
    /// `.running` tier reads identically, exactly as it does on the row.
    func testWorkingKeysOnTheRawStatusAndOnTheRunningTier() {
        XCTAssertEqual(
            Rollup.kinds([reading(.working, badge: nil)]), [.working],
            "the gate silences the glyph on the row, never the fact",
        )
        XCTAssertEqual(
            Rollup.kinds([reading(.none, badge: .running)]), [.working],
            "the badge route and the raw route are ONE reading",
        )
    }

    /// The done mark belongs to the AGENT's turn ending. A command's clean exit fuses into the same
    /// `TabBadgeKind`, so the badge alone cannot say whose finish it is — the rollup asks
    /// ``RailRowsBuilder/finishIsAgents(badge:status:unseenDone:)``, the same predicate that decides
    /// whether the ROW's check is the agent's. Round 24's law (the mark column is the agent's alone)
    /// holds in the band too.
    func testDoneIsTheAgentsFinishNotACommandsExit() {
        XCTAssertEqual(
            Rollup.kinds([reading(.done, badge: .completed)]), [.done],
            "a live done status is the agent's own finish",
        )
        XCTAssertEqual(
            Rollup.kinds([reading(.none, badge: .completed, unseenDone: true)]), [.done],
            "the unread latch carries the finish after the status has settled",
        )
        XCTAssertEqual(
            Rollup.kinds([reading(.none, badge: .completed, unseenDone: false)]), [],
            "a plain command exiting 0 is NOT the agent tier — the band says nothing",
        )
        XCTAssertEqual(
            Rollup.kinds([reading(.none, badge: .error)]), [],
            "a failed command speaks in the row's slot, never in the mark column",
        )
    }

    /// Three panes in three states light three marks — the cluster is a set union over the rows, not
    /// the rail's single most-urgent rollup (``WorkspaceStore/rollupStatus(forSession:)``). Losing
    /// this is how "3 marks" quietly becomes "1 mark".
    func testEveryPresentStateGetsItsOwnMark() {
        XCTAssertEqual(
            Rollup.kinds([
                reading(badge: .awaitingInput),
                reading(.working),
                reading(.done, badge: .finished, unseenDone: true),
                reading(.idle),
            ]),
            [.waiting, .working, .done],
        )
    }

    /// Each state draws the ROW's mark, borrowed rather than respelled: change a row's hue or
    /// silhouette and the band follows without being touched. Asserted against the presentation map
    /// itself, so this can never harden into a second copy of the vocabulary.
    @MainActor
    func testEachMarkIsTheRowsOwnMark() {
        XCTAssertEqual(
            Rollup.style(for: .waiting),
            StatusPresentation.statusDot(working: false, badge: .awaitingInput),
            "the waiting mark IS the row's hand",
        )
        XCTAssertEqual(
            Rollup.style(for: .working), StatusPresentation.thinkingMark,
            "the working mark IS the row's spinner",
        )
        XCTAssertEqual(
            Rollup.style(for: .done),
            StatusPresentation.statusDot(working: false, badge: .completed, agentFinish: true),
            "the done mark IS the row's filled check",
        )
        for kind in Rollup.order {
            XCTAssertNotNil(Rollup.style(for: kind), "\(kind) must resolve to a drawable mark")
            XCTAssertFalse(Rollup.label(for: kind).isEmpty, "\(kind) must speak to VoiceOver")
        }
    }

    /// The cluster ends on the COLUMN's gutter — flush with the search plate under it, which is the
    /// user's own correction (2026-08-11: it stood 18pt short of that edge, on the rows' mark
    /// column, and read as a cluster that had failed to reach it).
    @MainActor
    func testMarksEndOnTheColumnsGutter() {
        XCTAssertEqual(Rollup.trailingInset, Slate.Metric.space2)
        XCTAssertNotEqual(
            Rollup.trailingInset,
            Slate.Metric.space2 + Slate.Metric.projectIslandInset + Slate.Metric.islandRail,
            "the rows' mark column is NOT where this stands any more",
        )
    }
}
#endif
