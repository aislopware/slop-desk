// StatusDotTests — pins the trailing status MARK: since round 19 the shape is the grammar and the
// hue rides along, so each state's pin is a (shape, ink) PAIR. The agent's own states are ONE
// CIRCLE and the pins say so: a resting code agent keeps the static finely dashed RING (muted), a
// working one becomes ONE SOLID ARC chasing its own tail round the circle (accent, keyed on the same
// raw-working status liveness uses, outranking every badge), an unread finish fills the circle in
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
        XCTAssertEqual(raw?.shape, .working, "a thinking agent's mark is the turning arc")
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
    /// from the closed attention ring — and from the working mark, which is the same circle drawn as one
    /// solid turning arc. It does NOT move.
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
        XCTAssertTrue(StatusMarkShape.working.animates, "the agent's turning ring is the moving mark")
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
        XCTAssertGreaterThan(AgentWorkingMark.cycle, 0)
        XCTAssertGreaterThan(AgentWorkingMark.span, 0)
    }

    /// The arc CHASES ITS OWN TAIL: through the first half of a cycle the head runs out to ``span``,
    /// through the second the tail catches up to it. Pinned as the sweep's shape — shortest at both ends
    /// of the cycle, widest in the middle, never past `span`, never below ``minSweep``.
    ///
    /// ⚠️ `minSweep` is not decoration: an arc allowed to collapse to zero BLINKS OUT at the end of every
    /// cycle, and a mark that vanishes 40 times a minute reads as broken rather than busy.
    func testTheArcGrowsToItsMarkThenCollapsesOntoIt() {
        let cycle = AgentWorkingMark.cycle
        let widest = AgentWorkingMark.figure(at: cycle / 2).sweep
        XCTAssertEqual(widest, AgentWorkingMark.span, accuracy: 1e-9, "mid-cycle the head is at its mark")
        for step in 0...200 {
            let sweep = AgentWorkingMark.figure(at: Double(step) * cycle / 200).sweep
            XCTAssertGreaterThanOrEqual(
                sweep, AgentWorkingMark.minSweep, "step \(step): the arc may never blink out",
            )
            XCTAssertLessThanOrEqual(
                sweep, AgentWorkingMark.span, "step \(step): the arc may never pass its mark",
            )
        }
        // Grows through the first half…
        XCTAssertGreaterThan(
            AgentWorkingMark.figure(at: cycle * 0.35).sweep,
            AgentWorkingMark.figure(at: cycle * 0.15).sweep, "the head runs ahead first",
        )
        // …and collapses through the second.
        XCTAssertLessThan(
            AgentWorkingMark.figure(at: cycle * 0.85).sweep,
            AgentWorkingMark.figure(at: cycle * 0.65).sweep, "then the tail catches up",
        )
        XCTAssertEqual(
            AgentWorkingMark.figure(at: 0).sweep, AgentWorkingMark.minSweep, accuracy: 1e-9,
            "a cycle opens at the shortest arc",
        )
    }

    /// ⚠️ The cycle is SEAMLESS by construction, which is what lets the mark hold no animation state: at
    /// the end of a cycle head and tail have both travelled exactly `span`, which is precisely where the
    /// next cycle starts from. Pinned across the boundary — a discontinuity here is a visible JUMP once
    /// every 1.4 s, and it is the exact failure a `repeatForever` animation would produce on every chrome
    /// tick.
    func testTheCycleBoundaryIsSeamless() {
        let cycle = AgentWorkingMark.cycle
        let epsilon = 1e-6
        let before = AgentWorkingMark.figure(at: cycle - epsilon)
        let after = AgentWorkingMark.figure(at: cycle + epsilon)
        XCTAssertEqual(before.tail, after.tail, accuracy: 1e-4, "the tail may not jump at the seam")
        XCTAssertEqual(before.sweep, after.sweep, accuracy: 1e-4, "nor may the length")
        // The TAIL only ever moves forward — sampled far finer than a frame, so a stall would show.
        var previous = AgentWorkingMark.figure(at: 0).tail
        for step in 1...2000 {
            let tail = AgentWorkingMark.figure(at: Double(step) * cycle * 2 / 2000).tail
            XCTAssertGreaterThanOrEqual(tail, previous, "step \(step): the arc must never run backwards")
            previous = tail
        }
    }

    /// The figure advances exactly ONE TURN per cycle — `span` walked by the arc plus ``spin`` drifted by
    /// the figure. That is not arithmetic tidiness: it means the head lands on the same clock position
    /// every cycle, which is what stops a spinner from looking like it is wandering.
    func testTheFigureAdvancesExactlyOneTurnPerCycle() {
        XCTAssertEqual(AgentWorkingMark.span + AgentWorkingMark.spin, 1, accuracy: 1e-12)
        let first = AgentWorkingMark.figure(at: 0).tail
        for lap in 1...4 {
            let tail = AgentWorkingMark.figure(at: Double(lap) * AgentWorkingMark.cycle).tail
            XCTAssertEqual(
                tail - first, Double(lap), accuracy: 1e-9,
                "cycle \(lap) must land one whole turn on from the last",
            )
        }
        XCTAssertLessThan(AgentWorkingMark.span, 1, "a closed ring shows nothing — the gap must survive")
        XCTAssertGreaterThan(AgentWorkingMark.span, 0.5, "…and at its widest it must read as an arc")
    }

    /// The head EASES onto its mark rather than arriving at a constant rate — smoothstep, flat at both
    /// ends: a spinner that looks drawn instead of driven. (The constant-rate cut was rejected by eye
    /// twice before; this is the same finding, kept.)
    func testTheHeadEasesOntoItsMarkRatherThanArrivingLinearly() {
        XCTAssertEqual(AgentWorkingMark.ease(0), 0, accuracy: 1e-12)
        XCTAssertEqual(AgentWorkingMark.ease(1), 1, accuracy: 1e-12)
        XCTAssertEqual(AgentWorkingMark.ease(0.5), 0.5, accuracy: 1e-12, "symmetric about the middle")
        // Flat at the ends, steep in the middle — the definition of eased, asserted as a rate ratio.
        let atEnd = AgentWorkingMark.ease(0.05) - AgentWorkingMark.ease(0)
        let atMiddle = AgentWorkingMark.ease(0.525) - AgentWorkingMark.ease(0.475)
        XCTAssertGreaterThan(atMiddle / atEnd, 3, "the middle must move far faster than the ends")
        // Out-of-range input is clamped, not extrapolated (an overshoot would push the arc past its mark).
        XCTAssertEqual(AgentWorkingMark.ease(-2), 0, accuracy: 1e-12)
        XCTAssertEqual(AgentWorkingMark.ease(9), 1, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(
            AgentWorkingMark.maxFrameInterval, 1.0 / 60, "smooth needs 60 fps at this size",
        )
    }

    /// The working mark is the RESTING ring's own circle: same diameter, same stroke weight, drawn as ONE
    /// SOLID ARC instead of eight dashes. That shared geometry is what makes the agent's states read as a
    /// progression instead of a legend, so both numbers are pinned — a drift in either splits the family
    /// in two.
    func testWorkingRingSharesTheRestingRingsGeometry() {
        XCTAssertEqual(StatusDot.ringDiameter, 8, "one diameter for the whole circle family")
        XCTAssertEqual(StatusDot.ringLineWidth, 1.5, "one stroke weight for the whole circle family")
        // The resting ring's own cut is untouched by the working mark's recuts — eight whole periods.
        let dash = StatusDot.ringDash
        XCTAssertEqual(
            Double((dash[0] + dash[1]) * CGFloat(StatusDot.ringDashCount)),
            Double(CGFloat.pi * StatusDot.ringDiameter), accuracy: 1e-9,
            "whole periods around the resting ring — no seam",
        )
    }

    /// ⚠️ The working mark is legible when FROZEN, not only when moving: Reduce Motion parks it at its
    /// WIDEST, where one continuous three-quarter arc cannot be mistaken for the resting ring's eight
    /// dashes. The distinction is SHAPE, so it survives a colour-blind eye too — which matters because
    /// the previous cut had to lean on the parked light's contrast for the same guarantee.
    func testFrozenWorkingRingStillDiffersFromTheRestingRing() {
        // The frozen frame is the mid-cycle one: the widest arc the figure ever draws.
        let frozen = AgentWorkingMark.span
        XCTAssertEqual(
            frozen, AgentWorkingMark.figure(at: AgentWorkingMark.cycle / 2).sweep, accuracy: 1e-9,
            "the frozen arc is one the moving figure actually passes through",
        )
        // …and it is a CONTINUOUS arc many times longer than any single resting dash.
        let restingDash = Double(StatusDot.ringDashFill) / Double(StatusDot.ringDashCount)
        XCTAssertGreaterThan(
            frozen / restingDash, 5,
            "a frozen working arc must dwarf a resting dash, or the two marks read alike",
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
        // A frozen working mark holds the WIDEST arc the figure passes through — unmistakably an arc.
        XCTAssertEqual(
            AgentWorkingMark.span, AgentWorkingMark.figure(at: AgentWorkingMark.cycle / 2).sweep,
            accuracy: 1e-9, "the frozen arc is a frame the moving figure actually draws",
        )
        XCTAssertGreaterThan(AgentWorkingMark.span, 0.5, "…and it still reads as 'not at rest'")
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
