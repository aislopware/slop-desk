import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The SINGLE per-pane ``ClaudePaneDetector`` is the host's one source of truth.
///
/// These tests drive the ONE detector with the full mix of inputs the live ``MuxChannelSession`` feeds it
/// — the foreground poll's `sample`, the per-poll `tick`, and the hook socket's `hook(bytes:)` — and
/// assert (a) the `.done→.idle` decay is now DRIVEN by ticks, (b) a presence flap can't clobber a hook
/// block, (c) the host's emitted type-27 `state` byte maps to EXACTLY the host's machine status on the
/// client (no divergence — the client just calls `ClaudeStatus(urgency:)`), and (d) a `claude`-prefixed
/// process name is NOT treated as claude (exact basename) and emits NO status churn (no inspector flap).
///
/// Pure + headless: the detector is value-in/value-out (no PTY/socket/syscall — the `PTYForegroundProbe`
/// and `UnixSocketAcceptor` shims are compiled + code-reviewed only). The clock is injected.
final class ClaudePaneDetectorTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// The EXACT client mapping (`LivePaneSession.feedAgentSignal` calls this on the type-27 `state`
    /// byte). Asserting against it proves host/client agreement without a cross-module import.
    private func clientStatus(forStateByte state: UInt8) -> ClaudeStatus {
        ClaudeStatus(urgency: Int(state))
    }

    /// Pulls the `(state)` byte out of an emitted type-27 message, failing if it is not a `claudeStatus`.
    private func stateByte(_ message: WireMessage?, _ file: StaticString = #filePath, _ line: UInt = #line) -> UInt8? {
        guard case let .claudeStatus(state, _, _)? = message else {
            if message != nil { XCTFail("expected a claudeStatus type-27, got \(message!)", file: file, line: line) }
            return nil
        }
        return state
    }

    // MARK: - (a) Decay is DRIVEN by ticks (the host emits a type-27 `.idle` after the timeout)

    /// A Stop hook puts the machine in `.done`; with NO further hook (the Stop hook fired and stopped),
    /// only TICKS advance time — and a tick past the timeout must emit a type-27 `.idle`. Without ticks
    /// advancing the host machine, a finished turn would stay `.done` (🔵) forever.
    func testStopThenOnlyTicksEmitsIdleAfterTimeout() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        // Hook: Stop → done. (No foreground sample needed — the hook drives presence-independent status.)
        let stop = d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#), at: 0)
        XCTAssertEqual(stateByte(stop.status), 2, "Stop → done (urgency 2)")
        XCTAssertEqual(d.status, .done)

        // A tick BEFORE the timeout changes nothing (dedupe — still done).
        let early = d.tick(at: 4)
        XCTAssertNil(early.status, "still done before the timeout — no new type-27")

        // A tick AT/AFTER the timeout decays to idle and EMITS the type-27 (the host pushes the decay).
        let decayed = d.tick(at: 6)
        XCTAssertEqual(d.status, .idle, "the decay fired — driven by the tick")
        XCTAssertEqual(stateByte(decayed.status), 1, "host emits type-27 idle (urgency 1) on the decay")
    }

    // MARK: - (b) A presence re-sample does NOT clobber a hook-set `.needsPermission`

    /// The review-#3 flap (a child process taking the PTY) is defended on the CLIENT (a type-26 edge is
    /// display-only there — see `ClaudeStatusWiringTests`). On the HOST, the realistic in-turn case is a
    /// hook block followed by a CONTINUED claude presence (the kernel keeps reporting `claude` for a
    /// claude turn) plus the 1 Hz tick — the block must SURVIVE: presence is a floor that never
    /// downgrades a richer hook status, and a redundant `sample("claude")` must not knock it back to idle.
    func testContinuedClaudePresenceKeepsHookBlock() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"Notification","message":"needs your permission"}"#), at: 1)
        XCTAssertEqual(d.status, .needsPermission)
        // The 1 Hz poll re-reads `claude` (+ a tick) — presence is a floor, it must NOT downgrade.
        _ = d.tick(at: 2)
        let resample = d.sample(name: "claude", at: 2)
        XCTAssertEqual(d.status, .needsPermission, "a redundant claude presence must not clear the hook block")
        XCTAssertNil(resample.status, "no status change → no type-27 churn (dedupe)")
    }

    // MARK: - (c) The client status EQUALS the host's type-27 verdict (no divergence)

    /// For a representative signal sequence, every host-emitted type-27 `state` byte maps (via the EXACT
    /// client mapping `ClaudeStatus(urgency:)`) back to the host machine's OWN status — proving the client
    /// (a passive display) can never diverge from the host's verdict.
    func testEmittedStateByteMatchesHostStatusForClient() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        func assertAgrees(_ e: ClaudePaneDetector.Emission, _ file: StaticString = #filePath, _ line: UInt = #line) {
            guard let state = stateByte(e.status) else { return } // deduped → no frame, nothing to compare
            XCTAssertEqual(
                clientStatus(forStateByte: state), d.status,
                "the client maps the emitted byte to the host's own status (no divergence)",
                file: file, line: line,
            )
        }
        assertAgrees(d.sample(name: "claude", at: 0)) // → idle
        assertAgrees(d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 1)) // → working
        assertAgrees(d.hook(
            bytes: json(#"{"hook_event_name":"Notification","message":"needs your permission"}"#),
            at: 2,
        ))
        assertAgrees(d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"done"}"#), at: 3))
        assertAgrees(d.tick(at: 9)) // decay → idle
        assertAgrees(d.sample(name: "zsh", at: 10)) // claude gone → none
    }

    // MARK: - (d) `claude-monitor` / `myclaudewrapper` is NOT claude (exact basename, no flap)

    /// A process whose name merely CONTAINS "claude" (`claude-monitor`, `myclaudewrapper`) is NOT claude
    /// (exact basename match). The host status stays `.none`, the client (mapping byte 0) agrees, and
    /// because the status never lifts off `.none` there is no type-27 churn that would flap the inspector.
    func testClaudePrefixedProcessIsNotClaudeNoInspectorFlap() {
        for name in ["claude-monitor", "myclaudewrapper", "/usr/local/bin/claude-monitor"] {
            var d = ClaudePaneDetector()
            let e = d.sample(name: name, at: 0)
            XCTAssertEqual(d.status, .none, "\(name) must not be treated as claude (exact basename)")
            // The first sample emits the anchor type-27 (none); the client maps byte 0 → .none (agreement).
            if let state = stateByte(e.status) {
                XCTAssertEqual(state, 0)
                XCTAssertEqual(clientStatus(forStateByte: state), .none, "host + client agree it is not claude")
            }
            // A second identical sample emits NO further type-27 → no inspector flap on the client.
            let again = d.sample(name: name, at: 1)
            XCTAssertNil(again.status, "an unchanged non-claude name does not churn type-27 (no inspector flap)")
        }
    }

    // MARK: - Dedupe is COUNTED, not just nil-checked

    /// A genuine dedupe assertion: COUNT the type-27 frames emitted across a stream that repeats the same
    /// status, and assert exactly one frame ships per DISTINCT `(state,kind,label)` triple. With the
    /// dedupe guard removed, every fold would emit a frame (the count would balloon) — so this fails
    /// loudly if the guard regresses, unlike a single `XCTAssertNil` on one repeat.
    func testRepeatedIdenticalStatusEmitsExactlyOneType27() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        var emittedStates: [UInt8] = []
        func feedHook(_ json: String, at t: TimeInterval) {
            if let s = stateByte(d.hook(bytes: self.json(json), at: t).status) { emittedStates.append(s) }
        }
        func feedTick(at t: TimeInterval) {
            if let s = stateByte(d.tick(at: t).status) { emittedStates.append(s) }
        }
        // working ×3 (2 dups), block ×2 (1 dup), then idle on decay; plus quiet ticks that change nothing.
        feedHook(#"{"hook_event_name":"UserPromptSubmit"}"#, at: 0) // working
        feedHook(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#, at: 1) // working (dup triple)
        feedTick(at: 2) // no change → no frame
        feedHook(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#, at: 3) // working (dup triple)
        feedHook(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#, at: 4) // done
        feedTick(at: 5) // no change yet (timeout is 5 from t=4 → not due)
        feedTick(at: 9) // decay → idle
        feedTick(at: 10) // idle, no change → no frame

        XCTAssertEqual(
            emittedStates, [3, 2, 1],
            "exactly one type-27 per distinct status (working 3, done 2, idle 1) — repeats + quiet ticks deduped",
        )
    }

    // MARK: - type-26 is a basename edge only (a display hint, not a status source)

    /// type-26 (`foregroundProcess`) fires only on a basename EDGE and is independent of the type-27
    /// status stream — a coarse display hint, never a second status source.
    func testType26IsBasenameEdgeOnly() {
        var d = ClaudePaneDetector()
        let first = d.sample(name: "zsh", at: 0)
        XCTAssertEqual(first.foreground, .foregroundProcess(name: "zsh"), "first sample emits the basename")
        let same = d.sample(name: "zsh", at: 1)
        XCTAssertNil(same.foreground, "an unchanged basename does not re-emit type-26 (dedupe)")
        let edge = d.sample(name: "claude", at: 2)
        XCTAssertEqual(edge.foreground, .foregroundProcess(name: "claude"), "a basename change re-emits type-26")
    }

    // MARK: - Agent self-report folds as an authoritative hook

    /// A self-report `working`/`blocked`/`done`/`idle` maps to the same machine verdict an
    /// equivalent real hook would. Each is precedence-2 (authoritative), so it beats the bare
    /// foreground-process presence FLOOR (which only lifts `.none → .idle`).
    func testReportWorkingBlockedDoneIdle() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0) // presence floor = idle

        let working = d.report(state: "working", message: nil, at: 1)
        XCTAssertEqual(d.status, .working)
        XCTAssertEqual(stateByte(working.status), 3, "working → urgency 3")

        let blocked = d.report(state: "blocked", message: "approve?", at: 2)
        XCTAssertEqual(d.status, .needsPermission)
        XCTAssertEqual(stateByte(blocked.status), 4, "blocked → needsPermission urgency 4")

        let done = d.report(state: "done", message: "all set", at: 3)
        XCTAssertEqual(d.status, .done)
        XCTAssertEqual(stateByte(done.status), 2, "done → urgency 2")

        let idle = d.report(state: "idle", message: nil, at: 4)
        XCTAssertEqual(d.status, .idle)
        XCTAssertEqual(stateByte(idle.status), 1, "idle → urgency 1")
    }

    // MARK: - Pane keystrokes unblock (the Esc-cancel edge)

    /// A user keystroke into a BLOCKED pane emits the type-27 idle demotion (state 1, kind 0):
    /// Esc-cancel fires no Stop hook and the rest title already shows while the dialog is up, so
    /// the keystroke is the only host-visible signal that the modal is being handled. An answered
    /// dialog re-promotes via its own PreToolUse right after.
    func testUserKeystrokeDemotesABlockedPane() {
        var d = ClaudePaneDetector()
        let blocked = d.hook(
            bytes: json(
                #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}"#,
            ),
            at: 0,
        )
        XCTAssertEqual(stateByte(blocked.status), 4)

        let demoted = d.userInput(bytes: Data([0x1B]), at: 1) // the Esc key (legacy encoding)
        XCTAssertEqual(d.status, .idle, "Esc into the blocked pane → the block is being handled")
        guard case let .claudeStatus(state, kind, label)? = demoted.status else {
            XCTFail("expected a type-27 demotion, got \(String(describing: demoted.status))")
            return
        }
        XCTAssertEqual(state, 1, "idle urgency")
        // ⚠️ QUIET, not 0 (2026-08-11). The stale notification kind does die with the block — but
        // `needsPermission → idle` is the hook-less COMPLETION shape, so an un-qualified frame here
        // announced a finished turn (badge, banner, sound) to the very person who had just pressed
        // Esc. The kind byte is how the host says "display this, do not announce it".
        XCTAssertEqual(kind, AgentStatusKind.quiet.rawValue, "a dismissal is bookkeeping, not a finish")
        XCTAssertEqual(label, "", "the blocking question dies with the block")
    }

    /// Merely VISITING a blocked pane sends a focus-in report down the same input path — that is
    /// reading, not answering, and must leave the hand up. Same for a mouse-wheel scroll.
    func testFocusReportsAndScrollDoNotUnblock() {
        var d = ClaudePaneDetector()
        _ = d.hook(
            bytes: json(
                #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow?"}"#,
            ),
            at: 0,
        )
        let focusIn = d.userInput(bytes: Data("\u{1B}[I".utf8), at: 1)
        XCTAssertNil(focusIn.status, "focus-in is not a keystroke — no frame")
        let wheel = d.userInput(bytes: Data("\u{1B}[<64;10;10M".utf8), at: 2)
        XCTAssertNil(wheel.status, "scrolling the transcript is reading, not answering")
        XCTAssertEqual(d.status, .needsPermission, "the block stands until a real key arrives")
    }

    /// The narrowing to CANCEL keys (user-reported 2026-08-10). An `AskUserQuestion` is a block, and
    /// arrowing between its options — or hovering one, which floods X10 mouse motion down the same
    /// input path — used to demote the block; the still-visible dialog then re-raised it, so the
    /// awaiting-input cue rang again on every keypress and every pointer move. Only Esc / Ctrl-C may
    /// unblock: every other resolution announces itself through its own hook.
    func testOnlyCancelKeysUnblockAnAskUserQuestion() {
        var d = ClaudePaneDetector()
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#),
            at: 0,
        )
        XCTAssertEqual(d.status, .needsPermission, "AskUserQuestion blocks on the human")

        var t = 1.0
        // Navigating the options, and hovering one (X10 mouse: `CSI M` + three position bytes).
        for chunk in [
            Data("\u{1B}[A".utf8),
            Data("\u{1B}[B".utf8),
            Data("\u{1B}[13u".utf8),
            Data([0x1B, 0x5B, 0x4D, 32, 33, 33]),
            Data("y".utf8),
        ] {
            XCTAssertNil(d.userInput(bytes: chunk, at: t).status, "\(Array(chunk)) must emit nothing")
            XCTAssertEqual(d.status, .needsPermission, "the hand stays up")
            t += 1
        }
        // kitty's Esc — what Claude Code's own keyboard mode actually sends — DOES unblock.
        XCTAssertEqual(stateByte(d.userInput(bytes: Data("\u{1B}[27u".utf8), at: t).status), 1, "Esc cancels")
        XCTAssertEqual(d.status, .idle)
    }

    // MARK: - Compaction (the `/compact` announces-done regression)

    /// A `/compact` ends with a `Stop` like any turn. Before the `PreCompact` marker that minted
    /// `.done` and rang the finished-turn cue for housekeeping the user ran themselves. Now the turn
    /// lands on `.idle`, carried with the QUIET kind byte so the client — for whom `.working → .idle`
    /// is itself the hook-less completion edge — knows not to re-announce it.
    func testCompactionEmitsAQuietIdleNotADone() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit","prompt":"/compact"}"#), at: 0)
        XCTAssertEqual(d.status, .working)
        let compacting = d.hook(bytes: json(#"{"hook_event_name":"PreCompact","trigger":"manual"}"#), at: 1)
        XCTAssertNil(compacting.status, "a compaction starting is not a status of its own")

        let ended = d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"old"}"#), at: 2)
        guard case let .claudeStatus(state, kind, label)? = ended.status else {
            XCTFail("expected a type-27, got \(String(describing: ended.status))")
            return
        }
        XCTAssertEqual(state, 1, "idle, NOT done (2)")
        XCTAssertEqual(kind, AgentStatusKind.quiet.rawValue, "…and marked as bookkeeping for the client")
        XCTAssertEqual(label, "", "the pre-compaction assistant line is stale news")
    }

    /// The next REAL turn after a compaction still announces normally — the marker is a one-shot,
    /// and the quiet byte dies with the status it qualified.
    func testTurnAfterACompactionIsAnnouncedNormally() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"PreCompact","trigger":"auto"}"#), at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit","prompt":"ship it"}"#), at: 1)
        let done = d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"shipped"}"#), at: 2)
        guard case let .claudeStatus(state, kind, label)? = done.status else {
            XCTFail("expected a type-27, got \(String(describing: done.status))")
            return
        }
        XCTAssertEqual(state, 2, "a genuine done")
        XCTAssertEqual(kind, 0, "announceable")
        XCTAssertEqual(label, "shipped")
    }

    /// Keystrokes while NOT blocked never touch the machine (typing a prompt, a queued message
    /// mid-turn) — the unblock signal is scoped to exactly the modal-dialog state.
    func testKeystrokesOutsideABlockAreIgnored() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit","prompt":"do the thing"}"#), at: 0)
        XCTAssertEqual(d.status, .working)
        let typed = d.userInput(bytes: Data("more context\r".utf8), at: 1)
        XCTAssertNil(typed.status, "typing mid-turn emits nothing")
        XCTAssertEqual(d.status, .working, "the working state is untouched")
    }

    /// Self-report beats the foreground heuristic: with NO claude present (presence would force
    /// `.none`), a `working` report still lifts the status — the authoritative hook fold wins.
    func testReportBeatsForegroundFloor() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "zsh", at: 0) // not claude → status .none
        XCTAssertEqual(d.status, .none)
        _ = d.report(state: "working", message: nil, at: 1)
        XCTAssertEqual(d.status, .working, "the self-report is authoritative; presence floor cannot override it")
    }

    /// An unknown report state is a no-op (validate-then-drop) — no emission, no status change.
    func testReportUnknownStateIsNoOp() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let before = d.status
        let e = d.report(state: "frobnicating", message: nil, at: 1)
        XCTAssertNil(e.status, "unknown state emits nothing")
        XCTAssertEqual(d.status, before, "unknown state does not change the machine")
    }

    /// A self-report is STICKY against the ~1 Hz foreground poll: after `report(working)`, a
    /// following `tick` + `sample(name: non-claude)` (the supervised case — a custom orchestrator /
    /// node-wrapped CLI whose basename is NOT `claude`) must NOT wipe the reported state for the
    /// grace window. Without the stickiness floor, `sample`'s `processPresent(false)` terminates the
    /// machine ~1s after the report, fanning a spurious working→idle/none. This FAILS on the
    /// pre-fix code (the report is wiped on the very next poll).
    func testReportStickyAgainstForegroundAbsence() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "node", at: 0) // a non-claude wrapper → status .none
        XCTAssertEqual(d.status, .none)
        _ = d.report(state: "working", message: nil, at: 1)
        XCTAssertEqual(d.status, .working, "the self-report lifts the status")

        // The very next foreground poll (~1s later): a tick + a non-claude sample. Pre-fix this
        // terminated the machine; with the stickiness floor the reported state survives.
        _ = d.tick(at: 2)
        let resample = d.sample(name: "node", at: 2)
        XCTAssertEqual(d.status, .working, "a non-claude presence-absence must not wipe a recent self-report")
        XCTAssertNil(resample.status, "no transition → no spurious type-27 churn")

        // Several more polls within the grace window keep it sticky.
        _ = d.sample(name: "node", at: 10)
        XCTAssertEqual(d.status, .working, "still sticky well inside the grace window")
    }

    /// The stickiness floor LAPSES: once the grace window elapses with the agent still absent
    /// (genuinely exited — the SHELL is back in the foreground), a foreground-absence sample DOES
    /// terminate — a stale report does not pin the pane forever. Complements
    /// ``testReportStickyAgainstForegroundAbsence``. The basename here must be a NON-wrapper — a
    /// wrapper basename like `node` deliberately stays sticky beyond the window (bounded by the
    /// longer suppression window) while a hook/report-established status is live, see
    /// ``testWrapperAbsenceBeyondGraceWindowKeepsHookStatusWithinSuppressionWindow``.
    func testReportStickinessLapsesAfterGraceWindow() {
        var d = ClaudePaneDetector()
        _ = d.report(state: "working", message: nil, at: 0)
        XCTAssertEqual(d.status, .working)
        // A sample PAST the grace window with the shell back in the foreground → the agent really
        // left → terminate.
        let late = ClaudePaneDetector.reportGraceWindow + 1
        let e = d.sample(name: "zsh", at: late)
        XCTAssertEqual(d.status, .none, "after the grace window a non-wrapper absence terminates as before")
        XCTAssertNotNil(e.status, "the termination emits a type-27 transition")
    }

    // MARK: - Queue-safety: HOOK events get the same stickiness a ctl report has

    /// A real HOOK event must stamp the stickiness window exactly like a ctl self-report: with claude
    /// running under a wrapper (npm-installed `claude` is a `#!/usr/bin/env node` shebang → the PTY
    /// foreground basename is `node`), a `UserPromptSubmit` hook sets `.working`, and the very next
    /// ~1 Hz foreground poll (`tick` + `sample("node")`) must NOT terminate it. REVERT-TO-CONFIRM-FAIL:
    /// pre-fix only `report(...)` stamped `lastReportAt`, so the poll wiped the hook status ~1 s later
    /// (status flapped none↔working every second; a `.needsPermission` vanished before the user saw it).
    func testHookStatusStickyAgainstWrapperForegroundPoll() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "node", at: 0) // wrapper-launched claude → basename is never "claude"
        XCTAssertEqual(d.status, .none)
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 1)
        XCTAssertEqual(d.status, .working, "the hook is authoritative")

        // The next foreground poll (~1 s later): a tick + the wrapper basename (absence).
        _ = d.tick(at: 2)
        let resample = d.sample(name: "node", at: 2)
        XCTAssertEqual(d.status, .working, "a wrapper-basename absence must not wipe a fresh hook status")
        XCTAssertNil(resample.status, "no transition → no type-27 flap")
    }

    /// A hook-set `.needsPermission` (the supervision alert) survives the wrapper foreground poll —
    /// the exact lost-notification symptom: pre-fix the next poll tick wiped the blocked state (and its
    /// attention badge) within a second.
    func testHookNeedsPermissionSurvivesWrapperForegroundPoll() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "node", at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"Notification","message":"needs your permission"}"#), at: 1)
        XCTAssertEqual(d.status, .needsPermission)
        _ = d.tick(at: 2)
        _ = d.sample(name: "node", at: 2)
        XCTAssertEqual(d.status, .needsPermission, "the blocked state must outlive the ~1 Hz poll")
    }

    /// WRAPPER absence keeps a hook-established status alive well BEYOND the (30 s) grace window —
    /// the wrapped claude sitting quietly between turns (or inside a long tool run with no hook
    /// traffic) keeps its status while `node`/`npx`/`bun`/`deno`/`mise` holds the PTY foreground,
    /// for as long as the LONGER wrapper suppression window off the last hook/report.
    func testWrapperAbsenceBeyondGraceWindowKeepsHookStatusWithinSuppressionWindow() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionStart"}"#), at: 0) // hook-established idle
        XCTAssertEqual(d.status, .idle)
        let wayPast = ClaudePaneDetector.reportGraceWindow * 10 // 300 s — past grace, inside suppression
        _ = d.tick(at: wayPast)
        _ = d.sample(name: "node", at: wayPast)
        XCTAssertEqual(
            d.status, .idle,
            "a wrapper foreground preserves a hook-established status inside the suppression window",
        )
    }

    /// The wrapper suppression is TIME-BOUND: a claude killed WITHOUT a SessionEnd (hooks are
    /// best-effort on abrupt termination) followed by a long-running node-based tool in the SAME
    /// pane (`npm run dev` → foreground basename `node` for hours) must decay once the wrapper
    /// suppression window lapses with no hook/report traffic to refresh it — the stale verdict
    /// must not ride an unrelated process forever.
    func testWrapperAbsencePastSuppressionWindowDecays() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 0)
        XCTAssertEqual(d.status, .working) // then killed abruptly — no SessionEnd ever fires
        let late = ClaudePaneDetector.wrapperSuppressionWindow + 1
        let e = d.sample(name: "node", at: late)
        XCTAssertEqual(
            d.status, .none,
            "a stale hook verdict decays once the wrapper suppression window lapses",
        )
        XCTAssertNotNil(e.status, "the termination emits the type-27 transition")
    }

    /// Real hook traffic REFRESHES the wrapper suppression anchor: a wrapper-launched claude whose
    /// hooks keep firing stays preserved indefinitely, measured from the LAST hook — only silence
    /// for a whole window decays it.
    func testHookTrafficRefreshesWrapperSuppressionWindow() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 0)
        let mid = ClaudePaneDetector.wrapperSuppressionWindow - 100
        // A PostToolUse mid-run re-stamps the suppression anchor.
        _ = d.hook(bytes: json(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#), at: mid)
        // Past the ORIGINAL window but inside the refreshed one → still preserved.
        _ = d.sample(name: "node", at: ClaudePaneDetector.wrapperSuppressionWindow + 1)
        XCTAssertEqual(d.status, .working, "the window is measured from the last hook, not the first")
        // A whole window of silence after the last hook → decays.
        _ = d.sample(name: "node", at: mid + ClaudePaneDetector.wrapperSuppressionWindow + 1)
        XCTAssertEqual(d.status, .none, "silence for a full window decays even a wrapper foreground")
    }

    /// A NON-wrapper absence (zsh back in the foreground) past the grace window DOES terminate a
    /// hook-established status — a genuinely exited (or hard-killed) claude decays; the wrapper skip
    /// must not turn every absence into permanence.
    func testNonWrapperAbsencePastGraceWindowTerminatesHookStatus() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 0)
        XCTAssertEqual(d.status, .working)
        let late = ClaudePaneDetector.reportGraceWindow + 1
        let e = d.sample(name: "zsh", at: late)
        XCTAssertEqual(d.status, .none, "a non-wrapper absence past the window terminates as before")
        XCTAssertNotNil(e.status, "the termination emits the type-27 transition")
    }

    /// A SessionEnd hook terminates immediately — and AFTER it, a wrapper foreground must NOT
    /// resurrect/preserve anything (the authority is gone with the session).
    func testSessionEndClearsAuthoritySoWrapperAbsenceStaysNone() {
        var d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd"}"#), at: 1)
        XCTAssertEqual(d.status, .none, "SessionEnd terminates")
        _ = d.sample(name: "node", at: 2)
        XCTAssertEqual(d.status, .none, "no authority left — a wrapper foreground changes nothing")
    }

    /// A wrapper basename is NOT presence: with no hook/report authority it can never lift the floor
    /// off `.none` — a random `node` dev server must not light the agent dot.
    func testWrapperNeverLiftsPresenceFloor() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "node", at: 0)
        _ = d.sample(name: "node", at: 1)
        XCTAssertEqual(d.status, .none, "a wrapper foreground alone is not claude presence")
    }

    /// A repeated identical self-report dedupes (no second type-27) — the change-hook only fires
    /// on a real transition.
    func testRepeatedReportDedupes() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let first = d.report(state: "working", message: nil, at: 1)
        XCTAssertNotNil(first.status, "first working report emits")
        let second = d.report(state: "working", message: nil, at: 2)
        XCTAssertNil(second.status, "an identical consecutive report dedupes (no new type-27)")
    }

    // MARK: - Reattach re-assert (indicators must survive a client restart)

    /// Both streams are edge-triggered against the `lastEmitted*` anchors, so a returning client
    /// (whose mirrors reset to none on reconnect) would never be re-told about a working agent /
    /// foreground command that SPANS the reattach. ``ClaudePaneDetector/reestablishOnReattach()``
    /// re-emits the CURRENT truth verbatim — and must leave the dedupe anchors consistent so the
    /// very next unchanged fold stays silent (no double-emit churn).
    func testReestablishOnReattachReemitsCurrentTruthAndKeepsDedupe() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let hook = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 1)
        let announced = hook.status
        XCTAssertNotNil(announced, "the working transition emitted its type-27 (to the OLD client)")

        let reassert = d.reestablishOnReattach()
        XCTAssertEqual(reassert.foreground, .foregroundProcess(name: "claude"), "the type-26 name is re-told")
        XCTAssertEqual(reassert.status, announced, "the CURRENT working truth is re-told verbatim")

        _ = d.tick(at: 2)
        let resample = d.sample(name: "claude", at: 2)
        XCTAssertNil(resample.status, "the dedupe anchor survives the re-assert — unchanged folds stay silent")
    }

    /// Before ANY fold (detection off / nothing ever sampled) the re-assert must emit NOTHING —
    /// keeping the no-type-26/27-stream contract byte-identical for detection-off sessions.
    func testReestablishBeforeAnyFoldEmitsNothing() {
        var d = ClaudePaneDetector()
        XCTAssertTrue(d.reestablishOnReattach().isEmpty, "no truth yet — a fresh detector re-asserts nothing")
    }

    /// The hole `rebindRelay` guards against: a status change folded WHILE DETACHED lands on a wiped
    /// control-out queue (lost), and the anchor already advanced — so no future edge ever corrects
    /// the returning client's stale status. The re-assert must carry the machine's CURRENT truth
    /// (not the last delivered one): agent finishes while the link is down → reattach re-tells done.
    func testReestablishCarriesStatusChangeFoldedWhileDetached() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 1)
        XCTAssertEqual(d.status, .working)
        // Detached window: the Stop hook fires; its type-27 emission is wiped with control-out.
        let stop = d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#), at: 2)
        XCTAssertEqual(d.status, .done)

        let reassert = d.reestablishOnReattach()
        XCTAssertEqual(
            reassert.status,
            stop.status,
            "the reattach re-tells the CURRENT (done) truth, not the stale working one",
        )
    }

    // MARK: - Agent-session INTENT (the type-36 latch)

    /// The intent FOLLOWS the session's latest titleable prompt (the row answers "what is the
    /// agent doing NOW", not "what was it hired for"): each real prompt re-titles and emits type
    /// 36; an unchanged prompt emits nothing (dedupe); a slash-command leaves the standing intent
    /// untouched (no churn, no wipe).
    func testIntentFollowsLatestTitleablePrompt() {
        var d = ClaudePaneDetector()
        let first = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"refactor the parser"}"#),
            at: 0,
        )
        XCTAssertEqual(first.intent, .agentSessionIntent("refactor the parser"))

        let second = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"now add tests"}"#),
            at: 1,
        )
        XCTAssertEqual(
            second.intent, .agentSessionIntent("now add tests"),
            "a later prompt re-titles — the row follows the work",
        )

        let repeated = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"now add tests"}"#),
            at: 2,
        )
        XCTAssertNil(repeated.intent, "an unchanged intent emits nothing (dedupe)")

        let slash = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"/compact"}"#),
            at: 3,
        )
        XCTAssertNil(slash.intent, "a slash-command neither re-titles nor wipes the standing intent")
    }

    /// A slash-command / harness-XML first prompt has no titling value — the latch stays open so
    /// the session's first REAL prompt still names it.
    func testIntentSkipsSlashCommandThenLatchesRealPrompt() {
        var d = ClaudePaneDetector()
        let slash = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"/compact"}"#),
            at: 0,
        )
        XCTAssertNil(slash.intent)
        let real = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix the flaky CI test"}"#),
            at: 1,
        )
        XCTAssertEqual(real.intent, .agentSessionIntent("fix the flaky CI test"))
    }

    /// A prompt from a NEW session id re-derives the intent from scratch (a fresh `claude` run /
    /// `/clear` mints a new session) — the row re-titles to the new task.
    ///
    /// ⚠️ The `SessionEnd` is not decoration. A pane belongs to one session at a time (see
    /// `ClaudeStatusMachine.ownerSessionID`), and this is exactly how `/clear` behaves: in
    /// Claude Code 2.1.227 `clearConversation` **awaits** the `SessionEnd` hook (reason `clear`)
    /// before doing anything else, and `/resume` does the same with reason `resume`. So the old
    /// session always retires the pane before the new one speaks — which is precisely what
    /// separates a replacement from a nested `claude -p` that just starts talking.
    func testIntentRederivesOnNewSession() {
        var d = ClaudePaneDetector()
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix CI"}"#),
            at: 0,
        )
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1","reason":"clear"}"#), at: 1)
        let next = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s2","prompt":"write docs"}"#),
            at: 2,
        )
        XCTAssertEqual(next.intent, .agentSessionIntent("write docs"))
    }

    /// SessionEnd clears the latched intent with an EMPTY type-36 push (the client drops its
    /// mirror); a pane whose intent stream never spoke stays silent — no spurious clear frame.
    func testSessionEndClearsIntentWithEmptyPush() {
        var d = ClaudePaneDetector()
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix CI"}"#),
            at: 0,
        )
        let end = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 1)
        XCTAssertEqual(end.intent, .agentSessionIntent(""))

        var quiet = ClaudePaneDetector()
        let quietEnd = quiet.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 0)
        XCTAssertNil(quietEnd.intent, "a never-intent pane never emits, not even the clear")
    }

    /// A presence termination (claude died without a SessionEnd — hooks are best-effort) clears the
    /// intent too: a dead session's task line must not squat on whatever runs in the pane next.
    func testPresenceAbsencePastGraceClearsIntent() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix CI"}"#),
            at: 0,
        )
        let gone = d.sample(name: "zsh", at: ClaudePaneDetector.reportGraceWindow + 1)
        XCTAssertEqual(gone.intent, .agentSessionIntent(""))
    }

    /// The reattach re-assert re-tells the latched intent (the type-33/34 sibling rule): an intent
    /// latched while detached would otherwise be lost forever (its emission wiped with control-out).
    func testReestablishReassertsLatchedIntent() {
        var d = ClaudePaneDetector()
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix CI"}"#),
            at: 0,
        )
        XCTAssertEqual(d.reestablishOnReattach().intent, .agentSessionIntent("fix CI"))

        var quiet = ClaudePaneDetector()
        _ = quiet.sample(name: "claude", at: 0)
        XCTAssertNil(quiet.reestablishOnReattach().intent, "a never-intent stream stays silent")
    }

    /// The pure intent-line derivation: first non-blank line, inner whitespace collapsed, clamped;
    /// blank / slash-command / XML-block prompts yield nil (no titling value).
    func testIntentLineDerivation() {
        XCTAssertEqual(
            ClaudePaneDetector.intentLine(from: "\n\n  fix   the\tCI  \nsecond line"),
            "fix the CI",
        )
        XCTAssertEqual(
            ClaudePaneDetector.intentLine(from: String(repeating: "a", count: 500))?.count,
            ClaudePaneDetector.maxIntentChars,
        )
        XCTAssertNil(ClaudePaneDetector.intentLine(from: nil))
        XCTAssertNil(ClaudePaneDetector.intentLine(from: "   \n  "))
        XCTAssertNil(ClaudePaneDetector.intentLine(from: "/compact"))
        XCTAssertNil(ClaudePaneDetector.intentLine(from: "<command-name>/clear</command-name>"))
    }

    // MARK: - Structured block/failure events (PermissionRequest / AskUserQuestion / StopFailure)

    /// `PermissionRequest` is the STRUCTURED blocked signal: urgency 4 + kind 1 (permission), the
    /// gated tool naming the label — it cannot be missed by message-text heuristics.
    func testPermissionRequestBlocksWithToolLabel() {
        var d = ClaudePaneDetector()
        let e = d.hook(
            bytes: json(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#),
            at: 0,
        )
        guard case let .claudeStatus(state, kind, label)? = e.status else {
            XCTFail("expected a type-27")
            return
        }
        XCTAssertEqual(state, 4, "blocked (urgency 4)")
        XCTAssertEqual(kind, 1, "permission class")
        XCTAssertEqual(label, "Permission needed: Bash")
        XCTAssertEqual(d.status, .needsPermission)
    }

    /// `PreToolUse` of `AskUserQuestion` is Claude ASKING — waiting-for-input (kind 2) with the
    /// question text as the label, never `.working`; the answered question resolves via the tool's
    /// own `PostToolUse` (→ working) like any answered prompt.
    func testAskUserQuestionPreToolUseIsWaitingForInput() {
        var d = ClaudePaneDetector()
        let ask = #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","# +
            #""tool_input":{"questions":[{"question":"Which DB should we use?"}]}}"#
        let e = d.hook(bytes: json(ask), at: 0)
        guard case let .claudeStatus(state, kind, label)? = e.status else {
            XCTFail("expected a type-27")
            return
        }
        XCTAssertEqual(state, 4, "asking = blocked on the human (urgency 4)")
        XCTAssertEqual(kind, 2, "waiting-for-input class")
        XCTAssertEqual(label, "Which DB should we use?")

        _ = d.hook(bytes: json(#"{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}"#), at: 1)
        XCTAssertEqual(d.status, .working, "the answer resolves the block")
    }

    /// `StopFailure` (an API-error termination) ends the turn like a Stop — done with the error
    /// text as the label — instead of leaving the pane stuck `working` until absence wins.
    func testStopFailureEndsTheTurnAsDone() {
        var d = ClaudePaneDetector()
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix CI"}"#),
            at: 0,
        )
        XCTAssertEqual(d.status, .working)
        let e = d.hook(
            bytes: json(#"{"hook_event_name":"StopFailure","error_message":"API connection error"}"#),
            at: 1,
        )
        XCTAssertEqual(stateByte(e.status), 2, "done (urgency 2)")
        XCTAssertEqual(d.statusLabel, "API connection error")
    }

    /// The structured `notification_type` field decides the class even when the message text
    /// matches no heuristic (the text rules are the fallback now, not the authority). An
    /// `idle_prompt` is PRESENCE, never a block: it lifts a fresh pane to idle (urgency 1) and
    /// must not raise the act-now hand a done→visited pane already retired.
    func testNotificationTypeFieldClassifies() {
        var d = ClaudePaneDetector()
        let idle = d.hook(
            bytes: json(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hm"}"#),
            at: 0,
        )
        guard case let .claudeStatus(idleState, idleKind, _)? = idle.status else {
            XCTFail("expected a type-27")
            return
        }
        XCTAssertEqual(idleState, 1, "idle_prompt = presence floor, not blocked")
        XCTAssertEqual(idleKind, 0, "the detector zeroes the kind byte while not blocked")

        let blocked = d.hook(
            bytes: json(
                #"{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"?"}"#,
            ),
            at: 1,
        )
        guard case let .claudeStatus(state, kind, _)? = blocked.status else {
            XCTFail("expected a type-27")
            return
        }
        XCTAssertEqual(state, 4, "agent_needs_input stays a genuine block")
        XCTAssertEqual(kind, 2, "waiting-for-input class")
    }

    // MARK: - OSC-title corroboration (Claude Code's own busy/rest telltale)

    /// The Braille-spinner title promotes a DETECTED claude to working; the `✳` rest title demotes
    /// a live working back to idle — the missed-Stop stuck-working corrector.
    func testTitleSpinnerAndRestCorroborateLiveness() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0) // presence → idle
        let spin = d.title("⠧ tests running", at: 1)
        XCTAssertEqual(stateByte(spin.status), 3, "spinner title → working")
        let rest = d.title("✳ Claude Code", at: 2)
        XCTAssertEqual(stateByte(rest.status), 1, "rest title demotes the stuck working → idle")
    }

    /// Claude's own OSC-title TOPIC (the background-model summary / a `/rename`d name) supersedes
    /// the prompt-derived intent on the wire-36 latch; the static startup "Claude Code" names the
    /// program, not the work, and never re-titles.
    func testTitleTopicSupersedesPromptIntent() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let prompt = d.hook(
            bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hello"}"#),
            at: 1,
        )
        XCTAssertEqual(prompt.intent, .agentSessionIntent("hello"))
        // The startup title carries no topic — the prompt intent stands.
        let rest = d.title("✳ Claude Code", at: 2)
        XCTAssertNil(rest.intent)
        // A generated topic re-titles (spinner variant; glyph + whitespace stripped; emitted once).
        let topic = d.title("⠧ Fixing the auth bug", at: 3)
        XCTAssertEqual(topic.intent, .agentSessionIntent("Fixing the auth bug"))
        XCTAssertNil(d.title("⠴ Fixing the auth bug", at: 4).intent, "unchanged topic dedupes")
        // The rest-star variant re-titles too — the latch follows claude's newest self-title.
        XCTAssertEqual(d.title("✳ Auth bug fixed", at: 5).intent, .agentSessionIntent("Auth bug fixed"))
    }

    /// A title folded on an undetected pane can corroborate nothing — and must not conjure an
    /// intent either (every shell titles its tab; only a DETECTED claude's title is a topic).
    func testTitleTopicNeverConjuresIntentOnUndetectedPane() {
        var d = ClaudePaneDetector()
        XCTAssertNil(d.title("✳ Some topic", at: 0).intent)
        XCTAssertNil(d.title("plain shell title", at: 1).intent)
    }

    /// The pure topic-extraction pins: telltale glyphs + variation selectors + whitespace strip,
    /// inner whitespace collapses, the program-name title and empties reject.
    func testTopicLineExtraction() {
        XCTAssertEqual(ClaudePaneDetector.topicLine(fromTitle: "✳ Fix the bug"), "Fix the bug")
        XCTAssertEqual(ClaudePaneDetector.topicLine(fromTitle: "⠧ tests   running"), "tests running")
        XCTAssertEqual(ClaudePaneDetector.topicLine(fromTitle: "✳\u{FE0E} renamed session"), "renamed session")
        XCTAssertEqual(ClaudePaneDetector.topicLine(fromTitle: "my custom title"), "my custom title")
        XCTAssertNil(ClaudePaneDetector.topicLine(fromTitle: "✳ Claude Code"))
        XCTAssertNil(ClaudePaneDetector.topicLine(fromTitle: "⠧ "))
        XCTAssertNil(ClaudePaneDetector.topicLine(fromTitle: ""))
    }

    /// A title never conjures presence (`.none` stays `.none`) and never clears a hook block —
    /// in either direction (rest OR spinner).
    func testTitleNeverConjuresPresenceNorClearsHookBlock() {
        var d = ClaudePaneDetector()
        let ghost = d.title("⠧ busy", at: 0)
        XCTAssertNil(ghost.status)
        XCTAssertEqual(d.status, .none, "a spinner title cannot conjure presence")

        _ = d.sample(name: "claude", at: 1)
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#),
            at: 2,
        )
        XCTAssertEqual(d.status, .needsPermission)
        _ = d.title("✳ Claude Code", at: 3)
        XCTAssertEqual(d.status, .needsPermission, "a rest title never clears a hook block")
        _ = d.title("⠧ busy", at: 4)
        XCTAssertEqual(d.status, .needsPermission, "a spinner title never clears a hook block either")
    }

    /// The Claude Code NATIVE-INSTALL layout names the executable by its version
    /// (`…/.local/share/claude/versions/2.1.218`) — the canonical-name resolution must classify
    /// it as claude (presence floor lifts) and emit the type-26 display name `claude`, never the
    /// meaningless raw version basename.
    func testVersionNamedClaudeBinaryClassifiesAsClaude() {
        var d = ClaudePaneDetector()
        let e = d.sample(name: "/Users/abner/.local/share/claude/versions/2.1.218", at: 0)
        XCTAssertEqual(e.foreground, .foregroundProcess(name: "claude"), "the display name is the program")
        XCTAssertEqual(d.status, .idle, "presence classified — the floor lifts")
    }

    /// The pure canonical-name pins: a version-shaped basename walks up past the layout
    /// components to the owning app directory; every ordinary name stays the exact basename.
    func testCanonicalNameResolution() {
        XCTAssertEqual(
            ForegroundProcessDetector.canonicalName(of: "/Users/a/.local/share/claude/versions/2.1.218"),
            "claude",
        )
        XCTAssertEqual(ForegroundProcessDetector.canonicalName(of: "/opt/foo/versions/v1.2/bin/3.0.1"), "foo")
        XCTAssertEqual(ForegroundProcessDetector.canonicalName(of: "/usr/local/bin/claude"), "claude")
        XCTAssertEqual(ForegroundProcessDetector.canonicalName(of: "zsh"), "zsh")
        XCTAssertEqual(ForegroundProcessDetector.canonicalName(of: "2.1.218"), "2.1.218", "no parents to name it")
        XCTAssertEqual(ForegroundProcessDetector.canonicalName(of: ""), "")
        // Version-shape boundaries: at least one dot; digits+dots only (optional leading v).
        XCTAssertTrue(ForegroundProcessDetector.isVersionShaped("2.1.218"))
        XCTAssertTrue(ForegroundProcessDetector.isVersionShaped("v1.0"))
        XCTAssertFalse(ForegroundProcessDetector.isVersionShaped("7z"))
        XCTAssertFalse(ForegroundProcessDetector.isVersionShaped("2"))
        XCTAssertFalse(ForegroundProcessDetector.isVersionShaped("python3.11"))
    }

    /// The rest title does NOT demote `.done` — the unseen-completion signal keeps its decay window.
    func testRestTitleKeepsDone() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"done"}"#), at: 1)
        XCTAssertEqual(d.status, .done)
        _ = d.title("✳ Claude Code", at: 2)
        XCTAssertEqual(d.status, .done, "the rest title respects the done decay window")
    }

    // MARK: - suppressesChildNotifications (the host's type-25 duplicate gate)

    /// The OSC-notification suppression follows the HOOK authority exactly: false for a fresh /
    /// presence-only / title-only detection (the blind OSC 9 is the pane's only signal there), true
    /// from the first hook fold (the type-27 edge now owns notification duty), and false again once
    /// a genuine absence terminates the session (whatever runs in the pane next keeps its OSC path).
    func testChildNotificationSuppressionTracksHookAuthority() {
        var d = ClaudePaneDetector()
        XCTAssertFalse(d.suppressesChildNotifications, "fresh detector — nothing to suppress")

        // Presence + busy title = the hook-FREE detection mix — the OSC notification must pass.
        _ = d.sample(name: "claude", at: 0)
        _ = d.title("⠋ thinking", at: 1)
        XCTAssertFalse(
            d.suppressesChildNotifications,
            "screen-only detection keeps the OSC path — it is the only signal",
        )

        // First hook fold → the type-27 edge owns notifications; the blind OSC copy is redundant.
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionStart"}"#), at: 2)
        XCTAssertTrue(d.suppressesChildNotifications, "hook truth live — the OSC duplicate is suppressed")

        // A genuine absence past the grace window terminates → the authority (and suppression) die with it.
        _ = d.sample(name: "zsh", at: 2 + ClaudePaneDetector.reportGraceWindow + 1)
        XCTAssertEqual(d.status, .none)
        XCTAssertFalse(d.suppressesChildNotifications, "claude gone — a later child's OSC notification passes again")
    }
}
