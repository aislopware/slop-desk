import Foundation
import SlopDeskAgentDetect
import SlopDeskInspector
import SlopDeskProtocol

/// The SINGLE per-pane Claude-Code detector: ONE ``ClaudeStatusMachine`` fed by ALL the host's
/// detection inputs, so the host is the **single source of truth** and the client is a passive
/// display.
///
/// ## Why one detector
/// Splitting detection across two independent machines — ``ForegroundProcessDetector`` (foreground
/// watch) and ``AgentHookHandler`` (hook socket) — would have BOTH emit type-27 with no
/// reconciliation, so they fight (a hook `.working` and a foreground-poll `.idle` clobber each other
/// down the one CONTROL stream), and with no owner driving `.tick(at:)` the `.done → .idle` decay
/// never fires (a finished turn stays 🔵 forever). Fusing every input into ONE machine gives ONE
/// type-27 dedupe anchor and ONE type-26 edge anchor → one machine, one type-27 stream.
///
/// ## Inputs (folded through the ONE machine, in the machine's precedence order)
/// - ``sample(name:at:)`` — the ~1 Hz foreground poll: `.processPresent(isClaude)` (exact-basename
///   classified via ``ClaudeManifestMatcher``) drives the presence FLOOR, and emits type-26 on a
///   basename EDGE (a coarse process-name hint for display, NOT a status source).
/// - ``hook(bytes:at:)`` — the hook socket: parsed via ``HookParser`` and folded as `.hook(event)`.
/// - ``tick(at:)`` — the per-poll clock tick (~1 Hz) that drives the `.done → .idle` decay.
/// - ``manifestVerdict(_:at:)`` — the no-hooks screen-text/title fallback (Decision #5 signal 3).
///
/// After each fold, type-27 is emitted ONLY when the `(state, kind, label)` triple changes (dedupe);
/// type-26 only on a basename edge. PURE + total: every input (empty/huge/hostile bytes, any name) is
/// tolerated — validate-then-drop, never traps, never force-unwraps. The clock is injected (a plain
/// `Double` seconds); the machine never reads a wall clock.
public struct ClaudePaneDetector: Sendable {
    /// The matcher used to classify a foreground basename as `claude` (exact basename — no
    /// `claudefoo` false positive). One classifier.
    private let matcher: ClaudeManifestMatcher

    /// The ONE per-pane state machine — every signal folds through this single instance.
    private var machine: ClaudeStatusMachine

    /// The last foreground basename a type-26 was emitted for (`nil` before the first sample). A new
    /// sample emits type-26 iff its basename differs from this.
    private var lastEmittedName: String?

    /// The last `(state, kind, label)` triple a type-27 was emitted for (`nil` before the first emit).
    /// A new machine verdict emits type-27 iff this triple changed (dedupe).
    private var lastEmittedStatus: ForegroundProcessDetector.StatusTriple?

    /// Absolute time (injected `now`) of the LAST authoritative fold — a ctl self-report (the P1
    /// `report` verb) OR a parsed HOOK event — or `nil` if none.
    /// Within ``reportGraceWindow`` seconds of this, a foreground-presence ABSENCE (`sample(name:)`
    /// with a non-claude/empty basename) must NOT terminate the machine — both are the same
    /// precedence-2 authoritative signal, and a custom orchestrator / node-wrapped CLI will not
    /// classify as `claude`, so the ~1 Hz poll would otherwise wipe a just-set state on the very
    /// next tick. A hook must stamp this too, not only `report`: otherwise a wrapper-launched
    /// claude's hook status flaps none↔working every second.
    private var lastAuthoritativeAt: TimeInterval?

    /// TRUE while the machine's current (non-`.none`) status was established by an authoritative
    /// hook/report fold; cleared whenever the machine terminates (a SessionEnd hook, or a genuine
    /// absence termination). Gates the WRAPPER-basename absence skip in ``sample(name:at:)`` so a
    /// wrapper foreground can only preserve a genuinely hook-driven status — it can never manufacture
    /// presence on its own.
    private var hookAuthority = false

    /// Seconds an authoritative fold (report/hook) stays STICKY against a foreground-presence
    /// absence. Picked an order of magnitude above the ~1 Hz foreground poll so at least several
    /// polls cannot wipe it; an agent that keeps working re-reports (or its hooks fire) well within
    /// this, and a genuinely finished/exited agent decays normally once the window lapses.
    static let reportGraceWindow: TimeInterval = 30

    /// Seconds a hook/report-established status stays preserved by a WRAPPER-basename foreground
    /// (suppressor (b) in ``sample(name:at:)``) past the last authoritative fold. An order of
    /// magnitude above ``reportGraceWindow``: a wrapper-launched claude quietly between turns
    /// refreshes the anchor with its next hook/report well inside this, while a claude that died
    /// WITHOUT a SessionEnd (kill/crash/link drop — hooks are best-effort) cannot pin its stale
    /// verdict onto an unrelated later `node`/`npx`/`bun` process reusing the same pane forever.
    static let wrapperSuppressionWindow: TimeInterval = 600

    /// The wire `kind` byte for the LAST hook Notification class (`0` until a Notification arrives;
    /// carried so a type-27 emitted by a subsequent tick/presence fold still reports the live block
    /// class). Reset to `0` by any non-Notification transition through the machine that leaves the
    /// blocked state — modelled here as: a Notification sets it, anything that takes the machine off
    /// `.needsPermission` clears it back to `0`.
    private var lastNotificationKind: UInt8 = 0

    /// The hook session id the current ``sessionIntent`` belongs to — a `UserPromptSubmit` whose
    /// session differs re-derives the intent from scratch (a fresh `claude` run / `/clear`).
    private var intentSessionID: String?

    /// The pane's AGENT-SESSION INTENT (wire type 36): claude's OWN session title when the OSC
    /// title carries one (``topicLine(fromTitle:)``), else the session's LATEST titleable prompt —
    /// `nil` = no intent (cleared on SessionEnd / presence termination).
    private var sessionIntent: String?

    /// The last type-36 intent string emitted (`nil` before the first emit) — the dedupe anchor.
    /// Compared with a `?? ""` collapse so a session that never had an intent stays SILENT (no
    /// spurious empty clear frame on the first hook fold).
    private var lastEmittedIntent: String?

    /// TRUE while the pane's OSC title is one the DETECTED agent wrote (a Braille-spinner / `✳`
    /// telltale, or a claude-naming title) — i.e. the agent, not the shell, owns what the row shows.
    ///
    /// This is the ownership record the title retirement needs. Claude Code does emit its own
    /// exit-time clear, but as an EMPTY `OSC 0` that ``HostOutputSniffer`` drops on purpose
    /// (zsh/p10k/starship emit empty titles mid prompt-redraw), and a plain zsh prompt never
    /// re-titles afterwards — so the agent's `✳ <topic>` outlived the agent forever. Rather than
    /// loosen a guard that exists for a good reason, the detector that watched the agent TAKE the
    /// title gives it back on the agent-gone edge. Consumed (and cleared) by
    /// ``titleEmissionIfAgentGone()``.
    private var agentOwnsTitle = false

    /// Character cap on the derived intent line — a sidebar title, not a transcript.
    static let maxIntentChars = 120

    public init(doneToIdleTimeout: TimeInterval = 8) {
        matcher = ClaudeManifestMatcher()
        machine = ClaudeStatusMachine(doneToIdleTimeout: doneToIdleTimeout)
        lastEmittedName = nil
        lastEmittedStatus = nil
    }

    /// One decision: the (possibly empty) CONTROL messages to enqueue for this fold. Shape-identical to
    /// ``ForegroundProcessDetector/Emission`` so both drive the same `enqueueControl` wiring.
    public struct Emission: Sendable, Equatable {
        /// The type-26 `foregroundProcess(name:)` to send, or `nil` (no basename edge).
        public var foreground: WireMessage?
        /// The type-27 `claudeStatus(...)` to send, or `nil` (status unchanged).
        public var status: WireMessage?
        /// The type-36 `agentSessionIntent(...)` to send, or `nil` (intent unchanged).
        public var intent: WireMessage?
        /// The type-21 `title("")` RETIREMENT to send on the agent-gone edge, or `nil`. Only ever
        /// the empty string: the host sniffer drops empty OSC titles, so an empty type-21 on the
        /// wire is unambiguously this deliberate clear and nothing else.
        public var title: WireMessage?

        public var isEmpty: Bool { foreground == nil && status == nil && intent == nil && title == nil }

        /// Flattened for the caller's `enqueueControl([WireMessage])` — foreground first (presence
        /// floor), then the richer status, then the intent, mirroring the machine's precedence, and
        /// the title retirement last (a display consequence of the status having dropped).
        public var messages: [WireMessage] {
            var out: [WireMessage] = []
            if let foreground { out.append(foreground) }
            if let status { out.append(status) }
            if let intent { out.append(intent) }
            if let title { out.append(title) }
            return out
        }
    }

    /// The current rolled-up status (diagnostics / the live wiring's per-pane rollup).
    public var status: ClaudeStatus { machine.status }

    /// The `(state, kind, label)` triple the type-27 stream currently stands at — the CURRENT VALUE
    /// behind the edge, `nil` before the first emission. The workspace document publishes this so a
    /// client that missed the edge still learns the pane's agent state.
    public var lastEmittedStatusForControl: ForegroundProcessDetector.StatusTriple? { lastEmittedStatus }

    /// The agent's current session intent (type 36's value), `nil` when none is established.
    public var sessionIntentForControl: String? { sessionIntent }

    /// The machine's short human label (blocking question / last assistant line), `nil` when empty.
    /// Surfaced by the ctl `list-panes` verb as `stateMessage` so an orchestrator can read WHY a
    /// pane is blocked without scraping scrollback.
    public var statusLabel: String? { machine.displayLabel }

    /// TRUE while the pane's status is HOOK/REPORT-established (`hookAuthority`): the agent's own
    /// terminal notification (OSC 9 / 777 / 99 → wire type 25) is then REDUNDANT — the type-27
    /// agent edge already raises the client's agent banner, so forwarding the blind OSC copy would
    /// double-bang every permission/idle prompt. A hook-free pane (presence/title detection only)
    /// keeps `false` — the OSC notification is its only signal and must pass through. Cleared with
    /// the authority itself (SessionEnd / genuine absence termination).
    public var suppressesChildNotifications: Bool { hookAuthority }

    // MARK: - Inputs (all fold through the ONE machine)

    /// Fold one foreground-process sample at `now`. Emits type-26 on a basename edge (display hint) and
    /// drives the presence FLOOR; a non-claude/empty name forces `.none`. The richer hook status is NOT
    /// overridden by presence (presence only lifts `.none` → `.idle`; absence forces termination).
    public mutating func sample(name rawName: String, at now: TimeInterval) -> Emission {
        let base = ForegroundProcessDetector.canonicalName(of: rawName)
        var emission = Emission()
        if base != lastEmittedName {
            lastEmittedName = base
            emission.foreground = .foregroundProcess(name: base)
        }
        // Presence = ANY known agent, not just claude: the ported alias table (herdr's 21
        // agents) means a codex/gemini/opencode pane lights the same status machinery its
        // screen-manifest verdicts drive. The exact-basename discipline is preserved —
        // `AgentKind.identify` matches whole canonical names/aliases, never substrings.
        let present = matcher.isClaudeRunning(processName: base)
            || AgentKind.identify(processName: base) != nil
        // Stickiness: a recent authoritative fold (ctl self-report OR hook event) must not be wiped
        // by a foreground-presence ABSENCE — the common supervised agent (a custom orchestrator,
        // node-wrapped CLI, any non-`claude` basename) sets `working`/`blocked` authoritatively, and
        // the ~1 Hz poll's `present == false` would otherwise terminate it on the next tick. Two
        // suppressors:
        // (a) within the grace window of the last authoritative fold, ANY absence is dropped;
        // (b) while a hook/report-established status is live (`hookAuthority`), an absence whose
        //     basename is a known WRAPPER (`node`/`npx`/`bun`/`deno`/`mise`) is dropped for the
        //     LONGER ``wrapperSuppressionWindow`` — a wrapper-launched claude sitting quietly
        //     between turns (no hook traffic to re-stamp the short window) must not flap to `.none`
        //     while the wrapper still holds the PTY foreground. Still TIME-BOUND off the same
        //     `lastAuthoritativeAt` anchor: hooks are best-effort, so a claude killed without a
        //     SessionEnd would otherwise pin its stale verdict onto any later node-based tool
        //     (`npm run dev`, `bun test`, …) run in the same pane for as long as it lives. A
        //     wrapper never LIFTS the floor (absence cannot lift `.none`).
        // Once neither holds, absence terminates normally (a genuinely exited agent decays).
        // Ordered comparison (NaN-faithful) — never a bare `<` ternary.
        let absenceSuppressed: Bool = {
            guard !present else { return false }
            if let authoritativeAt = lastAuthoritativeAt {
                let elapsed = now - authoritativeAt
                if Double.minimum(elapsed, Self.reportGraceWindow) < Self.reportGraceWindow,
                   elapsed >= 0
                { return true }
                if hookAuthority, matcher.isLikelyWrapper(processName: base),
                   Double.minimum(elapsed, Self.wrapperSuppressionWindow) < Self.wrapperSuppressionWindow,
                   elapsed >= 0
                { return true }
            }
            return false
        }()
        if absenceSuppressed {
            // Skip the terminating absence fold; keep the authoritative status intact.
            // (No presence floor to lift — absence cannot lift `.none`.)
        } else {
            machine.reduce(.processPresent(present), at: now)
            // Presence absence terminates → not blocked anymore → forget the stale notification
            // kind AND the authoritative provenance (a later wrapper foreground preserves nothing).
            // The session intent dies with the session too (a claude killed without a SessionEnd
            // must not pin its task line onto whatever runs in the pane next).
            if !present {
                lastNotificationKind = 0
                hookAuthority = false
                lastAuthoritativeAt = nil
                intentSessionID = nil
                sessionIntent = nil
            }
        }
        emission.status = statusEmissionIfChanged()
        emission.intent = intentEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// Fold one received hook record (raw POST body bytes) at `now`. Parses via ``HookParser``
    /// (validate-then-drop: malformed/short/non-JSON bytes change nothing) and folds the event through
    /// the SAME machine. Emits type-27 iff the status triple changed; never a type-26 (the foreground
    /// process did not change).
    public mutating func hook(bytes: Data, at now: TimeInterval) -> Emission {
        var emission = Emission()
        guard let payload = HookParser.parse(bytes) else { return emission } // validate-then-drop
        // The INTENT fold (wire type 36) reads the payload BEFORE the status mapping strips the
        // prompt: each titleable prompt re-titles the session, SessionEnd clears.
        switch payload {
        case let .userPromptSubmit(info, prompt):
            foldIntent(sessionID: info.sessionID, prompt: prompt)
        case .sessionEnd:
            intentSessionID = nil
            sessionIntent = nil
        default:
            break
        }
        let (event, kindByte) = AgentHookHandler.mapToHookEvent(payload)
        // A REAL hook is the same precedence-2 authoritative signal as a ctl report, so it stamps
        // the SAME stickiness anchor — otherwise the ~1 Hz foreground poll terminates a hook-set
        // status within a second whenever claude runs under a wrapper (node/npx/mise) whose basename
        // never classifies as `claude`. Stamped on every parsed record (Pre/PostToolUse traffic
        // keeps a long turn's window fresh).
        //
        // EXCEPT `SessionEnd`. The anchor's whole job is to protect a LIVE state from a presence
        // poll that cannot see the agent; a session that just ended has no live state to protect,
        // and the absence the poll is about to report is the SessionEnd's own corroboration. Stamping
        // here inverted the mechanism — the one signal announcing the end became what kept the dead
        // state alive, for the full grace window. Clear the anchor instead, so the next absence
        // terminates on contact.
        if case .sessionEnd = payload {
            lastAuthoritativeAt = nil
        } else {
            lastAuthoritativeAt = now
        }
        machine.reduce(.hook(event), at: now)
        hookAuthority = machine.status != .none // SessionEnd terminates → authority is gone with it
        // Track the live block class: a Notification carries its kind; any transition that leaves the
        // blocked state forgets it (so a later tick/presence type-27 reports kind 0, not a stale class).
        lastNotificationKind = (machine.status == .needsPermission) ? kindByte : 0
        emission.status = statusEmissionIfChanged()
        emission.intent = intentEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// Fold an AGENT SELF-REPORT at `now` (the P1 `report` ctl verb). An agent inside a pane
    /// declares its own state — this is authoritative (precedence-2, same as a real hook),
    /// beating the foreground-process heuristic floor. The ctl state string is mapped to a
    /// synthetic ``ClaudeHookEvent`` and folded through the SAME machine so the existing
    /// precedence + dedupe apply unchanged:
    ///   - `working` → `.userPromptSubmit` (a turn is in progress),
    ///   - `blocked` → `.notification(.permission, label: message)` (needs a human),
    ///   - `done`    → `.stop(label: message)` (turn finished),
    ///   - `idle`    → `.sessionStart` (present & at rest, clears any stale block).
    ///
    /// Validate-then-drop: an unknown `state` string changes nothing and returns an empty
    /// emission (the caller has already validated via ``AgentControlState/isValid(_:)``, but a
    /// belt-and-braces guard here keeps this method safe in isolation). Emits type-27 iff the
    /// machine's status triple changed; never a type-26 (the foreground process did not change).
    public mutating func report(state: String, message: String?, at now: TimeInterval) -> Emission {
        var emission = Emission()
        let event: ClaudeHookEvent
        switch state {
        case "working":
            event = .userPromptSubmit(sessionID: nil)
        case "blocked":
            event = .notification(kind: .permission, label: message)
        case "done":
            event = .stop(sessionID: nil, label: message)
        case "idle":
            event = .sessionStart(sessionID: nil)
        default:
            return emission // validate-then-drop: unknown state is a no-op
        }
        // Record the report time so a subsequent foreground-presence absence cannot wipe this
        // authoritative state for the grace window (see `lastAuthoritativeAt` / `sample`). Only a
        // VALID (folded) state stamps the floor — an unknown state already returned above.
        lastAuthoritativeAt = now
        machine.reduce(.hook(event), at: now)
        hookAuthority = machine.status != .none
        lastNotificationKind = (machine.status == .needsPermission) ? 1 : 0
        emission.status = statusEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// A bare clock tick at `now` — drives the machine's `done → idle` decay. Emits type-27 iff the
    /// decay changed the status; never a type-26.
    public mutating func tick(at now: TimeInterval) -> Emission {
        machine.reduce(.tick, at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        var emission = Emission()
        emission.status = statusEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// Fold the no-hooks manifest fallback's coarse verdict at `now` (Decision #5 signal 3). Conservative:
    /// `.none` is ignored; richer verdicts apply only while a genuine HOOK block is not in effect (the
    /// machine enforces the precedence). Emits type-27 iff the status triple changed.
    ///
    /// The P6 "screen-text source" deferral is CLOSED by the herdr-port screen engine (round 4):
    /// the live feed drives ``screenDetection(_:at:)`` with the full manifest verdict off the
    /// resident grid. This coarse seam stays for the ctl surface and its pinned tests.
    public mutating func manifestVerdict(_ verdict: ClaudeStatus, at now: TimeInterval) -> Emission {
        machine.reduce(.manifestVerdict(verdict), at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        var emission = Emission()
        emission.status = statusEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// Fold one SCREEN-RULE verdict at `now` — the herdr-port manifest engine's published
    /// detection (the scan task has already applied the startup grace, idle-scan skip and the
    /// working→idle hold). The machine reconciles it against the hook edges (a visible idle /
    /// live spinner may clear even a hook block once it is past the paint grace — the screen is
    /// ground truth; a plain fallback idle never clears a hook block). NOT an authoritative
    /// fold — it stamps no stickiness anchor. Emits type-27 iff the status triple changed.
    public mutating func screenDetection(_ detection: AgentScreenDetection, at now: TimeInterval) -> Emission {
        machine.reduce(.screen(detection), at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        var emission = Emission()
        // Like `title`: never OPEN the type-27 stream while still `.none` (an unknown-state
        // verdict on an undetected pane must not announce a churn frame).
        guard machine.status != .none || lastEmittedStatus != nil else { return emission }
        emission.status = statusEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// Fold one sniffed OSC 0/2 title at `now`. Claude Code writes its own busy/rest telltale
    /// into the title (Braille spinner ⇒ working, `✳ ` ⇒ at rest), so the title corroborates
    /// where hooks have gaps — most importantly, a missed Stop's stuck `.working` demotes to
    /// `.idle` on the rest title. The machine applies the conservative precedence (a title never
    /// clears a hook block, never conjures presence, never touches `.done`). NOT an authoritative
    /// fold — it stamps no stickiness anchor. Emits type-27 iff the status triple changed.
    ///
    /// The title's TEXT is also claude's OWN session title: behind the telltale glyph rides a
    /// background-model-generated topic summary (and a `/rename`d session's custom name) — the
    /// canonical "what is this session about", the same string a tmux tab shows for the pane.
    /// A real topic SUPERSEDES the prompt-derived intent (wire 36); the static startup
    /// "Claude Code" names the program, not the work, and never re-titles. Folded only while
    /// claude is DETECTED — a plain shell's title must not conjure an agent intent.
    public mutating func title(_ title: String, at now: TimeInterval) -> Emission {
        machine.reduce(.oscTitle(title), at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        if machine.status != .none, let topic = Self.topicLine(fromTitle: title) {
            sessionIntent = topic
        }
        // Ownership: a title the DETECTED agent wrote is the agent's to give back when it goes.
        // A shell's own title (`nvim — README.md`, a long `make`) is not — it stays put.
        if machine.status != .none, ClaudeStatusMachine.titleIsAgentWritten(title) { agentOwnsTitle = true }
        var emission = Emission()
        // EVERY shell titles its tab — a title folded on an undetected pane (still `.none`) must
        // not OPEN the type-27 stream with a churn frame announcing the client's own default.
        guard machine.status != .none || lastEmittedStatus != nil else { return emission }
        emission.status = statusEmissionIfChanged()
        emission.intent = intentEmissionIfChanged()
        emission.title = titleEmissionIfAgentGone()
        return emission
    }

    /// Fold one client→PTY input chunk at `now` — the Esc-cancel unblock edge. Scoped hard: it
    /// looks at the bytes ONLY while the machine sits at `.needsPermission`, and only a genuine
    /// USER KEYSTROKE (``PaneInputClassifier`` — focus reports, device replies and mouse wheel are
    /// excluded) demotes the block to `.idle`. A keystroke into an open modal is the user HANDLING
    /// it: Esc-cancel fires no Stop hook and the ✳ rest title already shows while the dialog is
    /// up, so this is the only host-visible unblock signal; an answered dialog re-promotes to
    /// `.working` via its own PreToolUse a beat later. NOT an authoritative fold — it stamps no
    /// stickiness anchor. Emits type-27 iff the status triple changed.
    public mutating func userInput(bytes: Data, at now: TimeInterval) -> Emission {
        var emission = Emission()
        guard machine.status == .needsPermission,
              PaneInputClassifier.containsUserKeystroke(bytes)
        else { return emission }
        machine.reduce(.userInput, at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        emission.status = statusEmissionIfChanged()
        return emission
    }

    /// Reattach re-assert (the type-26/27 sibling of the echo re-anchor): the detector's
    /// CURRENT truth as fresh messages for a returning client whose per-pane mirrors reset to none on
    /// reconnect. Both streams are edge-triggered against the `lastEmitted*` anchors, so after
    /// `rebindRelay` wiped the control-out queue nothing would ever re-tell the new client about a
    /// foreground command / working agent that SPANS the reattach — and a status change folded WHILE
    /// DETACHED (its emission wiped with control-out, its anchor already advanced) is otherwise lost
    /// forever. The status is recomputed from the MACHINE (the truth), not replayed from the anchor,
    /// and the anchor is re-pointed at it so the next unchanged fold still dedupes. Quiet before any
    /// fold (both anchors nil): a detection-off session keeps its no-type-26/27-stream contract.
    public mutating func reestablishOnReattach() -> Emission {
        var emission = Emission()
        if let name = lastEmittedName {
            emission.foreground = .foregroundProcess(name: name)
        }
        if lastEmittedStatus != nil {
            let triple = ForegroundProcessDetector.StatusTriple(
                state: UInt8(truncatingIfNeeded: machine.status.urgency),
                kind: lastNotificationKind,
                label: machine.displayLabel ?? "",
            )
            lastEmittedStatus = triple
            emission.status = .claudeStatus(state: triple.state, kind: triple.kind, label: triple.label)
        }
        // The intent stream re-asserts the same way: current truth, anchor re-pointed, and quiet
        // for a pane whose intent stream never spoke (no spurious empty clear frame).
        if lastEmittedIntent != nil {
            let current = sessionIntent ?? ""
            lastEmittedIntent = current
            emission.intent = .agentSessionIntent(current)
        }
        return emission
    }

    // MARK: - Session intent (the type-36 latch)

    /// Folds one `UserPromptSubmit` into the intent: a prompt from a NEW session re-derives from
    /// scratch; within a session every TITLEABLE prompt re-titles (the row answers "what is the
    /// agent doing NOW", not "what was it hired for" — a multi-turn session's title follows the
    /// work). A non-titleable prompt (slash-command / harness XML / blank) leaves the standing
    /// intent untouched — a `/compact` must not wipe the task line.
    private mutating func foldIntent(sessionID: String?, prompt: String?) {
        if sessionID != intentSessionID {
            intentSessionID = sessionID
            sessionIntent = nil
        }
        guard let line = Self.intentLine(from: prompt) else { return }
        sessionIntent = line
    }

    /// Derives the one-line intent from a submitted prompt: the first non-blank line, inner
    /// whitespace collapsed, clamped to ``maxIntentChars``. `nil` when the prompt has no titling
    /// value — blank, a slash-command (`/compact`), or a harness-injected XML block — so a later
    /// REAL prompt can still name the session. Pure + total (any string tolerated).
    static func intentLine(from prompt: String?) -> String? {
        guard let prompt else { return nil }
        for rawLine in prompt.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("/") || line.hasPrefix("<") { return nil }
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String(collapsed.prefix(Self.maxIntentChars))
        }
        return nil
    }

    /// Claude's own session title out of a sniffed OSC title, or `nil` when the title carries no
    /// topic. Strips the leading busy/rest telltale (Braille spinner / `✳` + variation selectors)
    /// and whitespace; rejects an empty remainder and the static startup "Claude Code" (which
    /// names the program, not the work). Whitespace-collapsed and clamped like ``intentLine(from:)``
    /// — the two feed the same wire-36 latch. Pure + total (any string tolerated).
    static func topicLine(fromTitle title: String) -> String? {
        var scalars = title.unicodeScalars[...]
        while let first = scalars.first,
              (0x2800...0x28FF).contains(first.value) // Braille spinner frames
              || first.value == 0x2733 // ✳ rest star
              || first.value == 0xFE0E || first.value == 0xFE0F // variation selectors
              || first.properties.isWhitespace
        {
            scalars.removeFirst()
        }
        let text = String(String.UnicodeScalarView(scalars))
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != "Claude Code" else { return nil }
        return String(collapsed.prefix(Self.maxIntentChars))
    }

    // MARK: - Title retirement (the type-21 agent-gone edge)

    /// Returns the type-21 title RETIREMENT — an explicit empty title — on the edge where the agent
    /// that owned the pane's title has gone (`.none`), else `nil`.
    ///
    /// A ONE-SHOT edge: the ownership flag is consumed here, so a pane already handed back keeps
    /// whatever the shell (or a later agent) titles it next. Empty is deliberate and unambiguous —
    /// ``HostOutputSniffer`` drops empty OSC 0/2 bodies, so the client can read an empty type-21 as
    /// "the host means it" rather than as prompt-redraw noise.
    private mutating func titleEmissionIfAgentGone() -> WireMessage? {
        guard agentOwnsTitle, machine.status == .none else { return nil }
        agentOwnsTitle = false
        return .title("")
    }

    /// Returns a type-36 `agentSessionIntent` message iff the latched intent changed since the last
    /// emit (`nil`-anchor collapses to "" so a never-intent pane stays silent); empty = cleared.
    private mutating func intentEmissionIfChanged() -> WireMessage? {
        let current = sessionIntent ?? ""
        guard current != (lastEmittedIntent ?? "") else { return nil }
        lastEmittedIntent = current
        return .agentSessionIntent(current)
    }

    // MARK: - Status dedupe (ONE anchor for the ONE type-27 stream)

    /// Returns a type-27 `claudeStatus` message iff the machine's `(state, kind, label)` triple changed
    /// since the last emit; `nil` when unchanged (dedupe). `kind` reflects the live block class.
    private mutating func statusEmissionIfChanged() -> WireMessage? {
        let triple = ForegroundProcessDetector.StatusTriple(
            state: UInt8(truncatingIfNeeded: machine.status.urgency),
            kind: lastNotificationKind,
            label: machine.displayLabel ?? "",
        )
        if triple == lastEmittedStatus { return nil }
        lastEmittedStatus = triple
        return .claudeStatus(state: triple.state, kind: triple.kind, label: triple.label)
    }
}
