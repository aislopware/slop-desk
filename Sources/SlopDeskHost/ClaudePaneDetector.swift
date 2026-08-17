import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect
import SlopDeskInspector
import SlopDeskProtocol

/// The SINGLE per-pane Claude-Code detector: ONE `ClaudeStatusMachine` (``rust/slopdesk-agent``'s
/// `machine`) fed by
/// ALL the host's detection inputs, so the host is the **single source of truth** and the client is
/// a passive display.
///
/// ## Why one detector
/// Splitting detection across two independent machines — a foreground-watch reducer (the ~1 Hz
/// poll) and a hook-socket handler — would have BOTH emit type-27 with no reconciliation, so they
/// fight (a hook `.working` and a foreground-poll `.idle` clobber each other down the one CONTROL
/// stream), and with no owner driving ``tick(at:)`` the `.done → .idle` decay never fires (a
/// finished turn stays 🔵 forever). Fusing every input into ONE machine gives ONE type-27 dedupe
/// anchor and ONE type-26 edge anchor.
///
/// ## This is a call, not an implementation
/// Every rule above — the two dedupe anchors, the stickiness clock and its two absence suppressors,
/// the block-class carry, the session-intent latch, the title ownership record — is
/// `rust/slopdesk-agent::detector`, one layer above the machine it owns (docs/55). What is left here
/// is the crossing and the ``WireMessage`` shapes, because a wire enum is `SlopDeskProtocol`'s and a
/// fold is not.
///
/// A `final class` rather than the `struct` this was, for the reason `ClaudeStatusMachine` is one:
/// it holds a handle, so a copy was never a copy — two `ClaudePaneDetector` values sharing one
/// machine looked like value semantics and was not. Its owner holds exactly one per pane and never
/// copies it. Overlapping calls on one handle are aliasing UB rather than a lost update, so an owner
/// that ever shares one must serialise.
///
/// ## Inputs (folded through the ONE machine, in the machine's precedence order)
/// - ``sample(name:at:)`` — the ~1 Hz foreground poll: presence drives the FLOOR, and a basename
///   EDGE emits type-26 (a coarse display hint, NOT a status source).
/// - ``hook(bytes:at:)`` — the hook socket, read and folded in one crossing.
/// - ``report(state:message:at:)`` — the P1 ctl `report` verb, an agent declaring its own state.
/// - ``tick(at:)`` — the per-poll clock tick (~1 Hz) that drives the `.done → .idle` decay.
/// - ``screenDetection(_:at:)`` — the herdr-port screen engine's published verdict.
/// - ``title(_:at:)`` — a sniffed OSC 0/2 title.
/// - ``userInput(bytes:at:)`` — the Esc-cancel unblock edge.
///
/// After each fold, type-27 is emitted ONLY when the `(state, kind, label)` triple changes (dedupe);
/// type-26 only on a basename edge. Every input (empty/huge/hostile bytes, any name) is tolerated —
/// validate-then-drop, never traps. The clock is injected (a plain `Double` seconds); nothing here
/// or below reads a wall clock.
public final class ClaudePaneDetector: @unchecked Sendable {
    /// Seconds an authoritative fold (report/hook) stays STICKY against a foreground-presence
    /// absence.
    static let reportGraceWindow: TimeInterval = slopdesk_agent_detector_constant(1)

    /// Seconds a hook/report-established status stays preserved by a WRAPPER-basename foreground.
    static let wrapperSuppressionWindow: TimeInterval = slopdesk_agent_detector_constant(2)

    /// Scalar cap on the derived intent line — a sidebar title, not a transcript.
    static let maxIntentChars = Int(slopdesk_agent_detector_constant(3))

    private let handle: OpaquePointer

    public init(doneToIdleTimeout: TimeInterval = slopdesk_agent_detector_constant(0)) {
        guard let handle = slopdesk_agent_detector_new(doneToIdleTimeout) else {
            // A detector is a machine and ten small fields; a null here is the allocator being gone,
            // and a pane with no detector would report `.none` for a live agent forever.
            preconditionFailure("slopdesk_agent_detector_new returned null")
        }
        self.handle = handle
    }

    deinit { slopdesk_agent_detector_free(handle) }

    /// One decision: the (possibly empty) CONTROL messages to enqueue for this fold.
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

        /// Flattened for the caller's `broadcastControl([WireMessage])` — foreground first (presence
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

    // MARK: - Current state (diagnostics, the ctl surface, the live rollup)

    /// The current rolled-up status.
    public var status: ClaudeStatus {
        ClaudeStatus(ffiByte: slopdesk_agent_detector_status(handle))
    }

    /// TRUE while the CURRENT status is one the host has qualified as BOOKKEEPING — the wire `kind`
    /// byte already carries this to the client (``SlopDeskAgentDetect/AgentStatusKind/quiet``), and
    /// the host reads it too, so ``MuxChannelSession``'s completion epoch does not count a
    /// correction as a turn.
    public var isQuietTransition: Bool { slopdesk_agent_detector_is_quiet(handle) }

    /// TRUE while this pane's agent is announcing its own edges through the hook feed — the screen
    /// engine is corroboration rather than authority (see ``rust/slopdesk-agent``'s `machine`).
    public var hasAuthoritativeFeed: Bool {
        slopdesk_agent_detector_has_authoritative_feed(handle)
    }

    /// The `(state, kind, label)` triple the type-27 stream currently stands at — the CURRENT VALUE
    /// behind the edge, `nil` before the first emission. The workspace document publishes this so a
    /// client that missed the edge still learns the pane's agent state.
    public var lastEmittedStatusForControl: ClaudeStatusTriple? {
        guard slopdesk_agent_detector_has_last_status(handle) else { return nil }
        return ClaudeStatusTriple(
            state: slopdesk_agent_detector_last_status_state(handle),
            kind: slopdesk_agent_detector_last_status_kind(handle),
            label: text(slopdesk_agent_detector_last_status_label) ?? "",
        )
    }

    /// The agent's current session intent (type 36's value), `nil` when none is established.
    public var sessionIntentForControl: String? {
        text(slopdesk_agent_detector_session_intent)
    }

    /// The machine's short human label (blocking question / last assistant line), `nil` when empty.
    /// Surfaced by the ctl `list-panes` verb as `stateMessage` so an orchestrator can read WHY a
    /// pane is blocked without scraping scrollback.
    public var statusLabel: String? { text(slopdesk_agent_detector_status_label) }

    /// TRUE while the pane's status is HOOK/REPORT-established: the agent's own terminal
    /// notification (OSC 9 / 777 / 99 → wire type 25) is then REDUNDANT — the type-27 agent edge
    /// already raises the client's agent banner, so forwarding the blind OSC copy would double-bang
    /// every permission/idle prompt. A hook-free pane (presence/title detection only) keeps `false`:
    /// the OSC notification is its only signal and must pass through.
    public var suppressesChildNotifications: Bool {
        slopdesk_agent_detector_suppresses_child_notifications(handle)
    }

    // MARK: - Inputs (all fold through the ONE machine)

    /// Fold one foreground-process sample at `now`. Emits type-26 on a basename edge (display hint)
    /// and drives the presence FLOOR; a non-agent/empty name forces `.none` unless an authoritative
    /// fold is still sticky. Presence never overrides a richer hook status — it only lifts `.none`.
    public func sample(name rawName: String, at now: TimeInterval) -> Emission {
        withBytes(rawName.utf8) { bytes, count in
            emission(slopdesk_agent_detector_sample(handle, bytes, count, now))
        }
    }

    /// Fold one received hook record (raw POST body bytes) at `now`. The body is read and folded in
    /// ONE crossing — validate-then-drop, so malformed/short/non-JSON bytes change nothing. Emits
    /// type-27 iff the status triple changed; never a type-26 (the foreground did not change).
    public func hook(bytes: Data, at now: TimeInterval) -> Emission {
        bytes.withUnsafeBytes { raw in
            emission(slopdesk_agent_detector_hook(
                handle,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                now,
            ))
        }
    }

    /// Fold an AGENT SELF-REPORT at `now` (the P1 `report` ctl verb) — authoritative, the same
    /// precedence as a real hook. Validate-then-drop: an unknown `state` changes nothing, not even
    /// the stickiness anchor.
    public func report(state: String, message: String?, at now: TimeInterval) -> Emission {
        withBytes(state.utf8) { stateBytes, stateCount in
            // A nil message is NO message, which the door tells apart from an empty one.
            guard let message else {
                return emission(slopdesk_agent_detector_report(
                    handle, stateBytes, stateCount, nil, 0, now,
                ))
            }
            return withBytes(message.utf8) { messageBytes, messageCount in
                emission(slopdesk_agent_detector_report(
                    handle, stateBytes, stateCount, messageBytes, messageCount, now,
                ))
            }
        }
    }

    /// A bare clock tick at `now` — drives the machine's `done → idle` decay. Emits type-27 iff the
    /// decay changed the status; never a type-26.
    public func tick(at now: TimeInterval) -> Emission {
        emission(slopdesk_agent_detector_tick(handle, now))
    }

    /// Fold one SCREEN-RULE verdict at `now` — the herdr-port manifest engine's published detection
    /// (the scan task has already applied the startup grace, idle-scan skip and the working→idle
    /// hold). NOT an authoritative fold — it stamps no stickiness anchor.
    public func screenDetection(_ detection: AgentScreenDetection, at now: TimeInterval) -> Emission {
        var compact = detection.ffiDetection
        return emission(slopdesk_agent_detector_screen(handle, &compact, now))
    }

    /// Fold one sniffed OSC 0/2 title at `now`. Claude Code writes its own busy/rest telltale into
    /// the title, so the title corroborates where hooks have gaps — and behind the telltale rides
    /// claude's OWN session title, which supersedes the prompt-derived intent (wire 36). NOT an
    /// authoritative fold.
    public func title(_ title: String, at now: TimeInterval) -> Emission {
        withBytes(title.utf8) { bytes, count in
            emission(slopdesk_agent_detector_title(handle, bytes, count, now))
        }
    }

    /// Fold one client→PTY input chunk at `now` — the Esc-cancel unblock edge. The bytes are read
    /// ONLY while the machine sits at `.needsPermission`, and only a genuine CANCEL key demotes the
    /// block. NOT an authoritative fold.
    public func userInput(bytes: Data, at now: TimeInterval) -> Emission {
        bytes.withUnsafeBytes { raw in
            emission(slopdesk_agent_detector_user_input(
                handle,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                now,
            ))
        }
    }

    /// Reattach re-assert: the detector's CURRENT truth as fresh messages for a returning client
    /// whose per-pane mirrors reset to none on reconnect. Both streams are edge-triggered against
    /// their anchors, so after `rebindRelay` wiped the control-out queue nothing would ever re-tell
    /// the new client about a foreground command / working agent that SPANS the reattach — and a
    /// status change folded WHILE DETACHED is otherwise lost forever. Quiet before any fold: a
    /// detection-off session keeps its no-type-26/27-stream contract.
    public func reestablishOnReattach() -> Emission {
        emission(slopdesk_agent_detector_reestablish(handle))
    }

    // MARK: - The pure derivations, callable without a detector

    /// Derives the one-line intent from a submitted prompt: the first non-blank line, inner
    /// whitespace collapsed, clamped to ``maxIntentChars``. `nil` when the prompt has no titling
    /// value — blank, a slash-command (`/compact`), or a harness-injected XML block — so a later
    /// REAL prompt can still name the session.
    static func intentLine(from prompt: String?) -> String? {
        guard let prompt else { return nil }
        return withBytes(prompt.utf8) { bytes, count in
            answer { out, cap in slopdesk_agent_intent_line(bytes, count, out, cap) }
        }
    }

    /// Claude's own session title out of a sniffed OSC title, or `nil` when the title carries no
    /// topic. Strips the leading busy/rest telltale and whitespace; rejects an empty remainder and
    /// the static startup "Claude Code", which names the program rather than the work.
    static func topicLine(fromTitle title: String) -> String? {
        withBytes(title.utf8) { bytes, count in
            answer { out, cap in slopdesk_agent_topic_line(bytes, count, out, cap) }
        }
    }

    /// The `kind` byte a fold should leave standing: `0` when the pane is not blocked, the EVENT's
    /// class when the event is itself a blocking notification, and otherwise the class already
    /// standing — mid-block traffic describes the turn, not the block.
    static func blockKind(standing: UInt8, ledger: UInt8, event: UInt8, blocked: Bool) -> UInt8 {
        slopdesk_agent_block_kind(standing, ledger, event, blocked)
    }

    // MARK: - The crossing

    /// Reads the slot mask a fold answered and pulls back only the slots it names.
    ///
    /// The emission lives on the handle until the next fold replaces it, which is why this runs
    /// immediately and unconditionally after every fold rather than lazily.
    private func emission(_ slots: UInt32) -> Emission {
        var out = Emission()
        if slots & SLOPDESK_AGENT_EMIT_FOREGROUND != 0 {
            out.foreground = .foregroundProcess(
                name: text(slopdesk_agent_detector_emit_foreground) ?? "",
            )
        }
        if slots & SLOPDESK_AGENT_EMIT_STATUS != 0 {
            let packed = slopdesk_agent_detector_emit_status_bytes(handle)
            out.status = .claudeStatus(
                state: UInt8(truncatingIfNeeded: packed >> 8),
                kind: UInt8(truncatingIfNeeded: packed),
                label: text(slopdesk_agent_detector_emit_status_label) ?? "",
            )
        }
        if slots & SLOPDESK_AGENT_EMIT_INTENT != 0 {
            out.intent = .agentSessionIntent(text(slopdesk_agent_detector_emit_intent) ?? "")
        }
        if slots & SLOPDESK_AGENT_EMIT_TITLE != 0 {
            out.title = .title("")
        }
        return out
    }

    /// One `(handle, out, cap) -> ptrdiff_t` door, read through the §4 two-call convention.
    private func text(
        _ call: (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int,
    ) -> String? {
        answer { out, cap in call(handle, out, cap) }
    }
}

// MARK: - The buffer dance, shared by the doors above

/// Calls a `(out, cap) -> ptrdiff_t` door, growing the buffer once if the first guess was short.
///
/// `-1` is the only refusal — a 0-length answer is a PRESENT empty string, which is a real answer at
/// every door here (an intent that was cleared, a label the agent left blank). The wrapped functions
/// are pure or read a handle nothing else is touching, so the second call cannot disagree with the
/// first.
private func answer(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String? {
    var out = [UInt8](repeating: 0, count: 256)
    var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
    guard needed >= 0 else { return nil }
    if needed > out.count {
        out = [UInt8](repeating: 0, count: needed)
        needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        guard needed >= 0, needed <= out.count else { return nil }
    }
    // The bytes came back from a Rust `String`, so the repairing initialiser has no reachable
    // failure arm; the failable one would buy an optional that can never be `nil`.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: out[0..<needed], as: UTF8.self)
}

/// Lends one string's UTF-8 as a `(ptr, len)` pair for exactly the duration of `body`.
private func withBytes<T>(
    _ utf8: String.UTF8View,
    _ body: (UnsafePointer<UInt8>?, Int) -> T,
) -> T {
    Array(utf8).withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}
