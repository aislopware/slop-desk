// StatusDotTests — pins the trailing status MARK: since round 19 the shape is the grammar and the
// hue rides along, so each state's pin is a (shape, ink) PAIR. The ladder is the spec: a working
// agent PULSES on the accent (the asterisk breath the app's own `StatusGlyph` already speaks, the
// same raw-working key liveness uses, outranking every badge); a resting code agent keeps the
// static dashed RING, muted; a blocked agent raises the HAND, a finished one holds the filled green
// DOT, a failure the red TRIANGLE; a plain running command mounts nothing HERE (its spinner
// replaces the process label — ``RailRowsBuilder/showsCommandSpinner(badge:isAgent:processLabel:)``),
// and bare idle / privilege-only rows stay bare. The two ANIMATED marks are frame-stepped off a
// fixed wall-clock epoch, so the cadence is pinned headlessly (unison across rows, no restart on
// re-render). Headless VALUE assertions — no render. Ink identity is asserted SELF-consistently
// against the presentation maps (never absolute colour values — `Color` equality is provider-fragile).

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    /// A WORKING AGENT's mark is the accent PULSE and outranks every badge underneath it — keyed
    /// on the raw working status, so the badge gate can never kill the mark. The `.running`
    /// badge route (gate ON) must read identically to the raw route.
    @MainActor
    func testWorkingAgentPulsesAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertEqual(raw?.shape, .pulse, "a thinking agent's mark is the breathing asterisk")
        XCTAssertEqual(raw?.ink, Slate.State.accent, "working rides the in-motion accent")
        for badge: TabBadgeKind? in [.commandBusy, .error, .awaitingInput, .finished, .sudo] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: true, badge: badge), raw,
                "working outranks \(String(describing: badge)) — one accent pulse, always",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .running), raw,
            "the badge-routed agent tier and the raw-working route are ONE reading",
        )
    }

    /// Each attention kind wears its OWN pictogram — the round-12 vocabulary, one shape per state so
    /// the mark reads before its hue does — on exactly its attention ink.
    @MainActor
    func testAttentionKindsWearTheirOwnShapeOnTheirAttentionInk() {
        let expected: [TabBadgeKind: StatusMarkShape] = [
            .awaitingInput: .hand, .error: .alert, .completed: .dot, .finished: .dot,
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

    /// The four attention shapes are DISTINCT from each other and from the two agent-activity
    /// marks — no two states share a pictogram, so hue is never load-bearing alone.
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
        XCTAssertEqual(shapes.count, 5, "working, resting, hand, alert, dot all resolved")
    }

    /// A RESTING CODE AGENT keeps the STATIC dashed ring, muted — present, spending no hue,
    /// distinct from the working pulse and from every attention pictogram. The ring is the
    /// agent's alone, and it is the one mark that does NOT move.
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

    /// Exactly TWO marks animate — the working pulse and (outside this column) the command
    /// spinner. Every other shape holds still, so a settled rail is motionless.
    @MainActor
    func testOnlyTheWorkingPulseAnimatesInTheMarkColumn() {
        XCTAssertTrue(StatusMarkShape.pulse.animates, "the agent's breath is the moving mark")
        for shape: StatusMarkShape in [.ring, .hand, .dot, .alert] {
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

    // MARK: Cadence (both animated marks)

    /// The command spinner steps ONE braille frame per beat off the SAME fixed epoch the pulse uses
    /// and wraps at the cycle's end — so every spinning row steps in unison and a re-render lands
    /// mid-cycle instead of restarting it. Pure function of the date.
    func testCommandSpinnerStepsOneFramePerBeatAndWraps() {
        let frames = CommandSpinner.frames
        let beat = CommandSpinner.beat
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0..<(frames.count * 2) {
            let at = epoch.addingTimeInterval(Double(step) * beat + beat / 2)
            XCTAssertEqual(
                StatusGlyph.frame(at: at, frames: frames, beat: beat), frames[step % frames.count],
                "beat \(step) lands on its own frame",
            )
        }
        let mid = epoch.addingTimeInterval(3 * beat + beat / 3)
        XCTAssertEqual(
            StatusGlyph.frame(at: mid, frames: frames, beat: beat),
            StatusGlyph.frame(at: mid, frames: frames, beat: beat),
            "pure function of the instant — a re-render never restarts the cycle",
        )
    }

    /// The command spinner sweeps a LINE and the agent pulse blooms a STAR: the two animated marks
    /// share no frame, so adjacent rows can never read as the same activity. Every command frame is a
    /// plain ASCII scalar — braille (`⠋⠙⠹…`, heavy or light) is BANNED here: no mono face we can
    /// count on carries U+2800…U+28FF, so CoreText substitutes AppleBraille (an embossing font —
    /// sparse circles, weight ignored, invisible at 11pt).
    func testCommandSpinnerSweepsAsciiAndSharesNoFrameWithThePulse() {
        XCTAssertTrue(
            Set(CommandSpinner.frames).isDisjoint(with: Set(StatusDot.pulseFrames)),
            "a sweeping command and a breathing agent never wear the same glyph",
        )
        for frame in CommandSpinner.frames {
            guard frame.unicodeScalars.count == 1, let scalar = frame.unicodeScalars.first else {
                XCTFail("\(frame) must be ONE scalar so the mono slot's advance is stable")
                return
            }
            XCTAssertTrue(
                scalar.isASCII,
                "\(frame) must be ASCII — a substituted font draws its own idea of the glyph",
            )
        }
        XCTAssertEqual(
            Set(CommandSpinner.frames).count, CommandSpinner.frames.count,
            "a rotation repeats no frame — a repeat reads as a stall",
        )
    }

    /// ⚠️ Every DINGBAT pulse frame (U+2700…U+27BF — the stars) pins TEXT presentation with
    /// `\u{FE0E}`. Bare U+2733 `✳` resolves to `AppleColorEmojiUI` on Apple platforms: a colour emoji
    /// that ignores `foregroundStyle` and measures 16pt of advance where its Menlo siblings measure
    /// 6.62 — so that one frame flashed a coloured star and jumped the mark's width mid-cycle (and it
    /// is exactly the frame Reduce Motion freezes on). The selector keeps the whole cycle one
    /// typeface. `·` (U+00B7) is outside the block and is the mono face's own glyph.
    func testEveryDingbatPulseFramePinsTextPresentation() {
        let selector: Unicode.Scalar = "\u{FE0E}"
        for frame in StatusDot.pulseFrames {
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
        XCTAssertEqual(
            StatusDot.pulseStillFrame.unicodeScalars.last, selector,
            "the Reduce-Motion frame is the emoji-prone ✳ — it needs the selector most",
        )
    }

    /// The agent PULSE reuses the app's own `StatusGlyph` breath — the rail and the compact agent
    /// surfaces (iOS toolbar, Peek & Reply header) must speak ONE vocabulary for `working`, so the
    /// two can never disagree about the same pane.
    func testAgentPulseReusesTheStatusGlyphBreath() {
        XCTAssertEqual(
            StatusDot.pulseFrames, StatusGlyph.agentFrames,
            "one frame set for the agent's breath, everywhere",
        )
        XCTAssertEqual(
            StatusDot.pulseBeat, StatusGlyph.agentBeat,
            "one cadence for the agent's breath, everywhere",
        )
    }

    /// REDUCE MOTION freezes both animated marks on a REPRESENTATIVE frame rather than hiding them:
    /// the state must still be readable when the system asks for stillness.
    func testReduceMotionFreezesBothAnimatedMarksOnALegibleFrame() {
        XCTAssertEqual(
            StatusDot.pulseStillFrame, "✳\u{FE0E}",
            "the frozen breath is the mid-swell asterisk (text-pinned), not the near-invisible dot",
        )
        XCTAssertTrue(
            StatusDot.pulseFrames.contains(StatusDot.pulseStillFrame),
            "the still frame is one of the real frames",
        )
        XCTAssertEqual(
            CommandSpinner.stillFrame, CommandSpinner.frames[0],
            "a frozen spinner holds a real frame — every line frame carries the same ink",
        )
    }
}
