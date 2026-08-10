// StatusDotTests — pins the trailing status mark. The HUE names the STATE and the SYMBOL names what
// happened, in otty's own badge vocabulary (docs/DECISIONS.md round 23): the SPINNER for a working
// agent, the hand for a waiting question, the filled check for the AGENT's turn ending, and the
// dashed ring for an agent that is merely present. The resolver's ladder is the spec: a working
// agent spins (the same raw-working key liveness uses, outranking every badge); a RESTING CODE AGENT
// rings muted; the attention states wear their attention ink — the title never recolours, so the
// mark's hue is those states' entire rendering; a plain running command, a bare idle shell and
// privilege-only rows mount nothing. The STATIC contract — exactly ONE mark moves — rides the mark
// pins.
//
// ⚠️ The mark column is the AGENT's alone (round 24). A COMMAND's outcome mounts NO mark and speaks
// in the trailing SLOT instead, as the command's own name in the outcome's ink — pinned here as the
// PARTITION (a badge is either a mark or a receipt, never both, never neither).
// Headless VALUE assertions — no render. Ink identity is asserted SELF-consistently against the
// presentation maps (never absolute colour values — `Color` equality is provider-fragile).

import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class StatusDotTests: XCTestCase {
    /// A WORKING AGENT's mark outranks every badge underneath it — keyed on the raw working status,
    /// so the badge gate can never kill the mark. The `.running` badge route (gate ON) must read
    /// identically to the raw route.
    @MainActor
    func testWorkingAgentRingsAndOutranksEveryBadge() {
        let raw = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertNotNil(raw, "a thinking agent always mounts the mark")
        for badge: TabBadgeKind? in [.commandBusy, .error, .awaitingInput, .finished, .sudo] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: true, badge: badge), raw,
                "working outranks \(String(describing: badge)) — the spinner, always",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .running), raw,
            "the badge-routed agent tier and the raw-working route are ONE reading",
        )
    }

    /// Each attention kind the MARK still speaks for wears EXACTLY its attention ink — with a
    /// neutral title, the mark's hue is the state's whole rendering, so it can never drift off the
    /// hue budget (green unread finish, amber question). Whichever symbol, the hue is the same one.
    @MainActor
    func testAttentionKindsRingOnTheirAttentionInk() {
        let marked: [(TabBadgeKind, Bool)] = [
            (.awaitingInput, false), (.completed, true), (.finished, true),
        ]
        for (kind, agentFinish) in marked {
            let dot = StatusPresentation.statusDot(
                working: false, badge: kind, agentFinish: agentFinish,
            )
            XCTAssertNotNil(dot, "\(kind) must mount the mark — the neutral title can't say it")
            XCTAssertEqual(
                dot?.ink, StatusPresentation.attentionInk(kind),
                "\(kind)'s mark must wear its own attention ink",
            )
        }
    }

    /// A RESTING CODE AGENT's ring is muted — present, spending no hue — distinct from both the
    /// thinking ink and the attention hues. The muted ring is the agent's alone.
    @MainActor
    func testRestingAgentRingsMutedDistinctFromEveryHuedTier() {
        let working = StatusPresentation.statusDot(working: true, badge: nil)
        // The claude pane at its prompt keeps the shell busy for its whole lifetime, so it
        // arrives with either no badge or the `.commandBusy` tier — both read the same.
        for badge: TabBadgeKind? in [nil, .commandBusy] {
            let dot = StatusPresentation.statusDot(
                working: false, badge: badge, agentIdle: true,
            )
            XCTAssertNotNil(dot, "a resting agent mounts the muted ring")
            XCTAssertNotEqual(dot?.ink, working?.ink, "resting must not borrow the thinking ink")
            XCTAssertEqual(dot?.ink, Slate.Text.secondary, "resting spends no hue")
            XCTAssertEqual(dot?.mark, .agentRing, "presence is the ring, whatever the shell is doing")
        }
    }

    /// A plain running COMMAND — no code agent in the pane — mounts NOTHING: the ring is
    /// reserved for a resting agent, so `npm run dev` no longer decorates the rail.
    @MainActor
    func testPlainRunningCommandMountsNoMark() {
        for kind: TabBadgeKind in [.commandBusy, .commandRunning] {
            XCTAssertNil(
                StatusPresentation.statusDot(working: false, badge: kind),
                "\(kind) without an agent must leave the rail bare",
            )
        }
    }

    /// An attention state the mark speaks for OUTRANKS the resting-agent ring: a finished or
    /// blocked agent keeps its attention ink even though the same pane is also a resting agent.
    @MainActor
    func testAttentionOutranksTheRestingAgentRing() {
        let marked: [(TabBadgeKind, Bool)] = [
            (.awaitingInput, false), (.completed, true), (.finished, true),
        ]
        for (kind, agentFinish) in marked {
            XCTAssertEqual(
                StatusPresentation.statusDot(
                    working: false, badge: kind, agentIdle: true, agentFinish: agentFinish,
                )?.ink,
                StatusPresentation.attentionInk(kind),
                "\(kind) keeps its attention ink over the muted resting ring",
            )
        }
        // ⚠️ A COMMAND's outcome does NOT outrank it — it is not in the mark column at all, so the
        // resting agent beside it keeps saying the one thing this column is for: it is still there.
        for kind: TabBadgeKind in [.error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(
                working: false, badge: kind, agentIdle: true, agentFinish: false,
            )
            XCTAssertEqual(dot?.mark, .agentRing, "\(kind) leaves the mark column to the agent")
            XCTAssertEqual(dot?.ink, Slate.Text.secondary, "and the ring keeps spending no hue")
        }
    }

    /// Idle and privilege-only rows mount NOTHING in the status column — the resting rail is bare.
    /// (Privilege is not lifecycle: sudo and caffeinate speak in the SLOT, see ``tabBadge``.)
    @MainActor
    func testIdleAndPrivilegeOnlyRowsMountNoMark() {
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: nil))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .sudo))
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .caffeinate))
    }

    // MARK: - otty's vocabulary (round 23)

    /// ⚠️ The CHECK is the AGENT's turn ending, and it is the ONLY finish this column draws — a
    /// background command's clean exit mounts nothing here and reads in the slot instead. Both of
    /// OUR finish tiers read alike: the `.completed` flash and the settled `.finished` unread are
    /// one reading, since that split is freshness machinery and never visual.
    ///
    /// The two-speaker rule (round 21) survives round 24 with one speaker moved: an agent's state is
    /// continuous and belongs in the state column; a command's exit is a fact about a NAME, and a
    /// disc could not carry the name.
    @MainActor
    func testTheAgentsFinishIsACheckAndACommandsIsNoMarkAtAll() {
        for kind: TabBadgeKind in [.completed, .finished] {
            XCTAssertEqual(
                StatusPresentation.mark(for: kind, agentFinish: true), .agentFinish,
                "\(kind) from the AGENT is a turn that ENDED — the filled check",
            )
            XCTAssertEqual(
                StatusPresentation.statusDot(working: false, badge: kind, agentFinish: true)?.mark,
                .agentFinish,
                "\(kind) must RESOLVE to the filled check, not merely be classified as one",
            )
            XCTAssertNil(
                StatusPresentation.mark(for: kind, agentFinish: false),
                "\(kind) with no agent finish behind it is the SLOT's receipt, not a mark",
            )
            XCTAssertNil(
                StatusPresentation.statusDot(working: false, badge: kind, agentFinish: false),
                "and with no agent in the pane the row's mark column stays empty",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: .finished, agentFinish: true)?.ink,
            StatusPresentation.attentionInk(.finished),
            "the agent's own finish keeps the unread green",
        )
    }

    /// A failure NEVER draws in the mark column, whoever else is in the pane: `.error` can only come
    /// from a non-zero exit or a held-red `OSC 9;4;2` — `ClaudeStatus` has no error case, so it is
    /// always a COMMAND's fact, and a command's facts are the slot's.
    @MainActor
    func testAFailureLeavesTheMarkColumnToTheAgent() {
        for agents in [true, false] {
            XCTAssertNil(
                StatusPresentation.mark(for: .error, agentFinish: agents),
                "a non-zero exit is a COMMAND's fact even in an agent pane",
            )
        }
        XCTAssertNil(StatusPresentation.statusDot(working: false, badge: .error))
        // The red itself is NOT gone — it moved. The slot's receipt and the collapsed group's
        // roll-up count both still read the error ink.
        XCTAssertEqual(
            StatusPresentation.outcomeInk(.failed), StatusPresentation.attentionInk(.error),
            "the failure hue is one budget wherever it surfaces",
        )
    }

    // MARK: - The command's outcome speaks in the slot (round 24)

    /// ⚠️ A badge has exactly ONE voice. Every kind resolves to a mark or to a slot receipt, and
    /// never to both — the mark column is the agent's, so a command's exit that also drew a symbol
    /// would be the same news twice in two dialects.
    @MainActor
    func testEveryBadgeHasExactlyOneVoice() {
        let everyKind: [TabBadgeKind] = [
            .running, .commandRunning, .commandBusy, .completed, .finished, .error, .awaitingInput,
            .caffeinate, .sudo,
        ]
        for kind in everyKind {
            for agentFinish in [true, false] {
                let mark = StatusPresentation.mark(for: kind, agentFinish: agentFinish)
                let outcome = StatusPresentation.commandOutcome(
                    badge: kind, agentFinish: agentFinish,
                )
                XCTAssertFalse(
                    mark != nil && outcome != nil,
                    "\(kind) (agentFinish=\(agentFinish)) speaks twice",
                )
            }
        }
    }

    /// The OUTCOME map: a failure is red, a clean exit is bright — and only the agent's own finish
    /// escapes the slot, because that one has a mark. `nil` for everything still live: an outcome is
    /// a finished fact, so a busy shell never dresses its process name up as a verdict.
    @MainActor
    func testTheSlotReadsSucceededBrightAndFailedRed() {
        XCTAssertEqual(StatusPresentation.commandOutcome(badge: .error, agentFinish: false), .failed)
        XCTAssertEqual(StatusPresentation.commandOutcome(badge: .error, agentFinish: true), .failed)
        for kind: TabBadgeKind in [.completed, .finished] {
            XCTAssertEqual(
                StatusPresentation.commandOutcome(badge: kind, agentFinish: false), .succeeded,
            )
            XCTAssertNil(
                StatusPresentation.commandOutcome(badge: kind, agentFinish: true),
                "the AGENT's finish is the check — it never doubles as a command receipt",
            )
        }
        for kind: TabBadgeKind in [
            .awaitingInput,
            .commandBusy,
            .commandRunning,
            .running,
            .sudo,
            .caffeinate,
        ] {
            XCTAssertNil(StatusPresentation.commandOutcome(badge: kind, agentFinish: false))
        }
        XCTAssertNil(StatusPresentation.commandOutcome(badge: nil, agentFinish: false))
        // The slot's OWN register: the working exit spends BRIGHTNESS, not a hue, and red stays
        // reserved for broken. (It was written as the git line's while that line was monochrome; the
        // git readout took hues back per role on `07da1f5d` and this slot deliberately did not
        // follow — a command has two outcomes, not seven states.) Both are BOLD — at 10pt mono the
        // brightness step alone does not carry. The red is the INK cut, `StatusInk`, since a 10pt
        // mono run is the case the system palette read faintest in.
        XCTAssertEqual(StatusPresentation.outcomeInk(.succeeded), Slate.Text.primary)
        XCTAssertEqual(StatusPresentation.outcomeInk(.failed), Slate.StatusInk.err)
        XCTAssertNotEqual(
            StatusPresentation.outcomeInk(.succeeded), Slate.StatusInk.ok,
            "green was the mark's answer; 'it worked' is the expected case and buys no hue",
        )
        XCTAssertEqual(StatusPresentation.outcomeWeight, .bold)
    }

    /// A waiting question raises otty's HAND — the one state on this rail that is asking a person
    /// for something, and the only one whose silhouette says so without a legend.
    @MainActor
    func testAWaitingQuestionRaisesTheHand() {
        XCTAssertEqual(StatusPresentation.mark(for: .awaitingInput, agentFinish: false), .awaiting)
        let dot = StatusPresentation.statusDot(working: false, badge: .awaitingInput)
        XCTAssertEqual(dot?.mark, .awaiting)
        XCTAssertEqual(dot?.ink, StatusPresentation.attentionInk(.awaitingInput))
        // The hand is otty's artwork, not a look-alike: an OUTLINE at lucide's 2-unit stroke in a
        // 24 viewBox, with four subpaths (three finger joints + the palm-and-thumb).
        XCTAssertEqual(OttyIcon.hand.outlines.count, 4, "lucide `hand` is four strokes")
        XCTAssertEqual(OttyIcon.hand.strokeWidth, 2)
        XCTAssertEqual(OttyIcon.hand.viewBox, 24)
        XCTAssertTrue(OttyIcon.hand.fills.isEmpty, "an outline icon fills nothing")
    }

    /// Everything still mid-session keeps the ring — a live agent with nothing to report says only
    /// that it is there. ⚠️ `.running` is the exception, and it is not one: the resolver lifts that
    /// tier to the WORKING mark BEFORE the badge switch, so `mark(for:)`'s answer for it is never
    /// the one that reaches the row.
    @MainActor
    func testALiveSessionWithNothingToReportKeepsTheRing() {
        for kind: TabBadgeKind in [.running, .commandBusy, .commandRunning, .sudo, .caffeinate] {
            XCTAssertEqual(
                StatusPresentation.mark(for: kind, agentFinish: true), .agentRing,
                "\(kind) is not an outcome — the ring, not a symbol",
            )
        }
        XCTAssertEqual(
            StatusPresentation.statusDot(working: false, badge: nil, agentIdle: true)?.mark, .agentRing,
        )
        XCTAssertEqual(
            StatusPresentation.statusDot(
                working: false, badge: .commandBusy, agentIdle: true,
            )?.mark,
            .agentRing,
        )
    }

    /// The PRIVILEGE slot speaks in otty's drawings too — a shield for sudo, a duotone cup for
    /// caffeinate, both on the muted metadata ink. Every lifecycle kind returns nil: those live in
    /// the status column, so their rows keep the shell label in this slot.
    @MainActor
    func testPrivilegeSlotDrawsTheShieldAndTheCup() {
        XCTAssertEqual(StatusPresentation.tabBadge(.sudo)?.art, .symbol(.shieldFill))
        XCTAssertEqual(StatusPresentation.tabBadge(.caffeinate)?.art, .vector(OttyIcon.coffee))
        for kind: TabBadgeKind in [.sudo, .caffeinate] {
            XCTAssertEqual(
                StatusPresentation.tabBadge(kind)?.tint, Slate.Text.secondary,
                "a modifier is metadata, not a state — it spends no hue",
            )
        }
        for kind: TabBadgeKind in [
            .awaitingInput, .commandBusy, .commandRunning, .completed, .error, .finished, .running,
        ] {
            XCTAssertNil(StatusPresentation.tabBadge(kind), "\(kind) belongs to the status column")
        }
        // The cup is a DUOTONE: its body reads behind the outline, which is the whole reason a
        // Material icon needs two fill layers rather than one.
        XCTAssertEqual(OttyIcon.coffee.fills.count, 2)
        XCTAssertEqual(OttyIcon.coffee.fills.first?.opacity, 0.3)
        XCTAssertEqual(OttyIcon.coffee.fills.last?.opacity, 1)
        XCTAssertTrue(OttyIcon.coffee.outlines.isEmpty, "a filled icon strokes nothing")
    }

    /// The finish's OWNER comes from one shared predicate: a live agent `.done` or the client's
    /// unread latch, and ONLY on a finish badge. The same call gates the row's agent FINAL LINE, so
    /// the row that shows the agent's last words is exactly the row that fills its check — a
    /// command's exit can neither borrow the agent's line nor its weight.
    @MainActor
    func testTheFinishOwnerIsOnePredicateForLineAndMark() {
        for status: ClaudeStatus in [.done, .idle] {
            for unseen in [true, false] {
                let agents = RailRowsBuilder.finishIsAgents(
                    badge: .finished, status: status, unseenDone: unseen,
                )
                XCTAssertEqual(
                    agents, status == .done || unseen,
                    "a live `.done` OR the unread latch owns the finish (\(status), unseen=\(unseen))",
                )
                // Whatever the predicate says, the VOICE must follow it — never diverge: the
                // agent's finish is the check, a command's is the slot's receipt.
                XCTAssertEqual(
                    StatusPresentation.statusDot(
                        working: false, badge: .finished, agentFinish: agents,
                    )?.mark,
                    agents ? .agentFinish : nil,
                )
                XCTAssertEqual(
                    StatusPresentation.commandOutcome(badge: .finished, agentFinish: agents),
                    agents ? nil : .succeeded,
                )
            }
        }
        // A NON-finish badge is never the agent's finish, however done the agent looks — an error or
        // a busy tier must not be read as a completed turn.
        for kind: TabBadgeKind? in [.error, .commandBusy, .awaitingInput, .running, nil] {
            XCTAssertFalse(
                RailRowsBuilder.finishIsAgents(badge: kind, status: .done, unseenDone: true),
                "\(String(describing: kind)) is not a finish badge",
            )
        }
    }

    // MARK: - Geometry

    /// The resting ring is DOTS, and they stand FURTHER APART than the dashes they replaced — the
    /// whole point of the recut (user-directed 2026-08-10). Pinned as a value: shrink the gap and the
    /// mark quietly becomes a dashed ring with short dashes again, which is what it stopped being.
    func testTheRestingRingIsDotsSpacedWiderThanTheDashesItReplaced() {
        let period = CGFloat.pi * StatusDot.ringDiameter / CGFloat(StatusDot.ringDotCount)
        XCTAssertEqual(
            StatusDot.ringDotGap, period - StatusDot.ringDotDiameter, accuracy: 1e-9,
            "the gap is what the dots leave of their own period",
        )
        // The cut it replaced: eight dashes at a 0.6 fill, so the old air was 40% of the period.
        XCTAssertGreaterThan(
            StatusDot.ringDotGap, period * 0.4,
            "dots have to stand further apart than the dashes did, or nothing changed",
        )
        XCTAssertGreaterThan(
            StatusDot.ringDotGap, StatusDot.ringDotDiameter,
            "more air than dot — a ring of PARTS, not a circle with nicks in it",
        )
        // Quieter than the thinking cell, which shares this column: a present agent must never
        // out-weigh a working one.
        XCTAssertLessThan(
            StatusDot.ringDotDiameter, StatusDot.dotDiameter,
            "the resting dot stays smaller than the working cell's",
        )
    }

    /// The dots ride ON the ring's circle at even turns from 12 o'clock, so the mark keeps the
    /// four-fold symmetry that makes eight small shapes read as one circle. Pinned through the
    /// `Shape` itself — the path IS the artwork, and a phase or radius slip draws a plausible ring
    /// that is subtly off its own column.
    func testTheRingDotsSitOnTheCircleStartingAtTwelveOClock() {
        let side = StatusDot.ringDiameter
        let box = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        let bounds = DottedRing().path(in: box).boundingRect
        // Eight dots on a Ø10 circle, each spilling half its width outside it — exactly as the
        // stroke they replaced did, so the ring's visual diameter is unchanged.
        let spread = side + StatusDot.ringDotDiameter
        XCTAssertEqual(bounds.width, spread, accuracy: 0.001, "dots at 3 and 9 o'clock set the width")
        XCTAssertEqual(bounds.height, spread, accuracy: 0.001, "dots at 12 and 6 set the height")
        XCTAssertEqual(bounds.midX, box.midX, accuracy: 0.001, "the ring is centred in its box")
        XCTAssertEqual(bounds.midY, box.midY, accuracy: 0.001, "the ring is centred in its box")
    }

    /// ⚠️ The column is sized to otty's OWN badge box (14pt), and every mark is drawn to fit inside
    /// it. The previous port squeezed these same silhouettes into 8pt and they read as fussy detail
    /// — the fix was the size and the fidelity, not the idea (docs/DECISIONS.md rounds 19–21, 23).
    func testEveryMarkFitsOttysBadgeBox() {
        XCTAssertEqual(StatusDot.footprint, 14, "otty's badge box, undivided")
        XCTAssertEqual(StatusDot.handSide, StatusDot.footprint, "the outlined hand takes the box")
        for size in [StatusDot.finishSymbolSize, StatusDot.badgeSymbolSize] {
            XCTAssertLessThanOrEqual(size, StatusDot.footprint, "a symbol must fit its column")
        }
        XCTAssertLessThanOrEqual(
            StatusDot.ringDiameter + StatusDot.ringDotDiameter, StatusDot.footprint,
            "the ring's dots stay inside the column, so the right edge never wavers",
        )
        // ⚠️ The finish is 13, a point ABOVE otty's own 12 (user-directed 2026-08-10): measured, it
        // was never the smaller mark it read as — a filled disc simply reads smaller than a ring of
        // eight dots the eye counts the air inside. It must stay AHEAD of the ring's outer extent,
        // which is what the reading correction bought, and inside the box, which is checked above.
        XCTAssertEqual(StatusDot.finishSymbolSize, 13)
        XCTAssertGreaterThan(
            StatusDot.finishSymbolSize, StatusDot.ringDiameter + StatusDot.ringDotDiameter,
            "the finish mark reads at least as large as the resting ring it replaces on the row",
        )
        // otty's size for the rest, kept: a filled straight-edged glyph out-weighs a circle at equal
        // point size, so the privilege shield sits a point under the finish's original 12.
        XCTAssertEqual(StatusDot.badgeSymbolSize, 11)
        XCTAssertEqual(StatusDot.symbolWeight, .medium, "otty draws every badge at Medium")
    }

    // MARK: - The one thing that moves (round 23)

    /// The THINKING agent's mark is otty's own: `TabBadge.running` shows a spinning
    /// `NSProgressIndicator` at the row's trailing edge, and so do we. It spends MOTION, not hue —
    /// the rail's colour budget belongs to the states that want the eye, and an agent merely
    /// thinking is answering "is this still alive?", which only movement can answer honestly.
    @MainActor
    func testTheThinkingMarkIsTheSpinner() {
        let thinking = StatusPresentation.statusDot(working: true, badge: nil)
        XCTAssertEqual(thinking?.mark, .working, "otty's answer for this state, and ours")
        XCTAssertNotEqual(
            thinking?.ink, Slate.State.accent, "the accent is no longer the rail's busy voice",
        )
        XCTAssertNotEqual(
            thinking?.mark,
            StatusPresentation.statusDot(working: false, badge: nil, agentIdle: true)?.mark,
            "working and resting must never collapse into one mark",
        )
        XCTAssertEqual(StatusDot.spinnerSide, StatusDot.footprint, "otty lays it out at 14×14")
    }

    /// ⚠️ ONLY the raw-working route moves. `claude` holds the shell's OSC-133 block open for its
    /// whole interactive lifetime, so a busy-means-motion rule would leave every idle agent's row
    /// spinning for HOURS (docs/DECISIONS.md rounds 19, 22, 23) — and a settled rail that twitches is
    /// the exact failure round 19 was reverted for.
    @MainActor
    func testNothingSettledMoves() {
        let still: [(String, StatusDotStyle?)] = [
            ("resting agent", StatusPresentation.statusDot(working: false, badge: nil, agentIdle: true)),
            ("busy shell + agent", StatusPresentation.statusDot(
                working: false, badge: .commandBusy, agentIdle: true,
            )),
            ("question", StatusPresentation.statusDot(working: false, badge: .awaitingInput)),
            ("agent finish", StatusPresentation.statusDot(
                working: false, badge: .finished, agentFinish: true,
            )),
            ("command failure + agent", StatusPresentation.statusDot(
                working: false, badge: .error, agentIdle: true,
            )),
            ("command finish + agent", StatusPresentation.statusDot(
                working: false, badge: .completed, agentIdle: true,
            )),
        ]
        for (name, style) in still {
            XCTAssertNotNil(style, "\(name) still mounts a mark")
            XCTAssertNotEqual(style?.mark, .working, "\(name) must hold absolutely still")
        }
        // The badge-routed agent tier is the SAME reading as raw working — including the motion.
        XCTAssertEqual(StatusPresentation.statusDot(working: false, badge: .running)?.mark, .working)
    }
}
