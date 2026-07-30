// StatusDotTests — pins the trailing status mark. The HUE names the STATE and the SYMBOL names what
// happened, in otty's own badge vocabulary (docs/DECISIONS.md round 23): the SPINNER for a working
// agent, the hand for a waiting question, the filled check for the AGENT's turn ending, the plain
// disc for a background command's clean exit, the alert triangle for a failure, and the dashed ring
// for an agent that is merely present. The resolver's ladder is the spec: a working agent spins (the
// same raw-working key liveness uses, outranking every badge); a RESTING CODE AGENT rings muted; the
// attention states wear their attention ink — the title never recolours, so the mark's hue is those
// states' entire rendering; a plain running command, a bare idle shell and privilege-only rows mount
// nothing. The STATIC contract — exactly ONE mark moves — rides the mark pins.
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

    /// Each attention kind's mark wears EXACTLY its attention ink — with a neutral title, the
    /// mark's hue is the state's whole rendering, so it can never drift off the hue budget
    /// (green unread finish, amber question, red failure). Whichever symbol, the hue is the same one.
    @MainActor
    func testAttentionKindsRingOnTheirAttentionInk() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            let dot = StatusPresentation.statusDot(working: false, badge: kind)
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

    /// An attention state OUTRANKS the resting-agent ring: a finished/blocked/failed agent keeps
    /// its attention ink even though the same pane is also a resting agent.
    @MainActor
    func testAttentionOutranksTheRestingAgentRing() {
        for kind: TabBadgeKind in [.awaitingInput, .error, .completed, .finished] {
            XCTAssertEqual(
                StatusPresentation.statusDot(working: false, badge: kind, agentIdle: true)?.ink,
                StatusPresentation.attentionInk(kind),
                "\(kind) keeps its attention ink over the muted resting ring",
            )
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

    /// ⚠️ The CHECK is the AGENT's turn ending; a background command's clean exit takes the plain
    /// DISC. Both of OUR finish tiers read alike: the `.completed` flash and the settled `.finished`
    /// unread are one reading, since that split is freshness machinery and never visual.
    ///
    /// The two-speaker rule (round 21) is otty's too — it draws its own `completed` as
    /// `checkmark.circle.fill` and its `finished` as an 8pt filled oval. An agent's state is
    /// continuous; a command badge is an unread receipt the store keeps only for an unfocused pane.
    @MainActor
    func testTheAgentsFinishIsACheckAndACommandsIsADisc() {
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
            XCTAssertEqual(
                StatusPresentation.mark(for: kind, agentFinish: false), .commandFinish,
                "\(kind) with no agent finish behind it is a background command's receipt",
            )
            XCTAssertEqual(
                StatusPresentation.statusDot(working: false, badge: kind, agentFinish: false)?.mark,
                .commandFinish,
            )
        }
        // Filling the check must not change what the mark SAYS — one hue budget across both.
        for agents in [true, false] {
            XCTAssertEqual(
                StatusPresentation.statusDot(
                    working: false, badge: .finished, agentFinish: agents,
                )?.ink,
                StatusPresentation.attentionInk(.finished),
                "the speaker changes the weight, never the hue",
            )
        }
    }

    /// A failure is ALWAYS the alert triangle, whoever else is in the pane: `.error` can only come
    /// from a non-zero exit or a held-red `OSC 9;4;2` — `ClaudeStatus` has no error case, so the
    /// agent never speaks red.
    @MainActor
    func testAFailureIsAlwaysTheAlertTriangle() {
        for agents in [true, false] {
            XCTAssertEqual(
                StatusPresentation.mark(for: .error, agentFinish: agents), .failure,
                "a non-zero exit is a COMMAND's fact even in an agent pane",
            )
        }
        let dot = StatusPresentation.statusDot(working: false, badge: .error)
        XCTAssertEqual(dot?.mark, .failure)
        XCTAssertEqual(dot?.ink, StatusPresentation.attentionInk(.error))
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
                // Whatever the predicate says, the mark must follow it — never diverge.
                XCTAssertEqual(
                    StatusPresentation.statusDot(
                        working: false, badge: .finished, agentFinish: agents,
                    )?.mark,
                    agents ? .agentFinish : .commandFinish,
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

    /// ⚠️ A command's OUTCOME empties the slot beside it: the disc or the triangle is the row's whole
    /// news, and `make` / `swift` printed next to it is what WAS running, in the past tense, on a row
    /// whose title already says it. Everything still LIVE keeps its label — a running command's name
    /// is current information.
    @MainActor
    func testACommandsOutcomeEmptiesTheSlotBesideIt() {
        for kind: TabBadgeKind in [.error, .completed, .finished] {
            XCTAssertTrue(
                StatusPresentation.markSpeaksForTheSlot(
                    StatusPresentation.statusDot(working: false, badge: kind, agentFinish: false),
                ),
                "\(kind) as a command's receipt says everything the process name would",
            )
        }
        // Live states keep the label: a busy shell, a running command, a thinking or resting agent.
        let live: [StatusDotStyle?] = [
            StatusPresentation.statusDot(working: true, badge: nil),
            StatusPresentation.statusDot(working: false, badge: .commandBusy, agentIdle: true),
            StatusPresentation.statusDot(working: false, badge: nil, agentIdle: true),
            StatusPresentation.statusDot(working: false, badge: .awaitingInput),
            StatusPresentation.statusDot(working: false, badge: .commandRunning),
        ]
        for style in live {
            XCTAssertFalse(
                StatusPresentation.markSpeaksForTheSlot(style),
                "a live row's process name is current information",
            )
        }
        // The AGENT's finish is not a command's — its row never carried a process label anyway, and
        // suppressing one there would be a rule about the wrong speaker.
        XCTAssertFalse(
            StatusPresentation.markSpeaksForTheSlot(
                StatusPresentation.statusDot(working: false, badge: .finished, agentFinish: true),
            ),
        )
    }

    // MARK: - Geometry

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

    /// ⚠️ The column is sized to otty's OWN badge box (14pt), and every mark is drawn to fit inside
    /// it. The previous port squeezed these same silhouettes into 8pt and they read as fussy detail
    /// — the fix was the size and the fidelity, not the idea (docs/DECISIONS.md rounds 19–21, 23).
    func testEveryMarkFitsOttysBadgeBox() {
        XCTAssertEqual(StatusDot.footprint, 14, "otty's badge box, undivided")
        XCTAssertEqual(StatusDot.handSide, StatusDot.footprint, "the outlined hand takes the box")
        for size in [StatusDot.finishSymbolSize, StatusDot.alertSymbolSize] {
            XCTAssertLessThanOrEqual(size, StatusDot.footprint, "a symbol must fit its column")
        }
        XCTAssertLessThanOrEqual(
            StatusDot.ringDiameter + StatusDot.ringLineWidth, StatusDot.footprint,
            "the ring's stroke stays inside the column, so the right edge never wavers",
        )
        // otty configures its own badges at these exact sizes: the finish a point larger than the
        // alert, because a filled triangle out-weighs a circle at equal point size.
        XCTAssertEqual(StatusDot.finishSymbolSize, 12)
        XCTAssertEqual(StatusDot.alertSymbolSize, 11)
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
            ("command failure", StatusPresentation.statusDot(working: false, badge: .error)),
            ("command finish", StatusPresentation.statusDot(working: false, badge: .completed)),
        ]
        for (name, style) in still {
            XCTAssertNotNil(style, "\(name) still mounts a mark")
            XCTAssertNotEqual(style?.mark, .working, "\(name) must hold absolutely still")
        }
        // The badge-routed agent tier is the SAME reading as raw working — including the motion.
        XCTAssertEqual(StatusPresentation.statusDot(working: false, badge: .running)?.mark, .working)
    }
}
