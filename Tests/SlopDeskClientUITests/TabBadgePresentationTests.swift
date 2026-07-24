// TabBadgePresentationTests — pins the pure view-side status map: the INK DIALECT. A sidebar row
// never mounts a lifecycle glyph — the attention states recolour the row's own TITLE ink
// (`StatusPresentation.attentionInk`, all static hard cuts — running belongs to the ring mark),
// and ONLY the privilege modifiers (`#`/`∞`) occupy the trailing slot
// (`StatusPresentation.tabBadge`). `tabBadgeLabel` gives every kind a distinct non-empty AX/tooltip
// string. Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream. (Ink colours are
// deliberately NOT asserted against tokens — `Color` equality is provider-fragile; the ink/glyph/nil
// CLASS of each kind is the load-bearing spec.)

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    private let allKinds: [TabBadgeKind] = [
        .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
        .caffeinate, .sudo,
    ]

    /// THE dialect contract: a kind carries attention ink EXACTLY when it is attention-class — the
    /// states that wait on you recolour the title, and nothing else does (running is the ring
    /// mark's job, privilege is slot text, so the ink can never double-book a row).
    func testAttentionInkCoversExactlyTheAttentionClass() {
        for kind in allKinds {
            if kind.needsAttention {
                XCTAssertNotNil(
                    StatusPresentation.attentionInk(kind),
                    "\(kind) waits on the user — its title must wear the attention ink",
                )
            } else {
                XCTAssertNil(
                    StatusPresentation.attentionInk(kind),
                    "\(kind) is not attention-class — the title keeps the resting ink ladder",
                )
            }
        }
    }

    /// No lifecycle state mounts trailing slot TEXT — attention is ink, running is the ring mark,
    /// so the slot stays free for the shell label on every non-privilege row.
    func testLifecycleStatesMountNoSlotGlyph() {
        let lifecycle: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
        ]
        for kind in lifecycle {
            XCTAssertNil(
                StatusPresentation.tabBadge(kind),
                "\(kind) must not occupy the trailing slot — status speaks through the title",
            )
        }
    }

    /// The privilege markers are the ONLY slot glyphs — small text in the shell's dialect
    /// (modifiers, not lifecycle states).
    func testPrivilegeMarkersAreTheOnlySlotGlyphs() {
        XCTAssertEqual(StatusPresentation.tabBadge(.sudo)?.text, "#")
        XCTAssertEqual(StatusPresentation.tabBadge(.caffeinate)?.text, "∞")
    }

    /// The compact agent surfaces (iOS toolbar, Peek & Reply header) speak the `StatusGlyph`
    /// vocabulary: each `ClaudeStatus` maps onto the shared reading set, and only "no agent"
    /// renders nothing.
    func testAgentStatusesShareTheGlyphVocabulary() {
        XCTAssertNil(StatusPresentation.agentReading(.none))
        XCTAssertEqual(StatusPresentation.agentReading(.idle), .resting)
        XCTAssertEqual(StatusPresentation.agentReading(.working), .working)
        XCTAssertEqual(StatusPresentation.agentReading(.done), .done)
        XCTAssertEqual(StatusPresentation.agentReading(.needsPermission), .awaiting)
    }

    /// The agent spinner's cadence, pinned headlessly off the pure frame function: frames advance
    /// one per beat from the fixed epoch, wrap at the cycle's end, and a re-render at the same
    /// instant yields the same frame (phase is a function of the wall clock, not of mount count).
    func testSpinnerFrameCadenceAdvancesOnePerBeatAndWraps() {
        let frames = StatusGlyph.agentFrames
        let beat = StatusGlyph.agentBeat
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0..<(frames.count * 2) {
            let at = epoch.addingTimeInterval(Double(step) * beat + beat / 2)
            XCTAssertEqual(
                StatusGlyph.frame(at: at, frames: frames, beat: beat),
                frames[step % frames.count],
                "step \(step) must land on its own frame",
            )
        }
        let mid = epoch.addingTimeInterval(3.14)
        XCTAssertEqual(
            StatusGlyph.frame(at: mid, frames: frames, beat: beat),
            StatusGlyph.frame(at: mid, frames: frames, beat: beat),
            "same instant ⇒ same frame — a re-mount can't skip",
        )
    }

    /// The collapsed group's roll-up: the header count borrows the STRONGEST attention ink among
    /// the hidden rows' fused badges — a waiting question outranks an error outranks an unread
    /// finish (the resolver's own precedence) — and stays `nil` when nothing inside waits, so the
    /// count keeps the muted metadata ink. Assertions are SELF-consistent against `attentionInk`
    /// (never absolute colour values, per the header note).
    func testAttentionRollupInkFollowsBadgePrecedence() {
        XCTAssertNil(StatusPresentation.attentionRollupInk([]))
        XCTAssertNil(
            StatusPresentation.attentionRollupInk([nil, .running, .sudo, .commandBusy]),
            "busy/privilege tiers roll up to no ink — only attention states colour the count",
        )
        XCTAssertEqual(
            StatusPresentation.attentionRollupInk([nil, .finished]),
            StatusPresentation.attentionInk(.finished),
        )
        XCTAssertEqual(
            StatusPresentation.attentionRollupInk([.completed, .error, nil, .running]),
            StatusPresentation.attentionInk(.error),
            "an error outranks an unread finish",
        )
        XCTAssertEqual(
            StatusPresentation.attentionRollupInk([.error, .awaitingInput, .finished]),
            StatusPresentation.attentionInk(.awaitingInput),
            "a waiting question outranks everything",
        )
    }

    /// Every kind carries a non-empty, distinct AX/tooltip label so the colour-spoken state stays
    /// legible and testable.
    func testEveryKindHasADistinctNonEmptyLabel() {
        let labels = allKinds.map { StatusPresentation.tabBadgeLabel($0) }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "no blank badge labels")
        XCTAssertEqual(Set(labels).count, allKinds.count, "labels are distinct per kind")
    }
}
