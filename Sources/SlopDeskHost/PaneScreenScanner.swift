import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect
import SlopDeskArena
import SlopDeskScreen

/// One pane's screen-detection pipeline: the socket to `slopdesk-screend`, and nothing else.
///
/// ## Neither half of this is hostd's judgement any more
/// The grid, the OSC tracker, the synchronized-frame parser and the manifest rule ladder are
/// `rust/slopdesk-screend`, reached by one `detect` verb per tick. The TEMPORAL layer — the startup
/// grace, the idle-scan skip, the working→idle hold, the visible-blocker heartbeat, the cap on an
/// open synchronized frame — is `rust/slopdesk-agent`'s `panescan`, reached by the two doors below.
/// The old split, "screend owns everything that reads the BYTES and hostd owns everything that
/// reads the CLOCK", is unchanged; what changed is that the clock half is no longer written twice
/// over, once here and once in a crate.
///
/// What is left in this file is the one thing that genuinely is this process's: it holds the screend
/// connection, so it makes the call.
///
/// ## The tick is TWO door calls around ONE exchange
/// `plan` folds the tick's timing facts and says whether the exchange is worth making and with which
/// flags; the exchange happens here; `finish` takes the outcome and says what to publish. Nothing is
/// remembered on this side between the two — the handle holds all of it — so there is no scan state
/// in Swift to drift.
///
/// ## Absent screend costs this pane its screen tier, and nothing else
/// A failed exchange is reported as such and publishes NOTHING — not idle, not the previous verdict.
/// Hook and ctl `report` evidence is authoritative anyway (`docs/50`) and never passes through here.
/// Only the scan task calls ``scan(_:)``.
struct PaneScreenScanner {
    /// The scan state, in Rust, for exactly as long as this scanner lives.
    ///
    /// A class rather than a stored pointer for the reason `docs/55` §4b gives: a struct holding a
    /// raw handle frees it once per COPY, and the one owner here (``MuxChannelSession``) resets its
    /// scanner by assignment. The box makes the free the box's.
    private final class Handle {
        let pointer: OpaquePointer

        init() {
            guard let pointer = slopdesk_pane_scan_new() else {
                // A scanner is a few counters; a failure here is the allocator being gone, and a
                // pane with no scanner would flap rather than fail quietly.
                preconditionFailure("slopdesk_pane_scan_new returned null")
            }
            self.pointer = pointer
        }

        deinit { slopdesk_pane_scan_free(pointer) }
    }

    /// This pane's key in screend's registry. Distinct per scanner, never reused across panes.
    private let paneKey: String
    private let screen: ScreenClient
    private let state = Handle()

    /// Ceiling on how long an open synchronized frame may suppress publishing, as the state machine
    /// spells it. A frame is one repaint — milliseconds — so any frame still open a second later is
    /// a program that died mid-paint, and detection must not be frozen by it.
    static var syncFrameHoldCap: TimeInterval { slopdesk_pane_scan_sync_frame_cap() }

    /// The key defaults to a fresh identity, which is all it has to be: screend's registry is a
    /// CACHE, not durable state — a key nobody holds is evicted, and a grid that goes missing is
    /// rebuilt from the pane's ring on the next tick. It deliberately does NOT reuse the pane id: a
    /// scanner's grid is private to the scanner, and two scanners sharing a key would fold one
    /// model two streams.
    init(paneKey: String = UUID().uuidString, screen: ScreenClient = .shared) {
        self.paneKey = paneKey
        self.screen = screen
    }

    /// Drops the pane's grid and trackers from screend. Called when the pane goes; best-effort,
    /// because screend evicts on its own when the table fills.
    func release() {
        screen.forget(pane: paneKey)
    }

    struct Input {
        /// PTY output bytes accumulated since the last scan (empty when quiet).
        var pending: Data
        /// Non-nil = the model is stale (resize / overflow / first scan): rebuild the grid at
        /// `rows`×`cols` and replay these bytes (the scrollback ring — full-screen apps repaint,
        /// so a mid-ring start converges, the same property the `screen` verb relies on).
        var rebuildReplay: Data?
        var rows: Int
        var cols: Int
        /// The identified foreground agent, or `nil` (plain shell / unknown program).
        var agent: AgentKind?
        /// Monotonic content sequence — bumped per non-empty PTY chunk (the idle-scan skip).
        var contentSeq: UInt64
        var now: TimeInterval
    }

    struct Output: Equatable {
        /// A detection worth folding into the pane's status machine, or `nil`.
        var publish: AgentScreenDetection?
        /// Seconds until the next scan (tightens to 100 ms while an idle hold is pending).
        var nextInterval: TimeInterval
    }

    mutating func scan(_ input: Input) -> Output {
        let plan = plan(input)
        var verdict = SlopDeskScanVerdict()
        var outcome: UInt8 = 0
        var labels: (rule: String?, fallback: String?) = (nil, nil)
        if plan.exchange {
            var payload = input.rebuildReplay ?? Data()
            payload.append(input.pending)
            do {
                let reply = try screen.detect(
                    pane: paneKey,
                    agent: plan.label_suppressed ? "" : input.agent?.label ?? "",
                    raw: payload,
                    rows: input.rows,
                    cols: input.cols,
                    reset: plan.reset,
                    rebuildReplay: input.rebuildReplay != nil,
                    agentChanged: plan.agent_changed,
                )
                let detection = AgentScreenDetection(reply)
                outcome = 1
                verdict = SlopDeskScanVerdict(
                    detection: detection.crossing,
                    frame_open: reply.frameOpen,
                    frame_generation: reply.frameGeneration,
                )
                labels = (detection.matchedRuleID, detection.fallbackReason)
            } catch {
                outcome = 2
            }
        }
        return finish(outcome: outcome, verdict: verdict, labels: labels)
    }

    /// The first door: what to ask screend this tick.
    private func plan(_ input: Input) -> SlopDeskScanPlan {
        var tick = SlopDeskScanTick(
            payload_empty: input.pending.isEmpty && (input.rebuildReplay?.isEmpty ?? true),
            rebuild_replay: input.rebuildReplay != nil,
            rows: UInt16(truncatingIfNeeded: input.rows),
            cols: UInt16(truncatingIfNeeded: input.cols),
            content_seq: input.contentSeq,
            now: input.now,
        )
        var plan = SlopDeskScanPlan()
        ffiLend(input.agent?.label ?? "") { bytes in
            slopdesk_pane_scan_plan(
                state.pointer, &tick, bytes.baseAddress, bytes.count, input.agent != nil, &plan,
            )
        }
        return plan
    }

    /// The second door: the exchange's outcome in, the tick's answer out.
    ///
    /// The two labels go over on every answered exchange and come back only on a publish — the
    /// state machine caches them so this side does not have to mirror the three places its own
    /// cache is cleared.
    private func finish(
        outcome: UInt8, verdict: SlopDeskScanVerdict, labels: (rule: String?, fallback: String?),
    ) -> Output {
        var verdict = verdict
        var answer = SlopDeskScanAnswer()
        ffiLend(labels.rule ?? "") { ruleBytes in
            ffiLend(labels.fallback ?? "") { fallbackBytes in
                slopdesk_pane_scan_finish(
                    state.pointer, outcome, &verdict,
                    ruleBytes.baseAddress, ruleBytes.count, labels.rule != nil,
                    fallbackBytes.baseAddress, fallbackBytes.count, labels.fallback != nil,
                    &answer,
                )
            }
        }
        guard answer.publish else { return Output(publish: nil, nextInterval: answer.next_interval) }
        let published = publishedLabels(answer)
        return Output(
            publish: AgentScreenDetection(
                answer.detection,
                matchedRuleID: answer.has_rule ? published.rule : nil,
                fallbackReason: answer.has_fallback ? published.fallback : nil,
            ),
            nextInterval: answer.next_interval,
        )
    }

    /// The published verdict's two labels, split at ``SlopDeskScanAnswer/rule_len``. A pure read of
    /// the handle, so the §4 retry is safe: asking twice cannot advance a tick.
    private func publishedLabels(_ answer: SlopDeskScanAnswer) -> (rule: String, fallback: String) {
        let buffer = ffiAnswerBytes(capacity: 256) { out, cap in
            slopdesk_pane_scan_published_labels(state.pointer, out, cap)
        }
        guard answer.rule_len <= buffer.count else { return ("", "") }
        // swiftlint:disable optional_data_string_conversion
        let rule = String(decoding: buffer[..<answer.rule_len], as: UTF8.self)
        let fallback = String(decoding: buffer[answer.rule_len...], as: UTF8.self)
        // swiftlint:enable optional_data_string_conversion
        return (rule, fallback)
    }
}

extension AgentScreenDetection {
    /// The wire verdict in the terms the status machine speaks.
    ///
    /// An unrecognised state label decodes to `unknown` rather than throwing: the two ends ship
    /// together, so this cannot happen, and if it somehow did then "I do not know" is the honest
    /// answer and a thrown error would cost the pane its screen tier over a spelling.
    init(_ verdict: ScreenDetection) {
        self.init(
            state: AgentScreenState(rawValue: verdict.state) ?? .unknown,
            skipStateUpdate: verdict.skipStateUpdate,
            visibleIdle: verdict.visibleIdle,
            visibleBlocker: verdict.visibleBlocker,
            visibleWorking: verdict.visibleWorking,
            matchedRuleID: verdict.matchedRuleId,
            fallbackReason: verdict.fallbackReason,
        )
    }
}

private extension AgentScreenDetection {
    /// The same verdict in the shape the temporal layer compares, with the two LABELS left behind:
    /// they are diagnostics, they can be long, and the door carries them on their own so a tick
    /// that publishes nothing pays nothing for them.
    init(
        _ crossing: SlopDeskAgentDetection, matchedRuleID: String?, fallbackReason: String?,
    ) {
        self.init(
            state: AgentScreenState(byte: crossing.state),
            skipStateUpdate: crossing.skip_state_update,
            visibleIdle: crossing.visible_idle,
            visibleBlocker: crossing.visible_blocker,
            visibleWorking: crossing.visible_working,
            matchedRuleID: matchedRuleID,
            fallbackReason: fallbackReason,
        )
    }

    /// This verdict as the door's five fields. The inverse of the initializer above.
    var crossing: SlopDeskAgentDetection {
        SlopDeskAgentDetection(
            state: state.crossing,
            skip_state_update: skipStateUpdate,
            visible_idle: visibleIdle,
            visible_blocker: visibleBlocker,
            visible_working: visibleWorking,
        )
    }
}

private extension AgentScreenState {
    /// The discriminant this state crosses as — screend answers a NAME, the door speaks a byte.
    var crossing: UInt8 {
        switch self {
        case .idle: 0
        case .working: 1
        case .blocked: 2
        case .unknown: 3
        }
    }

    /// The inverse, in the order the door documents. An unknown byte is `unknown`, for the reason
    /// an unknown NAME is: the two ends ship together, and a spelling must not cost a screen tier.
    init(byte: UInt8) {
        self =
            switch byte {
            case 0: .idle
            case 1: .working
            case 2: .blocked
            default: .unknown
            }
    }
}
