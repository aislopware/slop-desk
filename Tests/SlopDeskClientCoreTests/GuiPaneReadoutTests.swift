// GuiPaneReadoutTests — what a video pane SAYS, and the gates that decide whether it says it.
//
// None of this had a test while it lived in `GuiLeafView`: reaching a formatter there meant
// instantiating a SwiftUI view over a Metal-hosting seam, which is the hang-unsafe thing CLAUDE.md
// rule #6 forbids a test from doing. So the five telemetry rows, the stall caption, the fps/bitrate
// choice tables and five predicates shipped unpinned for as long as they existed.
//
// THE RULES ARE RUST NOW (`slopdesk_workspace::gui_readout`), AND THIS SUITE DID NOT MOVE WITH THEM.
// Every assertion below was written against the deleted Swift and passes unchanged against the
// doors, which is the evidence the port is behaviour-identical — the same standard
// `WorkspaceIntentApplierTests` sets one boundary over (docs/55 §4b). It is not a mirror of the
// crate's own tests: what it pins is the CROSSING — that ten `Optional`s reach the far side as ten
// presence flags in the right order, and that the strings come back byte for byte.
//
// The claim these suites keep is one sentence: ABSENT, NEVER WRONG. A stat with no sample prints `—`
// and not `0`; a stall with no epoch prints `RECONNECTING` and not `· 0S`. A zero that means "no
// reading" is the one lie an instrument readout must not tell — and it is the easy regression, since
// every one of these values is an `Optional` whose `?? 0` compiles fine.
//
// TWO GATES LOST AN INPUT, AND WITH IT THE ASSERTIONS THAT WERE ITS ONLY CALLER. `showsControlBar`
// and `isDesktopUploadTarget` each began `!staticMirror && …`, a flag for a headless `ImageRenderer`
// snapshot path that reached them threaded down through the pane canvas. Nothing in `Sources/`,
// `Apps/` or `ThirdParty/` ever passed `true` — the `true` cases below were, with one in
// `GuiLeafReadOnlyPillTests`, the only ones in the tree. So the assertions were DELETED with the
// parameter (increment 56d) rather than rewritten to keep passing: a case that is a branch's sole
// producer does not cover the branch, it preserves it. `slopdesk-invariants` fails the build if the
// flag comes back.

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class GuiPaneReadoutFormatterTests: XCTestCase {
    /// A fully-measured stream prints all five rows with their units.
    func testTheFiveRowsReadTheirMeasurements() {
        let rows = GuiPaneReadout.statRows(GuiStreamTelemetry(
            streamFps: 60, streamKbps: 12500,
            statsFps: 59.6, statsPacerDepth: 3,
            statsFecPerSec: 1.24, statsUnrecoveredPerSec: 0,
            statsRttMs: 8.04, statsEncodeMs: 2.5, statsDecodeMs: 1.1,
            statsHoldMs: 16,
        ))

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0], "60 FPS · 12.5 MBPS")
        XCTAssertEqual(rows[1], "RX 60 FPS · DEPTH 3", "the received rate rounds to whole frames")
        XCTAssertEqual(rows[2], "FEC 1.2/S · LOST 0.0/S")
        XCTAssertEqual(rows[3], "RTT 8.0 · ENC 2.5 · DEC 1.1")
        XCTAssertEqual(rows[4], "HOLD 16 MS")
    }

    /// THE LAW: a pane whose stream has produced no sample yet says so, in every slot. A `0` here
    /// would read as a measured zero — a stalled encoder, a lossless link — which is a different and
    /// much better-sounding fact than "no reading".
    func testAnUnmeasuredStreamPrintsTheEmDashEverywhere() {
        // The default init IS the unmeasured sample — every field `nil` — which is what a pane looks
        // like for the first beat of every stream.
        let rows = GuiPaneReadout.statRows(GuiStreamTelemetry())

        XCTAssertEqual(rows[0], "— FPS · — MBPS")
        XCTAssertEqual(rows[1], "RX — FPS · DEPTH —")
        XCTAssertEqual(rows[2], "FEC —/S · LOST —/S", "an absent RATE still reads as a rate")
        XCTAssertEqual(rows[3], "RTT — · ENC — · DEC —")
        XCTAssertEqual(rows[4], "HOLD — MS")
    }

    /// EACH SLOT ON ITS OWN, because the sample crosses as ten values with ten flags beside them and
    /// the failure a whole-sample test cannot see is a flag wired to its NEIGHBOUR. All-present and
    /// all-absent both pass with any two same-typed pairs transposed; a sample with exactly one
    /// reading in it does not.
    func testEachReadingCrossesIntoItsOwnSlotAndNoOther() {
        let cases: [(GuiStreamTelemetry, String)] = [
            (GuiStreamTelemetry(streamFps: 9), "9 FPS"),
            (GuiStreamTelemetry(streamKbps: 9000), "9.0 MBPS"),
            (GuiStreamTelemetry(statsFps: 9), "RX 9 FPS"),
            (GuiStreamTelemetry(statsPacerDepth: 9), "DEPTH 9"),
            (GuiStreamTelemetry(statsFecPerSec: 9), "FEC 9.0/S"),
            (GuiStreamTelemetry(statsUnrecoveredPerSec: 9), "LOST 9.0/S"),
            (GuiStreamTelemetry(statsRttMs: 9), "RTT 9.0"),
            (GuiStreamTelemetry(statsEncodeMs: 9), "ENC 9.0"),
            (GuiStreamTelemetry(statsDecodeMs: 9), "DEC 9.0"),
            (GuiStreamTelemetry(statsHoldMs: 9), "HOLD 9 MS"),
        ]

        for (sample, expected) in cases {
            let joined = GuiPaneReadout.statRows(sample).joined(separator: "\n")
            XCTAssertTrue(joined.contains(expected), "\(expected) is missing from\n\(joined)")
            XCTAssertEqual(
                joined.filter { $0 == "9" }.count, expected.filter { $0 == "9" }.count,
                "exactly one slot may carry a reading:\n\(joined)",
            )
        }
    }

    /// kbps on the wire, Mbps at the surface — the one conversion the readout does.
    func testTheBitrateRowConvertsToMbps() {
        XCTAssertEqual(GuiPaneReadout.mbpsLabel(kbps: 0), "0.0")
        XCTAssertEqual(GuiPaneReadout.mbpsLabel(kbps: 999), "1.0")
        XCTAssertEqual(GuiPaneReadout.mbpsLabel(kbps: 20000), "20.0")
        XCTAssertEqual(GuiPaneReadout.mbpsLabel(kbps: nil), "—")
    }

    /// The stall caption carries only what the DRAINED last frame cannot: that recovery is running,
    /// and how old the frozen frame is. With no epoch it says the first half and stops.
    func testTheStallCaptionTicksAndFloorsAtZero() {
        let now = Date(timeIntervalSince1970: 1000)

        XCTAssertEqual(GuiPaneReadout.stallCaption(since: nil, now: now), "RECONNECTING")
        XCTAssertEqual(
            GuiPaneReadout.stallCaption(since: now.addingTimeInterval(-12.7), now: now),
            "RECONNECTING · 12S",
            "the age truncates — a stall is 12 seconds old until it is 13",
        )
        XCTAssertEqual(
            GuiPaneReadout.stallCaption(since: now.addingTimeInterval(5), now: now),
            "RECONNECTING · 0S",
            "a clock skew must never print a negative age",
        )
    }

    /// The cap-gated placeholder names its OWN cause: two live streams is a deliberate ceiling, and
    /// "paused" without the reason would read as a failure.
    func testThePlaceholderNamesTheCapWhenItIsTheCap() {
        XCTAssertEqual(GuiPaneReadout.placeholderLabel(.gated), "Video paused — too many live streams")
        XCTAssertEqual(GuiPaneReadout.placeholderLabel(.entryForm), "desktop")
        XCTAssertEqual(GuiPaneReadout.placeholderLabel(.live), "desktop")
    }
}

final class GuiPaneReadoutQualityTests: XCTestCase {
    /// `0` IS NOT A QUANTITY on either axis — it is the absence of a cap, and both labels have to say
    /// so or the picker reads as "cap the stream at zero frames".
    func testZeroReadsAsAutoOnBothAxes() {
        XCTAssertEqual(GuiPaneReadout.fpsChoices.first, 0)
        XCTAssertEqual(GuiPaneReadout.mbpsChoices.first, 0)
        XCTAssertEqual(GuiPaneReadout.fpsChoiceLabel(0), "Auto")
        XCTAssertEqual(GuiPaneReadout.mbpsChoiceLabel(0), "Auto")
        XCTAssertEqual(GuiPaneReadout.fpsChoiceLabel(30), "30")
        XCTAssertEqual(GuiPaneReadout.mbpsChoiceLabel(20), "20 Mb")
    }

    /// Mbps at the surface, bps on the model and the wire. The picker offers whole Mbps only, so the
    /// round trip through it is lossless for every value it can actually show — and `0` (Auto) stays
    /// `0` on both sides, which is the case a `max(1, …)` would quietly break.
    func testTheMbpsRoundTripHoldsForEveryOfferedChoice() {
        for mbps in GuiPaneReadout.mbpsChoices {
            XCTAssertEqual(GuiPaneReadout.mbps(fromBps: GuiPaneReadout.bps(fromMbps: mbps)), mbps)
        }
        XCTAssertEqual(GuiPaneReadout.bps(fromMbps: 0), 0, "Auto is Auto on both sides")
        XCTAssertEqual(GuiPaneReadout.mbps(fromBps: 12_500_000), 12, "a value the picker cannot show truncates")
    }
}

final class GuiPaneReadoutGateTests: XCTestCase {
    /// The control bar's verbs (resize / lock / zoom) are meaningful only against a live stream, so
    /// the picker and cap-gated states show no footer.
    func testTheControlBarNeedsALiveStream() {
        XCTAssertTrue(GuiPaneReadout.showsControlBar(hasLiveDescriptor: true))
        XCTAssertFalse(GuiPaneReadout.showsControlBar(hasLiveDescriptor: false))
    }

    /// The gesture is "drop onto the remote DESKTOP": no other pane kind is a target, and lighting a
    /// border that is not one would promise an upload that cannot happen.
    func testOnlyALiveDesktopPaneAcceptsAFileDrop() {
        XCTAssertTrue(GuiPaneReadout.isDesktopUploadTarget(kind: .desktop, hasLiveDescriptor: true))
        XCTAssertFalse(
            GuiPaneReadout.isDesktopUploadTarget(kind: .terminal, hasLiveDescriptor: true),
            "a terminal pane has no remote desktop to drop onto",
        )
        XCTAssertFalse(
            GuiPaneReadout.isDesktopUploadTarget(kind: nil, hasLiveDescriptor: true),
            "a pane with no spec resolved yet is not a target",
        )
        XCTAssertFalse(GuiPaneReadout.isDesktopUploadTarget(kind: .desktop, hasLiveDescriptor: false))
    }

    /// EVERY latched mode has to reach the collapsed chip's tint, or folding the bar away hides a
    /// status light. Each is asserted on its own so a dropped clause fails here rather than in a
    /// user's "why is immersive still on" report.
    func testEachLatchedModeOnItsOwnLightsTheChip() {
        func latched(
            immersive: Bool = false, lock: Bool = false, audio: Bool = false,
            fps: Int = 0, bitrate: Int = 0,
        ) -> Bool {
            GuiPaneReadout.hasLatchedMode(
                immersive: immersive, viewportLocked: lock, audioEnabled: audio,
                streamFpsCap: fps, streamBitrateCeilingBps: bitrate,
            )
        }

        XCTAssertFalse(latched(), "a resting pane has no status light")
        XCTAssertTrue(latched(immersive: true))
        XCTAssertTrue(latched(lock: true))
        XCTAssertTrue(latched(audio: true))
        XCTAssertTrue(latched(fps: 30))
        XCTAssertTrue(latched(bitrate: 10_000_000))
    }

    /// The activation `.task` identity has to MOVE on all three edges — a mount, a sibling freeing a
    /// cap slot, and a visibility flip. Under keep-all-mounted a returning pane is never remounted,
    /// so a key that ignores visibility leaves it waiting for a remount that never comes.
    func testTheActivationKeyMovesOnEveryEdgeThatShouldReRequestASlot() {
        let base = GuiPaneReadout.activationKey(paneHash: 7, promotionGeneration: 1, isVisible: true)

        XCTAssertNotEqual(base, GuiPaneReadout.activationKey(paneHash: 8, promotionGeneration: 1, isVisible: true))
        XCTAssertNotEqual(base, GuiPaneReadout.activationKey(paneHash: 7, promotionGeneration: 2, isVisible: true))
        XCTAssertNotEqual(
            base, GuiPaneReadout.activationKey(paneHash: 7, promotionGeneration: 1, isVisible: false),
            "a pane returning to screen must re-request its slot immediately",
        )
        XCTAssertEqual(
            base, GuiPaneReadout.activationKey(paneHash: 7, promotionGeneration: 1, isVisible: true),
            "…and it settles, or admission re-runs on every body pass",
        )
    }

    /// The upload row's GLYPH says which way a settled upload settled; the TONE only says that it
    /// did. Two colours for done-vs-failed would be the same fact twice, and the tint is a semantic
    /// here precisely so the token lookup stays in whichever framework is drawing.
    func testTheUploadGlyphCarriesTheOutcomeAndTheToneOnlyCarriesSettlement() {
        XCTAssertEqual(GuiPaneReadout.uploadGlyph(.sending), "arrow.up.circle")
        XCTAssertEqual(GuiPaneReadout.uploadGlyph(.completed), "checkmark.circle.fill")
        XCTAssertEqual(GuiPaneReadout.uploadGlyph(.failed), "exclamationmark.triangle.fill")

        XCTAssertEqual(GuiPaneReadout.uploadTint(.sending), .icon)
        XCTAssertEqual(GuiPaneReadout.uploadTint(.completed), .accent)
        XCTAssertEqual(GuiPaneReadout.uploadTint(.failed), .accent)
    }
}
