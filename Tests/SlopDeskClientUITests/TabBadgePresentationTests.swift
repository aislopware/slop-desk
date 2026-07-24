// TabBadgePresentationTests — pins the pure view-side badge map. `StatusPresentation.tabBadge`
// resolves each `TabBadgeKind` to a reading of the ONE-SHAPE circle (`StatusRing`): every lifecycle
// state is the same Ø12 silhouette differing by hue + fill (busy = the sweeping comet arc, awaiting
// = ring + blinking cursor dot, error = the broken ring, completed/finished = the filled circle),
// privilege = small text glyphs. `tabBadgeLabel` gives every kind a distinct non-empty AX/tooltip string.
// Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream. (Tints are deliberately
// NOT asserted — `Color` equality is provider-fragile; the reading CLASS is the load-bearing spec.)

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    private func ringReading(of kind: TabBadgeKind) -> StatusRing.Reading? {
        if case let .ring(reading, _) = StatusPresentation.tabBadge(kind) { return reading }
        return nil
    }

    private func glyphText(of kind: TabBadgeKind) -> String? {
        if case let .glyph(text, _) = StatusPresentation.tabBadge(kind) { return text }
        return nil
    }

    /// Every lifecycle state resolves to a `StatusRing` reading — one silhouette across the whole
    /// badge vocabulary; only the privilege markers stay text. This is THE one-shape contract: a
    /// state edge must read as a colour/fill change of the same circle, never an icon swap.
    func testEveryLifecycleStateIsARingReading() {
        let lifecycle: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
        ]
        for kind in lifecycle {
            XCTAssertNotNil(ringReading(of: kind), "\(kind) must speak the one-shape circle")
        }
    }

    /// Every busy tier — a working agent, an instrumented command, a plain busy shell — is the ONE
    /// sweeping `working` comet (hue, not shape, separates agent from command motion). The SIDEBAR
    /// rows never mount these (split on `TabBadgeKind.isBusyTier`: the agent tier shimmers the
    /// title); the ring stays the vocabulary for any other badge mount.
    func testEveryBusyTierIsTheWorkingRing() {
        XCTAssertEqual(ringReading(of: .running), .working)
        XCTAssertEqual(ringReading(of: .commandRunning), .working)
        XCTAssertEqual(ringReading(of: .commandBusy), .working)
    }

    /// `.awaitingInput` ⇒ the `awaiting` ring — distinct from motion (an ignored question must not
    /// read as progress) and from the broken error ring (a question is not a failure).
    func testAwaitingIsTheAwaitingRing() {
        XCTAssertEqual(ringReading(of: .awaitingInput), .awaiting)
    }

    /// `.error` ⇒ the `error` ring — static (it waits on you), never the awaiting reading.
    func testErrorIsTheErrorRing() {
        XCTAssertEqual(ringReading(of: .error), .error)
    }

    /// Both clean-finish tiers ⇒ the ONE quiet `done` fill (the circle at full fill — a marker, not
    /// a trophy). The completed/finished split stays semantic (freshness machinery, control-backend
    /// tokens) while the rail speaks one unread marker.
    func testDoneTierIsTheQuietFilledCircle() {
        XCTAssertEqual(ringReading(of: .completed), .done)
        XCTAssertEqual(ringReading(of: .finished), .done)
    }

    /// The privilege markers stay small text in the shell's dialect — modifiers, not lifecycle
    /// states, so they sit outside the circle vocabulary.
    func testPrivilegeMarkersAreTextGlyphs() {
        XCTAssertEqual(glyphText(of: .sudo), "#")
        XCTAssertEqual(glyphText(of: .caffeinate), "∞")
    }

    /// The agent surfaces (iOS toolbar, Peek & Reply header) speak the same circle: each
    /// `ClaudeStatus` maps onto the shared reading set, and only "no agent" renders nothing.
    func testAgentStatusesShareTheRingVocabulary() {
        XCTAssertNil(StatusPresentation.agentReading(.none))
        XCTAssertEqual(StatusPresentation.agentReading(.idle), .resting)
        XCTAssertEqual(StatusPresentation.agentReading(.working), .working)
        XCTAssertEqual(StatusPresentation.agentReading(.done), .done)
        XCTAssertEqual(StatusPresentation.agentReading(.needsPermission), .awaiting)
    }

    /// Every kind carries a non-empty, distinct AX/tooltip label so the icon-free badge is legible/testable.
    func testEveryKindHasADistinctNonEmptyLabel() {
        let kinds: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
            .caffeinate, .sudo,
        ]
        let labels = kinds.map { StatusPresentation.tabBadgeLabel($0) }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "no blank badge labels")
        XCTAssertEqual(Set(labels).count, kinds.count, "labels are distinct per kind")
    }
}
