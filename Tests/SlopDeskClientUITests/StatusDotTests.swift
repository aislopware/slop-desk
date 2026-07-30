// StatusDotTests — pins the trailing status MARK: since round 19 the shape is the grammar and the
// hue rides along, so each state's pin is a (shape, ink) PAIR. The agent's own states are ONE
// CIRCLE and the pins say so: a resting code agent keeps the static dashed RING (muted), a working
// one CLOSES that ring and turns it (accent SWEEP, keyed on the same raw-working status liveness
// uses, outranking every badge), an unread finish fills it as the green DOT; the two states you must
// act on stay in the SAME circle with a glyph inside — `?` for a question, `!` for a failure. A
// plain running command mounts nothing HERE (its wheel replaces the process label —
// ``RailRowsBuilder/showsCommandSpinner(badge:isAgent:processLabel:)``), and bare idle /
// privilege-only rows stay bare.
//
// ⚠️ Both ANIMATED marks are DRAWN GEOMETRY, never glyphs — pinned here as pure numbers (step
// counts, a drawn fraction, an opacity ramp) precisely because a TYPED spinner is at the mercy of
// whichever font the machine substitutes. The typed twin that survives
// (`StatusGlyph`, 16pt in a text row) keeps its own pin: every dingbat frame must carry `\u{FE0E}`
// or it renders as a colour emoji. Headless VALUE assertions — no render. Ink identity is asserted
// SELF-consistently against the presentation maps (never absolute colour values — `Color` equality
// is provider-fragile).

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    /// A WORKING AGENT's mark is the accent turning RING and outranks every badge underneath it — keyed
    /// on the raw working status, so the badge gate can never kill the mark. The `.running`
    /// badge route (gate ON) must read identically to the raw route.
    @MainActor
    func testWorkingAgentTurnsAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertEqual(raw?.shape, .sweep, "a thinking agent's mark is the turning ring")
        XCTAssertEqual(raw?.ink, Slate.State.accent, "working rides the in-motion accent")
        for badge: TabBadgeKind? in [.commandBusy, .error, .awaitingInput, .finished, .sudo] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: true, badge: badge), raw,
                "working outranks \(String(describing: badge)) — one accent ring, always",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .running), raw,
            "the badge-routed agent tier and the raw-working route are ONE reading",
        )
    }

    /// Each attention kind wears its OWN pictogram — one shape per state, so
    /// the mark reads before its hue does — on exactly its attention ink.
    @MainActor
    func testAttentionKindsWearTheirOwnShapeOnTheirAttentionInk() {
        let expected: [TabBadgeKind: StatusMarkShape] = [
            .awaitingInput: .question, .error: .alert, .completed: .dot, .finished: .dot,
        ]
        for (kind, shape) in expected {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.shape, shape, "\(kind) must wear its own pictogram")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s mark must wear its own attention ink",
            )
        }
    }

    /// Every state's shape is DISTINCT — no two share a pictogram, so hue is never load-bearing
    /// alone (the working ring and the resting ring differ in their DRAWING, not their case).
    @MainActor
    func testEveryStateWearsADistinctShape() {
        var shapes: [StatusMarkShape] = []
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed] {
            if let shape = StatusPresentation.statusDot(working: false, badge: kind)?.shape {
                shapes.append(shape)
            }
        }
        if let working = StatusPresentation.statusDot(working: true, badge: nil)?.shape {
            shapes.append(working)
        }
        if let resting = StatusPresentation.statusDot(
            working: false, badge: nil, agentIdle: true,
        )?.shape {
            shapes.append(resting)
        }
        XCTAssertEqual(
            Set(shapes).count, shapes.count,
            "each state owns one shape — `.completed`/`.finished` are the only pair that share",
        )
        XCTAssertEqual(shapes.count, 5, "working, resting, question, alert, dot all resolved")
    }

    /// A RESTING CODE AGENT keeps the STATIC dashed ring, muted — present, spending no hue,
    /// distinct from the working ring's closed sweep and from every attention pictogram — the SAME
    /// circle, spending its ink on eight small gaps instead of one travelling gap. It does NOT move.
    @MainActor
    func testRestingAgentRingsMutedAndStatic() {
        // The claude pane at its prompt keeps the shell busy for its whole lifetime, so it
        // arrives with either no badge or the `.commandBusy` tier — both read the same.
        for badge: TabBadgeKind? in [nil, .commandBusy] {
            let dot = StatusPresentation.statusDot(
                working: false, badge: badge, agentIdle: true,
            )
            XCTAssertEqual(dot?.shape, .ring, "a resting agent mounts the static dashed ring")
            XCTAssertEqual(dot?.ink, Slate.Text.secondary, "resting spends no hue")
            XCTAssertFalse(dot?.shape.animates ?? true, "the resting ring never moves")
        }
    }

    /// Exactly TWO marks animate — the working ring and (outside this column) the command wheel.
    /// Every other shape holds still, so a settled rail is motionless.
    @MainActor
    func testOnlyTheWorkingRingAnimatesInTheMarkColumn() {
        XCTAssertTrue(StatusMarkShape.sweep.animates, "the agent's turning ring is the moving mark")
        for shape: StatusMarkShape in [.ring, .question, .dot, .alert] {
            XCTAssertFalse(shape.animates, "\(shape) is a still mark")
        }
    }

    /// A plain running COMMAND — no code agent in the pane — mounts NOTHING in the mark column:
    /// its motion is the spinner that takes the process-label slot instead, so a busy `npm run
    /// dev` row never carries two activity marks.
    @MainActor
    func testPlainRunningCommandMountsNoMark() {
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            XCTAssertNil(
                StatusPresentation.statusDot(working: false, badge: kind),
                "\(kind) without an agent must leave the mark column bare",
            )
        }
    }

    /// An attention state OUTRANKS the resting-agent ring: a finished/blocked/failed agent keeps
    /// its attention ink AND its own pictogram even though the same pane is also a resting agent.
    @MainActor
    func testAttentionOutranksTheRestingAgentRing() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind, agentIdle: true)
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind) keeps its attention ink over the muted resting ring",
            )
            XCTAssertNotEqual(dot?.shape, .ring, "\(kind) keeps its pictogram, not the resting ring")
        }
    }

    /// Idle and privilege-only rows mount NOTHING — the resting rail is bare.
    @MainActor
    func testIdleAndPrivilegeOnlyRowsMountNoMark() {
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: nil))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .sudo))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .caffeinate))
    }

    /// The ring's dash pattern tiles the circumference EXACTLY — `ringDashCount` whole periods,
    /// so the dashes stay evenly spread with no seam where the stroke closes.
    func testRingDashTilesTheCircumferenceEvenly() {
        let dash = StatusDot.ringDash
        XCTAssertEqual(dash.count, 2, "one dash length, one gap length")
        let period = dash[0] + dash[1]
        let circumference = CGFloat.pi * StatusDot.ringDiameter
        XCTAssertEqual(
            Double(period * CGFloat(StatusDot.ringDashCount)), Double(circumference),
            accuracy: 1e-9, "whole periods around the ring — no seam",
        )
        XCTAssertGreaterThan(dash[0], dash[1], "drawn beats gap — the ring reads as a circle")
    }

    /// Every mark — moving or still, glyph or symbol — renders inside the SAME fixed footprint, so
    /// a state edge (or a spinner frame) can never move a pixel of the row's trailing edge.
    func testEveryMarkSharesOneFixedFootprint() {
        XCTAssertGreaterThanOrEqual(
            StatusDot.footprint, StatusDot.ringDiameter,
            "the ring fits its own column",
        )
        XCTAssertGreaterThanOrEqual(
            StatusDot.footprint, StatusDot.symbolSize,
            "the hand / triangle / dot fit the same column the ring does",
        )
    }

    // MARK: Command spinner (the process-label slot)

    /// The command spinner replaces the process label for a real PROGRAM running past the busy
    /// reveal — and for nothing else: an AGENT pane never spins (its `claude` process holds the
    /// shell busy for hours, and the mark column already speaks its state), a busy SHELL never
    /// spins (a login shell is not a command), an unreported process never spins, and a row with
    /// no busy badge at all (the sub-threshold `ls`) never spins.
    func testCommandSpinnerShowsOnlyForARealProgramRunningInANonAgentPane() {
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            XCTAssertTrue(
                RailRowsBuilder.showsCommandSpinner(
                    badge: kind, isAgent: false, processLabel: "swift",
                ),
                "\(kind) with a real program spins",
            )
            XCTAssertTrue(
                RailRowsBuilder.showsCommandSpinner(
                    badge: kind, isAgent: false, processLabel: "/usr/bin/make",
                ),
                "a full path is basenamed before the shell test",
            )
            XCTAssertFalse(
                RailRowsBuilder.showsCommandSpinner(
                    badge: kind, isAgent: true, processLabel: "claude",
                ),
                "an agent pane's busy shell must never spin — the mark column speaks for it",
            )
            for shell in ["zsh", "-zsh", "bash", "fish", "login"] {
                XCTAssertFalse(
                    RailRowsBuilder.showsCommandSpinner(
                        badge: kind, isAgent: false, processLabel: shell,
                    ),
                    "\(shell) is the shell, not a command",
                )
            }
            XCTAssertFalse(
                RailRowsBuilder.showsCommandSpinner(
                    badge: kind, isAgent: false, processLabel: nil,
                ),
                "no reported process ⇒ nothing to say it is running",
            )
        }
        // Sub-threshold + settled rows: the busy badge is the reveal gate, so no badge ⇒ no spinner.
        for badge: TabBadgeKind? in [nil, .finished, .error, .awaitingInput, .running, .sudo] {
            XCTAssertFalse(
                RailRowsBuilder.showsCommandSpinner(
                    badge: badge, isAgent: false, processLabel: "swift",
                ),
                "\(String(describing: badge)) is not a running-command tier",
            )
        }
    }

    // MARK: Cadence (both animated marks, both DRAWN)

    /// The shared cadence primitive: one frame per beat off a FIXED epoch, wrapping at the frame
    /// count — so every animating row in the rail steps in unison, and a re-render at the same
    /// instant lands on the same frame instead of restarting the cycle. Pure function of the date;
    /// degenerate inputs resolve to frame 0 rather than trapping.
    func testFrameSteppingAdvancesOnePerBeatAndWraps() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        for frames in [CommandSpinner.spokeCount, 10] {
            let beat = 0.1
            for step in 0..<(frames * 2) {
                let at = epoch.addingTimeInterval(Double(step) * beat + beat / 2)
                XCTAssertEqual(
                    StatusDot.frame(at: at, frames: frames, beat: beat), step % frames,
                    "beat \(step) of \(frames) lands on its own frame",
                )
            }
            let mid = epoch.addingTimeInterval(3 * beat + beat / 3)
            XCTAssertEqual(
                StatusDot.frame(at: mid, frames: frames, beat: beat),
                StatusDot.frame(at: mid, frames: frames, beat: beat),
                "same instant ⇒ same frame — a re-mount can't skip",
            )
            XCTAssertEqual(StatusDot.frame(at: epoch, frames: frames, beat: 0), 0, "beat 0 ⇒ frame 0")
        }
        XCTAssertEqual(StatusDot.frame(at: epoch, frames: 0, beat: 0.1), 0, "no frames ⇒ frame 0")
    }

    /// ⚠️ BOTH animated marks are DRAWN, never typed — the load-bearing lesson of this round. The
    /// instrument face is only JetBrains Mono when that font is installed (it is NOT, on every
    /// machine), so a typed spinner gets SUBSTITUTED: braille lands in AppleBraille (embossing dots,
    /// weight ignored, invisible at 11pt) and a bare dingbat star lands in AppleColorEmojiUI (a
    /// colour emoji that ignores the ink and is 2.4× the advance). Vector geometry has no such
    /// failure mode, so these two marks are pinned as PURE NUMBERS: a frame count and a beat, no
    /// glyph table anywhere.
    func testBothAnimatedMarksAreDrawnGeometryNotGlyphs() {
        XCTAssertEqual(CommandSpinner.spokeCount, 8, "the AppKit wheel's own spoke count")
        XCTAssertGreaterThan(CommandSpinner.beat, 0)
        XCTAssertGreaterThan(AgentSweepMark.revolution, 0)
        XCTAssertGreaterThan(AgentSweepMark.breath, 0)
    }

    /// ⚠️ The agent's ring turns CONTINUOUSLY — its angle is a smooth function of the clock, NOT a
    /// frame index. The first cut hopped through 12 discrete steps and read as plastic: a hop is the
    /// mechanism showing through. So the rotation is pinned as a monotonic ramp over a revolution
    /// that wraps exactly once, with no plateaus — a plateau IS a hop.
    func testAgentRingTurnsContinuouslyAndWrapsOncePerRevolution() {
        let revolution = AgentSweepMark.revolution
        XCTAssertEqual(AgentSweepMark.turns(at: 0), 0, accuracy: 1e-12, "the epoch is 0 turns")
        XCTAssertEqual(
            AgentSweepMark.turns(at: revolution / 4), 0.25, accuracy: 1e-12,
            "a quarter of the period is a quarter turn — linear, no easing",
        )
        XCTAssertEqual(
            AgentSweepMark.turns(at: revolution), 0, accuracy: 1e-12, "one period wraps to 0",
        )
        // Sampling far finer than any frame interval must still advance EVERY time.
        var previous = AgentSweepMark.turns(at: 0)
        for sample in 1...200 {
            let value = AgentSweepMark.turns(at: Double(sample) * revolution / 400)
            XCTAssertGreaterThan(value, previous, "sample \(sample) must advance — a plateau is a hop")
            previous = value
        }
        // Negative clocks (a date before the reference epoch) stay in [0, 1) rather than mirroring.
        let behind = AgentSweepMark.turns(at: -revolution / 4)
        XCTAssertTrue((0..<1).contains(behind), "a pre-epoch instant is still a real angle")
    }

    /// The arc's LENGTH breathes on its own slow sine, and the two cycles are deliberately
    /// incommensurate — so the figure never repeats a silhouette and the motion never reads as a loop.
    /// The length stays inside its range at every instant (a closed ring shows nothing; a stub reads
    /// as a dot).
    func testAgentArcBreathesInsideItsRangeOnAnIncommensurateCycle() {
        let range = AgentSweepMark.arcRange
        XCTAssertLessThan(range.upperBound, 1, "never closes — a closed ring has nothing to see")
        XCTAssertGreaterThan(range.lowerBound, 0.2, "never a stub — that reads as a dot, not an arc")
        for sample in 0...400 {
            let time = Double(sample) * AgentSweepMark.breath / 100
            let length = AgentSweepMark.length(at: time)
            XCTAssertTrue(range.contains(length), "sample \(sample) escaped the arc range")
        }
        // Both extremes are actually reached over a breath — the swing is real, not a rounding wobble.
        let samples = (0...200).map { AgentSweepMark.length(at: Double($0) * AgentSweepMark.breath / 200) }
        XCTAssertEqual(samples.min() ?? 0, range.lowerBound, accuracy: 1e-3, "the breath bottoms out")
        XCTAssertEqual(samples.max() ?? 0, range.upperBound, accuracy: 1e-3, "…and tops out")
        let ratio = AgentSweepMark.breath / AgentSweepMark.revolution
        XCTAssertGreaterThan(
            abs(ratio - ratio.rounded()), 0.05,
            "breath must NOT be a multiple of the revolution, or the motion loops visibly",
        )
        XCTAssertTrue(
            AgentSweepMark.arcRange.contains(AgentSweepMark.stillArc),
            "the Reduce-Motion arc is one the moving figure actually passes through",
        )
    }

    /// The working ring is the RESTING ring's own circle: same diameter, same stroke weight, an arc
    /// travelling instead of eight static dashes. That shared geometry is what makes the agent's
    /// states read as a progression instead of a legend, so both numbers are pinned — a drift in
    /// either splits the family in two.
    func testWorkingRingSharesTheRestingRingsGeometry() {
        XCTAssertEqual(StatusDot.ringDiameter, 8, "one diameter for the whole circle family")
        XCTAssertEqual(StatusDot.ringLineWidth, 1.5, "one stroke weight for the whole circle family")
    }

    /// ⚠️ EVERY mark in the column is that same circle — including the two states that need a human.
    /// otty's raised HAND and warning TRIANGLE shipped first and were pulled: a distinct silhouette
    /// per state is a legend to learn, where one circle whose INSIDE changes is a progression. This
    /// pins the circle variants, so a triangle cannot creep back in.
    func testTheTwoHumanStatesStayInsideTheCircleFamily() {
        XCTAssertEqual(StatusMarkShape.question.symbol, .questionmarkCircle, "a question, in the circle")
        XCTAssertEqual(StatusMarkShape.alert.symbol, .exclamationmarkCircle, "a failure, in the circle")
        for shape: StatusMarkShape in [.ring, .sweep, .dot] {
            XCTAssertNil(shape.symbol, "\(shape) is DRAWN — no symbol may stand in for it")
        }
        for shape in StatusMarkShape.allCases {
            guard let name = shape.symbol?.rawValue else { continue }
            XCTAssertTrue(
                name.contains("circle"),
                "\(name) must be a circle variant — the column has exactly one silhouette",
            )
        }
    }

    /// A spoke's opacity ramps DOWN with its distance behind the leading spoke — the AppKit wheel's
    /// comet tail, so an otherwise symmetric wheel reads as having a direction. Never reaches zero:
    /// the wheel stays a wheel rather than becoming a broken arc.
    func testCommandWheelOpacityRampTrailsTheLeadingSpoke() {
        let lead = CommandSpinner.opacity(spoke: 3, step: 3)
        XCTAssertEqual(lead, 1, "the leading spoke is fully inked")
        var previous = lead
        for behind in 1..<CommandSpinner.spokeCount {
            let value = CommandSpinner.opacity(
                spoke: (3 - behind + CommandSpinner.spokeCount) % CommandSpinner.spokeCount,
                step: 3,
            )
            XCTAssertLessThan(value, previous, "spoke \(behind) behind the lead fades further")
            previous = value
        }
        XCTAssertGreaterThan(previous, 0, "even the tail spoke is visible — the ring never breaks")
    }

    /// REDUCE MOTION freezes both animated marks on a REPRESENTATIVE frame rather than hiding them:
    /// the state must still be readable when the system asks for stillness.
    func testReduceMotionFreezesBothAnimatedMarksOnALegibleFrame() {
        XCTAssertTrue(
            AgentSweepMark.arcRange.contains(AgentSweepMark.stillArc),
            "a frozen working ring holds a real arc — it still reads as 'not at rest'",
        )
        XCTAssertEqual(
            CommandSpinner.stillStep, 0,
            "a frozen wheel is the evenly-lit one, its comet tail at the top",
        )
    }

    // MARK: The typed twin (StatusGlyph — iOS toolbar / Peek & Reply header)

    /// ⚠️ `StatusGlyph` still TYPES the asterisk bloom (it is a 16pt glyph in a text row, not a 12pt mark),
    /// so every DINGBAT frame there must pin TEXT presentation with `\u{FE0E}`. Bare U+2733 `✳`
    /// resolves to `AppleColorEmojiUI`: a colour emoji that ignores `tint` and measures 16pt of advance
    /// where its Menlo siblings measure 6.62 — one frame in ten flashed a coloured star at the wrong
    /// width. `·` (U+00B7) is outside the block and is the mono face's own glyph. The rail's mark is
    /// immune by construction: it is drawn, and shares no frame table with this surface at all.
    func testEveryDingbatGlyphFramePinsTextPresentation() {
        let selector: Unicode.Scalar = "\u{FE0E}"
        for frame in StatusGlyph.agentFrames {
            guard let first = frame.unicodeScalars.first else {
                XCTFail("an empty frame renders nothing")
                return
            }
            guard (0x2700...0x27BF).contains(first.value) else { continue }
            XCTAssertEqual(
                frame.unicodeScalars.last, selector,
                "\(frame) must carry VARIATION SELECTOR-15 or it renders as a colour emoji",
            )
            XCTAssertEqual(
                frame.unicodeScalars.count, 2,
                "\(frame) is one star plus the selector — nothing else belongs in a frame",
            )
        }
        XCTAssertGreaterThan(StatusGlyph.agentBeat, 0, "the typed twin keeps its own breath")
    }
}
