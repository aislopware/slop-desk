import Foundation
import SlopDeskProtocol
import SlopDeskTransport

/// The SlopDesk client session driver — the real, working PATH 1 client.
///
/// `SlopDeskClient` owns a single ``ClientTransporting`` and turns its merged
/// host→client ``ClientTransporting/inbound`` stream into three things a UI/CLI needs:
///
/// - **output bytes** — exposed as an `AsyncStream<Data>` (``output``) *and* fed to an
///   optional ``TerminalSurface`` (the libghostty seam / `HeadlessTerminalSurface`);
/// - **title / bell** — surfaced via the ``events`` stream;
/// - **exit** — surfaced via ``events`` and terminates ``output``.
///
/// ### Ack policy
/// Tracks the **highest contiguous** `output.seq` delivered to the surface
/// (``highestContiguousSeq``) and periodically `sendAck`s it so the host's `ReplayBuffer`
/// can release acked output and the offline gate can recover. **Coalesced**: a pending-ack
/// flag is set when the contiguous counter advances; a background ticker flushes it at most
/// once every ``ackInterval`` (default 50ms). Never ack a seq we have not delivered —
/// correctness over cadence (`docs/20` §5).
///
/// ### Reconnect + seq dedup
/// On a transport drop ``ReconnectManager`` calls back into ``connect(...)`` presenting the
/// SAME `sessionID` + ``highestContiguousSeq`` as `lastReceivedSeq`. The **dedup** is robust:
/// the client drops any inbound `output` whose `seq <= highestSeqFed`, so a replayed
/// already-delivered tail (or a re-presented stale seq) splices into ``output`` gap-free and
/// dup-free.
///
/// IMPORTANT — what reconnect does TODAY: the mux transport (the sole terminal connectivity)
/// has **no per-channel server-side resume**. A real drop kills the host shell; reconnect spawns
/// a BRAND-NEW one whose `output` restarts at seq 1 — no replay (see `MuxChannelSession` "S1 has
/// no per-channel reconnect/resume", `HostServer.spawnMuxChannel`). So reconnect is the **ssh
/// model (fresh shell)**, NOT a byte-exact resume, and ``connect(...)`` RESETS the dedup/ack
/// high-water marks on every (re)connect so the fresh shell renders from seq 1. Client-side
/// scrollback survives a SwiftUI surface rebuild (tab switch) via the view model's replay ring,
/// but NOT a transport drop. Host-side survival + true `seq > lastReceivedSeq` replay
/// (`docs/20` §8.3) is designed-but-unimplemented; if it lands, the unconditional reset in
/// ``connect(...)`` must become conditional on a host-authoritative returning flag.
///
/// ### iOS lifecycle seam ([17] §2.5, [18] §H)
/// ``pause()`` / ``resume()`` are the hooks wired to UIKit `didEnterBackground` /
/// `willEnterForeground`. `pause()` proactively closes the transport (iOS tears the TCP down a
/// few seconds after backgrounding anyway — see DECISIONS §reconnect); `resume()` triggers a
/// reconnect with the preserved `sessionID` + seq. Per the reconnect note above, on the mux path
/// this yields a FRESH shell (not a byte-exact resume): the renderer resets and the new shell
/// repaints from its first prompt.
///
/// All mutable state lives inside this `actor`. No `@unchecked Sendable`.
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
        /// other name clears it. The UI folds this into the pane's ``ClaudeStatusMachine`` presence
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
        /// The remote child process exited with `code`. Terminal — ``output`` finishes
        /// right after this is surfaced.
        case exit(code: Int32)
        /// A fresh smoothed app-layer RTT sample (EWMA over ping/pong on the CONTROL
        /// channel). Surfaced so the chrome can show a latency badge and lag can be
        /// attributed (network RTT vs host stall vs client render).
        case rtt(milliseconds: Double)
        /// The host PTY's termios `ECHO` edge (wire type 31, host → client). `enabled == true`
        /// is the canonical echoing prompt; `enabled == false` is a no-echo hidden-password prompt (`sudo` /
        /// `ssh` / `read -s`). The macOS UI engages process-global Secure Keyboard Entry while `false`. Emitted
        /// only on the edge (the host's `EchoModeDetector` suppresses chatter).
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
        /// The transport dropped (network loss / clean close). ``ReconnectManager``
        /// reacts to this; surfaced for diagnostics.
        case disconnected(reason: String)
        /// A reconnect completed and the host began replaying the missing tail.
        case reconnected(sessionID: UUID, resumeFromSeq: Int64)
    }

    /// What the CURRENT connection turned out to be, derived from the first `output` seq it
    /// delivers — the only reliable fresh-shell-vs-reattach signal on the mux path, where the
    /// `channelOpenAck` carries no host-authoritative `resumeFromSeq` (the transport hardcodes 0).
    ///
    /// The host's per-channel seq stream is monotonic across a PATH-A reattach (the ReplayBuffer
    /// survives with the shell, and `replay(after: lastReceivedSeq)` only ever emits
    /// `seq > lastReceivedSeq`), while a PATH-B/C FRESH shell mints a new ReplayBuffer whose first
    /// output is seq 1. So, having presented `lastReceivedSeq = N` in the channelOpen preamble:
    /// first delivered `seq > N` (with `N > 0`) ⇒ the SAME shell resumed; first delivered
    /// `seq <= N` (or `N == 0` — nothing to resume) ⇒ a fresh shell. Consumed by
    /// `TerminalViewModel.observe` to gate the one-shot fresh-session surface wipe: a warm
    /// reattach must NOT wipe the surviving screen/scrollback the host never re-sends.
    public enum SessionResumeOutcome: Sendable, Equatable {
        /// No output delivered on the current connection yet (or the link is down).
        case undetermined
        /// The seq stream restarted — the host spawned a FRESH shell (PATH B/C).
        case freshShell
        /// The seq stream continued past the presented `lastReceivedSeq` — the host
        /// reattached the SAME live shell (PATH A) and resumes byte-exact.
        case resumedSession
    }

    /// How often the coalesced ack ticker may flush a pending ack. Correctness does not
    /// depend on this value (we never ack an undelivered seq); it only bounds how stale
    /// the host's view of our progress can get.
    public static let defaultAckInterval: Duration = .milliseconds(50)

    /// RTT probe cadence (docs/26 D1). 3s: cheap (one 14-byte control frame each way) yet
    /// fresh enough for a latency badge / typing-lag attribution.
    public static let pingInterval: Duration = .seconds(3)

    /// EWMA-smoothed app-layer RTT in milliseconds (`nil` until the first pong). α = 0.25
    /// (≈ TCP SRTT's 1/8–1/4 family): responsive to weather changes without flapping on
    /// one outlier.
    public private(set) var smoothedRTTMS: Double?

    // MARK: Surfaced streams

    /// Inbox of delivered-but-not-yet-consumed `output` payloads, drained in batches by the
    /// single consumer via ``takeOutputBatch()``. Batched rather than a per-chunk `AsyncStream<Data>`
    /// so a backlog crosses to the consumer as ONE batch (one MainActor hop, one render flush)
    /// instead of one job per wire chunk. Each entry carries its wire byte count: taking a batch
    /// CREDITS those bytes back to the host (credit-at-consumption), so the inbox can never hold
    /// more than ~one mux window and the host's PTY-pause backpressure engages from a slow client.
    private var outputInbox: [(bytes: Data, wireBytes: Int)] = []
    private let outputWakeStream: AsyncStream<Void>
    private let outputWakeContinuation: AsyncStream<Void>.Continuation

    /// Multicast hub for events: each ``events`` access subscribes a fresh child stream so
    /// `ReconnectManager` and the view-models can all observe the SAME events concurrently
    /// without stealing them from one another (a plain `AsyncStream` is single-consumer /
    /// fan-in; see ``EventBroadcaster``).
    private let eventBroadcaster = EventBroadcaster<Event>()

    /// Wakeups for the output inbox: one (coalesced) signal per append burst.
    ///
    /// **SINGLE consumer only**: the consumer
    /// loops `for await _ in outputWakeups { await takeOutputBatch() … }` and MUST do one
    /// final ``takeOutputBatch()`` after the loop exits — a tail appended immediately
    /// before the stream finishes (exit/close) is otherwise lost. `bufferingNewest(1)`
    /// coalesces redundant wakes; appends always happen BEFORE the yield, so a pending
    /// wake always observes a complete inbox.
    public nonisolated var outputWakeups: AsyncStream<Void> { outputWakeStream }

    /// Atomically takes the whole pending output backlog (FIFO order preserved) and
    /// CREDITS the taken bytes back to the host (credit-at-consumption: "taken" means the
    /// single consumer is about to feed them — the next take cannot happen until that
    /// ingest returns, so client-side un-rendered bytes stay bounded by ~one window plus
    /// the batch in hand). Raw PTY/VT output bytes from the host, spliced gap-free /
    /// dup-free across reconnects by ``deliverOutput(seq:bytes:)``'s dedup.
    public func takeOutputBatch() async -> [Data] {
        guard !outputInbox.isEmpty else { return [] }
        let batch = outputInbox
        outputInbox.removeAll(keepingCapacity: true)
        let wireBytes = batch.reduce(0) { $0 + $1.wireBytes }
        await transport?.noteOutputConsumed(wireBytes: wireBytes)
        return batch.map(\.bytes)
    }

    /// Title / bell / exit / connection lifecycle events.
    ///
    /// **Each access returns a NEW broadcasting child stream** — every concurrent consumer
    /// (the reconnect supervisor, the chrome view-model, …) sees *every* event. This is a
    /// live multicast: a late subscriber sees only events from its subscription point on.
    /// (It is NOT a single shared `AsyncStream`; that would deliver each event to exactly
    /// one of the loops, nondeterministically.)
    public nonisolated var events: AsyncStream<Event> { eventBroadcaster.subscribe() }

    // MARK: Connection target (remembered for reconnect)

    public private(set) var host: String?
    public private(set) var port: UInt16?

    /// Authoritative session id learned from the first `helloAck`. Preserved across
    /// reconnects so the host recognizes us as a RETURNING_CLIENT.
    public private(set) var sessionID: UUID?

    /// Highest **contiguous** output seq delivered to the surface. This is what we ack
    /// and what we present as `hello.lastReceivedSeq` on reconnect.
    public private(set) var highestContiguousSeq: Int64 = 0

    /// Highest output seq actually fed to the surface (== ``highestContiguousSeq`` while
    /// the stream is contiguous, which it always is here). Used as the dedup high-water
    /// bound — any inbound `output` with `seq <= highestSeqFed` is a replay duplicate and
    /// is dropped.
    private var highestSeqFed: Int64 = 0

    /// Fresh-shell-vs-reattach verdict for the CURRENT connection (see ``SessionResumeOutcome``).
    /// Re-armed to `.undetermined` on every adopted `connect(...)` and on a stream end (so a
    /// stale verdict from a dead link can never gate the NEXT session's wipe), then resolved by
    /// ``deliverOutput(seq:bytes:wireBytes:)`` from the first `output` seq it sees.
    public private(set) var sessionResumeOutcome: SessionResumeOutcome = .undetermined

    /// The `lastReceivedSeq` this client presented in the most recently ADOPTED connect's
    /// channelOpen preamble — the reference point ``sessionResumeOutcome`` is resolved against.
    /// (Captured separately because `connect` resets ``highestContiguousSeq`` right after
    /// presenting it — the mux transport reports no host-authoritative resume seq.)
    private var presentedResumeSeq: Int64 = 0

    // MARK: Internals

    private let ackInterval: Duration
    /// Factory for the session transport, injected so a pane is backed by a logical channel over a
    /// shared ``MuxNWConnection`` (a `MuxClientTransport`, supplied by
    /// ``WorkspaceStore/liveMakeSession`` bound to the per-host ``ConnectionRegistry``).
    private let makeTransport: @Sendable () -> any ClientTransporting
    private var transport: (any ClientTransporting)?
    private var initialCwd: String?
    private var inboundTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var ackPending = false
    private var closed = false
    private var paused = false
    /// Set when the remote child `.exit`s — TERMINAL for this client instance, like `closed`. The
    /// wake stream (`outputWakeups`) is created once in init and permanently `finish()`ed on
    /// `.exit`; its single consumer returns and is never restarted. Any later `connect()` on the
    /// SAME client would therefore hand a fresh host shell to a consumer-less inbox:
    /// `takeOutputBatch` never runs, no window credit is re-granted, and every reconnect strands up
    /// to one mux window of bytes forever. So `connect()` refuses, `resume()` no-ops, the post-exit
    /// stream end surfaces no `.disconnected`, and `ReconnectManager` gates on ``isExited`` beside
    /// `isPaused`/`isClosed`. A respawn is an explicit re-dial, which builds a NEW client.
    private var childExited = false

    /// Monotonic connect-attempt counter. Each ``connect(...)`` captures its value at entry; if a
    /// NEWER connect starts during this one's `await transport.connect(...)` suspension (the actor is
    /// reentrant at every await), the older invocation observes its captured generation is now stale
    /// and DISCARDS its just-built transport instead of adopting it. Without this, two overlapping
    /// connects (e.g. the reconnect supervisor racing iOS `resume()`) both reach `self.transport =
    /// transport`; the second overwrites the first WITHOUT tearing it down, leaking a fully-live
    /// transport (2 sockets + inbound pump + ack ticker) and its ``ConnectionRegistry`` refcount — the
    /// "zombie transport" race. Paired with the post-handshake `closed`/`paused` re-check below for the
    /// close()/pause()-during-reconnect variants.
    private var connectGeneration: UInt64 = 0

    /// Set while we are deliberately replacing the transport (reconnect entry / pause).
    /// `teardownTransport()` closes the OLD transport, finishing the OLD inbound stream and landing
    /// the old pump in ``handleStreamEnded(error:)`` with `nil` — a SELF-INFLICTED end, not a real
    /// drop. This flag lets `handleStreamEnded` suppress that spurious `.disconnected` (mirror of
    /// the `closed` guard), so `ReconnectManager` does not queue a redundant reconnect campaign. The
    /// real drop path (``forceDropForTesting()`` / transport failing on its own) leaves this `false`.
    /// DEPTH counter, not a bare Bool: two overlapping teardowns — a reentrant connect()/pause() whose
    /// teardownTransport awaits across another — must not clobber each other's suppression window. A
    /// shared Bool would let the inner scope's `= false` clear the outer's `= true`, briefly
    /// un-suppressing handleStreamEnded so a self-inflicted stream-end surfaces a spurious
    /// `.disconnected` + redundant reconnect. Each scope inc/decrements only its own, so depth stays
    /// > 0 for the whole span any teardown is in flight.
    private var tearingDownDepth = 0
    private var tearingDown: Bool { tearingDownDepth > 0 }
    private var lastSentResize: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?

    /// Optional terminal renderer fed the inbound output (libghostty seam / headless).
    /// Held as `AnyObject` + a feeder closure so this target need not link SlopDeskTerminal.
    private var surfaceFeed: (@Sendable (Data) -> Void)?

    /// The restored-pane resume identity, threaded into ``init(ackInterval:makeTransport:resumeSeed:)``
    /// so it is set SYNCHRONOUSLY as part of construction — before the client object escapes to any
    /// concurrent caller. Mirrors exactly the trio ``seedResumeIdentity(sessionID:seq:)`` mutates
    /// (`sessionID`, `highestContiguousSeq`, `highestSeqFed`).
    ///
    /// Seeds inside `init` to close a race (docs/DECISIONS, seed-resume-identity): seeding via an
    /// UNAWAITED `Task { await c.seedResumeIdentity(...) }` after construction orders nothing between
    /// that seed job's actor-hop and a separately-scheduled `connect()` Task's OWN actor-hop, so a
    /// cold-launch restore of many panes can lose the race and silently start a fresh session instead
    /// of reattaching. Init-time seeding removes the async gap entirely: there is no point after
    /// construction where the fields are still unseeded, so a racing `connect()` can never observe
    /// stale state.
    public typealias ResumeSeed = (sessionID: UUID, lastSeq: Int64)

    /// - Parameters:
    ///   - ackInterval: how often the coalesced ack ticker may flush (correctness-independent).
    ///   - makeTransport: the session-transport factory. Vends a logical channel over a shared
    ///     ``MuxNWConnection`` (a `MuxClientTransport`) — wired at the
    ///     `WorkspaceStore.liveMakeSession` construction site, never on the hot path.
    ///   - resumeSeed: an optional restored-pane identity, applied synchronously before this
    ///     initializer returns (see ``ResumeSeed``). `nil` (the default) is the ordinary fresh-shell
    ///     path.
    @preconcurrency
    public init(
        ackInterval: Duration = SlopDeskClient.defaultAckInterval,
        makeTransport: @escaping @Sendable () -> any ClientTransporting,
        resumeSeed: ResumeSeed? = nil,
    ) {
        self.ackInterval = ackInterval
        self.makeTransport = makeTransport
        (outputWakeStream, outputWakeContinuation) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        if let resumeSeed {
            sessionID = resumeSeed.sessionID
            highestContiguousSeq = resumeSeed.lastSeq
            highestSeqFed = resumeSeed.lastSeq
        }
    }

    /// Attaches a feeder that mirrors every delivered `output` payload to a terminal
    /// surface (in addition to the ``output`` stream). The closure runs on the actor;
    /// a GUI surface should hop to `@MainActor` inside it.
    @preconcurrency
    public func setSurfaceFeed(_ feed: @escaping @Sendable (Data) -> Void) {
        surfaceFeed = feed
    }

    // MARK: Connect / reconnect

    /// Pre-seeds the resume identity so the NEXT ``connect(...)`` presents this session
    /// UUID and last-received seq to the host (the SLOPDESK_DETACH_ENABLED path).
    ///
    /// NOT the production restore-a-pane path (seed-resume-identity-race, docs/DECISIONS):
    /// ``LivePaneSession/makeTerminal(_:makeClient:makeInspector:target:)`` threads a restored
    /// ``PaneSpec/resumeSessionID`` through ``init(ackInterval:makeTransport:resumeSeed:)`` instead,
    /// because calling this method requires an actor hop (`await`) that a separately-scheduled
    /// `connect()` Task is not ordered against. Init-time seeding has no such window: the fields are
    /// set before the object is ever handed to a second caller. This method remains for the CLI
    /// (`slopdesk-client`, a single sequential `Task` with no competing connect job — not racy there)
    /// and for tests that seed after construction.
    ///
    /// Design: seeding into the existing actor state (`sessionID` / `highestContiguousSeq`)
    /// means the established ``connect(...)`` line `let resume = sessionID ?? WireMessage.newSessionID`
    /// picks it up with no new parameter — the connect path needs no change. Calling this BEFORE
    /// `connect()` is the only safe window: `connect()` immediately reads both fields on the fast
    /// (pre-suspension) path. Calling it after `connect()` has no effect (the live session has
    /// already presented its own learned identity). Must only be called before the first connect.
    public func seedResumeIdentity(sessionID: UUID, seq: Int64) {
        self.sessionID = sessionID
        highestContiguousSeq = seq
        highestSeqFed = seq
    }

    /// Provides the transport with a startup cwd for the next PTY spawn. A host-side reattach IGNORES it
    /// (the live shell's cwd is preserved — `performReattach` never reads `channelOpen.initialCwd`); only a
    /// FRESH respawn honors it. It is therefore passed on every (re)connect (see `connect(...)`), so a pane
    /// whose host shell had to be respawned lands back in its project directory, not the daemon's `$HOME`.
    public func setInitialCwd(_ cwd: String?) {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        initialCwd = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Connects to `host:port`. A first call uses a NEW session (zero sessionID); a
    /// later call (driven by ``ReconnectManager`` or ``resume()``) reuses the learned
    /// ``sessionID`` and presents ``highestContiguousSeq`` so the host replays the tail.
    ///
    /// Idempotency: any previous transport is torn down first, so a reconnect attempt
    /// never leaks the old channels.
    public func connect(
        host: String,
        port: UInt16,
        handshakeTimeout: Duration = .seconds(10),
    ) async throws {
        guard !closed else { throw ClientError.invalidState("connect after close") }
        guard !childExited else { throw ClientError.invalidState("connect after child exit") }
        self.host = host
        self.port = port

        // Claim a generation BEFORE the first suspension (teardown). A concurrent connect that starts
        // while we are suspended will claim a HIGHER one, marking us stale at the post-handshake check.
        connectGeneration &+= 1
        let myGeneration = connectGeneration

        // Tear down any prior transport (reconnect path) so we never double-pump. Guard the
        // teardown so the old inbound pump's self-inflicted stream-end (the OLD transport
        // closing finishes the OLD inbound stream) does NOT surface a spurious `.disconnected`
        // that would make ReconnectManager queue a redundant reconnect campaign.
        tearingDownDepth += 1
        await teardownTransport()
        tearingDownDepth -= 1

        let transport = makeTransport()
        let resume = sessionID ?? WireMessage.newSessionID
        let lastSeq = highestContiguousSeq
        if let configurable = transport as? any InitialCwdConfigurableTransport {
            // Pass the startup cwd on EVERY (re)connect, not only the first. On the host a RETURNING
            // reattach (PATH A, `performReattach`) never reads `channelOpen.initialCwd` — it rebinds the
            // live shell, so the hint is ignored and the shell's real cwd is preserved. Only a FRESH
            // respawn (PATH B/C, `spawnFreshShell`, taken when the detached session is gone / TTL-expired)
            // reads it — and there we WANT the pane's project dir. Nil-ing it on reconnect would make
            // every fresh respawn land in `$HOME`, losing the working directory and collapsing the
            // cwd-derived pane/tab title to "Terminal".
            await configurable.setInitialCwd(initialCwd)
        }
        do {
            try await transport.connect(
                host: host,
                port: port,
                resume: resume,
                lastReceivedSeq: lastSeq,
                handshakeTimeout: handshakeTimeout,
            )
        } catch {
            await transport.close()
            throw error
        }

        // POST-HANDSHAKE re-check — the actor was reentrant across `await transport.connect(...)`.
        // If, during that suspension, the client was closed (deliberate disconnect) or paused (iOS
        // background), OR a NEWER connect() superseded us (claimed a higher `connectGeneration`), OR our
        // driving task was cancelled, we must DISCARD this freshly-built transport rather than adopt it.
        // Adopting it would assign `self.transport = transport` over the other live/closing one WITHOUT
        // tearing this one down — leaking a live transport + its inbound pump + ack ticker + the
        // ConnectionRegistry channel refcount (the zombie-transport bug). `transport.close()` releases
        // the channel (refcount--), so nothing leaks. We RETURN rather than throw: a thrown error would
        // make ``ReconnectManager``'s loop RETRY and fight whichever connect legitimately won — returning
        // tells it "the client is handled, stop the campaign."
        if closed || paused || Task.isCancelled || myGeneration != connectGeneration {
            await transport.close()
            return
        }

        self.transport = transport
        let learnedID = await transport.sessionID
        let resumeFromSeq = await transport.resumeFromSeq
        let returning = await transport.returningClient
        if let learnedID { sessionID = learnedID }

        // RESET DEDUP / ACK STATE — conditional on the HOST's authoritative resumeFromSeq.
        //
        // The correct signal is the HOST-AUTHORITATIVE `resumeFromSeq` from the handshake ack, NOT
        // the client-side `returningClient` flag (computed as `resume != newSessionID`, so ALWAYS
        // true on reconnect — a `!returning` gate would skip the reset exactly when it is most
        // needed; the dedup-regression test pins this).
        //
        //   • resumeFromSeq == 0  →  the mux path's constant answer (the openAck carries only
        //     `accepted: Bool`) — the host may have spawned a FRESH shell OR genuinely
        //     reattached (PATH A); the client cannot tell. The seq marks MUST be reset so a
        //     fresh shell's seq-1 output isn't dropped as a "duplicate" (a reattached shell's
        //     next seqs just re-baseline via the gap-tolerant `deliverOutput`).
        //
        //   • resumeFromSeq > 0  →  HOST honored a real RETURNING_CLIENT resume (SLOPDESK_DETACH_ENABLED
        //     path): it replays the tail from `resumeFromSeq` onward. The client's marks were seeded
        //     by ``seedResumeIdentity(sessionID:seq:)`` to match, so the dedup high-water is ALREADY
        //     correct — resetting would discard them and make `deliverOutput` re-deliver the replayed
        //     tail as new, duplicating output on the pane. Leave them.
        if resumeFromSeq == 0 {
            highestSeqFed = 0
            highestContiguousSeq = 0
            ackPending = false
            // KEEP the un-consumed inbox bytes. `deliverOutput` advanced `highestContiguousSeq` at
            // wire-ARRIVAL time, and this connect already presented it as `lastReceivedSeq` — so on a
            // genuine reattach the host will NEVER resend these bytes: the inbox copy is the only copy,
            // and a `removeAll()` here would make a silent, permanent scrollback gap at every reconnect
            // that races an undrained burst (deterministically so on iOS pause→resume). The entries
            // stay FIFO-ahead of the new life's output — correct for PATH A (tail of the same shell)
            // and for PATH B (the grid keeps the old session's content; its tail still belongs before
            // the fresh shell's bytes). Their wire-credit is ZEROED because `takeOutputBatch` credits
            // taken entries to the CURRENT transport, and the NEW channel's peer never sent those bytes
            // (a phantom windowAdjust over-grant otherwise).
            if !outputInbox.isEmpty {
                outputInbox = outputInbox.map { (bytes: $0.bytes, wireBytes: 0) }
            }
        }

        if returning, let learnedID {
            // Surface the reconnect so the UI flips `.reconnecting` → `.connected`
            // (ConnectionViewModel folds this event). NOTE: despite the name, this is NOT a byte-exact
            // resume on the mux path — the shell is fresh; the event only conveys "the link came back".
            eventBroadcaster.yield(.reconnected(sessionID: learnedID, resumeFromSeq: resumeFromSeq))
        }

        // Re-assert the last known window size on (re)connect so the remote PTY matches
        // the local terminal even after a resume rebound the control channel.
        if let size = lastSentResize {
            try? await transport.sendResize(cols: size.cols, rows: size.rows, pxWidth: size.px, pxHeight: size.py)
        }

        // POST-ADOPTION re-check: the post-handshake check above ran BEFORE four more cross-actor awaits
        // (transport.sessionID/resumeFromSeq/returningClient/sendResize), each a reentrancy window. If a
        // deliberate close()/pause() landed during any of them, teardownTransport() already cancelled +
        // niled the pumps and closed this transport — re-creating the pumps here would leak a forever-
        // spinning ack ticker (its loop has no closed/transport guard). Bail before starting them.
        if closed || paused || Task.isCancelled || myGeneration != connectGeneration {
            await transport.close()
            return
        }

        // Arm the resume-outcome probe for THIS adopted connection, strictly BEFORE the pump can
        // deliver its first output: `deliverOutput` resolves ``sessionResumeOutcome`` against the
        // `lastReceivedSeq` we presented (captured pre-handshake — the marks above were reset since).
        presentedResumeSeq = lastSeq
        sessionResumeOutcome = .undetermined

        startInboundPump(transport)
        startAckTicker()
        startPingTicker()
    }

    /// Pumps the transport's merged inbound stream: dedups + delivers `output`, surfaces
    /// title/bell/exit, and finishes (surfacing `.disconnected`) when the stream ends.
    private func startInboundPump(_ transport: any ClientTransporting) {
        let inbound = transport.inbound
        inboundTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in inbound {
                    await handleInbound(message)
                }
                await handleStreamEnded(error: nil)
            } catch {
                await handleStreamEnded(error: error)
            }
        }
    }

    /// Test-only seam: drive one inbound `WireMessage` through the exact same handling
    /// path the live inbound pump uses (dedup + contiguous tracking + surface/event
    /// fan-out), without standing up a real transport. `internal`, reached via
    /// `@testable import` — this is the only way to prove the client-side dedup high-water
    /// mark independent of host replay behavior (the host always keys replay off
    /// `lastReceivedSeq`, so an e2e never feeds an already-fed seq).
    func handleInboundForTesting(_ message: WireMessage) async {
        await handleInbound(message)
    }

    /// Test-only: whether a transport is currently adopted (`self.transport != nil`). Used by the
    /// reconnect-race regression suite to assert that a connect superseded/closed/paused mid-handshake
    /// does NOT leave a zombie transport adopted on the client.
    var hasLiveTransportForTesting: Bool { transport != nil }

    private func handleInbound(_ message: WireMessage) async {
        switch message {
        case let .output(seq, bytes):
            await deliverOutput(seq: seq, bytes: bytes, wireBytes: message.wireByteCount)
        case let .exit(code):
            // TERMINAL for this client (see `childExited`): the wake stream below cannot be
            // re-armed, so no later connect may spawn a shell into the now consumer-less inbox.
            childExited = true
            eventBroadcaster.yield(.exit(code: code))
            // The byte stream is over once the child exits. Finishing the wake stream ends
            // the consumer's wake loop; its final takeOutputBatch() drains any tail.
            outputWakeContinuation.finish()
            // `.exit` is data-class (it rode the windowed DATA sub-channel): credit it
            // immediately — it never enters the inbox.
            await transport?.noteOutputConsumed(wireBytes: message.wireByteCount)
        case let .title(text):
            eventBroadcaster.yield(.title(text))
        case .bell:
            eventBroadcaster.yield(.bell)
        case let .commandStatus(status):
            eventBroadcaster.yield(.commandStatus(status))
        case let .notification(title, body):
            eventBroadcaster.yield(.notification(title: title, body: body))
        case let .foregroundProcess(name):
            // COARSE Claude detection (type 26): surface the PTY foreground-process basename so the UI
            // can derive a presence floor for this pane. Rides CONTROL; never blocks output.
            eventBroadcaster.yield(.foregroundProcess(name: name))
        case let .claudeStatus(state, kind, label):
            // RICH Claude status (type 27): surface the raw bytes; the UI maps them back to a
            // ClaudeStatus (SlopDeskClient does not depend on SlopDeskAgentDetect).
            eventBroadcaster.yield(.claudeStatus(state: state, kind: kind, label: label))
        case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText, promptOrdinal):
            // BLOCK metadata (type 28): surface verbatim; the UI upserts a per-pane block keyed by index.
            eventBroadcaster.yield(.commandBlock(
                index: index, exitCode: exitCode, durationMS: durationMS,
                complete: complete, outputLen: outputLen, commandText: commandText,
                promptOrdinal: promptOrdinal,
            ))
        case let .blockOutput(index, output):
            // BLOCK output (type 29): the reply to a requestBlockOutput. Surface the raw VT bytes; the
            // UI resolves the pending request (empty == evicted/unknown — the UI must not hang).
            eventBroadcaster.yield(.blockOutput(index: index, output: output))
        case let .metadataResponse(requestID, status, payload):
            // METADATA reply (type 30): the reply to a requestMetadata. Surface the raw status byte +
            // opaque payload verbatim; the UI's MetadataRequestRegistry correlates it by requestID and the
            // typed MetadataClient decodes the payload (SlopDeskClient does not depend on MetadataCodec).
            eventBroadcaster.yield(.metadataResponse(requestID: requestID, status: status, payload: payload))
        case let .inputEcho(enabled):
            // SECURE INPUT (type 31): surface the host PTY termios `ECHO` edge so the macOS UI can engage
            // process-global Secure Keyboard Entry while the remote shell is at a no-echo password prompt.
            // Rides CONTROL; never blocks output.
            eventBroadcaster.yield(.inputEcho(enabled: enabled))
        case let .progress(state, percent):
            // OSC 9;4 PROGRESS (type 32): the decoder carried the RAW state byte verbatim (a faithful
            // byte round-trip keeps the golden vector stable); VALIDATE it HERE at the boundary and DROP an
            // unknown discriminant (4/5/…/255) rather than forwarding a byte the UI cannot map. The
            // host-clamped `percent` (0…100) rides through. Only a known state reaches the UI's badge/Dock.
            guard let validated = ProgressState(wire: state) else { break }
            eventBroadcaster.yield(.progress(state: validated, percent: percent))
        case let .cwd(path):
            eventBroadcaster.yield(.cwd(path))
        case let .projectKey(path):
            // Host-computed By-Project key (type 34): surface verbatim; the GUI store validates + persists.
            eventBroadcaster.yield(.projectKey(path))
        case let .pong(timestampMS):
            recordPong(sentAtMS: timestampMS)
        default:
            // input/hello/resize/ack/bye/helloAck never arrive on the client inbound.
            // Ignore defensively.
            break
        }
    }

    /// Folds one pong into the smoothed RTT (EWMA α=0.25) and broadcasts the fresh value.
    /// The timestamp is OUR monotonic clock echoed verbatim, so the math never involves
    /// the host's clock. A stale pong from before a suspend can yield a huge sample; the
    /// EWMA absorbs it (and the next samples correct it).
    private func recordPong(sentAtMS: UInt64) {
        let nowMS = DispatchTime.now().uptimeNanoseconds / 1_000_000
        guard nowMS >= sentAtMS else { return }
        let sample = Double(nowMS - sentAtMS)
        let smoothed = smoothedRTTMS.map { $0 * 0.75 + sample * 0.25 } ?? sample
        smoothedRTTMS = smoothed
        eventBroadcaster.yield(.rtt(milliseconds: smoothed))
    }

    /// The dedup + contiguous-tracking core. Drops any `output` already delivered
    /// (`seq <= highestSeqFed`) — this is what makes a replayed tail splice in without a
    /// duplicate. A future seq beyond `highestSeqFed + 1` would be a gap; the transport
    /// guarantees ascending in-order delivery (replay tail then live, `docs/20` §8.3), so
    /// in practice every accepted output advances the counter by exactly one.
    private func deliverOutput(seq: Int64, bytes: Data, wireBytes: Int) async {
        // First output on the CURRENT connection resolves the fresh-shell-vs-reattach verdict
        // (see ``SessionResumeOutcome``): a PATH-A reattach continues the retained seq stream
        // strictly past the presented `lastReceivedSeq`; a fresh shell restarts at seq 1. The
        // verdict is re-armed to `.undetermined` only by an adopted connect (before its pump
        // starts) or a stream end (after its pump's last delivery), so an OLD connection's late
        // delivery can never resolve the NEW connection's probe — the resolve is per-connection.
        if sessionResumeOutcome == .undetermined {
            sessionResumeOutcome =
                (presentedResumeSeq > 0 && seq > presentedResumeSeq) ? .resumedSession : .freshShell
        }
        guard seq > highestSeqFed else {
            // Duplicate (replayed) — drop, but still CREDIT it: the bytes crossed the wire
            // and were fully processed (by discarding); withholding the credit would leak
            // window capacity on every replay.
            await transport?.noteOutputConsumed(wireBytes: wireBytes)
            return
        }
        highestSeqFed = seq
        // Contiguous advance: with in-order delivery this tracks highestSeqFed exactly.
        if seq == highestContiguousSeq + 1 {
            highestContiguousSeq = seq
        } else if seq > highestContiguousSeq {
            // Defensive: never regress; accept forward jumps as the new contiguous high
            // (the transport does not produce gaps, but we must never ack less than we
            // delivered, and never more than we have).
            highestContiguousSeq = seq
        }
        // Append-then-yield: the pending wake (bufferingNewest(1)) always observes a
        // complete inbox, so no chunk can be stranded without a wake. The wire byte count
        // rides along so takeOutputBatch can credit the consumption.
        outputInbox.append((bytes: bytes, wireBytes: wireBytes))
        outputWakeContinuation.yield(())
        surfaceFeed?(bytes)
        // Mark an ack as pending; the coalescing ticker sends it.
        ackPending = true
    }

    private func handleStreamEnded(error: Error?) {
        // The link is gone: the dead connection's resume verdict must not survive it — a stale
        // `.resumedSession` read between the drop and the next connect would let the UI skip the
        // fresh-session wipe the NEXT session may need. Reset unconditionally (before the guards:
        // a deliberate close / self-inflicted teardown end invalidates the verdict just the same).
        sessionResumeOutcome = .undetermined
        // Surface a disconnect (unless we are closing on purpose, or we ourselves are
        // tearing the old transport down to reconnect — in which case this end is
        // self-inflicted and a real `.disconnected` would queue a redundant reconnect).
        // ReconnectManager watches `events` / observes the thrown connect error.
        // `childExited`: the post-exit FIN is likewise an EXPECTED end — the `.exit` event already
        // told the UI the session is over; a `.disconnected` here would flip the pane to a
        // forever-"reconnecting" (and, before the ReconnectManager exit gate, launched a respawn
        // campaign against a client whose output nothing can consume).
        guard !closed, !tearingDown, !childExited else { return }
        let reason = if let error { String(describing: error) } else { "stream ended (FIN)" }
        eventBroadcaster.yield(.disconnected(reason: reason))
    }

    // MARK: Ack coalescing

    /// Starts (or restarts) the background ack ticker. On each tick, if a contiguous
    /// advance is pending, send a single `ack(highestContiguousSeq)`. Cancelled on
    /// teardown/close. We re-create it per connect so it always targets the live
    /// transport.
    private func startAckTicker() {
        ackTask?.cancel()
        let interval = ackInterval
        ackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await flushAckIfPending()
            }
        }
    }

    /// Starts (or restarts) the RTT probe ticker: one `ping(now)` on the CONTROL channel
    /// every ``pingInterval``. Best-effort (`try?`) — a dropped probe just skips a sample.
    /// Re-created per connect so it always targets the live transport; cancelled on
    /// teardown/close beside the ack ticker.
    private func startPingTicker() {
        pingTask?.cancel()
        let interval = Self.pingInterval
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await sendPingProbe()
            }
        }
    }

    private func sendPingProbe() async {
        guard let transport else { return }
        let nowMS = DispatchTime.now().uptimeNanoseconds / 1_000_000
        try? await transport.sendPing(timestampMS: nowMS)
    }

    private func flushAckIfPending() async {
        guard ackPending, let transport else { return }
        let seq = highestContiguousSeq
        ackPending = false
        // Never ack 0 (nothing received) or a seq we have not delivered.
        guard seq > 0 else { return }
        do {
            try await transport.sendAck(seq: seq)
        } catch {
            // Send failed (channel dropped): re-arm so the next live transport acks it.
            ackPending = true
        }
    }

    /// Forces an immediate ack flush (used by tests and by ``close()`` for a clean
    /// final ack). Safe to call any time.
    public func flushAck() async {
        await flushAckIfPending()
    }

    // MARK: Outbound (client → host)

    /// Sends raw keystroke/paste bytes as `input`.
    public func sendInput(_ bytes: Data) async throws {
        guard let transport else { throw ClientError.invalidState("sendInput before connect") }
        try await transport.sendInput(bytes)
    }

    /// Sends a `resize`, remembering it so it is re-asserted after a reconnect.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        lastSentResize = (cols, rows, pxWidth, pxHeight)
        guard let transport else { throw ClientError.invalidState("sendResize before connect") }
        try await transport.sendResize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight)
    }

    /// Requests a Block's captured OUTPUT bytes (wire type 15) — fired when the user copies/expands a
    /// block whose `index` came from a `.commandBlock` event. The host replies with a `.blockOutput`
    /// (type 29) the inbound pump surfaces as a `.blockOutput` event (empty == evicted/unknown). Rides the
    /// CONTROL channel, so it never head-of-line-blocks behind an output flood on DATA.
    public func requestBlockOutput(index: UInt32) async throws {
        guard let transport else { throw ClientError.invalidState("requestBlockOutput before connect") }
        try await transport.sendRequestBlockOutput(index: index)
    }

    /// Requests host-side pane metadata (wire type 16) — fired by the typed ``MetadataClient`` façade
    /// behind the Details Panel. `verb` selects the operation (``MetadataVerb``), `requestID` is a
    /// client-chosen monotonic id the host echoes so the registry can correlate the reply, and `payload`
    /// carries the verb's argument (empty for the pane-scoped verbs — the pane rides the channel
    /// envelope). The host always replies with a `.metadataResponse` (type 30) the inbound pump surfaces;
    /// the registry's 5 s timeout is the belt-and-braces guard for a dropped reply. Rides the CONTROL
    /// channel, so it never head-of-line-blocks behind an output flood on DATA.
    public func requestMetadata(requestID: UInt32, verb: UInt8, payload: Data) async throws {
        guard let transport else { throw ClientError.invalidState("requestMetadata before connect") }
        try await transport.sendMetadataRequest(requestID: requestID, verb: verb, payload: payload)
    }

    // MARK: iOS lifecycle seam ([17] §2.5)

    /// App backgrounded: proactively tear the transport down. The host keeps the shell
    /// + replay buffer alive; output produced while paused is retained for replay. Idempotent.
    public func pause() async {
        guard !paused, !closed else { return }
        paused = true
        // Best-effort clean ack of what we have, then a clean bye so the host marks us
        // offline immediately (the kernel would FIN soon anyway).
        await flushAckIfPending()
        if let transport {
            try? await transport.sendBye()
        }
        // Guard the teardown so the old inbound pump's self-inflicted end does not add a
        // spurious `.disconnected` on top of the explicit "paused" one we yield below.
        tearingDownDepth += 1
        await teardownTransport()
        tearingDownDepth -= 1
        eventBroadcaster.yield(.disconnected(reason: "paused (backgrounded)"))
    }

    /// App foregrounded: reconnect with the preserved `sessionID` + seq for a byte-exact
    /// resume. No-op if not paused / already closed.
    public func resume() async throws {
        // `childExited`: an exited pane must not come back on foreground — resume would spawn a
        // fresh host shell into the finished wake stream's consumer-less inbox. No-op, like closed.
        guard paused, !closed, !childExited else { return }
        paused = false
        guard let host, let port else { throw ClientError.invalidState("resume before first connect") }
        try await connect(host: host, port: port)
    }

    /// True while paused by ``pause()`` (diagnostics / reconnect gating).
    public var isPaused: Bool { paused }

    /// True once ``close()`` has permanently retired the client (diagnostics / reconnect gating).
    /// ``ReconnectManager`` consults this ALONGSIDE ``isPaused`` because the two deliberate-shutdown
    /// paths are NOT symmetric: ``pause()`` yields an explicit `.disconnected` AND sets `paused`,
    /// but ``close()`` sets `closed` and `finish()`es the event stream WITHOUT yielding `.disconnected`.
    /// A real transport drop that yielded `.disconnected` just before `close()` leaves that event
    /// BUFFERED in a subscriber ahead of the stream's finish — so a reconnect supervisor that gated
    /// only on `isPaused` would pop the stale drop after close and run a doomed `connect`-after-close
    /// campaign. Gating on `isClosed` too closes that race.
    public var isClosed: Bool { closed }

    /// True once the remote child has `.exit`ed — this client instance is permanently done (see
    /// `childExited`). ``ReconnectManager`` consults this ALONGSIDE ``isPaused``/``isClosed``:
    /// `.exit` sets neither of those, and the host's post-exit FIN would otherwise read as a real
    /// drop and launch a reconnect campaign that respawns host shells into a consumer-less inbox.
    public var isExited: Bool { childExited }

    /// Test-only: simulate a hard network loss — tear down the transport (cancelling the
    /// underlying NWConnections) WITHOUT sending a clean `bye`, exactly as an iOS TCP
    /// teardown or a NetBird path flap would. Preserves `sessionID` + `highestContiguousSeq`
    /// so a subsequent ``connect(...)`` is a byte-exact RETURNING_CLIENT resume. The
    /// surfaced ``output`` / ``events`` streams stay open (this is a drop, not a close).
    ///
    /// Marked underscored + documented as test-only; the production drop path is the
    /// transport failing on its own (handled by ``handleStreamEnded(error:)``).
    public func forceDropForTesting() async {
        await teardownTransport()
    }

    // MARK: Teardown

    /// Tears down only the transport + its pumps (NOT the surfaced streams) so a
    /// reconnect can replace them. Cancels the inbound + ack tasks and closes the
    /// transport (which cancels its forwarders and the underlying NWConnections).
    private func teardownTransport() async {
        let oldInbound = inboundTask
        inboundTask?.cancel()
        ackTask?.cancel()
        pingTask?.cancel()
        inboundTask = nil
        ackTask = nil
        pingTask = nil
        await transport?.close()
        transport = nil
        // Drain the old inbound pump to completion. `close()` above finished the old
        // inbound stream, so the pump is unwinding into `handleStreamEnded(error: nil)`.
        // Awaiting its `.value` here guarantees that self-inflicted end is fully processed
        // BEFORE the caller clears `tearingDown` — so its `.disconnected` is suppressed
        // deterministically (not by timing). The task never throws (`Task<Void, Never>`).
        await oldInbound?.value
    }

    /// Permanently closes the client: tears down the transport and finishes the
    /// surfaced streams. After this the client is unusable.
    public func close() async {
        guard !closed else { return }
        closed = true
        await flushAckIfPending()
        if let transport { try? await transport.sendBye() }
        await teardownTransport()
        outputWakeContinuation.finish()
        eventBroadcaster.finish()
    }
}
