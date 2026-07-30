// StatusDotTests — pins the trailing status MARK: since round 19 the shape is the grammar and the
// hue rides along, so each state's pin is a (shape, ink) PAIR. The agent's own states are ONE
// CIRCLE and the pins say so: a resting code agent keeps the static finely dashed RING (muted), a
// working one GATHERS those dashes into five longer arcs and turns them (accent SWEEP, keyed on the
// same raw-working status liveness uses, outranking every badge), an unread finish fills the circle in
// as the green DOT; and the two states you must act on CLOSE the ring and hold still — amber for a
// question, red for a failure (⚠️ those two draw ALIKE and are separated by HUE alone, by user
// ruling: the `?`/`!` glyphs inside the ring came out for reading as fussy detail at 8pt). A
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

    /// Each attention kind resolves to its OWN shape case on exactly its attention ink. `.question`
    /// and `.alert` are distinct CASES that happen to draw the same closed ring (hue separates them);
    /// the finish is the filled dot.
    @MainActor
    func testAttentionKindsWearTheirOwnShapeOnTheirAttentionInk() {
        let expected: [TabBadgeKind: StatusMarkShape] = [
            .awaitingInput: .question, .error: .alert, .completed: .dot, .finished: .dot,
        ]
        for (kind, shape) in expected {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
            XCTAssertEqual(dot?.shape, shape, "\(kind) must resolve to its own shape")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s mark must wear its own attention ink",
            )
        }
    }

    /// Every state resolves to a DISTINCT shape case — the resolver never collapses two states onto
    /// one reading (the working ring and the resting ring differ in their DRAWING, not their case).
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

    /// A RESTING CODE AGENT keeps the STATIC dashed ring, muted — present, spending no hue, distinct
    /// from the working ring's five turning arcs and from the closed attention ring — the SAME circle,
    /// cut into eight fine dashes instead of five long ones. It does NOT move.
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
    /// its attention ink AND its own mark even though the same pane is also a resting agent.
    @MainActor
    func testAttentionOutranksTheRestingAgentRing() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind, agentIdle: true)
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind) keeps its attention ink over the muted resting ring",
            )
            XCTAssertNotEqual(dot?.shape, .ring, "\(kind) keeps its own mark, not the resting ring")
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

    /// Every mark — moving or still — renders inside the SAME fixed footprint, so a state edge (or an
    /// animation frame) can never move a pixel of the row's trailing edge. The command WHEEL shares
    /// that column too, since a row swaps between spinning and marked.
    func testEveryMarkSharesOneFixedFootprint() {
        XCTAssertGreaterThanOrEqual(
            StatusDot.footprint, StatusDot.ringDiameter,
            "the ring fits its own column",
        )
        XCTAssertEqual(
            CommandSpinner.diameter, StatusDot.footprint,
            "the command wheel fits the same column the marks do",
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
        XCTAssertGreaterThan(AgentSweepMark.knit, 0)
    }

    /// ⚠️ The agent's ring turns CONTINUOUSLY and NOT LINEARLY — the two complaints that killed the
    /// earlier cuts. Discrete hops read as plastic (a hop is the mechanism showing through) and so does
    /// a constant rate, so the angle leads and lags an even sweep once per DASH. Pinned: strictly
    /// increasing when sampled far finer than any frame (a plateau IS a hop), wrapping exactly once per
    /// revolution, and measurably OFF a straight line.
    func testAgentRingTurnsContinuouslyEasedAndWrapsOncePerRevolution() {
        let revolution = AgentSweepMark.revolution
        let dashes = Double(AgentSweepMark.dashCount)
        XCTAssertEqual(AgentSweepMark.turns(at: 0), 0, accuracy: 1e-12, "the epoch is 0 turns")
        XCTAssertEqual(
            AgentSweepMark.turns(at: revolution), 0, accuracy: 1e-12, "one period wraps to 0",
        )
        // NOT linear — sampled a QUARTER of a dash period in, where the ease is at full lead. ⚠️ The
        // ease crosses zero at every HALF dash period (`sin(2πN·t)`), so sampling on one of those
        // points would sit exactly on the straight line and prove the opposite of what it looks like
        // it proves. The sample must be an odd quarter.
        let fullLead = revolution / (4 * dashes)
        XCTAssertEqual(
            AgentSweepMark.turns(at: fullLead), 1 / (4 * dashes) + AgentSweepMark.swing,
            accuracy: 1e-9,
            "a quarter dash period in, the ring must LEAD an even sweep by the full swing",
        )
        XCTAssertGreaterThan(
            abs(AgentSweepMark.turns(at: fullLead) - 1 / (4 * dashes)), 0.01,
            "a constant rate is the plastic tell — the ring must lead here",
        )
        // Sampling 400× finer than a 60fps frame must still advance EVERY time: monotonic, no stall,
        // never backwards. This is what `swingCeiling` protects.
        var previous = AgentSweepMark.turns(at: 0)
        var minStep = Double.infinity
        var maxStep = 0.0
        let samples = 4000
        for sample in 1..<samples {
            let value = AgentSweepMark.turns(at: Double(sample) * revolution / Double(samples))
            let step = value - previous
            XCTAssertGreaterThan(step, 0, "sample \(sample) must advance — a plateau is a hop")
            minStep = Double.minimum(minStep, step)
            maxStep = Double.maximum(maxStep, step)
            previous = value
        }
        // …and the rate must genuinely VARY, or "eased" is a comment rather than a behaviour.
        XCTAssertGreaterThan(maxStep / minStep, 2, "the sweep must visibly speed up and coast")
        // Negative clocks (a date before the reference epoch) stay in [0, 1) rather than mirroring.
        XCTAssertTrue(
            (0..<1).contains(AgentSweepMark.turns(at: -revolution / 4)),
            "a pre-epoch instant is still a real angle",
        )
    }

    /// ⚠️ The ease amplitude is bounded by ARITHMETIC, not taste: the angle is `t + swing·sin(2πN·t)`,
    /// whose derivative is `1 + 2πN·swing·cos(2πN·t)` — so at or above `1/2πN` the ring STALLS and then
    /// runs BACKWARDS once a cycle, which reads as broken rather than eased. The ceiling therefore
    /// TIGHTENS as the dash count rises; pinned against ``AgentSweepMark/dashCount`` so a later
    /// "make it bouncier" (or a change of cut) cannot cross the line unnoticed.
    func testEaseAmplitudeStaysUnderTheStallCeiling() {
        XCTAssertEqual(
            AgentSweepMark.swingCeiling,
            1 / (2 * .pi * Double(AgentSweepMark.dashCount)), accuracy: 1e-12,
        )
        XCTAssertLessThan(
            AgentSweepMark.swing, AgentSweepMark.swingCeiling,
            "above the ceiling the sweep reverses — broken, not eased",
        )
        XCTAssertGreaterThan(AgentSweepMark.swing, 0, "zero swing is the linear look that was rejected")
    }

    /// The arcs SPLIT down the middle and KNIT back on their own cycle, incommensurate with the
    /// rotation — so the figure never repeats a silhouette and the motion never reads as a loop. The
    /// parting stays in `[0, splitMax]`, reaches BOTH ends over a cycle, and is EASED at both ends: the
    /// ring must DWELL as five long arcs and again as ten short ones, because a plain sine spends its
    /// time mid-parting and reads as a wobble instead of two states trading.
    func testAgentArcsSplitAndKnitBackWithADwellAtEachEnd() {
        let cycle = AgentSweepMark.knit
        for sample in 0...400 {
            let split = AgentSweepMark.split(at: Double(sample) * cycle / 100)
            XCTAssertTrue(
                (0...AgentSweepMark.splitMax).contains(split), "sample \(sample) escaped the parting",
            )
        }
        XCTAssertEqual(AgentSweepMark.split(at: 0), 0, accuracy: 1e-12, "the epoch is fully knit")
        XCTAssertEqual(
            AgentSweepMark.split(at: cycle / 2), AgentSweepMark.splitMax, accuracy: 1e-12,
            "half a cycle in, the arcs are fully parted",
        )
        XCTAssertEqual(
            AgentSweepMark.split(at: cycle), 0, accuracy: 1e-12, "one cycle knits back",
        )
        // The DWELL: a tenth of a cycle either side of an extreme must still be within a tenth of that
        // extreme. A raw sine moves ~19% of its span in that time — this is the eased-ends pin.
        let tenth = AgentSweepMark.splitMax / 10
        XCTAssertLessThan(AgentSweepMark.split(at: cycle / 10), tenth, "it dwells knit")
        XCTAssertGreaterThan(
            AgentSweepMark.split(at: cycle / 2 + cycle / 10), AgentSweepMark.splitMax - tenth,
            "…and dwells parted",
        )
        // …and it crosses between them FASTER than an even sine would: peak rate beats π/2 × mean.
        let steps = (1...200).map {
            abs(AgentSweepMark.split(at: Double($0) * cycle / 200)
                - AgentSweepMark.split(at: Double($0 - 1) * cycle / 200))
        }
        let peak = steps.max() ?? 0
        let mean = steps.reduce(0, +) / CGFloat(steps.count)
        XCTAssertGreaterThan(
            Double(peak / mean), .pi / 2,
            "the crossing must be steeper than a raw cosine's, or the dwell is imaginary",
        )
        let ratio = AgentSweepMark.knit / AgentSweepMark.revolution
        XCTAssertGreaterThan(
            abs(ratio - ratio.rounded()), 0.05,
            "the knit cycle must NOT be a multiple of the revolution, or the motion loops visibly",
        )
    }

    /// ⚠️ The parting is bounded at BOTH ends by legibility. Too far and each half is a speck at 8pt —
    /// and worse, ten evenly-spaced short dashes IS the resting ring's cut, which the working mark may
    /// not borrow. Fully KNIT the middle gap must be exactly ZERO, because that is what makes the merge
    /// one continuous parameter instead of a swap between two dash patterns (a swap would pop).
    func testPartingStaysLegibleAndClosesToExactlyZero() {
        let knit = AgentSweepMark.dash(split: 0)
        XCTAssertEqual(knit.count, 4, "[half, parting, half, gap] at every frame")
        XCTAssertEqual(knit[1], 0, "fully knit ⇒ a zero-length parting ⇒ the halves abut as one arc")
        XCTAssertEqual(knit[0], knit[2], "the halves are halves")
        let parted = AgentSweepMark.dash(split: AgentSweepMark.splitMax)
        XCTAssertGreaterThan(
            parted[0], AgentSweepMark.splitFloorPoints,
            "a fully parted half must still read as an arc, not a speck",
        )
        XCTAssertLessThan(
            parted[1], parted[3],
            "the parting must stay TIGHTER than the gap between arcs, or the paired halves read as "
                + "ten evenly-spaced dashes — the resting ring's own cut",
        )
        // Out-of-range input is clamped rather than inverting the pattern (a negative half would).
        XCTAssertEqual(AgentSweepMark.dash(split: -1), knit, "below zero clamps to knit")
        XCTAssertEqual(
            AgentSweepMark.dash(split: 9), parted, "above the ceiling clamps to fully parted",
        )
    }

    /// The working ring is the RESTING ring's own circle: same diameter, same stroke weight, its dashes
    /// gathered into FEWER, longer arcs and turning. That shared geometry is what makes the agent's
    /// states read as a progression instead of a legend, so both numbers are pinned — a drift in
    /// either splits the family in two. The working ring's dashes tile the circumference exactly at
    /// EVERY parting frame (whole periods, no seam where the stroke closes).
    func testWorkingRingSharesTheRestingRingsGeometry() {
        XCTAssertEqual(StatusDot.ringDiameter, 8, "one diameter for the whole circle family")
        XCTAssertEqual(StatusDot.ringLineWidth, 1.5, "one stroke weight for the whole circle family")
        let circumference = CGFloat.pi * StatusDot.ringDiameter
        for split in [CGFloat(0), AgentSweepMark.splitMax / 2, AgentSweepMark.splitMax] {
            let dash = AgentSweepMark.dash(split: split)
            XCTAssertEqual(dash.count, 4, "[half, parting, half, gap] at every frame")
            XCTAssertEqual(
                Double(dash.reduce(0, +) * CGFloat(AgentSweepMark.dashCount)),
                Double(circumference), accuracy: 1e-9,
                "whole periods at parting \(split) — a split may not open a seam",
            )
            // A parting spends ink, and there is a floor: below ~40% of the circumference inked the
            // mark reads as scattered specks rather than a circle (measured on the render sheet — at
            // 0.45 parting the pairing is gone entirely).
            XCTAssertGreaterThan(
                Double((dash[0] + dash[2]) / (dash.reduce(0, +))), 0.4,
                "at parting \(split) too little of the ring is inked to read as a circle",
            )
        }
        // Knit, the two halves ARE the arc: their sum is the declared fill of one period.
        let period = CGFloat.pi * StatusDot.ringDiameter / CGFloat(AgentSweepMark.dashCount)
        let knit = AgentSweepMark.dash(split: 0)
        XCTAssertEqual(
            Double((knit[0] + knit[2]) / period), Double(AgentSweepMark.dashFill), accuracy: 1e-9,
            "the fill is what it says it is",
        )
    }

    /// ⚠️ The working ring is legible when FROZEN, not only when moving: its cut differs from the
    /// resting ring's, so Reduce Motion — and a colour-blind eye, which sees neither the accent nor the
    /// muted grey as itself — still reads two distinct marks. This is the pin that makes the dashed
    /// working ring safe: identical dashes turning would have collapsed to "same mark, different hue"
    /// the moment the system asked for stillness.
    func testFrozenWorkingRingStillDiffersFromTheRestingRing() {
        XCTAssertLessThan(
            AgentSweepMark.dashCount, StatusDot.ringDashCount,
            "working gathers the resting ring's dashes into FEWER, longer arcs — more ink, at work",
        )
        XCTAssertGreaterThan(AgentSweepMark.dashCount, 3, "fewer arcs than this reads as a broken ring")
        // Longer arcs at the same stroke weight: the frozen mark is heavier, measurably. Frozen means
        // fully KNIT — the parting is the one thing Reduce Motion must not leave half-done, because a
        // half-parted ring frozen forever is just a ring with an odd rhythm.
        XCTAssertEqual(AgentSweepMark.stillSplit, 0, "a frozen working ring is fully knit")
        let arc = AgentSweepMark.dash(split: AgentSweepMark.stillSplit)
        XCTAssertGreaterThan(
            arc[0] + arc[1] + arc[2], StatusDot.ringDash[0],
            "each working arc must be longer than a resting dash, or the cuts read alike",
        )
    }

    /// ⚠️ ONE diameter, no exceptions — including the finish DOT, which used to be drawn smaller on
    /// the argument that a solid mark carries more weight per point than an outline one. True in the
    /// abstract, wrong here: it made the column's sizes wobble row to row, which is the one thing a
    /// fixed status column may not do. Aliased in the source so it cannot drift again; pinned here so
    /// the reasoning survives the next person who thinks the dot looks heavy.
    func testEveryMarkIsDrawnAtTheOneDiameter() {
        XCTAssertEqual(
            StatusDot.dotDiameter, StatusDot.ringDiameter,
            "the finish dot is the SAME circle, filled — never a smaller one",
        )
        XCTAssertLessThanOrEqual(
            StatusDot.ringDiameter, StatusDot.footprint,
            "…and every one of them fits the fixed column",
        )
    }

    /// ⚠️ EVERY mark in the column is DRAWN — no glyph, no symbol, nothing typed. Three cuts of the two
    /// human states have now been pulled from here: otty's raised HAND and warning TRIANGLE (a
    /// silhouette per state is a legend to learn), then `?` and `!` inside the circle (fussy detail at
    /// 8pt — the same lesson the animated mark learned twice). What is left is the COMPLETENESS ladder,
    /// pinned here as the vocabulary itself: dashed at rest → turning at work → CLOSED when a human is
    /// wanted → FILLED when unread-done. ⚠️ It follows — by the user's own ruling — that `question` and
    /// `alert` draw ALIKE and are told apart by HUE alone; that is the one place in this column where
    /// hue is load-bearing on its own, and it is deliberate, not an oversight.
    @MainActor
    func testTheColumnIsFiveDrawnShapesAndNoGlyphs() {
        XCTAssertEqual(StatusMarkShape.allCases.count, 5, "rest, work, wants-you, failure, done")
        // The two human states are the same closed ring, so ONLY their ink separates them — which makes
        // the ink pair load-bearing in a way it was not while the glyphs were there.
        XCTAssertNotEqual(
            StatusPresentation.attentionInk(.awaitingInput), StatusPresentation.attentionInk(.error),
            "if these two ever share an ink, the two states become indistinguishable outright",
        )
        // …and the closed ring must not collide with the shapes that DO carry their own geometry.
        for shape: StatusMarkShape in [.question, .alert] {
            XCTAssertFalse(shape.animates, "a state waiting on a human holds still")
            XCTAssertNotEqual(shape, .ring, "closed is not dashed")
            XCTAssertNotEqual(shape, .dot, "closed is not filled")
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
            AgentSweepMark.stillSplit == 0,
            "a frozen working ring is fully knit — five long arcs still read as 'not at rest'",
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
