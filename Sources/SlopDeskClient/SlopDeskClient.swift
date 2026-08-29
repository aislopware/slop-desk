import CSlopDeskFFI
import Foundation
import SlopDeskProtocol
import SlopDeskTransport

/// One pane's client session, as the face over `rust/slopdesk-clientdriver`.
///
/// `docs/63` stage G.5. What used to be here was the session: an owned transport, four background
/// tasks, an output inbox, a dedup high-water mark, an ack coalescer, an RTT ticker, a connect
/// generation, a teardown depth and a multicast hub — 984 lines in which every rule about a
/// reconnect was written twice, once as a comment and once as an `if`. All of it is
/// ``PaneDriving``'s now, and behind the shipping conformer it is one Rust supervisor thread and a
/// mailbox. What is left here is the three things that cannot cross a C ABI:
///
/// - **the `Event` vocabulary**, because its payloads are Swift values the app pattern-matches;
/// - **the multicast**, because its subscribers are Swift `AsyncStream`s and the driver has exactly
///   one observer — the fan-out has to happen on whichever side the streams are;
/// - **the hop**, because every driver call BLOCKS by design and the callers are on the main actor.
///
/// ### The reconnect campaign is not here either
/// `ReconnectManager` was 281 lines that watched `events` for a `.disconnected`, re-asked four
/// terminal-state flags, and drove a capped exponential ladder. The driver runs that campaign
/// itself, from inside the thread that owns the transport, so the four flags are read where they
/// are written rather than across an actor hop that can interleave. What reaches the UI is the two
/// events the ladder produces — ``Event/retrying(attempt:nextRetryAt:)`` and
/// ``Event/gaveUp(attempts:)`` — plus its already-worded ``Event/log(_:)`` lines.
///
/// ### Ack policy, dedup, resume verdict
/// All three are `slopdesk_clientsession`'s rules, applied by the driver: the highest CONTIGUOUS
/// delivered seq is what gets acked and what the next `channelOpen` presents; an `output` at or
/// below the high-water mark is a replayed duplicate and is dropped (but still credited, so a replay
/// cannot leak window capacity); and the fresh-shell-vs-reattach verdict is resolved from the first
/// seq a connection delivers, re-armed on every adopted connect and on every stream end.
public actor SlopDeskClient {
    /// A host→client event the client surfaces beyond the raw byte stream.
    public enum Event: Sendable, Equatable {
        /// Window/title text (OSC 0/2).
        case title(String)
        /// Terminal bell.
        case bell
        /// Per-command shell status (OSC 133 C/D, sniffed host-side). Drives the per-pane
        /// running/idle indicator + the long-command completion notification.
        case commandStatus(WireMessage.CommandStatus)
        /// An EXPLICIT desktop notification the child requested (OSC 9 / OSC 777, sniffed
        /// host-side). The client posts it as a local notification; clicking focuses the pane.
        case notification(title: String, body: String)
        /// The PTY's current foreground-process basename (wire type 26, host → client). The COARSE
        /// Claude-Code detection signal: `"claude"` means a `claude` is in the foreground, `""`/any
        /// other name clears it. The UI folds this into the pane's `ClaudeStatusMachine`
        /// (``rust/slopdesk-agent``'s `machine`) presence
        /// floor. The pane identity comes from the channel envelope, not this body.
        case foregroundProcess(name: String)
        /// A rich Claude-Code agent-status update (wire type 27, host → client). `state` is the raw
        /// `SlopDeskAgentDetect.ClaudeStatus.urgency` byte, `kind` the notification class
        /// (`0 none / 1 permission / 2 waitingForInput / 3 other`), `label` an optional human chip
        /// string. Surfaced verbatim; the UI maps `state`/`kind` back to a `ClaudeStatus`.
        case claudeStatus(state: UInt8, kind: UInt8, label: String)
        /// A per-command Warp-style "Block" METADATA update (wire type 28, host → client). The
        /// host segments the outbound PTY byte stream into per-command blocks and emits this on each
        /// create / update / complete; it carries ONLY the metadata (NOT the output bytes). The UI
        /// upserts a per-pane block keyed by `index` (the request key for ``blockOutput``). A running
        /// block: `complete == false`, nil exit/duration, partial `outputLen`. `promptOrdinal` is the
        /// block's 1-based prompt-cycle ordinal (counts EVERY OSC-133 `A` cycle incl. blockless empty
        /// Enters, matching libghostty's `.prompt` rows — the outline-jump anchor; 0 = unknown). See
        /// ``WireMessage/commandBlock(index:exitCode:durationMS:complete:outputLen:commandText:promptOrdinal:)``.
        case commandBlock(
            index: UInt32,
            exitCode: Int32?,
            durationMS: UInt32?,
            complete: Bool,
            outputLen: UInt32,
            commandText: String,
            promptOrdinal: UInt32,
        )
        /// A Block's captured OUTPUT bytes (wire type 29, host → client), in reply to a
        /// ``requestBlockOutput(index:)``. `output` is the RAW captured VT bytes (control sequences
        /// preserved — the UI strips them for clipboard). An EMPTY `output` means the block was evicted
        /// from the host's ring or never existed → the UI shows "output no longer available", never hangs.
        case blockOutput(index: UInt32, output: Data)
        /// A host metadata reply (wire type 30, host → client), in reply to a
        /// ``requestMetadata(requestID:verb:payload:)``. `requestID` echoes the request so the client's
        /// ``MetadataRequestRegistry`` correlates it to one of several in-flight requests; `status` is the
        /// raw ``MetadataStatus`` byte (0 ok / 1 notFound / 2 error / 3 unsupportedVerb — an unknown
        /// future byte is treated as error); `payload` is the opaque, verb-specific bytes (a `MetadataCodec`
        /// list, raw UTF-8, or raw file bytes) the typed `MetadataClient` decodes. The host ALWAYS replies
        /// (status error/empty on any failure) so the registry never hangs.
        case metadataResponse(requestID: UInt32, status: UInt8, payload: Data)
        /// The remote child process exited with `code`. Terminal — ``outputWakeups`` finishes right
        /// after this is surfaced, so the single consumer's loop ends and its final
        /// ``takeOutputBatch()`` drains the tail.
        case exit(code: Int32)
        /// A fresh smoothed app-layer RTT sample (EWMA over ping/pong on the CONTROL
        /// channel). Surfaced so the chrome can show a latency badge and lag can be
        /// attributed (network RTT vs host stall vs client render).
        case rtt(milliseconds: Double)
        /// The host PTY's termios `ECHO` edge (wire type 31, host → client). `enabled == true`
        /// is the canonical echoing prompt; `enabled == false` is a no-echo hidden-password prompt (`sudo` /
        /// `ssh` / `read -s`). The macOS UI engages process-global Secure Keyboard Entry while `false`. Emitted
        /// only on the edge (the host's `PaneTruths` echo fold suppresses chatter).
        case inputEcho(enabled: Bool)
        /// An OSC 9;4 taskbar-style PROGRESS update (wire type 32, host → client). The host parses
        /// the `ESC]9;4;<state>[;<pct>]` subtype out of the OSC-9 stream and forwards it on the CONTROL
        /// channel. The decoder carries the RAW state byte verbatim (a faithful byte round-trip keeps the
        /// golden vector stable); this event carries the byte VALIDATED at the client boundary
        /// (``ProgressState/init(wire:)``), so an unknown discriminant (4/5/…/255) is DROPPED and never
        /// reaches the UI. `percent` is clamped 0…100 host-side; it is meaningful for `inProgress`/`error`.
        /// Drives the per-pane tab badge (spinner / error) + the macOS Dock aggregate. Rides CONTROL.
        case progress(state: ProgressState, percent: UInt8)
        /// The shell-reported current working directory (OSC 7, wire type 33). The GUI persists this
        /// into the pane spec so split/new-tab inherit the live cwd immediately.
        case cwd(String)
        /// The HOST-computed By-Project sidebar key (wire type 34): the git worktree toplevel containing
        /// the pane's cwd, else the cwd itself. Emitted on change edges and re-asserted on reattach, so a
        /// reconnecting GUI renders the final sections without re-deriving anything (zero-flicker).
        case projectKey(String)
        /// A HOST-PUSHED project git summary (wire type 35): the FSEvents watcher's event-driven
        /// `git status` fold for one repo toplevel. The GUI books it per PROJECT (section header) and
        /// backs its own poll cadence off while pushes stay fresh.
        case projectGitStatus(WireMessage.ProjectGitStatus)
        /// The pane's sticky AGENT-SESSION INTENT (wire type 36): the agent session's first
        /// titleable prompt, host-latched per session and re-asserted on reattach. Empty =
        /// cleared (session ended) — the GUI drops its mirror and the row title falls back.
        case agentSessionIntent(String)
        /// The transport dropped (network loss, clean close, or a deliberate ``pause()``). The
        /// driver's own campaign reacts to it; surfaced for the chrome and for diagnostics.
        case disconnected(reason: String)
        /// A reconnect completed and the host began replaying the missing tail.
        case reconnected(sessionID: UUID, resumeFromSeq: Int64)
        /// The reconnect campaign is on `attempt`, and `nextRetryAt` is when the NEXT one fires.
        ///
        /// `nil` means this attempt is firing now — there is nothing to count down to yet. A date
        /// means the attempt just failed and the ladder is waiting, which is what the chrome renders
        /// as "retrying in Ns". The driver sends a DURATION and this is where it becomes an instant,
        /// because the two sides do not share a clock epoch and this one is the UI's.
        case retrying(attempt: Int, nextRetryAt: Date?)
        /// The campaign exhausted ``maxReconnectAttempts`` without reconnecting. The pane is
        /// unreachable rather than reconnecting, and the chrome flips to a terminal state instead of
        /// a frozen dot.
        case gaveUp(attempts: Int)
        /// A diagnostic line, already worded by the driver.
        ///
        /// The sentences are Rust's because they describe a ladder Rust owns; a second wording on
        /// this side would drift from the behaviour it claims to narrate.
        case log(String)
    }

    /// What the CURRENT connection turned out to be, derived from the first `output` seq it
    /// delivers plus the host's authoritative `resumeFromSeq`.
    ///
    /// Consumed by `TerminalViewModel.observe` to gate the one-shot fresh-session surface wipe: a
    /// warm reattach must NOT wipe the surviving screen/scrollback the host never re-sends. So
    /// `undetermined` must never be read as "fresh" — a stream that has produced nothing has
    /// established nothing.
    public enum SessionResumeOutcome: Sendable, Equatable {
        /// No output delivered on the current connection yet (or the link is down).
        case undetermined
        /// The seq stream restarted — the host spawned a FRESH shell (PATH B/C).
        case freshShell
        /// The seq stream continued past the presented `lastReceivedSeq` — the host
        /// reattached the SAME live shell (PATH A) and resumes byte-exact.
        case resumedSession

        /// The verdict `slopdesk_clientsession`'s probe answered, as a case. An unreadable byte is
        /// `undetermined` — the reading that establishes nothing, which is the honest answer to a
        /// byte nobody here can interpret.
        public init(code: UInt8) {
            switch code {
            case 1: self = .freshShell
            case 2: self = .resumedSession
            default: self = .undetermined
            }
        }
    }

    /// The reconnect ladder's schedule, as the driver's config field rather than a policy of its own.
    ///
    /// The shipped values are stated once in `slopdesk_clientsession::backoff` and read here; a
    /// literal `250ms`/`2s`/`2.0` in Swift would be a second copy of a rule that already has one.
    public struct Backoff: Sendable, Equatable {
        public var initial: Duration
        public var maximum: Duration
        public var multiplier: Double

        private static let shipped = slopdesk_pane_backoff_default()
        public static let defaultInitial = Duration.nanoseconds(Self.shipped.initial_ns)
        public static let defaultMaximum = Duration.nanoseconds(Self.shipped.maximum_ns)
        public static let defaultMultiplier = Self.shipped.multiplier

        public init(
            initial: Duration = Self.defaultInitial,
            maximum: Duration = Self.defaultMaximum,
            multiplier: Double = Self.defaultMultiplier,
        ) {
            self.initial = initial
            self.maximum = maximum
            self.multiplier = multiplier
        }

        /// The schedule in NANOSECONDS, which is how the driver's config states it: a `Duration`
        /// carries attoseconds, and a millisecond unit would round a sub-millisecond schedule away.
        var initialNanoseconds: UInt64 { Self.nanoseconds(initial) }
        var maximumNanoseconds: UInt64 { Self.nanoseconds(maximum) }

        private static func nanoseconds(_ duration: Duration) -> UInt64 {
            let components = duration.components
            guard components.seconds >= 0 else { return 0 }
            let whole = UInt64(components.seconds).multipliedReportingOverflow(by: 1_000_000_000)
            guard !whole.overflow else { return UInt64.max }
            let fraction = UInt64(max(components.attoseconds, 0) / 1_000_000_000)
            let total = whole.partialValue.addingReportingOverflow(fraction)
            return total.overflow ? UInt64.max : total.partialValue
        }
    }

    /// The restored-pane resume identity, threaded through ``init(registry:ackInterval:backoff:resumeSeed:)``
    /// so it is part of CONSTRUCTION rather than a later call.
    ///
    /// Seeding at init closes a race (docs/DECISIONS, seed-resume-identity): a fire-and-forget
    /// `Task { await client.seed(…) }` after construction orders nothing against a
    /// separately-scheduled `connect()` task, so a cold-launch restore of many panes could lose the
    /// race and start a fresh session instead of reattaching. There is no post-construction seeding
    /// door at all now, which is what makes the race unreachable rather than merely unlikely.
    public typealias ResumeSeed = (sessionID: UUID, lastSeq: Int64)

    /// How often the coalesced ack ticker may flush a pending ack. Correctness does not depend on
    /// this value (the driver never acks an undelivered seq); it only bounds how stale the host's
    /// view of our progress can get.
    public static let defaultAckInterval: Duration = .milliseconds(50)

    /// RTT probe cadence (docs/26 D1). 3s: cheap (one 14-byte control frame each way) yet
    /// fresh enough for a latency badge / typing-lag attribution.
    public static let pingInterval: Duration = .seconds(3)

    /// The give-up ceiling, and the SINGLE source of truth for it: the UI's "attempt N of M" copy
    /// (`ConnectionPresenter.maxReconnectAttempts`) mirrors this value, so the campaign and the
    /// displayed cap can never diverge into an impossible "attempt 25 of 20".
    public static let maxReconnectAttempts = Int(slopdesk_pane_backoff_max_attempts())

    // MARK: - What is held

    private let driver: any PaneDriving

    /// Multicast hub for events: each ``events`` access subscribes a fresh child stream, so the
    /// chrome view-model, the terminal model and the store can all observe the SAME events
    /// concurrently without stealing them from one another.
    private let broadcaster = EventBroadcaster<Event>()

    private let outputWakeStream: AsyncStream<Void>
    private let outputWakeContinuation: AsyncStream<Void>.Continuation

    /// Builds a session on the app's shared per-host mux pool.
    ///
    /// - Parameters:
    ///   - registry: the pool every pane to one host shares. One mux, one client identity.
    ///   - ackInterval: how often the coalesced ack ticker may flush (correctness-independent).
    ///   - backoff: the reconnect ladder, or `nil` for a session that must not reconnect itself.
    ///   - resumeSeed: an optional restored-pane identity (see ``ResumeSeed``).
    public init(
        registry: ConnectionRegistry,
        ackInterval: Duration = SlopDeskClient.defaultAckInterval,
        backoff: Backoff? = Backoff(),
        resumeSeed: ResumeSeed? = nil,
    ) {
        self.init(driver: LivePaneDriver(
            registry: registry,
            ackInterval: ackInterval,
            pingInterval: SlopDeskClient.pingInterval,
            backoff: backoff,
            resumeSeed: resumeSeed,
        ))
    }

    /// Builds a session over an arbitrary ``PaneDriving``.
    ///
    /// The seam a suite injects at. It takes a driver rather than a transport on purpose: a fake
    /// here can only SAY what arrived, never decide anything, because every decision lives behind
    /// the protocol in Rust.
    public init(driver: any PaneDriving) {
        self.driver = driver
        (outputWakeStream, outputWakeContinuation) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // Both sinks are called from driver threads and touch only `Sendable` values — a broadcaster
        // guarded by its own lock, and a continuation, which is safe to yield to from anywhere. So
        // neither hops onto this actor, and an event reaches its subscriber with no queue in
        // between. Neither captures `self`, so the driver holding them is not a cycle.
        let broadcaster = broadcaster
        let wake = outputWakeContinuation
        driver.attach(
            events: { event in
                broadcaster.yield(event)
                // The byte stream is over once the child exits: finishing the wake ends the single
                // consumer's loop, whose final `takeOutputBatch()` drains the tail. Ordered AFTER
                // the yield so a subscriber that reads `isExited` on the `.exit` sees it set.
                if case .exit = event { wake.finish() }
            },
            wake: { wake.yield(()) },
        )
    }

    // MARK: - Surfaced streams

    /// Wakeups for the output inbox: one signal per accepted `output`, coalesced.
    ///
    /// **SINGLE consumer only**: the consumer loops
    /// `for await _ in outputWakeups { await takeOutputBatch() … }` and MUST do one final
    /// ``takeOutputBatch()`` after the loop exits — a tail appended immediately before the stream
    /// finishes (exit/close) is otherwise lost. `bufferingNewest(1)` is the coalescing the driver
    /// deliberately does not do on its side: only this side can see whether a consumer is parked.
    public nonisolated var outputWakeups: AsyncStream<Void> { outputWakeStream }

    /// Title / bell / exit / connection lifecycle events.
    ///
    /// **Each access returns a NEW broadcasting child stream** — every concurrent consumer sees
    /// *every* event. This is a live multicast: a late subscriber sees only events from its
    /// subscription point on. (It is NOT a single shared `AsyncStream`; that would deliver each
    /// event to exactly one of the loops, nondeterministically.)
    public nonisolated var events: AsyncStream<Event> { broadcaster.subscribe() }

    /// Atomically takes the whole pending output backlog (FIFO order preserved) and CREDITS the
    /// taken bytes back to the host.
    ///
    /// Credit-at-consumption: "taken" means the single consumer is about to feed them — the next
    /// take cannot happen until that ingest returns, so client-side un-rendered bytes stay bounded
    /// by ~one mux window plus the batch in hand, and the host's PTY-pause backpressure engages
    /// from a slow client. The bytes are spliced gap-free and dup-free across reconnects by the
    /// driver's seq dedup.
    public func takeOutputBatch() -> [Data] { driver.takeOutput() }

    // MARK: - Readouts

    /// EWMA-smoothed app-layer RTT in milliseconds (`nil` until the first pong).
    public var smoothedRTTMS: Double? { driver.smoothedRTTMS }

    /// Authoritative session id learned from the first handshake, preserved across reconnects so
    /// the host recognises us as a RETURNING_CLIENT.
    public var sessionID: UUID? { driver.sessionID }

    /// Highest **contiguous** output seq delivered. This is what is acked and what the next
    /// `channelOpen` presents as `lastReceivedSeq`.
    public var highestContiguousSeq: Int64 { driver.highestContiguousSeq }

    /// Fresh-shell-vs-reattach verdict for the CURRENT connection (see ``SessionResumeOutcome``).
    public var sessionResumeOutcome: SessionResumeOutcome { driver.resumeOutcome }

    /// True while paused by ``pause()`` (diagnostics / reconnect gating).
    public var isPaused: Bool { driver.isPaused }

    /// True once ``close()`` has permanently retired the session.
    public var isClosed: Bool { driver.isClosed }

    /// True once the remote child has exited — this session is permanently done.
    public var isExited: Bool { driver.isExited }

    /// True once the HOST closed this pane's channel, for any reason.
    ///
    /// A `channelClose` sets neither `isPaused`, `isClosed` nor `isExited`, and it ends the inbound
    /// stream exactly as a drop does — so without this a recovery would re-open the channel, which
    /// for a reaped pane forks a shell the host has already given up on, and for an evicted
    /// subscriber re-joins to be evicted again.
    public var isHostClosed: Bool { driver.hostCloseReason != nil }

    /// WHY the host closed this pane's channel, `nil` if it did not.
    ///
    /// The campaign gate is ``isHostClosed`` and asks nothing about the reason — every host close
    /// ends THIS session. The reason is for the layer above, which owns the different question of
    /// whether a NEW session may be built for the pane: `.retired` says the pane is gone,
    /// `.subscriberEvicted` says only this attachment was.
    public var hostChannelCloseReason: MuxCloseReason? { driver.hostCloseReason }

    // MARK: - Connect / lifecycle

    /// Provides a startup cwd for the next PTY spawn.
    ///
    /// A host-side reattach IGNORES it (the live shell's cwd is preserved); only a FRESH respawn
    /// honours it. It is re-sent on every (re)connect, so a pane whose host shell had to be
    /// respawned lands back in its project directory rather than the daemon's `$HOME`.
    public func setInitialCwd(_ cwd: String?) {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        driver.setInitialCwd((trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    /// Connects to `host:port`. A first call uses a NEW session; a later call reuses the learned
    /// ``sessionID`` and presents ``highestContiguousSeq`` so the host replays the tail.
    ///
    /// RETURNS rather than throwing when a `close()` or a `pause()` superseded the dial: the caller
    /// reads a return as "somebody else is handling this pane" and a throw as "the host is
    /// unreachable", and reporting the first as the second whitewashes a torn-down pane.
    public func connect(
        host: String,
        port: UInt16,
        handshakeTimeout: Duration = .seconds(10),
    ) async throws {
        let driver = driver
        _ = try await Self.offCallerThread { try driver.connect(
            host: host,
            port: port,
            handshakeTimeout: handshakeTimeout,
        ) }
    }

    /// App backgrounded: proactively tear the transport down.
    ///
    /// The host keeps the shell and its replay buffer alive, so output produced while paused is
    /// retained for replay. Idempotent. Surfaces its own ``Event/disconnected(reason:)``.
    public func pause() async {
        let driver = driver
        await Self.offCallerThread { driver.pause() }
    }

    /// App foregrounded: reconnect with the preserved `sessionID` + seq. A no-op unless paused.
    public func resume() async throws {
        let driver = driver
        _ = try await Self.offCallerThread { try driver.resume(handshakeTimeout: .seconds(10)) }
    }

    /// Permanently retires the session and finishes the surfaced streams. After this the client is
    /// unusable; a recovery builds a new one.
    public func close() async {
        let driver = driver
        await Self.offCallerThread { driver.close() }
        outputWakeContinuation.finish()
        broadcaster.finish()
    }

    // MARK: - Outbound (client → host)

    /// Forces an immediate ack flush. Safe to call any time.
    public func flushAck() { driver.flushAck() }

    /// Sends raw keystroke/paste bytes as `input`, on the windowed DATA lane.
    ///
    /// Hopped off the caller's thread because the door BLOCKS while the credit window is empty —
    /// that IS the backpressure, and it is why there is no bounded queue on this side any more.
    public func sendInput(_ bytes: Data) async throws {
        let driver = driver
        try await Self.offCallerThread { try driver.sendInput(bytes) }
    }

    /// Sends a `resize`. The driver REMEMBERS it, so every later connection re-asserts it —
    /// including when this send itself fails, which is exactly the resize the next one must assert.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) throws {
        try driver.sendResize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight)
    }

    /// Requests a Block's captured OUTPUT bytes (wire type 15) — fired when the user copies/expands a
    /// block whose `index` came from a ``Event/commandBlock(index:exitCode:durationMS:complete:outputLen:commandText:promptOrdinal:)``.
    /// The host replies with a ``Event/blockOutput(index:output:)`` (empty == evicted/unknown). Rides
    /// CONTROL, so it never head-of-line-blocks behind an output flood on DATA.
    public func requestBlockOutput(index: UInt32) throws {
        try driver.sendControl(.requestBlockOutput(index: index))
    }

    /// Requests host-side pane metadata (wire type 16) — fired by the typed `MetadataClient` façade
    /// behind the Details Panel. The host always replies with a
    /// ``Event/metadataResponse(requestID:status:payload:)``; the registry's timeout is the
    /// belt-and-braces guard for a dropped reply. Rides CONTROL.
    public func requestMetadata(requestID: UInt32, verb: UInt8, payload: Data) throws {
        try driver.sendControl(.metadataRequest(requestID: requestID, verb: verb, payload: payload))
    }

    // MARK: - Internals

    /// Runs one blocking driver door off the caller's thread.
    ///
    /// Every door parks by design — the driver is a mailbox and a supervisor thread — and every
    /// caller here is on the main actor or on the cooperative pool, neither of which may block.
    /// A `DispatchQueue.global` hop is the spelling that keeps the door synchronous in Rust, where
    /// a blocking wait is the simple correct thing, without that simplicity landing on the UI.
    private static func offCallerThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { resumption in
            DispatchQueue.global(qos: .userInitiated).async {
                resumption.resume(with: Result { try body() })
            }
        }
    }

    /// The non-throwing half, spelled separately so `pause`/`close` need no `try`.
    private static func offCallerThread(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { resumption in
            DispatchQueue.global(qos: .userInitiated).async {
                body()
                resumption.resume()
            }
        }
    }
}
