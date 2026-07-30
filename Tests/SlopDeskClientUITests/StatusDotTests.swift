// StatusDotTests — pins the trailing status MARK: since round 19 the shape is the grammar and the
// hue rides along, so each state's pin is a (shape, ink) PAIR. The agent's own states are ONE
// CIRCLE and the pins say so: a resting code agent keeps the static finely dashed RING (muted), a
// working one keeps that IDENTICAL cut and runs a LIGHT through it (accent, keyed on the same
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
        XCTAssertEqual(raw?.shape, .working, "a thinking agent's mark is the ring with the travelling light")
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
    /// from the closed attention ring — and from the working ring, which is the SAME cut with a light
    /// running through it on the accent. It does NOT move.
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
        XCTAssertGreaterThan(AgentWorkingMark.lap, 0)
        XCTAssertGreaterThan(AgentWorkingMark.dashFill, 0)
    }

    /// ⚠️ The mark's GEOMETRY CANNOT MOVE — the whole point of this cut, and the pin that protects it:
    /// an arc's position is a function of its INDEX and nothing else, so there is no instant to move it
    /// with. Four earlier cuts all moved the shape (a star blooming, a comet sweeping, a dashed ring
    /// turning and splitting) and all read as cheap at 12pt; what moves here is light.
    func testTheWorkingRingsGeometryIsFixedForever() {
        let starts = (0..<AgentWorkingMark.dashCount).map { AgentWorkingMark.start(arc: $0) }
        XCTAssertEqual(starts.first, 0, "the first arc starts at 3 o'clock")
        for (index, start) in starts.enumerated() {
            XCTAssertEqual(
                start, Double(index) / Double(AgentWorkingMark.dashCount), accuracy: 1e-12,
                "arc \(index) sits on its own even slot",
            )
        }
        // The arcs fill exactly the declared fraction of the circle, leaving even gaps between them.
        XCTAssertEqual(
            AgentWorkingMark.arcLength * Double(AgentWorkingMark.dashCount),
            Double(AgentWorkingMark.dashFill), accuracy: 1e-12,
            "five arcs of this length ARE the dash fill — no seam, no overlap",
        )
        XCTAssertLessThan(
            AgentWorkingMark.arcLength, 1 / Double(AgentWorkingMark.dashCount),
            "a dash must be shorter than its slot or the ring closes",
        )
    }

    /// The LIGHT travels: it visits every arc, once per lap, in order — and the travel is a pure
    /// function of the clock off a fixed epoch, so every working row in the rail lights the same arc at
    /// the same instant and a re-render lands mid-lap instead of restarting the chase.
    func testTheLightVisitsEveryArcInOrderOncePerLap() {
        let lap = AgentWorkingMark.lap
        XCTAssertEqual(AgentWorkingMark.phase(at: 0), 0, accuracy: 1e-12, "the epoch is 3 o'clock")
        XCTAssertEqual(AgentWorkingMark.phase(at: lap), 0, accuracy: 1e-12, "one lap wraps round")
        XCTAssertEqual(
            AgentWorkingMark.phase(at: lap * 1.25), AgentWorkingMark.phase(at: lap * 0.25),
            accuracy: 1e-12, "the lap after is the lap before",
        )
        XCTAssertTrue(
            (0..<1).contains(AgentWorkingMark.phase(at: -lap / 3)),
            "a pre-epoch instant is still a real position",
        )
        // Each arc takes its turn as the brightest, and they do so in index order across one lap.
        var order: [Int] = []
        for step in 0..<600 {
            let phase = AgentWorkingMark.phase(at: Double(step) * lap / 600)
            let lit = (0..<AgentWorkingMark.dashCount).max {
                AgentWorkingMark.brightness(arc: $0, phase: phase)
                    < AgentWorkingMark.brightness(arc: $1, phase: phase)
            }
            if let lit, order.last != lit { order.append(lit) }
        }
        XCTAssertEqual(
            Set(order).count, AgentWorkingMark.dashCount, "every arc must get the light once a lap",
        )
        // …and in ORDER: the sequence is the arcs rotating, not an arbitrary flicker. (The lap may
        // start mid-arc, so compare against the same cycle rotated to wherever it began — and a lap
        // sampled to its end legitimately returns to the arc it started on.)
        let expected = (0..<AgentWorkingMark.dashCount).map {
            (order[0] + $0) % AgentWorkingMark.dashCount
        }
        XCTAssertEqual(
            Array(order.prefix(AgentWorkingMark.dashCount)), expected,
            "the light must travel round, not hop about",
        )
        if order.count > AgentWorkingMark.dashCount {
            XCTAssertEqual(
                order[AgentWorkingMark.dashCount], order[0], "…and comes back round, not back down",
            )
        }
    }

    /// The pulse's SHAPE: brightest on the arc it sits over, falling off with wrapped angular distance,
    /// and never darker than ``dimFloor``.
    ///
    /// ⚠️ Two things are load-bearing here. The distance is WRAPPED — measured the short way round —
    /// or the chase would stall and jump at 3 o'clock once per lap, where the seam is. And the floor is
    /// NOT zero: the comet cut proved that ink fading to nothing at 12pt simply disappears, so the ring
    /// would break into a moving arc, which is the generic-spinner look this replaced. The floor is what
    /// holds the SHAPE constant while only the light moves.
    func testThePulseFallsOffTheShortWayRoundAndNeverGoesDark() {
        let mid = AgentWorkingMark.middle(arc: 0)
        let onIt = AgentWorkingMark.brightness(arc: 0, phase: mid)
        XCTAssertEqual(onIt, 1, accuracy: 1e-9, "the arc under the light is fully inked")
        // Monotonic falloff as the light walks away from arc 0 — up to half a turn, then it comes back.
        var previous = onIt
        for step in 1...50 {
            let value = AgentWorkingMark.brightness(arc: 0, phase: mid + Double(step) / 100)
            XCTAssertLessThan(value, previous, "step \(step) away must be dimmer")
            XCTAssertGreaterThanOrEqual(
                value, AgentWorkingMark.dimFloor, "the ring may never go dark at step \(step)",
            )
            previous = value
        }
        // The wrap: a light just BEFORE 3 o'clock lights arc 0 exactly as much as one just after it.
        XCTAssertEqual(
            AgentWorkingMark.brightness(arc: 0, phase: mid + 0.97),
            AgentWorkingMark.brightness(arc: 0, phase: mid - 0.97 + 1), accuracy: 1e-12,
            "the far side of the seam is the near side — a chase with a seam stalls once a lap",
        )
        XCTAssertGreaterThan(AgentWorkingMark.dimFloor, 0.15, "below this the dim arcs vanish at 8pt")
        XCTAssertLessThan(
            AgentWorkingMark.dimFloor, 0.5, "above this the light stops reading as a light",
        )
        // The pulse is roughly one dash wide: clearly ON one dash, just touching its neighbours.
        let neighbour = AgentWorkingMark.brightness(arc: 1, phase: mid)
        XCTAssertLessThan(neighbour, 0.75, "the neighbour must not be lit as brightly as the dash")
        XCTAssertGreaterThan(
            neighbour, AgentWorkingMark.dimFloor,
            "…but it must be touched, or the arcs blink in sequence instead of handing over",
        )
    }

    /// The cadence: a lap is fast enough that the light reads as ONE thing moving and slow enough that
    /// the ring does not strobe. Pinned as the per-arc interval, which is what the eye actually times.
    func testTheLapReadsAsOneTravellingLight() {
        XCTAssertGreaterThan(AgentWorkingMark.handoff, 0.12, "faster than this and the ring strobes")
        XCTAssertLessThan(AgentWorkingMark.handoff, 0.5, "slower than this and the mark looks asleep")
        // ⚠️ The HAND-OFF is the constant and the lap is derived, not the other way round: a cut with
        // more dashes must take LONGER to go round, never flicker faster. (Pinning the lap instead is
        // how a dash-count change turns into a strobe nobody meant.)
        XCTAssertEqual(
            AgentWorkingMark.lap,
            AgentWorkingMark.handoff * Double(AgentWorkingMark.dashCount), accuracy: 1e-12,
        )
        // The pulse is likewise measured in SLOTS, so it tracks the cut instead of being retuned with it.
        XCTAssertEqual(
            AgentWorkingMark.pulseWidth,
            AgentWorkingMark.pulseSlots / Double(AgentWorkingMark.dashCount), accuracy: 1e-12,
        )
        XCTAssertLessThanOrEqual(
            AgentWorkingMark.maxFrameInterval, 1.0 / 60, "the fade needs 60 fps to stay smooth",
        )
    }

    /// The working ring is the RESTING ring's own circle: same diameter, same stroke weight, its dashes
    /// gathered into FEWER, longer arcs and turning. That shared geometry is what makes the agent's
    /// states read as a progression instead of a legend, so both numbers are pinned — a drift in
    /// either splits the family in two. The working ring's dashes tile the circumference exactly
    /// (whole periods, no seam where the stroke closes).
    func testWorkingRingSharesTheRestingRingsGeometry() {
        XCTAssertEqual(StatusDot.ringDiameter, 8, "one diameter for the whole circle family")
        XCTAssertEqual(StatusDot.ringLineWidth, 1.5, "one stroke weight for the whole circle family")
        // ⚠️ The working ring's cut is the resting ring's, ALIASED — not merely equal today. An earlier
        // cut made it five longer arcs ("more ink while busy") and that made the column's rhythm change
        // from row to row for no gain, so the numbers are shared at the source and pinned here.
        XCTAssertEqual(
            AgentWorkingMark.dashCount, StatusDot.ringDashCount, "one dash count for the whole column",
        )
        XCTAssertEqual(
            AgentWorkingMark.dashFill, StatusDot.ringDashFill, "one dash length for the whole column",
        )
        XCTAssertEqual(
            AgentWorkingMark.arcLength,
            Double(StatusDot.ringDash[0]) / Double(CGFloat.pi * StatusDot.ringDiameter),
            accuracy: 1e-12,
            "a working dash IS a resting dash — the same arc, measured in turns",
        )
    }

    /// ⚠️ The working ring is legible when FROZEN, not only when moving — and since its cut is now the
    /// resting ring's exactly, the thing that carries the difference is the PARKED LIGHT: one dash at
    /// full ink against neighbours at ``dimFloor``, in the accent rather than the muted grey. This is
    /// the pin that makes sharing the cut safe; without the light's own contrast, Reduce Motion would
    /// collapse working and resting to one mark in two hues.
    func testFrozenWorkingRingStillDiffersFromTheRestingRing() {
        let parked = (0..<AgentWorkingMark.dashCount)
            .map { AgentWorkingMark.brightness(arc: $0, phase: AgentWorkingMark.stillPhase) }
        guard let brightest = parked.max(), let dimmest = parked.min() else {
            XCTFail("a ring with no dashes cannot be a mark")
            return
        }
        XCTAssertEqual(brightest, 1, accuracy: 1e-9, "one dash is fully lit even frozen")
        XCTAssertGreaterThan(
            brightest - dimmest, 0.5,
            "the frozen frame needs real contrast, or it reads as the resting ring in another hue",
        )
        // Exactly ONE dash carries the light — a frozen frame with two equal candidates has no subject.
        let lit = parked.filter { $0 > (brightest + dimmest) / 2 }
        XCTAssertEqual(lit.count, 1, "the parked light has one subject")
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
        // ⚠️ A frozen chase parks the light ON an arc, not at 12 o'clock: with five arcs nothing sits
        // exactly there, and a light parked in a GAP freezes the mark as two half-lit arcs with no
        // subject — the one still frame that reads as broken rather than paused.
        let parked = (0..<AgentWorkingMark.dashCount)
            .map { AgentWorkingMark.brightness(arc: $0, phase: AgentWorkingMark.stillPhase) }
        XCTAssertEqual(
            parked.max() ?? 0, 1, accuracy: 1e-9,
            "the frozen frame has one arc FULLY lit — it is a legible still",
        )
        XCTAssertLessThan(
            abs(AgentWorkingMark.stillPhase - 0.75), 1 / Double(AgentWorkingMark.dashCount) / 2,
            "…and it is the arc nearest the top, so the still frame looks deliberate",
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
