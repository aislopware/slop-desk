// TabBadgePresentationTests — pins the pure view-side badge map. `StatusPresentation.tabBadge`
// resolves each `TabBadgeKind` to a `StatusGlyph` reading — the terminal text dialect: every
// lifecycle state is the character a CLI would print (agent = the asterisk pulse, command = the
// braille dot-walker, awaiting = blinking `?`, error = `✗`, completed/finished = `●`), privilege =
// small static text glyphs. `tabBadgeLabel` gives every kind a distinct non-empty AX/tooltip string.
// Headless VALUE assertions — no SwiftUI render, no video/Metal/SCStream. (Tints are deliberately
// NOT asserted — `Color` equality is provider-fragile; the reading CLASS is the load-bearing spec.)

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    private func glyphReading(of kind: TabBadgeKind) -> StatusGlyph.Reading? {
        if case let .reading(reading, _) = StatusPresentation.tabBadge(kind) { return reading }
        return nil
    }

    private func glyphText(of kind: TabBadgeKind) -> String? {
        if case let .glyph(text, _) = StatusPresentation.tabBadge(kind) { return text }
        return nil
    }

    /// Every lifecycle state resolves to a `StatusGlyph` reading — one terminal-dialect vocabulary
    /// across the whole badge set; only the privilege markers stay free-text. This is THE dialect
    /// contract: a state edge is one character trading for another in the same mono slot, never a
    /// drawn icon appearing.
    func testEveryLifecycleStateIsAGlyphReading() {
        let lifecycle: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
        ]
        for kind in lifecycle {
            XCTAssertNotNil(glyphReading(of: kind), "\(kind) must speak the terminal glyph dialect")
        }
    }

    /// The busy tiers split by VOICE, not just hue: a working agent spins the AI-CLI asterisk pulse
    /// (`working`), a plain command spins the shell's braille dot-walker (`busy`). The SIDEBAR rows
    /// never mount these (split on `TabBadgeKind.isBusyTier`: the agent tier shimmers the title);
    /// the spinners stay the vocabulary for any other badge mount.
    func testBusyTiersSplitAgentPulseFromCommandWalker() {
        XCTAssertEqual(glyphReading(of: .running), .working)
        XCTAssertEqual(glyphReading(of: .commandRunning), .busy)
        XCTAssertEqual(glyphReading(of: .commandBusy), .busy)
    }

    /// `.awaitingInput` ⇒ the `awaiting` reading (the blinking `?`) — distinct from motion (an
    /// ignored question must not read as progress) and from the error `✗` (a question is not a
    /// failure).
    func testAwaitingIsTheAwaitingReading() {
        XCTAssertEqual(glyphReading(of: .awaitingInput), .awaiting)
    }

    /// `.error` ⇒ the `error` reading (`✗`) — static (it waits on you), never the awaiting reading.
    func testErrorIsTheErrorReading() {
        XCTAssertEqual(glyphReading(of: .error), .error)
    }

    /// Both clean-finish tiers ⇒ the ONE quiet `done` reading (`●` — a marker, not a trophy). The
    /// completed/finished split stays semantic (freshness machinery, control-backend tokens) while
    /// the rail speaks one unread marker.
    func testDoneTierIsTheQuietDot() {
        XCTAssertEqual(glyphReading(of: .completed), .done)
        XCTAssertEqual(glyphReading(of: .finished), .done)
    }

    /// The privilege markers stay small text in the shell's dialect — modifiers, not lifecycle
    /// states, so they sit outside the reading vocabulary.
    func testPrivilegeMarkersAreTextGlyphs() {
        XCTAssertEqual(glyphText(of: .sudo), "#")
        XCTAssertEqual(glyphText(of: .caffeinate), "∞")
    }

    /// The agent surfaces (iOS toolbar, Peek & Reply header) speak the same dialect: each
    /// `ClaudeStatus` maps onto the shared reading set, and only "no agent" renders nothing.
    func testAgentStatusesShareTheGlyphVocabulary() {
        XCTAssertNil(StatusPresentation.agentReading(.none))
        XCTAssertEqual(StatusPresentation.agentReading(.idle), .resting)
        XCTAssertEqual(StatusPresentation.agentReading(.working), .working)
        XCTAssertEqual(StatusPresentation.agentReading(.done), .done)
        XCTAssertEqual(StatusPresentation.agentReading(.needsPermission), .awaiting)
    }

    /// The spinner cadence, pinned headlessly off the pure frame function: frames advance one per
    /// beat from the fixed epoch, wrap at the cycle's end, and a re-render at the same instant
    /// yields the same frame (phase is a function of the wall clock, not of mount count).
    func testSpinnerFrameCadenceAdvancesOnePerBeatAndWraps() {
        let frames = StatusGlyph.commandFrames
        let beat = StatusGlyph.commandBeat
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

    /// Every kind carries a non-empty, distinct AX/tooltip label so the animated/mono badge is
    /// legible and testable.
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
