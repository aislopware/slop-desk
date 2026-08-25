import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import SlopDeskSupervisor
import SlopDeskTransport
import SlopDeskTTY

/// Identity of ONE subscriber to a pane — the key the PTY-size fold and (from the fan-out on) the
/// per-subscriber relay state are held under.
///
/// A plain integer minted by the session rather than the client's `sessionID`: subscribers are a
/// host-side set with host-side lifetimes, and keying them by anything a peer supplies would let a
/// peer address another peer's slot.
typealias MuxSubscriberID = UInt64

/// One logical mux channel's host-side PTY relay.
///
/// A ``PTYProcess`` bridged to the client over a channel's data + control ``MuxSubChannel`` pair,
/// with per-channel `output` sequencing via a private ``ReplayBuffer``. MANY of these ride ONE
/// shared ``MuxNWConnection`` — one TCP connection-pair carries N panes, each with its own shell.
/// Implemented over the ``MessageChannel`` protocol (which ``MuxSubChannel`` conforms to).
///
/// Relay shape:
/// - OUTPUT: a no-buffer ``PaneOutputStream`` → an ordered FIFO → one sequential awaiter that assigns a
///   seq via the per-channel `ReplayBuffer` and writes `output` on the channel's DATA sub-channel;
///   `.title`/`.bell` sniffed non-destructively and written on the CONTROL sub-channel after.
/// - INPUT: the DATA sub-channel's inbound `input` → master fd.
/// - RESIZE/BYE/ACK: the CONTROL sub-channel's inbound → `TIOCSWINSZ` / offline / (ack is a no-op
///   beyond release; there is no per-channel reconnect replay so it just keeps the buffer bounded).
/// - EXIT: the reaper enqueues `exit(code:)` on the same FIFO so it follows the final output tail.
///
/// ### Bounded output queue (always on)
/// The DATA send window SUSPENDS the drain when a flooding channel runs out of credit — but without
/// an upstream bound that just moves the unboundedness one hop: the reader would buffer the
/// whole `yes` flood into the FIFO. So the queue is BOUNDED by a
/// ``SlopDeskProtocol/BoundedQueuePolicy`` (byte high-water mark): when enqueued-not-yet-sent bytes
/// cross the bound the ``PaneOutputStream`` is PAUSED (superd stops issuing `read()`, so
/// the kernel PTY buffer fills and backpressures the shell — the real flood fix); it RESUMES when
/// the drain brings the queue back under the bound.
///
/// ### Detach / reattach (tmux-style survival)
/// On client disconnect with detach enabled, ``detach()`` runs instead of ``shutdown()``: it cancels
/// the relay tasks and DROPS this pane's supervised output subscription, keeping only the byte
/// OFFSET the stream had reached. The shell survives, and it keeps running at full speed — superd's
/// pump drains the master into its ring with or without a subscriber, so nothing about being
/// detached backpressures the agent. On return, ``rebindRelay(data:control:onExit:)`` swaps the
/// stale sub-channels, re-subscribes at that offset (the detached window arrives from superd's ring,
/// with an announced gap if it has evicted past it), KEEPS the out-FIFO (its frames were never
/// sequenced into the ReplayBuffer, so the cancelled drain's leftovers are only recoverable there),
/// clears the stateless control-out, rebuilds the wake streams, and restarts the relay tasks.
///
/// `@unchecked Sendable`: mutable state is touched under `taskLock` / `replayLock` / the
/// ``PausableQueueGate``'s own lock; the PTY/channels are themselves thread-safe.
final class MuxChannelSession: @unchecked Sendable {
    let channelID: UInt32
    let pty: PTYProcess

    /// The session identity the client sent in the `channelOpen` preamble. Used by
    /// ``DetachedSessionStore`` and ``HostServer`` to match a returning client to its live
    /// shell. Immutable after init.
    private(set) var sessionID: UUID

    /// This object's identity where objects cannot go: the slot ``HostSessionRegistry`` files every
    /// relation about this session under.
    ///
    /// Minted per OBJECT, not per session id — the detach window can mint a fresh session under an
    /// id whose predecessor is still winding down, and every identity guard hostd spells `===`
    /// (remove this key only while it still names THIS session; does this teardown still own the
    /// hook sink) is that distinction. Unique for the life of the process and never zero.
    let registrySlot: UInt64 = HostSessionRegistry.mintSlot()

    /// Whether this session is currently in the detached state (client gone, shell alive).
    /// Answered by ``PaneLifecycle``, which serializes it. A detached session must NOT be
    /// `shutdown()`'d — use ``detach()`` / ``shutdownDetached()`` from ``DetachedSessionStore.evict``
    /// paths.
    var isDetached: Bool { life.isDetached }

    /// One subscriber's half of the relay: the sub-channel PAIR it rides, the three tasks bound to
    /// that pair, its own control-out queue, and its own ack cursor.
    ///
    /// The channels are `let` — a subscriber IS its pair. A returning client REPLACES the member
    /// instead of having new channels swapped in underneath it, so every task a subscriber owns is
    /// bound to a pair that cannot change under it. That is what makes it safe for the inbound loops
    /// to read their own channel directly: there is no "the session's channel" for half the relay to
    /// follow and the other half to stay pinned to.
    ///
    /// Every NUMBER about a member — its ack cursor, its delivery frontier, whether it has a sender,
    /// whether it has been told the exit, whether it is on its way out — lives in ``PaneFanout``
    /// under the same id, never here. What is left is what could not cross a C ABI: the pair, the
    /// tasks bound to it, its two queues and their wakes.
    ///
    /// Locks: `subscribersLock` guards the three task references and `retired`; `controlOutLock`
    /// guards the control queue + its wake (the same lock those fields had as session state);
    /// `fifoLock` guards the data queue + its wake.
    final class Subscriber: @unchecked Sendable {
        let id: MuxSubscriberID
        let data: MuxSubChannel
        let control: MuxSubChannel

        /// The three tasks bound to this pair, and whether the pair has been retired. All four are
        /// guarded by `subscribersLock`: a relay builder and a retire can genuinely race (a channel
        /// that finishes the instant it is handed over), and the flag is what stops the loser of
        /// that race from installing a task on a member nobody will ever cancel.
        ///
        /// `retired` is the ONE latch that did not go to ``PaneFanout``, and deliberately: it is
        /// about this OBJECT's tasks being cancelled, not about the set. It outlives membership
        /// (``shutdown()`` cancels every member's relays without retiring the set) and it must be
        /// readable from a task builder holding a member the set may already have dropped.
        var inputTask: Task<Void, Never>?
        var controlTask: Task<Void, Never>?
        var controlSendTask: Task<Void, Never>?
        var retired = false

        /// This subscriber's OWN outbound DATA queue + wake + sender, built only once the pane is
        /// FANNED OUT (see ``MuxChannelSession/fanoutActive``). With one member the drain sends
        /// inline and all three stay nil.
        ///
        /// One queue per member is the only shape that keeps the drain single-consumer without
        /// giving the slowest reader head-of-line over everybody: ``MuxSubChannel/send(_:)`` parks
        /// on its OWN credit window, so a serial `for sub in subscribers { await sub.data.send() }`
        /// would let one parked phone stall delivery to a Studio indefinitely — and eviction could
        /// never fire, because the drain that would notice is the thing that is parked.
        ///
        /// Unbounded by construction and bounded in effect: everything queued here is un-acked, so
        /// ``PaneFanout/lagBytes`` caps it at 32 MiB per member before eviction
        /// takes the member out.
        var dataOut: [WireMessage] = []
        var dataWake: AsyncStream<Void>.Continuation?
        var dataSendTask: Task<Void, Never>?

        /// This subscriber's OWN pending control queue + wake. One queue per member, deliberately:
        /// the ``MuxChannelSession/maxControlOutQueued`` newest-shed promises a bound per reader, and
        /// a single shared queue with N cursors would let one stalled reader hold it at the cap and
        /// shed messages for the healthy ones.
        var controlOut: [WireMessage] = []
        var controlWake: AsyncStream<Void>.Continuation?

        init(
            id: MuxSubscriberID,
            data: MuxSubChannel,
            control: MuxSubChannel,
        ) {
            self.id = id
            self.data = data
            self.control = control
        }
    }

    /// Every client half currently holding this pane, keyed by ``MuxSubscriberID``.
    ///
    /// **N is exactly 1.** The set replaces the single `data`/`control` pair the relay used to hold
    /// so that the fan-out is a change of population rather than a change of shape — but nothing
    /// here adds a second member, and no caller can.
    ///
    /// `subscribersLock` is the INNERMOST lock in this file: it is taken, the answer is copied out,
    /// and it is released — never held across another lock acquisition or a call-out. That is what
    /// lets ``broadcastControl(_:)`` run from INSIDE `taskLock` (the reattach re-asserts do exactly
    /// that) without a lock cycle.
    private let subscribersLock = NSLock()

    /// The OBJECTS, by id. A channel pair, four tasks and two queues have no shape a C ABI could
    /// carry, so this half stays here; every scalar about a member is ``fanout``'s.
    private var subscribers: [MuxSubscriberID: Subscriber] = [:]

    /// The set as NUMBERS — `rust/slopdesk-muxsession`'s `fanout`, reached through `pane_fanout`.
    ///
    /// It owns the roster and its order, the id mint, each member's ack and delivery cursors, the
    /// retention floor, the producer bound, and both halves of the laggard rule. Guarded by
    /// `subscribersLock`, the one lock every scalar it holds already lived under.
    private let fanout = PaneFanout()

    /// Serializes the drain's [assign seq → hand the frame to every member] step against a JOIN.
    ///
    /// A joiner is state-transferred a rendered screen and then follows the live stream. Those two
    /// halves must MEET: composing the snapshot and entering the set have to be atomic w.r.t. the
    /// drain, or frames sequenced in between go to the incumbent alone and the joiner's transcript
    /// has a hole that no replay can fill (the joiner is not in the set to receive them, and they
    /// are below the seqs it will start from).
    ///
    /// Held ONLY across non-suspending work: the drain's inline `await send` happens after the
    /// unlock. Lock order: `fanoutLock` → `subscribersLock` / `replayLock` / `taskLock`; nothing
    /// takes it in the other direction. Only ``admitJoiner`` and
    /// ``rebindRelay(data:control:onExit:transformDetachedBacklog:)`` hold it together with
    /// `taskLock`, and both take it FIRST — the rebind then releases it before doing its work, so no
    /// section ever holds `taskLock` while a drain is parked on this.
    private let fanoutLock = NSLock()

    /// Whether the drain hands frames to per-member outboxes instead of sending inline.
    ///
    /// Set the first time a second member joins, and cleared at exactly ONE place: a
    /// ``rebindRelay(data:control:onExit:transformDetachedBacklog:)`` on a session whose set has
    /// EMPTIED. It survives a member merely LEAVING, deliberately — flipping modes while a surviving
    /// member's sender is still draining its outbox would put two writers on one data channel. An
    /// emptied set has no such member: `detach()` retired every one of them, finishing its wake and
    /// dropping its outbox, so the returning client is a genuine one-member pane again.
    /// Guarded by `fanoutLock`.
    ///
    /// While false — every pane exactly one client is holding, which is most of them — the drain is
    /// a plain inline send and no outbox is ever built.
    private var fanoutActive = false

    /// Closes ONE subscriber's channel from OUTSIDE this session — the eviction seam.
    ///
    /// `MuxSubChannel.finish()` is internal to `SlopDeskTransport` and a session holds no reference
    /// to the owning ``MuxNWConnection``, so there is no way to wake a member parked on an
    /// exhausted credit window from in here. ``HostServer`` wires this to
    /// `connection.closeChannel(channelID)`, which finishes both sub-channels — a parked sender
    /// throws and unwinds. Invoked from a DETACHED task, never from the drain the park is blocking
    /// and never via a further `send`.
    var onEvictSubscriber: (@Sendable (MuxSubscriberID) -> Void)?

    /// Optional diagnostic sink (the daemon log), set by the owner. `nil` (the headless smoke
    /// daemon and every unit test that does not wire it) means an eviction is silent.
    var onLog: (@Sendable (String) -> Void)?

    /// Every subscriber in ascending id order — a deterministic broadcast order (dictionary order
    /// is not).
    private func subscriberList() -> [Subscriber] {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return fanout.ids.compactMap { subscribers[$0] }
    }

    /// How many members hold this pane right now (the fold's and the gate's population).
    var subscriberCount: Int {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return fanout.count
    }

    private func subscriber(_ id: MuxSubscriberID) -> Subscriber? {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return subscribers[id]
    }

    /// Whether host-side Claude-Code agent detection (the foreground process-watch) is enabled for
    /// this channel. When true, ``startRelay()`` spins a low-rate poll that resolves
    /// the PTY's foreground basename and drives ``ClaudePaneDetector`` → type-26/27.
    private let agentDetectEnabled: Bool

    /// The interval between foreground-process samples (~1 Hz; injected so a future test could
    /// drive it, though the poll itself is never run in a unit test — hang-safety).
    private let agentPollInterval: Duration

    /// LIVE probe of the host's agent-hook listener bind state, injected by ``HostServer``
    /// (`{ agentHookListener?.isListening ?? false }`). Read per
    /// `agentHookStatus` (verb 13) request so the reply reports whether hooks are ACTUALLY flowing,
    /// not just installed on disk. Defaults `false` (no listener wired — the honest answer).
    private let agentHookListenerActive: @Sendable () -> Bool

    /// Whether this channel asked superd for a command-block tap. When false no segmenter touches
    /// the pane's stream, no `0x05` frame ever arrives, and no type-28/29 is ever emitted. Resolved
    /// from `SLOPDESK_BLOCKS` (default-ON) by the owner and sent with the `spawn`.
    private let blocksEnabled: Bool

    /// The pane's LATCHED TRUTHS and the ONE lock over them — docs/59 §4, step 4.
    ///
    /// The title and its stamp, the OSC 9;4 badge, the command edge, the last exit code and
    /// duration, the running block's command line, the echo anchor and the finished-turn counter
    /// were SEVEN stored properties behind seven `NSLock`s, all seven written on the read-loop
    /// thread and read from a control socket's. They were separate because the FIELDS were separate,
    /// never because the truths are: one sniffed batch folds most of them in one pass, so seven
    /// acquisitions bought no concurrency against a serial writer and cost every reader the chance
    /// of a torn view.
    ///
    /// Each one is a LATCH rather than a query, and that distinction is load-bearing:
    /// ``PaneLiveness/capture`` reads the running command for every pane on every reconciler tick,
    /// so it has to be a lock acquisition rather than a round trip. Everything else about a pane's
    /// blocks IS a round trip (`blockOutput`, `blockSnapshot`, `blockControl`), because every other
    /// reader is a person or an agent asking once.
    ///
    /// ``agentDetector`` sits behind this lock too: it is folded from the same batch (a sniffed
    /// title is a detection input) and read in the same breath (the type-25 gate asks it whether the
    /// pane's agent already announces its own edges), so a second lock would only be a chance to
    /// pair a fresh title with a stale verdict.
    ///
    /// The PROJECT truths — the freshest cwd, the By-Project key it resolved to, and the warm-up
    /// gate in front of both — are the eighth latch this lock absorbed (docs/59 §4, step 5). They
    /// are written from a second context (`metadataQueue`, when a resolver walk returns) and read
    /// by the same reattach re-assert as everything above, so the pairing argument is the one this
    /// lock already makes: a client that reconnects must not be told a cwd and a key that were
    /// never true at the same instant.
    private let truthsLock = NSLock()
    private let truths = PaneTruths()

    /// The SINGLE per-pane Claude detector (ONE `ClaudeStatusMachine`, ``rust/slopdesk-agent``'s
    /// `machine`). Fed by ALL detection
    /// inputs — the foreground poll's `processPresent`, the per-poll `tick` (drives the `.done→.idle`
    /// decay), and the hook socket's bytes — so the host is the single source of truth. Touched from
    /// TWO contexts (the serial `agentWatchTask` and the socket-accept thread when a hook POSTs), so
    /// it is guarded by ``truthsLock``. ONE machine, deliberately: a pair of independent machines
    /// (`foregroundDetector` + `agentHookHandler`) would fight over the one type-27 stream.
    private let agentDetector = ClaudePaneDetector()

    /// The foreground-watch poll task (cancel on shutdown).
    private var agentWatchTask: Task<Void, Never>?

    /// Screen-rule engine feed (the herdr-port manifest engine, DECISIONS round 4). The
    /// latency-critical read loop only APPENDS each chunk here (one bounded `Data` append —
    /// the P6 objection to per-chunk scanning stays honoured); the 300 ms scan task drains it
    /// into the resident grid and runs the regex ladder. Guarded by `screenScanLock`; the
    /// scanner itself is scan-task-owned (single writer, never shared).
    private let screenScanLock = NSLock()
    private var screenPendingBytes = Data()
    /// TRUE ⇒ the resident grid is stale (first scan / resize / pending overflow): the next
    /// scan rebuilds it by replaying the scrollback ring (full-screen apps repaint, so a
    /// mid-ring start converges — the same property the `screen` verb relies on).
    private var screenModelDirty = true
    /// Bumped per PTY chunk — the scanner's idle-scan skip (no new bytes ⇒ no regex work).
    private var screenContentSeq: UInt64 = 0
    /// Pending-bytes bound: a scan task this far behind falls back to a ring rebuild.
    private static let screenPendingCap = 512 * 1024
    private var screenScanner = PaneScreenScanner()
    private var screenScanTask: Task<Void, Never>?
    /// Mirrors `agentDetectEnabled`. It used to AND in a `SLOPDESK_AGENT_SCREEN` opt-out — a second
    /// flag for one feature, with no UI and no operational reason, whose OFF blinded the only
    /// detection branch that runs on a host without hooks. Detection is one decision, taken once.
    private let agentScreenDetectEnabled: Bool
    /// Deep job-probe cache (wrapper basenames): positive hits stick 5 s (herdr's identified
    /// recheck), misses 1 s — the 300 ms scan never pays a pgroup enumeration per tick.
    private var jobProbeCachedAgent: AgentKind?
    private var jobProbeCachedAt: TimeInterval = -.infinity

    // MARK: - Agent-control surface state

    /// The last foreground process name the watcher sampled (`pane/foregroundProcess`). Latched
    /// here rather than re-probed per read: `PTYForegroundProbe.foregroundName` is a syscall, and
    /// the reconciler would pay it per pane per tick.
    private let foregroundLock = NSLock()
    private var _lastForeground: String?

    /// Test seam for the prompt-edge cwd probe (the ``HostMetadataProbe`` `proc_pidinfo` read):
    /// unit tests drive ``ingestPTYChunkForTesting(_:)`` on an UNSPAWNED PTY (hang-safety rule), where
    /// the real probe answers `nil` (pid −1 guards out before any syscall) — injecting a fake here
    /// lets them exercise the non-OSC-7 derivation path deterministically. `nil` (production) uses
    /// the real probe.
    var cwdProbeOverride: (() -> String?)?

    /// Test seam for the async project-key resolve hop: production dispatches the
    /// ``ProjectKey/of(cwd:)`` stat-walk onto the serial `metadataQueue` (resolves stay ordered);
    /// tests inject a run-inline executor (deterministic emission) or a deferred one (pinning that
    /// a slow/hung resolve never blocks ``ingestPTYChunk(_:)``). `nil` (production) uses
    /// `metadataQueue.async`.
    var projectKeyResolveExecutorOverride: ((_ resolve: @escaping @Sendable () -> Void) -> Void)?

    /// Fired whenever a NEW By-Project key LATCHES for this pane (spawn seed / cwd-change resolve —
    /// exactly the type-34 emission edges), on the resolve executor's thread, never the read loop.
    /// ``HostServer`` wires it to the ``RepoStatusWatcher`` refcounts so precisely the repos with
    /// live panes are FSEvents-watched. Set once at session wiring.
    var onProjectKeyResolved: (@Sendable (String) -> Void)?

    /// One-shot end-of-life signal (every teardown path funnels through ``shutdown()``), invoked
    /// OUTSIDE the locks. ``HostServer`` wires it to release this pane's repo-watch refcount —
    /// without it a closed pane would keep its repo's FSEvents stream (and probe subprocesses)
    /// alive for the daemon's life.
    var onTeardown: (@Sendable () -> Void)?
    private var teardownSignaled = false

    /// How many times ``teardown(killChild:)`` has run all the way to its last statement. Guarded by
    /// ``taskLock``, like every other teardown flag here. Read only by tests.
    private var teardownCompletions = 0

    /// Observer closures registered by the agent-control `wait` and `subscribe` verbs. Each is
    /// called with the raw PTY chunk immediately after the sniffer pass (non-destructive, never
    /// modifies the byte stream). Guarded by `observersLock`.
    private let observersLock = NSLock()
    private var outputObservers: [UUID: @Sendable (Data) -> Void] = [:]
    /// Close-observer closures registered by the agent-control `subscribe` verb. Called once,
    /// after the PTY read loop has drained to EOF (so all output observers fire before this),
    /// from the exit task. Guarded by `observersLock`.
    private var closeObservers: [UUID: @Sendable () -> Void] = [:]
    /// Block-observer closures registered by the agent-control `run --wait` verb. Called from
    /// ``notifyBlockObservers(_:)`` (the PTY read-loop thread) with each type-28 block-metadata emission,
    /// AFTER the tracker has retained the block's output (so a completion observer can fetch the
    /// body immediately). Guarded by `observersLock`.
    private var blockObservers: [UUID: @Sendable (CommandBlockUpdate) -> Void] = [:]

    /// One type-28 block-metadata emission, decoded for block observers. `complete` is true only
    /// for a `D`-closed block; a closed-but-interrupted block arrives `complete == false` with a
    /// non-nil `durationMS`, and a RUNNING open-block update carries `durationMS == nil`.
    struct CommandBlockUpdate: Sendable {
        var index: UInt32
        var commandText: String
        var exitCode: Int32?
        var durationMS: UInt32?
        var complete: Bool
    }

    /// A dedicated serial queue for the host metadata RPC's BLOCKING probe work (git/lsof/proc/
    /// FileManager). Kept OFF the serial control loop so a slow `lsof` / `git` can never stall this
    /// pane's resize/ack/ping; ``sendControl(_:to:)`` (lock-guarded) carries the answer back to the
    /// peer that asked. Serial so concurrent metadata requests for one pane don't pile up
    /// subprocesses.
    private let metadataQueue = DispatchQueue(label: "slopdesk.host.metadata", qos: .userInitiated)

    /// The bounded-admission counter for this session's metadata work (guarded by
    /// `metadataInFlightLock`; a slot is taken at admission in
    /// ``serveMetadata(requestID:verb:payload:)`` and released when the work item finishes). The
    /// control sub-channel is deliberately unwindowed, so this counter is the ONLY bound between a
    /// hostile/buggy peer streaming back-to-back tiny `.metadataRequest` frames and an unbounded
    /// pile of queued closures (each retaining its payload + self) forking `git`/`lsof` without
    /// limit. The count and the cap are ``MetadataAdmission``'s; the queue stays here.
    private let metadataInFlightLock = NSLock()
    private let metadataAdmission = MetadataAdmission()

    /// How many times the read loop has asked superd to retire the title anchor. Read only by the
    /// suite that pins WHEN the retirement is asked for; written only on the read-loop thread.

    /// The prior life's distilled transcript (fresh-spawn restore, `HostServer.spawnFreshShell`).
    /// Enqueued as the FIRST output frame(s) by ``startRelay()`` — before the read loop starts —
    /// so it precedes every live shell byte. `nil`/empty = nothing to restore. RELEASED (nil'd)
    /// by ``enqueueRestoredScrollback()`` once handed to the out-FIFO: a stored session-lifetime
    /// copy pinned up to the journal cap of bytes per restored pane. Guarded by `fifoLock`
    /// (written once post-init; the test seam reads it cross-thread).
    private var restoredScrollback: Data?
    /// Where this pane's supervised output stream is picked up — see
    /// ``PaneOutputStream``'s `fromOffset`. `0` (the whole ring) for a freshly spawned pane, whose
    /// stream starts there anyway; the offset its predecessor stopped ingesting at for an ADOPTED
    /// one, whose earlier bytes are already in ``restoredScrollback`` and must not arrive twice.
    private let resumeFromOffset: UInt64

    private let taskLock = NSLock()
    private var replay: ReplayBuffer
    private let replayLock = NSLock()

    /// State-transfer replay (docs/DECISIONS.md 2026-07-25): compose the reattach replay by
    /// RENDERING the screen model once instead of replaying (however distilled) byte history.
    struct SnapshotReplayPolicy: Sendable {
        /// `(raw chronological history, rows, cols) -> rendered snapshot stream`
        /// (``TerminalReplaySnapshot/compose(raw:rows:cols:)`` in production).
        let compose: @Sendable (Data, Int, Int) -> Data
        /// A WARM reconnect whose pending raw replay (the un-acked tail) meets this many bytes is
        /// snapshotted (the rendered preamble wipes the live grid);
        /// below it the tail replays raw, byte-exact. Cold clients always snapshot.
        let warmThresholdBytes: Int
    }

    /// The injected snapshot policy (nil = replay exactly as before). `HostServer` injects the
    /// env-derived policy; tests inject their own or none.
    private let snapshotReplay: SnapshotReplayPolicy?
    /// Serializes ``updateReplayBackpressure()``'s [recompute → gate apply] pair across the
    /// independent caller tasks (output drain / ack path / detach) — see that method's docs.
    private let backpressureApplyLock = NSLock()
    private var exitTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    /// Wake for the output FIFO drain. Read/written ONLY under `fifoLock` (producers run on
    /// the read-loop thread + the exit task; `shutdown()` nils it — an unguarded optional
    /// read would race the teardown).
    private var outputWakeContinuation: AsyncStream<Void>.Continuation?
    private var readLoop: PaneOutputStream?

    /// The pane's own arc, whose decisions live in `rust/slopdesk-muxsession`'s `lifecycle`: the
    /// one-time relay start, whether THIS detach is the one that tears down, whether a returning
    /// client may rebind, where its subscription re-opens, and the two latches the exit task waits
    /// on. It serializes itself — see ``PaneLifecycle`` — which is why `eofLock` and `exitSentLock`
    /// are gone and `taskLock` is left guarding only the objects that cannot cross.
    private let life = PaneLifecycle()

    /// Guards ``outbox`` and ``outputWakeContinuation`` — the pair whose atomicity is the whole
    /// no-lost-wake discipline. Producers append under this lock then yield the bufferingNewest(1)
    /// wake OUTSIDE it; the single drain pops until empty before re-parking (the proven
    /// ConnectionViewModel outQueue shape — append-then-yield, drain-until-empty, no lost wake, no
    /// Task-per-item).
    private let fifoLock = NSLock()

    /// The output queue, whose ORDER lives in `rust/slopdesk-muxsession`'s `outbox`: what coalesces,
    /// where an over-cap head splits, and that `.exit` is a barrier neither may cross. This side
    /// holds the bytes each queued slot names; no byte crosses the door. Guarded by `fifoLock`,
    /// which is why ``PaneOutbox`` carries no lock of its own.
    private let outbox = PaneOutbox()

    /// Guards every subscriber's ``Subscriber/controlOut`` + ``Subscriber/controlWake`` — one queue
    /// and one wake per member (same teardown race as ``outputWakeContinuation``).
    ///
    /// Sniffed control is split from the data drain so a slow/stalled CONTROL socket (or per-redraw
    /// title churn) can never stall data sends — a shared drain would make data wait on control.
    /// Per-subscriber control FIFO still holds (running→idle, successive titles); cross-socket order
    /// vs data is NOT guaranteed (different TCP connections).
    private let controlOutLock = NSLock()

    /// Pops the next frame the drain must ship, or `nil` when the queue is empty.
    ///
    /// The merge, the over-cap head split and the `.exit` barrier are ``PaneOutbox``'s — the
    /// arithmetic moved with the queue it is about. What is here is the lock the caller already
    /// owned: every producer and this one consumer touch the queue under `fifoLock`, which is the
    /// serialization ``PaneOutbox`` is documented to require rather than provide.
    func nextOutboundFrame() -> PaneOutbox.Frame? {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        return outbox.take()
    }

    /// Bounded-queue backpressure GATE: fuses the ``BoundedQueuePolicy`` accounting with the
    /// read-loop pause/resume action ATOMICALLY under one lock (see ``PausableQueueGate``).
    /// Built in ``startRelay()`` once the `readLoop` exists (so the gate can drive it). `nil` until then.
    private var outputGate: PausableQueueGate?

    // MARK: - The resolved grid (a min-fold over contributors, applied by ONE writer)

    /// One contributor as the workspace roster publishes it — who, whether they vote, and what they
    /// offered. The shape is ``PaneResizeFold``'s, because the fold that decides `contributes` is.
    typealias ResizeAttachment = PaneResizeFold.Attachment

    /// The subscriber every pane has before the fan-out exists: the one client channel this session
    /// was opened for. A named constant rather than a literal so the seam is visible.
    static let primarySubscriberID: MuxSubscriberID = 0

    /// One-frame (default) settle window for the inline resize micro-debounce. Injected so a test
    /// drives the deadline deterministically (the `StaticIDRDecider` `now`-injection discipline) —
    /// `.zero` in tests applies the LATEST size on the next runloop turn with no wall-clock sleep.
    private let resizeDebounce: Duration
    /// The longer settle a CONTRIBUTOR-SET change arms, so a burst of joins resolves the grid ONCE
    /// instead of SIGWINCHing the shell per arrival (docs/45 §8.3 rule 2).
    private let sizeSettle: Duration
    /// Whether the subscriber this session opens for votes in the fold. Resolved HOST-side from the
    /// workspace channel's `clientKind`, never from anything the pane channel itself claims.
    private let openedSizePassive: Bool
    /// Guards the resize state below. The state is touched from FOUR contexts — the serial
    /// `controlTask`, the debounce `Task` when it fires, the settle `Task` when it fires, and
    /// `shutdown()` — so unlike the single-writer `controlTask`-only fields it needs a lock (the
    /// codebase's `taskLock`/`replayLock` discipline). Held only around O(1) field reads/writes.
    private let resizeLock = NSLock()
    /// Makes "the ONE writer" a claim about the WRITE, not just about the resolve.
    ///
    /// ``applyResolvedGrid(ifGeneration:)`` runs from four contexts at once (the control relay's
    /// flush, the debounce task, the settle task, `resizeForControl` on the ctl connection thread).
    /// `resizeLock` alone only makes each RESOLVE atomic: two callers can resolve in one order and
    /// land their `TIOCSWINSZ` in the other, so the grid the PTY keeps is whichever thread the
    /// scheduler happened to resume LAST — an older fold silently undoing a newer one. That is how a
    /// busy host loses a `slopdesk-ctl resize` (the override applies, then a flush that resolved a
    /// beat earlier writes the old fold back over it) and how the journal size sidecar ends up
    /// naming a geometry the PTY no longer has.
    ///
    /// Holding this across the generation check, the resolve, the live compare and the ioctl makes
    /// the applies TOTALLY ORDERED: whoever writes last also resolved last, so the last write is by
    /// construction the newest state. OUTERMOST — taken only by `applyResolvedGrid`, always before
    /// `resizeLock`, so the order is one-directional and cannot invert.
    private let resizeWriteLock = NSLock()
    /// Regression seam: a stall the writer runs INSIDE `resizeWriteLock`, between resolving the grid
    /// and reading the live `TIOCGWINSZ`.
    ///
    /// `nil` outside `MuxChannelSessionResizeFoldTests`, where it is what makes the total order
    /// OBSERVABLE. Park one applier here and a second one either waits for the lock — and therefore
    /// resolves AFTER this write — or walks past it and has its newer resolution overwritten when
    /// this one resumes. Without the stall the interleaving belongs to the scheduler, and a green run
    /// says only that the machine happened to resume two threads in the order the state wanted.
    var resizeApplyStallForTesting: (@Sendable () -> Void)?
    /// The fold itself — every subscriber's standing offer, the ctl override, the settle latch and
    /// the generation counter — held in `rust/slopdesk-muxsession` through ``PaneResizeFold``.
    ///
    /// Offers are the fold's ONLY input: presence is 100 ms-throttled, per-connection,
    /// newest-clock-wins NETWORK state, and folding it would let a WireGuard flap reflow a terminal.
    /// Guarded by `resizeLock` exactly as the stored properties it replaced were.
    private let fold: PaneResizeFold
    /// The in-flight debounce task (cancel-replace, à la `WorkspaceStore.scheduleSave`).
    private var resizeDebounceTask: Task<Void, Never>?
    /// The in-flight contributor-set settle task, and whether one is outstanding. While it is, an
    /// ordinary offer joins the fold WITHOUT arming the 16 ms debounce — arming it there is exactly
    /// what would make a burst of joins resolve N times instead of once.
    private var sizeSettleTask: Task<Void, Never>?
    /// LOST-PROMPT guard: a one-shot, cancel-replace task that re-sends `SIGWINCH` (`pty.nudgeRedraw`) a
    /// short delay AFTER a resize settles. `TIOCSWINSZ` already delivers one SIGWINCH, but that fires
    /// WHILE the client grid is still mid-reflow, so the shell's `zle reset-prompt` redraws into a
    /// transient grid that the final reflow then clears — leaving the prompt line blank with only a bare
    /// cursor. A second nudge once the grid is stable forces the shell/TUI to repaint the prompt at the
    /// final size. Owned by `resizeLock` (same discipline as `resizeDebounceTask`).
    private var redrawNudgeTask: Task<Void, Never>?

    /// Called once when the child exits so the owner can drop this channel from its map.
    var onExit: (@Sendable (UInt32) -> Void)?

    /// Supervision hook — fired whenever this pane's detected Claude status TRANSITIONS to a
    /// new value (foreground poll, hook POST, or a self-report). The ``HostServer`` sets it (like
    /// ``onExit``) to fan the cross-pane `agent_status_changed` event to top-level subscribers.
    /// `nil` by default → no fan-out (the headless smoke daemon never sets it). The closure is
    /// invoked OUTSIDE ``truthsLock`` to avoid holding the detector lock across the server's
    /// observer fan-out. Deduping consecutive identical states is the server's responsibility.
    var onAgentStatusChanged: (@Sendable (ClaudeStatus) -> Void)?

    /// Invokes ``onAgentStatusChanged`` (if set) with `status`. Called from the detector-folding
    /// sites AFTER ``truthsLock`` is released, only on a real status transition.
    /// `quiet` = the detector has qualified this transition as BOOKKEEPING (the wire `kind` byte's
    /// ``AgentStatusKind/quiet``): a `/compact` boundary, an Esc-cancelled dialog, or the screen
    /// watchdog correcting a hook block it outlasted. The status still moves — dots, rollups, the
    /// document — but it must NOT count as a finished turn. Without this veto every one of those
    /// lands on `working|needsPermission → idle`, the hook-less completion shape, and mints an
    /// unread badge for every attached client over something nobody did. The CLIENT already vetoes
    /// on the same byte (``WorkspaceStore/setAgentStatus``); this is the host-side half, which is
    /// what the multi-client unread latch actually reads.
    private func notifyAgentStatusChanged(_ status: ClaudeStatus, quiet: Bool) {
        // A finished turn is a TRANSITION, counted here — at the ONE place every detector fold
        // funnels a real transition through — which is why the count cannot be double-bumped by two
        // feeds observing the same edge.
        truthsLock.lock()
        truths.foldCompletion(status, quiet: quiet)
        truthsLock.unlock()
        onAgentStatusChanged?(status)
    }

    /// Whether `previous → next` mints one finished turn — ``ClaudeStatus/mintsFinishedTurn(previous:next:)``,
    /// the face over `slopdesk-agent`'s `attention::mints_finished_turn`. Kept as a named seam here
    /// because the hook-authority suite reads the same answer this counter does.
    static func isCompletionTransition(previous: ClaudeStatus, next: ClaudeStatus) -> Bool {
        ClaudeStatus.mintsFinishedTurn(previous: previous, next: next)
    }

    // MARK: - Serial PTY-input writer (ONE queue for every write path)

    /// The ONE serial queue every PTY input write lands on — client `input` frames (live relay AND
    /// the rebound relay after a reattach) and the agent-control `write`/`send-keys` raw injection.
    /// A dedicated serial queue (mirroring the supervisor client's read thread) because the master
    /// fd is deliberately blocking; funneling EVERY writer here is what makes teardown safe:
    /// ``shutdown()`` closes ``inputWritesClosed`` and `sync`-drains this queue BEFORE
    /// `pty.closeMaster()`, so a stale write can never land on a recycled fd number after the close
    /// (the write-side sibling of the `exitLock` TOCTOU guard on `setWindowSize`).
    private let inputQueue: DispatchQueue

    /// Teardown gate for PTY input writes. Guarded by `inputGateLock` (set by ``shutdown()`` on the
    /// teardown queue; read at the top of every `inputQueue` write block). Once true, every queued
    /// or future write block is a no-op — bytes for a dying pane are dropped, never written.
    private let inputGateLock = NSLock()
    private var inputWritesClosed = false

    /// Test seam for the serial PTY-input writer: when set, invoked ON `inputQueue` IN PLACE of the
    /// real blocking `write(2)` for every payload that passed the teardown gate. Hang-safe tests
    /// drive the gate/drain semantics on an UNSPAWNED PTY (whose fd −1 no-ops the real write before
    /// anything is observable). `nil` (production) writes to the live master fd.
    var ptyWriteOverrideForTesting: ((Data) -> Void)?

    private func inputWritesAreClosed() -> Bool {
        inputGateLock.lock()
        defer { inputGateLock.unlock() }
        return inputWritesClosed
    }

    /// Writes one client `input` payload on `inputQueue` and suspends until the write lands (or is
    /// dropped by the teardown gate) — credit-at-consumption needs the completion. The fd is
    /// re-read AT WRITE TIME inside the queue block (never captured at relay start): a reattach
    /// swaps relays while the same PTY lives on, so a captured fd could be stale by the time a
    /// queued write runs.
    private func writePTYInput(_ bytes: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            inputQueue.async { [weak self] in
                defer { done.resume() }
                guard let self, !inputWritesAreClosed() else { return }
                performPTYWriteOnInputQueue(bytes)
            }
        }
    }

    /// Fire-and-forget variant for the agent-control raw-injection path (the control socket's
    /// handler thread must never park on a stalled PTY). Same queue, same gate.
    private func enqueuePTYWrite(_ bytes: Data) {
        inputQueue.async { [weak self] in
            guard let self, !inputWritesAreClosed() else { return }
            performPTYWriteOnInputQueue(bytes)
        }
    }

    /// The gated write body — MUST run on `inputQueue`, after the ``inputWritesClosed`` check.
    private func performPTYWriteOnInputQueue(_ bytes: Data) {
        if let override = ptyWriteOverrideForTesting {
            override(bytes)
            return
        }
        let fd = pty.masterFD
        guard fd >= 0 else { return }
        Self.writeAll(fd: fd, data: bytes)
    }

    /// - Parameter resizeDebounce: the latest-wins settle window for `TIOCSWINSZ` applies (default
    ///   ~one frame). See ``scheduleResize(from:cols:rows:px:py:)`` for WHY a host-side debounce exists.
    /// - Parameter sizeSettle: the longer window a CONTRIBUTOR-SET change arms (docs/45 §8.3 rule 2).
    /// - Parameter isSizePassive: whether the subscriber this channel opens for votes in the size
    ///   fold. `false` — CONTRIBUTES — is the right default: a pane channel with no workspace channel
    ///   behind it is the shipped `slopdesk-client` CLI, and a CLI that cannot size its own pane is
    ///   broken.
    /// - Parameter sessionID: the UUID the client included in the `channelOpen` preamble; used by
    ///   ``DetachedSessionStore`` to match a returning client to its detached shell.
    init(
        channelID: UInt32,
        pty: PTYProcess,
        data: MuxSubChannel,
        control: MuxSubChannel,
        sessionID: UUID = UUID(),
        resizeDebounce: Duration = .milliseconds(16),
        sizeSettle: Duration = .milliseconds(750),
        isSizePassive: Bool = false,
        replay: ReplayBuffer = MuxChannelSession.makeReplayBuffer(),
        agentDetectEnabled: Bool = false,
        agentPollInterval: Duration = .seconds(1),
        agentHookListenerActive: @escaping @Sendable () -> Bool = { false },
        blocksEnabled: Bool = true,
        restoredScrollback: Data? = nil,
        resumeFromOffset: UInt64 = 0,
        snapshotReplay: SnapshotReplayPolicy? = nil,
    ) {
        self.channelID = channelID
        self.pty = pty
        // Subscriber #1 — the channel this session is opened FOR. Seeded here rather than in
        // ``startRelay()`` because a session's client half exists from the moment it is
        // constructed: `detach()` runs on sessions that never started a relay, and it must have a
        // member to retire.
        subscribers[Self.primarySubscriberID] = Subscriber(
            id: Self.primarySubscriberID, data: data, control: control,
        )
        fanout.join(Self.primarySubscriberID, acked: 0)
        self.sessionID = sessionID
        self.resizeDebounce = resizeDebounce
        self.sizeSettle = sizeSettle
        openedSizePassive = isSizePassive
        fold = PaneResizeFold(openedSizePassive: isSizePassive)
        self.replay = replay
        self.snapshotReplay = snapshotReplay
        self.agentDetectEnabled = agentDetectEnabled
        agentScreenDetectEnabled = agentDetectEnabled
        self.agentPollInterval = agentPollInterval
        self.agentHookListenerActive = agentHookListenerActive
        self.blocksEnabled = blocksEnabled
        self.restoredScrollback = restoredScrollback
        self.resumeFromOffset = resumeFromOffset
        // The resume cursor's seed. It falls out without a special case: a fresh spawn seeds `0` —
        // the ring's start — so a detach before the first chunk resumes from the beginning; an
        // adopted pane seeds its predecessor's stop offset, whose earlier bytes are already in
        // ``restoredScrollback``; an adopted pane with NO recorded boundary seeds
        // ``PaneOutputStream/fromNowOn``, and re-opening "from now" a second time is the same
        // nothing the first subscription had. The cursor becomes real the moment one chunk lands.
        life.recordOffset(resumeFromOffset)
        inputQueue = DispatchQueue(label: "slopdesk.host.pty-input.\(channelID)", qos: .userInitiated)
    }

    // MARK: - Relay builders (one per task; the ordering belongs to the CALLER)

    /// Builds the session's ONE output drain: pop merged frames off the shared FIFO, assign a seq
    /// via the per-channel ``ReplayBuffer``, and write them on the subscriber's DATA channel.
    ///
    /// Session-level, not per-subscriber: there is one out-FIFO and one sequence space, so exactly
    /// one task may pop. One seq per byte range is the ReplayBuffer's whole contract, so the POP
    /// stays single-consumer and only the RESULT fans out. The targets are RESOLVED per frame
    /// rather than captured, so a REPLACE lands the next frame on the returning client's channel
    /// instead of half-following the swap.
    private func startOutputDrain() {
        let (outputWakeups, outputWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        fifoLock.lock()
        outputWakeContinuation = outputWake
        fifoLock.unlock()
        outputTask = Task { [weak self] in
            for await _ in outputWakeups {
                // Drain until empty BEFORE re-parking (bufferingNewest(1) holds at most one
                // pending wake — a one-frame-per-wake drain would strand backlog).
                while let frame = self?.nextOutboundFrame() {
                    guard let self else { return }
                    switch frame {
                    case let .output(bytes, byteCount, controlMessages):
                        // Sequence the frame and choose its delivery shape ATOMICALLY w.r.t. a
                        // JOIN, so a joiner is either in the set for this frame or state-
                        // transferred a screen that already contains it — never neither.
                        let (fannedOut, targets, seq) = sequenceAndFanOut(bytes)
                        if !fannedOut {
                            // ONE member: send inline, exactly as a single-subscriber pane always
                            // has. `send` SUSPENDS on the per-channel credit window, so a flooding
                            // channel naturally slows here. An EMPTY set drops the frame, exactly
                            // as a send on the finished pair a departed client left behind did —
                            // including the dequeue, without which the gate would strand bytes and
                            // wedge the read loop.
                            if let target = targets.first {
                                try? await target.data.send(.output(seq: seq, bytes: bytes))
                            }
                        }
                        // dequeue MUST stay post-send (the gate bounds enqueued-not-yet-SENT;
                        // moving it to take-time would let the read loop refill while a merged
                        // frame is still unsent). Under fan-out "sent" means "handed to every
                        // member's outbox" — the host owns one copy per laggard until it acks,
                        // which is what `PaneFanout.lagBytes` eviction exists to bound.
                        dequeueOutput(byteCount)
                        // Hand sniffed control to the control senders: the data drain never awaits
                        // a control socket, so a stalled control link cannot freeze data.
                        if !controlMessages.isEmpty { broadcastControl(controlMessages) }
                    case let .exit(code):
                        await deliverExit(code: code)
                        signalExitSent() // release the exit task's await so onExit can run
                    }
                }
            }
        }
    }

    /// Builds `sub`'s CONTROL-OUT sender: one serial drain of ITS queue onto ITS control
    /// sub-channel, FIFO per subscriber (the only ordering consumers rely on — they fold each type
    /// independently, and cross-socket order vs data is non-deterministic anyway).
    private func startControlSender(for sub: Subscriber) {
        let (controlWakeups, controlWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        controlOutLock.lock()
        sub.controlWake = controlWake
        controlOutLock.unlock()
        let control = sub.control
        let sender = Task { [weak self] in
            for await _ in controlWakeups {
                while let batch = self?.takeControlBatch(for: sub) {
                    for message in batch {
                        try? await control.send(message)
                    }
                }
            }
        }
        install(sender, as: \.controlSendTask, on: sub)
    }

    /// Builds `sub`'s INPUT relay: its DATA sub-channel's inbound `input` → the master fd.
    ///
    /// The blocking `write(2)` runs on the session's ONE serial `inputQueue` (mirroring
    /// the supervisor client's read thread): the PTY master fd is deliberately blocking, so on the
    /// cooperative pool a paste into a non-reading foreground program would park a width-limited
    /// thread — a few wedged writers would degrade every other pane's drains. Credit is granted only
    /// AFTER the write returns (credit-at-consumption), so a stalled PTY transitively parks the
    /// CLIENT's sender at one window instead of buffering the paste in host RAM.
    ///
    /// Every member of a pane writes: the fan-out is tmux's, where each attached client types into
    /// the same shell. This loop is one of three writers into the master fd — one copy per member,
    /// plus ``writeRawForControl(_:)`` (the `slopdesk-ctl` / orchestrator injection).
    private func startInputRelay(for sub: Subscriber) {
        let data = sub.data
        let relay = Task.detached { [weak self] in
            do {
                for try await message in data.inbound {
                    if case let .input(bytes) = message {
                        await self?.writePTYInput(bytes)
                        // termios ECHO flips fastest around a password prompt — re-probe right
                        // after writing this keystroke so AUTO Secure Keyboard Entry engages with minimal
                        // lag. The detector dedupes, so the steady (echo-on) state emits nothing.
                        if let self {
                            sampleEcho(masterFD: pty.masterFD)
                            // A keystroke into a BLOCKED agent pane is the Esc-cancel/answer
                            // unblock edge — fold it so the hand drops when the user handles the
                            // dialog (a no-op in every other state; see the detector).
                            foldUserInput(bytes)
                        }
                    }
                    // Consumed (written to the PTY, or processed): grant the
                    // window back ON THE CHANNEL THE BYTES ARRIVED ON. Every ``MuxSubChannel`` owns
                    // its own ``ReceiveWindowAccountant``, and a sender parked on an exhausted window
                    // wakes only on a grant for ITS channel — crediting any other one parks the real
                    // sender after a single window with no event that can ever free it.
                    await data.noteConsumed(message.wireByteCount)
                }
            } catch { /* channel gone — the daemon keeps the shell alive (keep-alive) */ }
            // The DATA channel ended (clean close or drop): this subscriber is no longer reachable.
            // Retire it — identity-guarded, so a tail that lands AFTER a REPLACE cannot evict the
            // member that took its place — then recompute the session's online truth from the SET.
            // With one member that recompute is the `false` this site has always applied (engaging
            // the ReplayBuffer's 64 MiB offline gate); asserting `false` outright is what would, the
            // moment there are two, pause the PTY for a client that is still right there.
            self?.retireSubscriber(sub)
            self?.recomputeClientOnline()
        }
        install(relay, as: \.inputTask, on: sub)
    }

    /// Builds `sub`'s CONTROL relay: resize / bye / ack / ping / RPC on ITS control sub-channel.
    ///
    /// RESIZE backstop (defense-in-depth): a fast client drag can deliver ~100 distinct `.resize`
    /// (the client coalescer is the PRIMARY converger, but an old/replayed/slow client may not
    /// coalesce). Applying each `TIOCSWINSZ` immediately fires zsh's SIGWINCH handler at every
    /// INTERMEDIATE size; its incremental prompt-redraw math desyncs against a size that keeps
    /// changing → orphaned cursor / misaligned prompt that only a fresh prompt heals. A LOCAL
    /// terminal never hits this because the KERNEL coalesces SIGWINCH. So we restore that:
    /// latest-wins micro-debounce on this SERIAL loop — overwrite `pendingResize`, cancel+re-arm
    /// ONE debounce task that applies the LATEST size once after a one-frame settle. INLINE on the
    /// serial loop (no Task-per-resize → no reorder hazard); only the FREQUENCY of distinct
    /// applies is bounded (the ioctl itself, microseconds, stays inline).
    ///
    /// The subscriber's identity is threaded into every REQUEST-SCOPED answer below: a pong echoes
    /// ONE peer's clock stamp, and `requestID` is a PER-CLIENT counter — an answer delivered to the
    /// wrong member pops a waiter that asked something else and hands it a foreign payload.
    private func startControlRelay(for sub: Subscriber) {
        let control = sub.control
        let id = sub.id
        let relay = Task { [weak self] in
            do {
                for try await message in control.inbound {
                    switch message {
                    case let .resize(cols, rows, px, py):
                        self?.scheduleResize(from: id, cols: cols, rows: rows, px: px, py: py)
                    case let .ack(seq):
                        // A non-resize control message: FLUSH any pending size FIRST so the serial
                        // loop's ordering contract holds (a size that arrived before this ack lands
                        // before the ack's effects) and no settled size is stranded.
                        self?.applyResolvedGrid()
                        self?.acknowledge(upTo: seq, from: id)
                    case .bye:
                        self?.applyResolvedGrid() // client leaving cleanly: never strand a size at teardown.
                    case let .ping(timestampMS):
                        // Stateless RTT probe: echo the client's timestamp back on ITS OWN control
                        // sender (FIFO, never blocks behind data). Deliberately NO
                        // applyResolvedGrid — a periodic ping must not defeat the resize
                        // micro-debounce, and a ping orders against nothing.
                        self?.sendControl([.pong(timestampMS: timestampMS)], to: id)
                    case let .requestBlockOutput(index):
                        // Serve the block's retained output (type 29) from the ring, or an
                        // empty response if evicted / blocks disabled. Orders against nothing — like
                        // a ping, deliberately NO applyResolvedGrid so it can't defeat the debounce.
                        self?.serveBlockOutput(index: index, to: id)
                    case let .metadataRequest(requestID, verb, payload):
                        // Serve the Details-Panel metadata RPC (type 30) off the metadata queue.
                        // Orders against nothing — like blockOutput, NO applyResolvedGrid.
                        self?.serveMetadata(requestID: requestID, verb: verb, payload: payload, to: id)
                    default:
                        self?.applyResolvedGrid()
                    }
                }
            } catch { /* control gone */ }
            // Channel closed: apply any settled-but-undebounced final size before the loop ends.
            self?.applyResolvedGrid()
        }
        install(relay, as: \.controlTask, on: sub)
    }

    /// Retires ONE subscriber: drops it from the set and cancels the three tasks bound to its pair,
    /// finishing its control wake so a producer's enqueue cannot strand a message on a queue nobody
    /// drains.
    ///
    /// Guarded by OBJECT IDENTITY, not by id: a REPLACE mints a new member under the SAME id, and a
    /// stale task tail arriving after it would otherwise evict the client that just returned.
    ///
    /// The size contribution is deliberately NOT retired here. Membership of the fold is a
    /// state-plane fact keyed by the same id, and it outlives a channel swap by design — forgetting
    /// a returning client's standing offer would snap the pane back to its spawn size until it
    /// happened to send a fresh one.
    ///
    /// - Returns: whether the set is now EMPTY, so the caller can decide whether the session-wide
    ///   teardown follows. The queue-budget swap and the ring fold are DETACH decisions, not
    ///   consequences of one channel reaching EOF.
    @discardableResult
    private func retireSubscriber(_ sub: Subscriber) -> Bool {
        subscribersLock.lock()
        // Guarded by IDENTITY on this side, because identity is the one thing that cannot cross:
        // the far side is told to drop the id only once the object holding it is confirmed to be
        // the incumbent, so a stale tail cannot evict the client that just replaced it.
        let isIncumbent = subscribers[sub.id] === sub
        if isIncumbent { subscribers.removeValue(forKey: sub.id) }
        let emptied = isIncumbent ? fanout.leave(sub.id) : fanout.isEmpty
        subscribersLock.unlock()
        guard isIncumbent else { return emptied }
        cancelSubscriberTasks(sub)
        return emptied
    }

    /// Cancels the three tasks bound to `sub`'s pair and finishes its control wake, without touching
    /// membership — what ``shutdown()`` wants (a torn-down relay is not the statement "nobody holds
    /// this pane") and the tail of ``retireSubscriber(_:)``.
    ///
    /// The task references are read + cleared under `subscribersLock` and cancelled OUTSIDE it, the
    /// same "read+nil under the lock, cancel outside" discipline `shutdown()` applies to the resize
    /// tasks. Marking the member retired under that lock is what makes a builder still assembling a
    /// task cancel it instead of installing an orphan.
    private func cancelSubscriberTasks(_ sub: Subscriber) {
        subscribersLock.lock()
        sub.retired = true
        let tasks = [sub.inputTask, sub.controlTask, sub.controlSendTask, sub.dataSendTask]
        sub.inputTask = nil
        sub.controlTask = nil
        sub.controlSendTask = nil
        sub.dataSendTask = nil
        // A frontier frozen by a task nobody will resume would pin the producer for as long as the
        // member stays in the set — which is exactly what a `shutdown()` here does: it cancels
        // without retiring membership.
        fanout.clearSender(sub.id)
        subscribersLock.unlock()
        controlOutLock.lock()
        sub.controlWake?.finish()
        sub.controlWake = nil
        controlOutLock.unlock()
        // The outbound data queue goes with the member, like its control queue: nothing left in it
        // is deliverable, and its bytes were already dequeued from the session's gate when the
        // drain handed them over.
        fifoLock.lock()
        sub.dataWake?.finish()
        sub.dataWake = nil
        sub.dataOut.removeAll(keepingCapacity: false)
        fifoLock.unlock()
        for task in tasks { task?.cancel() }
    }

    /// Installs a freshly built relay task on `sub`, or cancels it outright when `sub` was retired
    /// while the task was being assembled — otherwise the loser of that race is an orphan: running,
    /// unreferenced, bound to a dead pair, and never cancelled by any teardown.
    private func install(
        _ task: Task<Void, Never>,
        as keyPath: ReferenceWritableKeyPath<Subscriber, Task<Void, Never>?>,
        on sub: Subscriber,
    ) {
        subscribersLock.lock()
        let retired = sub.retired
        if !retired { sub[keyPath: keyPath] = task }
        subscribersLock.unlock()
        if retired { task.cancel() }
    }

    /// Marks the pane reachable iff SOMEBODY still holds it. Recomputed on every membership change
    /// rather than asserted by whichever loop noticed a channel die.
    private func recomputeClientOnline() {
        setClientOnline(!subscriberList().isEmpty)
    }

    /// Opens this pane's supervised output subscription at `offset` and installs it together with a
    /// fresh ``PausableQueueGate`` wired to it — the two are built as a PAIR because a gate whose
    /// `setPaused` sink names a dead stream silently breaks the never-drop invariant (the gate would
    /// pause a stream nobody reads while the live one keeps filling the FIFO).
    ///
    /// The subscription is NOT started: the caller does that after leaving whatever lock it holds,
    /// because `subscribe` is a socket round trip, and because ``startRelay()`` seeds the FIFO in
    /// between so restored history precedes every live byte.
    ///
    /// This is the ONLY place a `PaneOutputStream` is minted after init, on purpose. superd owns
    /// `read` on the master; a rebind that opened its own reader would STEAL bytes from the pane's
    /// other subscribers rather than observe them.
    private func openSupervisedOutput(from offset: UInt64) -> PaneOutputStream {
        let stream = pty.makeOutputStream(
            fromOffset: offset,
            onChunk: { [weak self] chunk, endOffset, sniffed, blocks in
                // The offset is the RESUME CURSOR: `detach()` keeps it and `rebindRelay` re-opens
                // there, which is how the detached window stays superd's ring instead of becoming a
                // third copy in this host.
                self?.recordStreamOffset(endOffset)
                self?.ingestPTYChunk(chunk, sniffed: sniffed, blocks: blocks)
            },
            onEOF: { [weak self] in self?.signalEOFReached() },
        )
        stream.onLog = { [weak self] line in self?.onLog?("mux: \(line)") }
        readLoop = stream
        // Tell the ladder a subscription is open, so a later ``detach()`` knows to stop it and a
        // later ``rebindRelay(...)`` knows to mint a fresh one at the cursor this one leaves.
        life.streamOpened()
        // Build the bounded-queue gate now that the read loop exists, so pause/resume is
        // applied ATOMICALLY with the accounting (no lost-wakeup freeze).
        outputGate = PausableQueueGate(capacity: MuxFlowControl.hostQueueCapacityBytes) { paused in
            stream.setPaused(paused)
        }
        return stream
    }

    func startRelay() {
        // The one-time claim is ``PaneLifecycle``'s, which serializes it — a second caller loses
        // here rather than under `taskLock`, which is left guarding only the tasks and the stream.
        guard life.start() else { return }

        let pty = pty
        let masterFD = pty.masterFD
        // Subscriber #1 was seeded at init; a session with no member has no relay to start.
        guard let sub = subscriber(Self.primarySubscriberID) else { return }

        startOutputDrain()
        startControlSender(for: sub)

        // The channel this session was opened for is a size CONTRIBUTOR from the moment its relay is
        // live — a state-plane fact, established here rather than inferred from its first `.resize`,
        // so the set is right even for a client that never sends one.
        addResizeContributor(sizePassive: openedSizePassive)

        // superd does the reading now (`PaneOutputStream`) — hostd's duplicate of the master is for
        // writes, `TIOCSWINSZ` and `tcgetpgrp` only. An unspawned pane's stream is EOF from the
        // start, exactly as `PTYReadLoop` was with `masterFD == -1`, so nothing below is
        // conditional on a child existing.
        let stream = openSupervisedOutput(from: resumeFromOffset)
        // Fresh-spawn history restore MUST land between the gate build (so its bytes are
        // accounted) and the read-loop start (so it precedes every live shell byte).
        enqueueRestoredScrollback()
        // The geometry a later life's restore parses at is superd's to record: it stamps the
        // spawn-time winsize when it forks the pane and every `resize` this session sends
        // afterwards (`PTYProcess.setWindowSize`), so there is nothing to seed here.
        stream.start()

        startInputRelay(for: sub)
        startControlRelay(for: sub)

        let id = channelID
        exitTask = Task { [weak self] in
            let code = await pty.waitForExit()
            // Gate the exit yield on the read loop having drained the master to EOF, so the
            // FINAL output tail is enqueued AHEAD of `.exit` on the shared FIFO. `onEOF` is called by
            // the stream only AFTER superd has drained every byte, so awaiting the EOF latch here
            // guarantees `.exit` follows the last `.chunk` (the FIFO + single sequential drain preserve
            // that order on the wire). Bounded so a wedged/paused read never hangs exit delivery forever.
            await self?.awaitEOFOrTimeout()
            // Notify close observers (subscribe verb) AFTER the read loop has drained all output
            // to the output observers, so subscribers see a complete output stream before the
            // {"event":"closed"} line. Called here, before enqueueExit, so the ordering matches
            // the output-observer → close-observer → wire-exit sequence.
            self?.notifyCloseObservers()
            self?.enqueueExit(code: code)
            // Wait until the drain actually SENT `.exit` on the wire before firing onExit (which
            // triggers shutdown → outputTask.cancel()). Otherwise teardown can cancel the drain before
            // the buffered exit code is flushed, dropping the clean exit status. Bounded + cancellation-
            // aware (shutdown cancels this task), so a dead client / torn-down pane never hangs. Ordering
            // is preserved: `.exit` still follows the tail chunks on the FIFO (the EOF latch above).
            await self?.awaitExitSentOrTimeout()
            self?.onExit?(id)
        }

        // Foreground-process watch — the PRIMARY agent-detection signal. A low-rate poll resolves
        // the PTY's foreground basename and folds it through the pure ``ClaudePaneDetector``,
        // enqueueing the resulting type-26/27 CONTROL messages on a basename edge / status change
        // (the detector dedupes — an idle `claude` does not spam identical frames). The OS probe
        // (`tcgetpgrp`/`proc_pidpath`) is the thin shim; the decision logic is the pure detector.
        // Gated by `agentDetectEnabled` so the headless byte pipeline is byte-identical when off.
        if agentDetectEnabled {
            let interval = agentPollInterval
            agentWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    sampleForeground(masterFD: masterFD)
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }

        // Screen-rule scan loop (the herdr port's detection cadence): 300 ms steady, tightening
        // to 100 ms while a working→idle hold is pending. All grid feeding + regex work happens
        // HERE, never on the read loop; a quiescent idle pane skips the scan entirely.
        if agentScreenDetectEnabled {
            screenScanTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = scanScreenOnce(masterFD: masterFD)
                    do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                }
            }
        }
    }

    /// One screen-detection scan: drain the pending PTY bytes into the resident grid (or
    /// rebuild it from the scrollback ring when dirty), resolve the foreground agent, run the
    /// manifest engine + temporal layer, and fold a publish-worthy verdict into the ONE
    /// detector. Returns the next scan interval. Runs only on the scan task.
    private func scanScreenOnce(masterFD: Int32) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let size = pty.currentWindowSize()
        let rows = Int(size?.rows ?? 24)
        let cols = Int(size?.cols ?? 80)
        screenScanLock.lock()
        let pending = screenPendingBytes
        screenPendingBytes.removeAll(keepingCapacity: true)
        let needsRebuild = screenModelDirty
        screenModelDirty = false
        let seq = screenContentSeq
        screenScanLock.unlock()
        // The ring snapshot is taken OUTSIDE the scan lock (the ring has its own locking). A
        // chunk landing between the flag flip and this snapshot is fed twice — tolerated: the
        // grid converges on the next repaint, the same property a mid-ring start relies on.
        let replay: Data? = needsRebuild ? scrollbackRawForControl() : nil
        let output = screenScanner.scan(PaneScreenScanner.Input(
            pending: pending,
            rebuildReplay: replay,
            rows: rows,
            cols: cols,
            agent: screenAgent(masterFD: masterFD, now: now),
            contentSeq: seq,
            now: now,
        ))
        if let detection = output.publish { foldScreenDetection(detection, at: now) }
        return output.nextInterval
    }

    /// The foreground agent for the screen engine: the cheap basename probe through the ported
    /// alias table first; a generic runtime/shell basename (the npm-wrapped `claude` case) falls
    /// back to the DEEP job probe (pgroup + argv unwrap) behind a small cache — positive hits
    /// stick 5 s, misses 1 s — so the 300 ms cadence never pays a pgroup enumeration per tick.
    private func screenAgent(masterFD: Int32, now: TimeInterval) -> AgentKind? {
        let base = PTYForegroundProbe.foregroundName(masterFD: masterFD)
        guard base.isEmpty == false else { return nil }
        if let direct = AgentKind.identify(processName: base) {
            jobProbeCachedAgent = nil
            jobProbeCachedAt = -.infinity
            return direct
        }
        guard AgentKind.isGenericRuntimeOrShell(base) else { return nil }
        let cacheAge = now - jobProbeCachedAt
        if let cached = jobProbeCachedAgent, cacheAge < 5 { return cached }
        if jobProbeCachedAgent == nil, cacheAge < 1 { return nil }
        jobProbeCachedAt = now
        jobProbeCachedAgent = PTYForegroundProbe.agent(masterFD: masterFD)
        return jobProbeCachedAgent
    }

    /// Folds one published screen detection through the detector and enqueues the resulting
    /// type-27 (the detector dedupes). Split so tests drive the pure fold with an injected clock.
    private func foldScreenDetection(_ detection: AgentScreenDetection, at now: TimeInterval) {
        truthsLock.lock()
        let emission = agentDetector.screenDetection(detection, at: now)
        let newStatus = emission.status != nil
            ? (agentDetector.status, agentDetector.isQuietTransition)
            : nil
        truthsLock.unlock()
        publishAgentEmission(emission)
        if let newStatus { notifyAgentStatusChanged(newStatus.0, quiet: newStatus.1) }
    }

    /// Marks the resident screen grid stale (resize / any geometry change): the pending buffer
    /// is dropped and the next scan rebuilds from the scrollback ring at the new size.
    private func markScreenModelDirty() {
        guard agentScreenDetectEnabled else { return }
        screenScanLock.lock()
        screenPendingBytes.removeAll(keepingCapacity: false)
        screenModelDirty = true
        screenScanLock.unlock()
    }

    /// Resolves the PTY's foreground basename via the OS probe, folds it (plus a clock TICK) through the
    /// single ``ClaudePaneDetector``, and enqueues any resulting type-26/27 CONTROL messages. The clock
    /// is the monotonic uptime — a plain `Double` seconds, honouring the no-wall-clock-in-logic
    /// convention (the pure detector takes the time as a parameter; only this driver reads it).
    ///
    /// The per-poll `tick(at:)` is what drives the `.done → .idle` decay — nothing else advances the
    /// host machine's clock, so without it a finished turn would stay 🔵 forever. Both folds share the
    /// one machine under ``truthsLock`` (the hook socket-accept thread also folds into it).
    private func sampleForeground(masterFD: Int32) {
        foldForegroundSample(
            name: PTYForegroundProbe.foregroundName(masterFD: masterFD),
            at: ProcessInfo.processInfo.systemUptime,
        )
        // Ride the same low-rate poll as a BACKSTOP for the PTY-echo edge (a no-echo prompt that
        // appears without a fresh keystroke). The PRIMARY driver is the post-input probe.
        sampleEcho(masterFD: masterFD)
    }

    /// Folds one already-resolved foreground basename (plus the clock TICK) through the detector and
    /// enqueues the resulting type-26/27 messages. Split from ``sampleForeground(masterFD:)`` so the
    /// OS probe and the pure fold are separable — the fold is exercised directly by tests via a seam,
    /// mirroring ``foldEchoSample(echoOn:)``.
    private func foldForegroundSample(name: String, at now: TimeInterval) {
        foregroundLock.lock()
        _lastForeground = name
        foregroundLock.unlock()
        truthsLock.lock()
        // Tick FIRST so the decay is evaluated at this `now`, then the presence sample; both emit
        // type-27 only on a real triple change (the detector dedupes), so at most one status frame ships.
        let tickEmission = agentDetector.tick(at: now)
        let sampleEmission = agentDetector.sample(name: name, at: now)
        // A status transition (from EITHER fold) → notify the cross-pane supervision observer.
        // Both folds share the one machine, so the final `status` is the post-fold value.
        let statusChanged = (tickEmission.status != nil || sampleEmission.status != nil)
        let newStatus = statusChanged
            ? (agentDetector.status, agentDetector.isQuietTransition)
            : nil
        truthsLock.unlock()
        publishAgentEmission(tickEmission)
        publishAgentEmission(sampleEmission)
        if let newStatus { notifyAgentStatusChanged(newStatus.0, quiet: newStatus.1) }
    }

    /// Ships one detector emission: enqueues its control messages and, when it carries a TITLE
    /// RETIREMENT, drops the pane's cached title and asks the read loop to forget its coalescing
    /// anchor. Every fold site goes through here so the retirement can never ship down one path and
    /// be missed on another.
    private func publishAgentEmission(_ emission: ClaudePaneDetector.Emission) {
        guard !emission.isEmpty else { return }
        if emission.title != nil {
            // No title, no stamp: an ownership retirement must not leave a freshness verdict behind
            // for a title that no longer exists, and the sniffer's coalescing anchor is asked to
            // retire with it.
            truthsLock.lock()
            truths.retireTitle()
            truthsLock.unlock()
        }
        broadcastControl(emission.messages)
    }

    /// Folds one sniffed OSC 0/2 title through the detector and enqueues the resulting type-27
    /// (the detector dedupes — an unchanged status triple emits nothing). The title is Claude
    /// Code's own busy/rest telltale; the machine's conservative precedence decides what (if
    /// anything) it changes. Split from the sniffer loop so tests drive the pure fold with an
    /// injected clock.
    private func foldTitleSample(title: String, at now: TimeInterval) {
        truthsLock.lock()
        let emission = agentDetector.title(title, at: now)
        let newStatus = emission.status != nil
            ? (agentDetector.status, agentDetector.isQuietTransition)
            : nil
        truthsLock.unlock()
        publishAgentEmission(emission)
        if let newStatus { notifyAgentStatusChanged(newStatus.0, quiet: newStatus.1) }
    }

    /// Folds one client→PTY input chunk through the detector — the Esc-cancel unblock edge (a
    /// keystroke into a blocked pane demotes `.needsPermission` to `.idle`; every other state, and
    /// every automatic terminal reply, is a no-op inside the detector). Called after each relayed
    /// `input` frame AND after each agent-control raw injection (the cockpit's routed answer).
    /// Cheap on the steady path: the detector bails on the status check before touching the bytes.
    private func foldUserInput(_ bytes: Data) {
        guard agentDetectEnabled else { return }
        truthsLock.lock()
        let emission = agentDetector.userInput(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
        let newStatus = emission.status != nil
            ? (agentDetector.status, agentDetector.isQuietTransition)
            : nil
        truthsLock.unlock()
        publishAgentEmission(emission)
        if let newStatus { notifyAgentStatusChanged(newStatus.0, quiet: newStatus.1) }
    }

    /// Probes the PTY master's termios `ECHO` flag via the thin ``PTYEchoProbe`` shim,
    /// folds it through ``PaneTruths``, and enqueues a type-31 ``WireMessage/inputEcho``
    /// on the CONTROL sender on an edge (the detector dedupes — an unchanged echo state emits nothing).
    /// Called opportunistically right after writing client input to the PTY (where `ECHO` flips fastest
    /// around a password prompt) and from the foreground poll backstop. Cheap (one `tcgetattr` syscall).
    private func sampleEcho(masterFD: Int32) {
        foldEchoSample(echoOn: PTYEchoProbe.echoEnabled(masterFD: masterFD))
    }

    /// Folds one already-resolved `echoOn` bool through the detector and enqueues a type-31 on an edge
    /// (the detector dedupes — unchanged echo emits nothing). Split out from ``sampleEcho(masterFD:)`` so the
    /// OS probe and the pure fold are separable (the fold is exercised directly by tests via a seam).
    private func foldEchoSample(echoOn: Bool) {
        // The warm-up gate and the dedupe are both the fold's: until a confirmed echo-ON sample has
        // been seen on THIS connection a no-echo reading is suppressed entirely, because a transient
        // startup no-echo (termios not yet settled) must not latch the client's Secure-Input pill.
        // (Reattach has its own un-gated re-assert path.)
        truthsLock.lock()
        let message = truths.foldEcho(echoOn: echoOn)
        truthsLock.unlock()
        if let message { broadcastControl([message]) }
    }

    /// On a client (re)attach, RE-ESTABLISH the client's echo truth. The detector is
    /// edge-triggered against `lastEmitted`, and the client resets `hostNoEcho = false` on reconnect, so if a
    /// no-echo prompt (sudo / ssh / `read -s`) is up ACROSS the reattach the host would see no edge and emit
    /// nothing — leaving the client's AUTO Secure Keyboard Entry disengaged for the rest of the password entry
    /// (keystrokes UNPROTECTED). Echo state is, BY DESIGN, NOT in the replayed output byte stream (it is a host
    /// termios `ECHO` line-discipline attribute carried ONLY as a type-31), so it can be re-established for a
    /// returning client ONLY by a fresh type-31. Re-anchoring the detector to the canonical echo-on baseline
    /// then folding the CURRENT probed echo forces a fresh type-31 iff the live echo still deviates — re-sending
    /// no-echo truth to the freshly-attached client. The re-anchor is the load-bearing step: without it the
    /// re-fold of an unchanged state is a no-op and nothing is re-sent.
    ///
    /// Addressed to the JOINING subscriber: this is a fact about what THAT client has yet to be
    /// told, not an edge the pane just crossed.
    private func reestablishEchoOnReattach(
        echoOn: Bool,
        to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
    ) {
        truthsLock.lock()
        let message = truths.reanchorEcho(echoOn: echoOn)
        truthsLock.unlock()
        if let message { sendControl([message], to: id) }
    }

    /// The type-23/26/27/32/33/34/36 sibling of ``reestablishEchoOnReattach(echoOn:to:)``: re-emits
    /// the pane's CURRENT activity truths so a returning client — whose per-pane mirrors reset to
    /// idle/none on reconnect — is re-told what is still live (`sleep 300`'s busy dot + "sleep"
    /// label, a working/blocked agent's badge, a spanning OSC 9;4 spinner). Every source contributes
    /// only a NON-DEFAULT truth, so an ordinary idle reconnect enqueues nothing: an idle shell has
    /// no `runningSince` (and idle IS the client's reset state — a synthetic `.idle` would fabricate
    /// a lastCommand/completion edge), a cleared progress latches `nil`, and an untouched detector
    /// keeps the detection-off stream byte-identical.
    ///
    /// Addressed to the JOINING subscriber, like the echo re-assert: everybody else was told these
    /// truths when they happened.
    ///
    /// **The ORDER is the handle's, not this function's** (docs/59 §4, step 5). It used to live in
    /// a comment here, which is the failure mode `docs/55` §8 names: the title must land AFTER the
    /// command stamp its freshness is judged against, and a re-ordering edit that broke that would
    /// still compile, still pass every message-content assertion, and quietly cost every returning
    /// client its `main.go - NVIM` row for the rest of the session. So the ladder crosses as two
    /// lists of discriminants — head, then the detector's own re-assert, then tail — and
    /// `rust/slopdesk-muxsession`'s `truths` owns both.
    ///
    /// The detector splices BETWEEN the two halves because two handles never hold each other. Every
    /// entry is a non-default truth, so an ordinary idle reconnect asks for nothing and enqueues
    /// nothing.
    private func reestablishActivityOnReattach(
        to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
    ) {
        truthsLock.lock()
        let head = truths.reestablishHead.compactMap(truths.message(for:))
        let agentEmission = agentDetector.reestablishOnReattach()
        let tail = truths.reestablishTail.compactMap(truths.message(for:))
        truthsLock.unlock()
        let messages = head + agentEmission.messages + tail
        if !messages.isEmpty { sendControl(messages, to: id) }
    }

    // MARK: - Detach / reattach (tmux-style survival)

    /// Non-destructively detaches the relay from its current client connection.
    ///
    /// **The subscription is DROPPED, and the resume cursor is what survives.** The pane's bytes
    /// while away are superd's ring — absolute-offset addressed, with announced eviction — so hostd
    /// buffers none of them: the resume cursor records how far this session got, the stream is
    /// unsubscribed, and ``rebindRelay`` opens a fresh subscription at exactly that offset. The
    /// shell keeps running at full speed: superd's pump keeps draining the master into its ring
    /// whether or not anyone is subscribed, and losing the last subscriber CLEARS the pause
    /// (`docs/51` §6.5), so a detached agent is never the one that blocks.
    ///
    /// This is why the read loop is not merely paused. Pausing it (the old shape) transitively
    /// backpressured the SHELL through the kernel PTY buffer the moment the host-side queue filled,
    /// which is the exact failure `docs/51` exists to prevent — the detached budget only chose how
    /// long a detached agent ran before it froze.
    ///
    /// **onExit is rewired before detach completes** so a shell that exits WHILE IN THE
    /// STORE fires `onDetachedExit` (provided by the caller) rather than a handler the
    /// HostServer may have installed for a since-gone connection. Pass a closure that calls
    /// `store.remove(sessionID)` + `session.shutdownDetached()`.
    func detach(onDetachedExit: @escaping @Sendable (UUID) -> Void) {
        // The flag flip and the "is this call the one that tears down" answer are ``PaneLifecycle``'s
        // — taken BEFORE `taskLock`, because the ladder serializes itself and the lock below now
        // guards only the tasks, the wake and the stream.
        let verdict = life.detach()
        taskLock.lock()
        // Rewire onExit: if the child exits while we are in the store, fire the detached-exit
        // handler instead of whatever the previous connection wired.
        let id = sessionID
        onExit = { _ in onDetachedExit(id) }
        // Idempotence: a second detach on an already-detached session — the failed-rebind re-park
        // racing handleLinkDown's own detach — must be a no-op past the exit-handler refresh above.
        // The relay tasks/continuations are already torn down, the offline gate engaged, and the
        // subscription already dropped; re-running the teardown would only churn state another
        // thread may be inspecting — and would re-read a resume cursor that has stopped advancing.
        if !verdict.first {
            taskLock.unlock()
            return
        }
        // Retire every member (there is one): its input/control/controlSend tasks go with it. The
        // exit task is NOT cancelled — it must keep watching the child so onExit fires if the
        // shell dies.
        for sub in subscriberList() { retireSubscriber(sub) }
        // The set is empty, so the SESSION-wide half of the relay goes too. This is the teardown
        // that belongs to the set EMPTYING — a lone member losing its channel does not get to stop
        // the drain for anyone else.
        fifoLock.lock()
        outputWakeContinuation?.finish()
        outputWakeContinuation = nil
        fifoLock.unlock()
        outputTask?.cancel()
        outputTask = nil
        // Hand the pane's detached window back to superd. The cursor is already recorded — the read
        // loop advanced it on every chunk it ingested — so all that is left is to stop consuming.
        // `stop()` is PERMANENT for a `PaneOutputStream` (the `stopped` flag is irreversible), which
        // is why the rebind mints a NEW one at the resume cursor rather than reviving this one; both
        // go through `PaneOutputStream`, so neither is a second `read` on the master.
        //
        // The GATE is deliberately left standing, holding its accounting. Its `setPaused` sink names
        // the stream being stopped here, which is inert (a stopped stream ignores `setPaused`), and
        // its `outstanding` is the only record of FIFO bytes the cancelled drain never shipped —
        // `rebindRelay` carries that number onto the gate it builds around the new stream, so the
        // books still sum to zero once the restarted drain sends them.
        let stream = verdict.stopStream ? readLoop : nil
        readLoop = nil
        taskLock.unlock()
        stream?.stop()
        // Nobody holds the pane, which the ReplayBuffer's retention still wants to know: with no
        // client online its offline gate bounds what the buffer keeps for a return. There is no read
        // loop left to pause, so this is now accounting only.
        recomputeClientOnline()
    }

    /// Rebinds the relay to a fresh pair of sub-channels from a returning client.
    ///
    /// **Re-opens the supervised output at the cursor `detach()` left.** The detached window is
    /// superd's ring, so the recovery is a `subscribe` at the resume cursor and nothing else — the
    /// resumed bytes enter the FIFO exactly as live ones do, are sequenced at drain time, and land
    /// after the caller's `replayTail` (fresh seqs above every replayed seq → byte order preserved).
    ///
    /// **Keeps the out-FIFO, clears only control-out.** The FIFO can still hold frames the cancelled
    /// drain never shipped; clearing them would drop bytes `replayTail` cannot replay (they were
    /// never sequenced) and leak their ``PausableQueueGate`` accounting. Control-out IS cleared:
    /// control is stateless/re-derived (the echo truth and block metadata are re-asserted below).
    ///
    /// **onExit atomicity**: `onExit` is assigned INSIDE `taskLock`, BEFORE the new `exitTask`
    /// is started, so the handler installed by `detach()` (which routes to `shutdownDetached`)
    /// can never be the one a reattached exit task fires. The caller MUST pass the new handler
    /// here and must NOT reassign `session.onExit` after this call returns — doing so reopens
    /// the very window this parameter closes.
    ///
    /// - Parameters:
    ///   - newData: The new data sub-channel from the returning client.
    ///   - newControl: The new control sub-channel from the returning client.
    ///   - onExit: The handler the reattached session's exit task must fire. Assigned under
    ///     `taskLock` before `exitTask` is (re)started, making the assignment atomic with the
    ///     task launch and eliminating the race between a racing exit and a post-call assignment.
    ///
    /// - Precondition: `isDetached == true`. A no-op (safe) if called on a live session —
    ///   returning `false` so the caller can REFUSE the channel instead of acking a pane whose
    ///   relay is actually wired to someone else (a silent no-op would leave the loser of a
    ///   concurrent double-reattach believing it owned the pane).
    ///
    /// - Returns: `true` when the relay was rebound to the new sub-channels; `false` when the
    ///   session was not detached (nothing was changed).
    func rebindRelay(
        data newData: MuxSubChannel,
        control newControl: MuxSubChannel,
        onExit newOnExit: (@Sendable (UInt32) -> Void)?,
    ) -> Bool {
        // Lock order `fanoutLock` → `taskLock`, matching ``admitJoiner`` — the only two places that
        // hold both. Taken across the guards as well as the clear below, so the decision "this
        // session is detached, so its set is empty" cannot be invalidated by a concurrent join
        // between reading it and acting on it.
        fanoutLock.lock()
        taskLock.lock()
        // BOTH guards are one call to ``PaneLifecycle``, which un-detaches only when it proceeds.
        //
        // The second of them is why a dead sub-channel is passed in rather than inferred:
        // `MuxNWConnection.finishLink` finishes every sub-channel BEFORE firing `linkDownHandler`,
        // so already-finished targets mean the NEW connection died while the reattach was still
        // replaying — and `handleLinkDown` has re-parked (or is about to re-park) this session in
        // the DetachedSessionStore. Rebinding would flip the detached flag onto channels every send
        // throws on, leaving a stored session that reads as "attached" — the next claim then fails
        // its rebind and the session is orphaned (live agent unreachable by every map, store, TTL,
        // and stop()). Refusing keeps the session detached and claimable; the caller re-parks/reaps
        // via its failed-rebind path.
        let ladder = life.rebind(
            dataFinished: newData.isFinished, controlFinished: newControl.isFinished,
        )
        guard case let .proceed(resumeFrom) = ladder else { taskLock.unlock()
            fanoutLock.unlock()
            return false
        }
        // Back to ONE member, so back to the inline send. A pane that was ever fanned out reaches
        // here with `fanoutActive` still true, and the member below is built with no outbox sender
        // (only the JOIN path builds those) — leaving the flag set would route every frame into a
        // queue with a nil wake: the returning client sees the caller's `replayTail` state transfer
        // and then silence, forever, `.exit` included. Safe precisely because the set EMPTIED:
        // `detach()` retired every member, so no surviving sender can be mid-outbox here.
        fanoutActive = false
        fanoutLock.unlock()
        // JOIN — the one-subscriber special case. The returning client REPLACES the member the
        // detach retired: a subscriber IS its channel pair, so a new pair is a new member under the
        // same id, never a swap underneath the tasks a departed one owned.
        let sub = Subscriber(
            id: Self.primarySubscriberID, data: newData, control: newControl,
        )
        subscribersLock.lock()
        subscribers[sub.id] = sub
        fanout.join(sub.id, acked: 0)
        subscribersLock.unlock()

        // CRITICAL — assign onExit FIRST, while taskLock is still held and BEFORE exitTask is
        // (re)started below. This atomically replaces the detached-exit handler that detach()
        // installed (which calls store.remove + shutdownDetached) with the new reattach handler
        // (which calls removeMuxSession → the new connection's teardown). Without this, a shell
        // that exits between rebindRelay returning and the caller's post-call `session.onExit =`
        // assignment could fire the stale detached-exit handler and kill the just-reattached PTY.
        onExit = newOnExit

        // ONLY the control-out queue is dropped — the out-FIFO is KEPT (see the doc comment).
        // `detach()` cancels the drain where it stands, so the FIFO can hold frames the pane had
        // already ingested and not yet sent. Clearing them here would drop those bytes permanently
        // (`replayTail` cannot replay them — they were never sequenced → silent transcript gap; nor
        // can the resume below, whose cursor is already PAST them) AND leak their PausableQueueGate
        // accounting (no matching dequeue → a ≥64 KiB residue would leave the read loop paused
        // FOREVER — a frozen pane). The queue goes with the retired member, which is the
        // REPLACE-path-only semantics this wipe always had: control is stateless/re-derived (the
        // echo truth and block metadata are re-asserted below), and the joining member starts with
        // an empty one.

        // RE-OPEN the supervised output at the cursor `detach()` left behind. This is the whole of
        // the detached-window recovery: superd kept pumping the master into its ring the entire time
        // (it does that with no subscribers, and unsubscribing CLEARED the pause, so the shell never
        // stalled), and a subscribe at the resume cursor replays exactly the bytes produced since. It
        // is a `subscribe`, not a `read` — superd owns the only reader on this master, and a second
        // one would STEAL bytes from the pane rather than observe them.
        //
        // The gate is rebuilt with the stream because its `setPaused` sink names it; the outstanding
        // count from the pre-detach FIFO leftovers is carried onto the new gate so the books still
        // sum to zero when the restarted drain ships them. Sessions that never started a relay
        // (tests that inject a gate directly) have no subscription to re-open and keep theirs.
        //
        // A resume older than the ring's start is LOSSY, and announced as such: `PaneOutputStream`
        // logs the gap and sets `resumedLossily`. The window is bounded by the ring
        // (`SLOPDESK_PANE_RING_BYTES`) and the client's own repaint on reattach covers the seam —
        // see docs/DECISIONS.md, "the detached window is superd's ring".
        var resumedStream: PaneOutputStream?
        if let resumeFrom {
            let carried = outputGate?.outstanding ?? 0
            resumedStream = openSupervisedOutput(from: resumeFrom)
            if carried > 0 { outputGate?.enqueue(carried) }
        }

        // Build the joining member's control sender FIRST — BEFORE the output drain below exists.
        // The restarted drain pops whatever the cancelled one left and hands its sniffed control to
        // `broadcastControl`, which reads each member's wake; were the output drain built + kicked
        // first, it could run in the window before this member has one and strand a carried-over
        // control message (e.g. an OSC-0/2 title change) in its queue with no wake.
        // `reestablishActivityOnReattach(to:)` re-asserts `.title`, so a stranded one is no longer
        // unrecoverable — but it would still arrive a beat late and out of order with the batch, so
        // the ordering below stands. Starting the control sender this early is safe in the other
        // direction: it simply parks on its fresh wake stream until the first enqueue.
        startControlSender(for: sub)

        // Rebuild the output wake stream and restart the session's output drain (AFTER the control
        // sender above — its sniffed-control hand-off needs the member's wake already installed).
        startOutputDrain()

        // Kick the restarted drain ONCE if unsent frames are already waiting: their producer-side
        // wakes landed on the FINISHED old continuation (detach() nil'd it), and a shell that has
        // gone idle since produces no future chunk to re-wake the drain — without this the retained
        // frames (and their gate accounting) would sit undelivered until the next supervised chunk.
        // bufferingNewest(1) holds the yield until the drain task starts its for-await.
        fifoLock.lock()
        let hasCarriedFrames = !outbox.isEmpty
        let backlogWake = outputWakeContinuation
        fifoLock.unlock()
        if hasCarriedFrames { backlogWake?.yield(()) }
        // Race seam: fired at the EARLIEST instant the restarted output drain can be running —
        // it has been created and its backlog kick delivered. The drain's
        // first act on a carried frame is nextOutboundFrame → broadcastControl(sniffed control),
        // which reads each member's wake; the ordering test pins that the joining member's wake is
        // ALREADY installed here (the race window itself — the drain Task getting scheduled inside
        // a few rebind-thread instructions — cannot be forced deterministically from outside).
        onOutputDrainRestartedForTesting?()

        // RE-ESTABLISH the client's echo truth on reattach (mirrors how the PTY size is
        // re-asserted on reconnect): re-anchor the edge-triggered detector and re-emit a fresh type-31 for the
        // CURRENT probed echo so a no-echo prompt that is up across this reattach re-engages the client's AUTO
        // Secure Keyboard Entry (which reset to echo-on on reconnect). Addressed to the JOINING member —
        // a re-assert is a fact about what THAT client has yet to be told, not a pane-wide edge — and done
        // AFTER its control sender + wake are built above (so the enqueue is delivered and drained, not
        // dropped onto a member with no wake). See ``reestablishEchoOnReattach(echoOn:to:)``.
        reestablishEchoOnReattach(
            echoOn: PTYEchoProbe.echoEnabled(masterFD: pty.masterFD), to: sub.id,
        )

        // RE-SEND the held blocks' metadata so the returning client rebuilds its
        // Commands/Outline navigator (block metadata rides the control channel and is not in the replayed
        // output byte stream). Addressed to the joining member and ordered after its control-sender build,
        // mirroring the echo re-assert.
        resendBlocksOnReattach(to: sub.id)

        // RE-ASSERT the remaining CONTROL-ONLY activity truths (same class as the echo
        // re-assert above): the busy bit (type-23 `.running`), the foreground-process name (type-26),
        // the agent status (type-27), and a live OSC 9;4 progress (type-32) are all edge-triggered
        // and never in the replayed output byte stream, and the client reset its mirrors on
        // reconnect — without a fresh emit, a `sleep 300` (or a working/blocked agent) that spans
        // the reattach shows NO indicator / command label on the returning client until the next
        // real edge. Same addressing and ordering as the echo re-assert: this is a JOIN-scoped
        // burst, and it runs after the joining member's control sender exists.
        reestablishActivityOnReattach(to: sub.id)

        // Start the joining member's input + control relays. Writes land on the SAME serial
        // `inputQueue` as every other life of this pane — teardown drains ONE queue, and the fd is
        // re-read at write time inside ``writePTYInput`` (never captured here, where it could go
        // stale under a later join).
        startInputRelay(for: sub)
        startControlRelay(for: sub)

        // The ORIGINAL exit task from startRelay() keeps running untouched — do NOT cancel+recreate
        // it here. It reads `self?.onExit` dynamically at fire time, and `onExit` was reassigned
        // above under taskLock, so whichever life the child dies in, the CURRENT handler fires
        // (every handler ignores its channel-ID argument and captures its own key/context). A
        // cancel+recreate would DOUBLE-REGISTER a waiter: `PTYProcess.waitForExit()` parks a plain
        // CheckedContinuation with no cancellation plumbing, so `exitTask?.cancel()` never retires
        // the old registration — `completeExit` would resume BOTH tasks and the pane would send a
        // duplicate `.exit` wire frame per reattach-while-alive cycle (and the stale task's
        // `notifyCloseObservers` could fire from the wrong life).

        // agentWatchTask is NOT cancelled by detach() — it survives the detached window so the poll
        // keeps running. But its control wake continuation was finished by detach(), so any
        // agent-status update emitted WHILE DETACHED is dropped (nil continuation). The new
        // continuation rebuilt above carries future updates; a brief stale status until the next
        // poll tick (~1 s) is acceptable. A nudge here would need sampleForeground exported to run
        // after unlock — not worth the risk vs. the natural 1-s poll cadence.

        taskLock.unlock()

        // The online recompute runs just AFTER taskLock is released so it can acquire replayLock
        // without nesting locks. Somebody holds the pane again, so it reads TRUE. The wake it
        // triggers goes to the new outputWakeContinuation (rebuilt inside taskLock above with
        // bufferingNewest(1)), so the wake is retained even if the drain task hasn't started its
        // `for await` loop yet — bufferingNewest(1) holds one pending yield. No output is lost.
        recomputeClientOnline()
        // Started OUTSIDE taskLock: `subscribe` is a round trip to superd, and this file's rule is
        // that no arbitrary wait happens under a lock the drain and the exit path also take. Ordered
        // after `recomputeClientOnline()` so the gate's replay-pause source is already at its
        // attached value when the first resumed chunk lands.
        resumedStream?.start()
        return true
    }

    /// Pumps the ReplayBuffer tail (`seq > lastReceivedSeq`) into `channel` as sequential
    /// `output` wire messages — the reconnect replay that brings the returning client up to date.
    ///
    /// Called BEFORE ``rebindRelay`` starts the live drain so the tail is delivered in order
    /// without interleaving live output. Non-blocking: iterates the already-retained entries
    /// (O(N) over the retained tail) without any timer or suspension point between frames.
    ///
    /// - Returns: `true` when the replay was a RENDERED snapshot (state-transfer) — the
    ///   caller's redraw-jiggle workaround is unnecessary then: every row the app believes
    ///   painted IS painted.
    @discardableResult
    func replayTail(after lastReceivedSeq: Int64, on channel: MuxSubChannel) async -> Bool {
        let (messages, snapshotComposed) = snapshotReplayTailForSend(after: lastReceivedSeq)
        for message in messages {
            try? await channel.send(message)
        }
        return snapshotComposed
    }

    /// Synchronously snapshots the ReplayBuffer tail under `replayLock` (NSLock is unavailable
    /// from the async ``replayTail(after:on:)`` directly — same discipline as ``rebindRelay``).
    ///
    /// With a ``SnapshotReplayPolicy`` injected, the replay is COMPOSED BY RENDERING first
    /// (``composeSnapshotReplay(after:policy:)``); every ineligible/fallback case (no seqs to
    /// ride, warm tail under the threshold, seq budget too small for the rendered bytes)
    /// falls through to the raw/distilled path unchanged.
    private func snapshotReplayTailForSend(after lastReceivedSeq: Int64) -> ([WireMessage], Bool) {
        if let policy = snapshotReplay,
           let rendered = composeSnapshotReplay(after: lastReceivedSeq, policy: policy)
        {
            return (rendered, true)
        }
        replayLock.lock()
        defer { replayLock.unlock() }
        return (replay.replay(after: lastReceivedSeq), false)
    }

    /// Builds the RENDERED-snapshot replay: the ring plus the un-acked tail, fed through the screen
    /// model at the live PTY size, rendered once, and re-chunked across the replay seqs.
    ///
    /// It composes SEQUENCED history and nothing else. The pane's detached window is not in scope
    /// here: those bytes are in superd's ring, and ``rebindRelay`` re-subscribes at
    /// the resume cursor AFTER this replay ships — so they reach the client on the ordinary drain,
    /// after the snapshot, in order.
    ///
    /// Returns `nil` (compose nothing, caller falls back) when:
    /// - there are no replay seqs to carry the stream (nothing retained above
    ///   `lastReceivedSeq` — e.g. an idle warm reconnect);
    /// - the client is WARM and the pending raw replay is under the policy threshold
    ///   (byte-exact continuation is worth more than a wipe+re-render);
    /// - the rendered bytes exceed the seq budget's frame-cap ceiling (pathological tiny-
    ///   session expansion — the raw path is cheap there anyway).
    ///
    /// `adopting: false` is the JOIN mode: read-only. Adopting the rendered stream as the retained
    /// history belongs to the caller sequence [detached → drain stopped → replay → rebind]; a join
    /// to a LIVE session must not do it, because that rewrites the seqs the incumbent is mid-stream
    /// on.
    private func composeSnapshotReplay(
        after lastReceivedSeq: Int64,
        policy: SnapshotReplayPolicy,
        adopting: Bool = true,
    ) -> [WireMessage]? {
        // Cheap eligibility first — the warm-below-threshold case is EVERY ordinary
        // reconnect, and must not pay the history copy just to say "no".
        let cold = lastReceivedSeq == 0
        if !cold {
            replayLock.lock()
            let tailBytes = replay.retainedBytes
            replayLock.unlock()
            guard tailBytes >= policy.warmThresholdBytes else { return nil }
        }
        replayLock.lock()
        let source = replay.snapshotSource(after: lastReceivedSeq)
        replayLock.unlock()
        guard !source.replaySeqs.isEmpty else { return nil }
        guard cold || source.replayBytes >= policy.warmThresholdBytes else { return nil }
        let input = source.history
        guard !input.isEmpty else { return nil }
        let size = pty.currentWindowSize()
        let rows = Int(size?.rows ?? 24)
        let cols = Int(size?.cols ?? 80)
        let rendered = policy.compose(input, rows, cols)
        // Credit-progress invariant: rechunk caps per-frame payloads, so the rendered bytes
        // must fit the seq budget or the LAST chunk would exceed the cap.
        guard rendered.count <= source.replaySeqs.count * MuxFlowControl.maxOutputFramePayloadBytes
        else { return nil }
        // Under the lock like every other call: the re-chunker writes the buffer's message slot,
        // and the handle admits no overlapping call even for one that reads no session state.
        replayLock.lock()
        let messages = replay.rechunkSnapshot(rendered, across: source.replaySeqs)
        replayLock.unlock()
        guard adopting else { return messages }
        // Adopt the rendered stream AS the retained history ("as if the host had emitted it
        // all along") so the next compose parses the small canonical history instead of
        // re-walking the raw ring.
        replayLock.lock()
        replay.adoptSnapshotReplay(messages)
        replayLock.unlock()
        return messages
    }

    /// Non-blocking check: returns `true` if the child shell has already exited (been reaped
    /// by `PTYProcess.startReaper`). Used by ``DetachedSessionStore/lookup(_:)`` and
    /// ``rebindRelay`` to avoid reattaching to a dead shell (PATH C → spawn fresh).
    func isChildExited() -> Bool {
        pty.waitExitCode() != nil
    }

    /// Tears this channel down FOR GOOD and releases its PTY + master fd.
    ///
    /// ⚠️ DESTROY-ONLY. Every caller of `shutdown()` is a genuine end-of-session:
    /// `HostServer.removeMuxSession()` — itself reached only from the child's own exit, a peer
    /// `channelClose`, or a whole-link drop (peer crash / TCP reset) — and the two refuse-the-open
    /// races in `HostServer` that tear down a session they never registered. There is NO
    /// per-channel reconnect/resume, so none of those is keep-alive: the shell MUST die here, or
    /// the PTY + master fd leak on every disconnect.
    ///
    /// **`HostServer.stop()` is NOT one of them any more** — a daemon stop goes through
    /// ``relinquishDetached(completion:)`` → ``relinquish()``, which is the entire point of
    /// `docs/51`. Do not route it back here.
    /// WHEN PER-CHANNEL RESUME LANDS, a resume-able disconnect must route to a NEW `detach()`
    /// that stops the read loop + closes the master WITHOUT killing the child — it must NOT
    /// come through here (this path SIGKILLs the shell).
    ///
    /// ### Why the child used to have to be killed BEFORE `closeMaster()`
    /// `closeMaster()` → `close(masterFD)` BLOCKS on macOS while a reader is parked inside an
    /// in-flight kernel `read()` on that same fd, and the in-process `PTYReadLoop` could not be
    /// interrupted out of one: that read returns only when the slave closes, i.e. when the child
    /// dies. So "stop the reader" implicitly meant "kill the shell", and this ladder — `hangup()`
    /// (SIGHUP; an interactive zsh exits AND persists its history, which it never does under
    /// SIGKILL) → `terminate()` → bounded wait → `forceTerminate()` — existed to produce the
    /// corpse the close needed.
    ///
    /// ### None of that is true any more, and the difference is ``relinquish()``
    /// This process no longer reads the master at all; superd does, and its reader parks in
    /// `poll(2)` on a wake pipe as well. Nothing here is parked in a `read()`, so `close()` cannot
    /// block on one. The signals below stay because this method's contract is still "destroy" —
    /// they are simply no longer load-bearing for the close, which is exactly what made it possible
    /// to let a pane GO without ending it.
    func shutdown() {
        teardown(killChild: true)
    }

    /// Lets this pane GO: same teardown as ``shutdown()``, but the child is neither signalled nor
    /// waited for, and superd is never told the pane is over.
    ///
    /// ⚠️ hostd-lifecycle ONLY — `HostServer.stop()`, and nothing else. The distinction is the
    /// entire product change behind `docs/51`: "this daemon is going away" and "this pane is over"
    /// used to be the same code path, so editing one Swift file cost the user every running agent.
    /// Now hostd drops its duplicate of the master and exits; superd still holds the original, the
    /// shell never sees a `SIGHUP`, and the next hostd adopts the pane back
    /// (`HostServer.adoptSurvivingPanes()`).
    ///
    /// Two things it deliberately does NOT do, either:
    /// - **delete the ZDOTDIR shim dir** — the shell is still running out of it;
    /// - **delete or unregister anything keyed by the session id** — the journal file on disk is
    ///   what the restart replays into the reattached pane.
    func relinquish() {
        // Nothing is written down on the way out any more. The boundary between "already on disk"
        // and "still to come" used to be hostd's to publish here, because hostd was journaling a
        // stream it did not own; superd owns both ends of that now and answers the same number from
        // memory when the next daemon asks (`journalInfo`, `docs/51` §6.8). The stream is still
        // stopped first, because a pane being let go is a pane in mid-sentence and its subscriber
        // is going away.
        stopSupervisedOutputStream()
        teardown(killChild: false)
    }

    /// Unsubscribes this pane's supervised output, without touching the child. Idempotent —
    /// ``teardown(killChild:)`` calls it again a moment later.
    private func stopSupervisedOutputStream() {
        taskLock.lock()
        let stream = readLoop
        taskLock.unlock()
        stream?.stop()
    }

    private func teardown(killChild: Bool) {
        taskLock.lock()
        let signalTeardown = !teardownSignaled
        teardownSignaled = true
        taskLock.unlock()
        // Outside the locks (an arbitrary server closure must never run under taskLock), exactly
        // once across the shutdown/shutdownDetached double-entry.
        if signalTeardown { onTeardown?() }
        taskLock.lock()
        readLoop?.stop()
        // Wake continuations are owned by their queue locks (producers on other threads read
        // them under the same lock — see the property docs), NOT by taskLock.
        fifoLock.lock()
        outputWakeContinuation?.finish()
        outputWakeContinuation = nil
        fifoLock.unlock()
        // Every member's wake + its three tasks go with it. Membership itself is left alone: the
        // session is dying, and a torn-down relay is not the same statement as "nobody holds this
        // pane" (which is what an empty set says to the size fold and the online recompute).
        for sub in subscriberList() { cancelSubscriberTasks(sub) }
        exitTask?.cancel()
        agentWatchTask?.cancel() // stop the foreground-process poll
        screenScanTask?.cancel() // stop the screen-rule scan loop
        screenScanTask = nil
        // Hand the pane's grid back to screend. Best-effort by construction — its registry evicts
        // on its own — but a host that never says so keeps 256 dead grids warm for the day.
        screenScanner.release()
        agentWatchTask = nil
        // `outputTask.cancel()` GENUINELY unblocks a drain parked on an exhausted DATA credit
        // window: `MuxSubChannel.awaitChunkCredit`'s park is cancellation-aware, so a cancelled sender
        // wakes + throws and the task completes. Without that, the `HostServer.stop()` teardown — which
        // does NOT route through `MuxNWConnection` (the only path that `finish()`es the sub-channels) —
        // would leak the parked `outputTask` + its retained sub-channel actors (the long-lived menu-bar
        // host accumulating one per affected channel on every Start/Stop).
        outputTask?.cancel()
        taskLock.unlock()
        // `resizeDebounceTask` is owned by `resizeLock` (scheduleResize / applyResolvedGrid), NOT
        // `taskLock`. Cancelling it under taskLock would race scheduleResize's store under
        // resizeLock — two disjoint mutexes guarding one ARC `Task` reference = a data race (torn read /
        // ARC over-release / missed cancel). Read+nil under its own lock, then cancel outside the lock.
        // The file's only nesting is one-directional (`resizeWriteLock` → `resizeLock`, taken by
        // `applyResolvedGrid` alone), and this path takes neither of them across another → no deadlock.
        resizeLock.lock()
        let resizeTask = resizeDebounceTask
        resizeDebounceTask = nil
        let nudgeTask = redrawNudgeTask
        redrawNudgeTask = nil
        let settleTask = sizeSettleTask
        sizeSettleTask = nil
        // Nobody holds a dead pane at a size.
        fold.removeAll()
        resizeLock.unlock()
        resizeTask?.cancel()
        nudgeTask?.cancel()
        settleTask?.cancel()
        // Release the exit task's EOF gate (it is also cancelled above, but signalling makes it
        // return promptly rather than polling to its timeout) so teardown never lingers on the latch.
        signalEOFReached()
        // Likewise release the exit-sent latch so a torn-down exit task returns at once instead
        // of polling to its timeout (mirrors the EOF latch above; the cancel above also unblocks it).
        signalExitSent()
        // DESTROY-path child termination (see the doc comment): SIGHUP first — an interactive
        // shell treats it as "terminal closed" and persists its command history to $HISTFILE
        // before exiting (it IGNORES SIGTERM, and SIGKILL would discard everything typed in
        // this pane since it opened) — plus SIGTERM for children that catch it for graceful
        // cleanup; then a bounded wait for the reaper to observe the exit; if the child
        // blocked/ignored both (or a foreground job kept the slave open), escalate to SIGKILL
        // and re-wait briefly.
        //
        // Skipped entirely on the relinquish path: there the shell is meant to still be running
        // when this returns, which is the one thing the whole daemon exists to make possible.
        if killChild {
            pty.hangup()
            pty.terminate()
            // Drain the master while waiting: the read loop is already stopped, and a shell caught
            // mid-prompt-redraw blocks in tcsetattr(TCSADRAIN) until its pending output is consumed
            // — undrained, it never processes the SIGHUP (no history save) and eats the SIGKILL.
            if !pty.waitUntilExitedDrainingMaster(timeout: 0.25) {
                pty.forceTerminate()
                if !pty.waitUntilExited(timeout: 0.25) {
                    // Every signal above travelled the supervisor socket, and each one's error path
                    // is deliberately empty — "this IS the escalation path", from a time when hostd
                    // held the ONLY master fd and `closeMaster()` guaranteed a `SIGHUP` whatever
                    // `kill(2)` did. It does not any more: superd holds the original, so a signal
                    // that never arrived leaves the child running with nothing left to end it. The
                    // user closes a tab, the `claude` behind it keeps going, and the next
                    // `adoptSurvivingPanes()` hands the closed tab back, live.
                    //
                    // `release` is the authoritative end — superd drops its own master and kills —
                    // and it is issued ONLY here, after the whole ladder failed. On the ordinary
                    // path the child is already dead and a release would race the reaper for the
                    // same pane.
                    if !pty.release(kill: true) {
                        onLog?(
                            "pane \(sessionID.uuidString): the child survived SIGHUP, SIGTERM and "
                                + "SIGKILL and superd could not be reached to release it — the "
                                + "shell is still running under superd and can be ended with "
                                + "`slopdesk-ctl`",
                        )
                    }
                }
            }
        }
        // Quiesce the PTY WRITER before closing the master — the write-side sibling of the
        // read-loop discipline above. Every input write runs as a blocking `write(2)` block on the
        // serial `inputQueue`; close the gate (any block enqueued from here on is a no-op), then
        // sync-drain the queue so an in-flight write COMPLETES before `close(masterFD)` — otherwise
        // the freed fd number could be recycled by a concurrent `openpty()` and the stale write
        // would inject bytes into an unrelated pane's PTY (the write-path TOCTOU). Bounded: the
        // child is already dead (SIGHUP/SIGTERM→SIGKILL above), so a write parked on a full kernel
        // PTY buffer returns EIO once the slave side is gone — the drain cannot hang.
        //
        // On the RELINQUISH path there is no such bound, and this used to be an unbounded
        // `inputQueue.sync {}`. The child is alive by design, and a foreground program that is not
        // reading its tty (a `claude` mid tool-call, a build) leaves a >8 KiB paste parked in the
        // kernel for as long as it likes. `HostServer.stop()` awaits every one of these, so one
        // such pane meant `slopdesk-hostd` never reached `exit(0)`: `make host-restart` timed out
        // with the OLD daemon still on the port — a restart that cannot finish, which is worse than
        // the restart cost this whole change set exists to remove. So the drain is bounded, and the
        // TIMEOUT decides the close: an in-flight `write(2)` on a descriptor we then closed is the
        // write-path TOCTOU (the fd number gets recycled by a concurrent `openpty()` and the stale
        // write lands in an unrelated pane's terminal), so a drain that did not finish keeps
        // hostd's duplicate OPEN. One leaked fd on a pane nobody could type into anyway, against a
        // daemon that cannot exit or a pane that receives another's keystrokes.
        inputGateLock.lock()
        inputWritesClosed = true
        inputGateLock.unlock()
        if quiesceInputWrites(timeout: killChild ? 5 : 2) {
            pty.closeMaster()
        } else {
            onLog?(
                "pane \(sessionID.uuidString): an input write is still parked in the kernel — "
                    + "hostd's duplicate of the master is left open rather than closed under it. "
                    + "The shell keeps running under superd; the fd goes when this process does",
            )
        }
        // The LAST statement of the teardown, and the only thing a test can watch to know the whole
        // path ran to the end. It used to watch the ZDOTDIR shim dir disappear here; that directory
        // now belongs to superd, which is the only process that outlives hostd and can therefore
        // clean it up at all (`shellintegration.rs`). Recording the fact directly says what those
        // tests were actually asserting, instead of inferring it from a side effect.
        taskLock.lock()
        teardownCompletions += 1
        taskLock.unlock()
    }

    /// How many times ``teardown(killChild:)`` has run to completion. A test seam.
    ///
    /// Teardown is dispatched to a queue, so "the session was shut down" is not observable at the
    /// call site; this is.
    var teardownCompletionsForTesting: Int {
        taskLock.lock()
        defer { taskLock.unlock() }
        return teardownCompletions
    }

    /// Waits for every already-enqueued input write to finish, or `timeout`, whichever comes first.
    ///
    /// The gate (``inputWritesClosed``) is closed before this is called, so nothing new joins the
    /// queue and the block enqueued here is the last one. `async` + a semaphore rather than `sync`,
    /// because `sync` on a serial queue with a blocking `write(2)` on it has no way out.
    ///
    /// - Returns: `true` when the queue drained, `false` on timeout — see the caller for why that
    ///   answer decides whether the master is closed.
    private func quiesceInputWrites(timeout: TimeInterval) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        inputQueue.async { drained.signal() }
        return drained.wait(timeout: .now() + timeout) == .success
    }

    /// A serial-safe BACKGROUND queue for the blocking ``shutdown()`` work, kept OFF the cooperative
    /// thread pool / the mux connection's receive loop. `concurrent` so simultaneous channel teardowns
    /// (a multi-pane link drop) tear down in parallel rather than ~0.5s × N serially.
    static let teardownQueue = DispatchQueue(
        label: "slopdesk.host.session-shutdown", qos: .utility, attributes: .concurrent,
    )

    /// NON-BLOCKING teardown: dispatches ``shutdown()`` to a background queue and returns IMMEDIATELY.
    ///
    /// ``shutdown()`` blocks the caller for up to ~0.5s (`SIGHUP`+`SIGTERM` → bounded `Thread.sleep`
    /// wait → `SIGKILL` → re-wait → `closeMaster`). An INTERACTIVE shell exits on the `SIGHUP` within
    /// milliseconds (persisting its history first), but a child that survives both signals rides the
    /// full ~250ms `SIGKILL` escalation. The host reaches a channel teardown
    /// SYNCHRONOUSLY from the mux connection's receive loop (a peer `channelClose` / link drop routes
    /// `MuxNWConnection.route`/`finishLink` → `hostCloseHandler` → `HostServer.removeMuxSession`), so
    /// blocking there would (a) stall EVERY OTHER pane riding the same shared connection for that whole
    /// window — closing one pane freezes its siblings — and (b) park a cooperative-pool thread on
    /// `Thread.sleep`. Offloading keeps the receive loop free; the caller has already removed the
    /// session from its map (the cross-shut/double-shut guard), so the PTY kill + fd close are safe to
    /// finish asynchronously. `shutdown()` is itself idempotent, so a detached double-call is harmless.
    ///
    /// `completion` fires on the teardown queue after `shutdown()` returns — used by
    /// ``HostServer/stop()`` to await every detached teardown before the daemon exits.
    func shutdownDetached(completion: (@Sendable () -> Void)? = nil) {
        Self.teardownQueue.async { [self] in
            shutdown()
            completion?()
        }
    }

    /// ``relinquish()`` on the teardown queue — the non-blocking form `HostServer.stop()` uses so
    /// N panes are let go in parallel rather than one after another.
    func relinquishDetached(completion: (@Sendable () -> Void)? = nil) {
        Self.teardownQueue.async { [self] in
            relinquish()
            completion?()
        }
    }

    // MARK: - The size fold (min over contributors; ONE writer to `TIOCSWINSZ`)

    /// Registers `subscriber` as a member of the contributing set, or updates its passivity.
    ///
    /// Membership is a STATE-PLANE fact: it changes only on an explicit channel open / close, never
    /// on a heartbeat. That is what makes the fold settle instead of flapping — tmux's
    /// `aggressive-resize on` expressed structurally rather than as a timer.
    ///
    /// An existing member keeps its standing offer: a reattach swaps the sub-channels while the same
    /// PTY lives on, and forgetting the offer there would snap the pane back to its spawn size until
    /// the returning client happened to send a new one.
    ///
    func addResizeContributor(
        _ subscriber: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
        sizePassive: Bool,
    ) {
        resizeLock.lock()
        armSizeSettleLocked(fold.add(subscriber, sizePassive: sizePassive))
        resizeLock.unlock()
    }

    /// Drops `subscriber` from the contributing set. A pane whose set EMPTIES keeps its last size —
    /// it does not snap back to 80×24 (docs/45 §8.3 rule 4).
    func removeResizeContributor(_ subscriber: MuxSubscriberID = MuxChannelSession.primarySubscriberID) {
        resizeLock.lock()
        armSizeSettleLocked(fold.remove(subscriber))
        resizeLock.unlock()
    }

    /// Records `subscriber`'s LATEST offer and (cancel-)re-arms a single debounce task that resolves
    /// the fold once after `resizeDebounce`. Because each `.resize` RE-ARMS (never blocks) the task,
    /// the debounce ALWAYS fires after the LAST resize → the latest offer always lands (trailing-edge
    /// guarantee). A generation guard makes a task already past its sleep bail if superseded — the
    /// exact `WorkspaceStore.scheduleSave` cancel-replace+generation pattern.
    ///
    /// An offer from a subscriber that is not in the set REGISTERS it as a contributor: the ctl-spawned
    /// and null-sub-channel paths never call ``addResizeContributor(_:sizePassive:)``, and a resize
    /// frame is itself proof that somebody is holding this pane at a size.
    func scheduleResize(
        from subscriber: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
        cols: UInt16,
        rows: UInt16,
        px: UInt16,
        py: UInt16,
    ) {
        resizeLock.lock()
        // The fold retires an orchestrator's override on a CREDITED offer and answers whether this
        // one is worth a timer: while a contributor-set change is still settling it is not, because
        // this offer simply joins the fold that settle will resolve, and arming the short debounce
        // there is precisely what would make a burst of joins SIGWINCH the shell once per arrival.
        let decision = fold.offer(from: subscriber, PaneResizeFold.Grid(cols: cols, rows: rows, px: px, py: py))
        guard decision.arm else {
            resizeLock.unlock()
            return
        }
        let generation = decision.generation
        resizeDebounceTask?.cancel()
        let debounce = resizeDebounce
        resizeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // superseded (cancelled) before firing — the re-armed task applies the latest.
            }
            guard let self else { return }
            // Past the sleep: `Task.cancel()` no longer helps, so the generation guard decides. Apply
            // only if still the latest scheduled resize.
            applyResolvedGrid(ifGeneration: generation)
        }
        resizeLock.unlock()
    }

    /// Resolves the grid from the contributing set and applies it via `TIOCSWINSZ` — the ONE writer
    /// every client and ctl resize path funnels through.
    ///
    /// **Idempotence is a comparison against the LIVE `TIOCGWINSZ`, never against the fold's own
    /// last resolution.**
    /// A redraw jiggle (``PTYProcess/beginRedrawJiggle()``) deliberately leaves the PTY one row short
    /// while the app re-layouts; a memo of the form "the resolved grid did not change, skip" would
    /// then leave the pane one row short for the rest of the session. Reading the size the PTY
    /// actually holds costs one non-blocking ioctl and cannot go stale.
    ///
    /// **The resolve and the write are ONE critical section** (`resizeWriteLock`). Resolving under
    /// `resizeLock` and writing after releasing it lets two callers land their ioctls in the opposite
    /// order to their resolutions, so the geometry the PTY keeps is the one whose thread the
    /// scheduler resumed last rather than the one the state says. Serialised, the last write is by
    /// construction the newest resolution — and the `ifGeneration` check below is only meaningful
    /// because it now shares that section with the write it guards.
    ///
    /// - Parameter ifGeneration: when non-nil (a timer-fire path), apply only if it still matches
    ///   the fold's generation — a stale already-past-sleep task must not apply an old fold. The flush
    ///   paths (ack/bye/close) pass `nil` to apply UNCONDITIONALLY (they must never strand a size).
    func applyResolvedGrid(ifGeneration generation: UInt64? = nil) {
        resizeWriteLock.lock()
        defer { resizeWriteLock.unlock() }

        resizeLock.lock()
        // Nobody holding this pane at a size (or a generation a newer apply superseded) resolves
        // nothing, and the pane keeps the size it has.
        let resolved = fold.resolve(ifGeneration: generation)
        resizeLock.unlock()
        guard let grid = resolved else { return }
        resizeApplyStallForTesting?()

        if let live = pty.currentWindowSizeWithPixels(),
           live.cols == grid.cols, live.rows == grid.rows,
           live.pxWidth == grid.px, live.pxHeight == grid.py
        {
            return // the PTY already holds exactly this grid.
        }
        // The RESOLVED size, not the requester's offer — and the same call tells superd, which
        // records it beside the transcript so a later life's restore parses those bytes at the
        // geometry they were emitted for. A width no client ever had would re-wrap every line.
        pty.setWindowSize(cols: grid.cols, rows: grid.rows, pxWidth: grid.px, pxHeight: grid.py)
        // The resident screen grid is fixed-size — a geometry change rebuilds it from the ring
        // on the next scan (full-screen apps repaint at the new size anyway).
        markScreenModelDirty()
        scheduleRedrawNudge()
    }

    /// Starts the settle the fold asked for, if it asked for one.
    ///
    /// The fold arms only when the contributing set moved BETWEEN two non-empty states — a set going
    /// 0→1 or 1→0 has exactly one possible fold, so making the first client of a fresh pane wait
    /// 750 ms for a size it alone decides would be latency for nothing. Caller holds `resizeLock`.
    private func armSizeSettleLocked(_ decision: PaneResizeFold.Arm) {
        guard decision.arm else { return }
        let generation = decision.generation
        sizeSettleTask?.cancel()
        let settle = sizeSettle
        sizeSettleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: settle)
            } catch {
                return // superseded before firing — the re-armed settle owns the pending flag.
            }
            guard let self else { return }
            clearSizeSettle(ifGeneration: generation)
            applyResolvedGrid(ifGeneration: generation)
        }
    }

    /// Releases the settle latch so ordinary offers arm the short debounce again. Guarded by the
    /// generation so a superseded task cannot unlatch the settle a newer set change owns.
    private func clearSizeSettle(ifGeneration generation: UInt64) {
        resizeLock.lock()
        let wasSettling = fold.isSettling
        fold.clearSettle(ifGeneration: generation)
        if wasSettling, !fold.isSettling {
            sizeSettleTask = nil
        }
        resizeLock.unlock()
    }

    // MARK: Fold readouts (the workspace roster's publication sink)

    /// The grid the fold resolved for this pane, as the roster publishes it.
    ///
    /// Falls back to the live winsize for a pane nothing has ever resolved — a ctl-spawned shell with
    /// no contributing subscriber is still a real terminal at a real size, and publishing 0×0 for it
    /// would make every client render a letterbox for a pane that is fine.
    var resolvedGridForWorkspace: (cols: UInt16, rows: UInt16) {
        resizeLock.lock()
        let resolved = fold.lastResolved
        resizeLock.unlock()
        if let resolved { return (cols: resolved.cols, rows: resolved.rows) }
        guard let live = pty.currentWindowSize() else { return (cols: 0, rows: 0) }
        return (cols: live.cols, rows: live.rows)
    }

    /// Every contributor's standing offer, in subscriber order — what the roster turns into
    /// `WorkspaceRosterPane.attachments` so a client can name who is clamping the grid.
    ///
    /// A subscriber that has not yet offered reports 0×0, which is honest: it holds the pane but has
    /// not said how big it is.
    ///
    /// `contributes` is what the fold ACTUALLY does, not the passivity flag alone: a phone alone on
    /// a pane sizes it (see ``fold(_:)``), and publishing `false` there would make it render a
    /// letterbox crediting a client that is not here.
    var resizeContributionsForWorkspace: [ResizeAttachment] {
        resizeLock.lock()
        defer { resizeLock.unlock() }
        return fold.attachments
    }

    /// Regression seam: whether a delayed redraw nudge is armed. The nudge itself is a `SIGWINCH` to
    /// somebody else's process group, which a test cannot observe.
    var hasArmedRedrawNudgeForTesting: Bool {
        resizeLock.lock()
        defer { resizeLock.unlock() }
        return redrawNudgeTask != nil
    }

    /// Regression seam: whether a contributor-set change is still settling.
    var isSizeSettlingForTesting: Bool {
        resizeLock.lock()
        defer { resizeLock.unlock() }
        return fold.isSettling
    }

    /// Schedules a single delayed `SIGWINCH` (cancel-replace) so the shell repaints its prompt AFTER the
    /// client grid has settled at the new size (see `redrawNudgeTask`). Each resize cancels the prior
    /// pending nudge, so a drag emits exactly one nudge — at the final size. Same lock discipline as
    /// `scheduleResize`; `nudgeRedraw` is internally fd-locked and a no-op on a closed PTY.
    private func scheduleRedrawNudge() {
        resizeLock.lock()
        redrawNudgeTask?.cancel()
        redrawNudgeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(90))
            } catch {
                return // superseded by a newer resize before firing — that resize schedules its own nudge.
            }
            self?.pty.nudgeRedraw()
        }
        resizeLock.unlock()
    }

    // MARK: - Bounded-output-queue backpressure (lock-guarded; the value type is not Sendable)

    /// Accounts `count` enqueued output bytes; pauses the read loop if the FIFO crossed the bound.
    /// The accounting + the pause action are applied ATOMICALLY inside ``PausableQueueGate``
    /// (under one lock) so a concurrent ``dequeueOutput(_:)`` can never interleave a stale resume
    /// after this pause and leave the loop frozen below capacity.
    private func enqueueOutput(_ count: Int) {
        outputGate?.enqueue(count)
    }

    /// Accounts `count` sent output bytes; resumes a paused read loop if the FIFO drained below the
    /// bound. Atomic with the accounting (see ``PausableQueueGate``).
    private func dequeueOutput(_ count: Int) {
        outputGate?.dequeue(count)
    }

    // MARK: - Output FIFO / control-out producers (append-then-yield; no lost wake)

    /// The PTY read-loop chunk handler (runs on the read-loop thread, serial). Factored out of
    /// the `onChunk` closure so the sniffer + FIFO path is drivable headlessly (no PTY) via
    /// ``ingestPTYChunkForTesting(_:)``.
    private func ingestPTYChunk(
        _ chunk: Data,
        sniffed: [SniffedEvent] = [],
        blocks: [BlockEvent] = [],
    ) {
        // A title RETIREMENT folded on another thread since the last chunk (a detected agent
        // exited) also retires the sniffer's coalescing anchor — otherwise the NEXT agent's
        // opening title, which is very often byte-identical to the one just retired
        // (`✳ Claude Code`), would be deduped away and the pane would stay untitled.
        let now = ProcessInfo.processInfo.systemUptime
        truthsLock.lock()
        let forgetTitle = truths.takeTitleCoalescingReset()
        // The type-25 gate, read in the SAME acquisition the fold runs in: while this pane's agent
        // announces its own edges through the hook feed, its OSC notification duplicates the type-27
        // the client already banners, so one blocked prompt raises ONE notification. A hook-free pane
        // keeps the OSC path — it is that pane's only signal. Two handles never hold each other, so
        // the detector's verdict crosses as a VALUE.
        let suppressChildNotifications = agentDetector.suppressesChildNotifications
        // What the shell said out of band in THESE bytes, as superd's pump found it
        // (`rust/slopdesk-superd/src/sniffer.rs`), folded in ONE pass: the title latch, the command
        // edge, the exit code, the duration and the progress badge all move together, and the fold
        // answers what each message is and where it goes. Byte-faithfully interleaved exactly as it
        // was, because the batch arrived paired with the chunk it came from.
        let routed = truths.ingest(
            sniffed: sniffed,
            reference: Date().timeIntervalSinceReferenceDate,
            uptime: now,
            suppressChildNotifications: suppressChildNotifications,
        )
        truthsLock.unlock()
        if forgetTitle { pty.forgetTitleCoalescing() }
        // Agent-detection: a sniffed title carries Claude Code's own busy/rest telltale (the Braille
        // spinner / `✳` prefix) — fold the EDGE into the ONE detector (the sniffer dedupes titles, so
        // this fires only on a real change). Gated like every other detection input, and taken
        // OUTSIDE the fold's acquisition because publishing an emission broadcasts.
        if agentDetectEnabled {
            for entry in routed {
                guard case let .title(title) = entry.message else { continue }
                foldTitleSample(title: title, at: now)
            }
        }
        let controlMsgs = routed.map(\.message)
        // Host-authoritative By-Project key (type 34): scan THIS chunk's sniffed batch for a cwd
        // change (the OSC-7 sniff when present, else the prompt-edge probe — cheap, sync) and, on
        // a change, hand the resolver's blocking stat-walk to the metadataQueue; the emission
        // lands on the CONTROL sender when the resolve completes. Never a filesystem touch on
        // this read-loop thread — a cwd on a hung network mount must not freeze the pane's
        // output. The cwd is still latched in the fold at the sniff point, for the same reattach
        // reason as the progress latch above.
        deriveProjectKey(from: controlMsgs)
        // Agent-control: fire output observers for the `wait` verb AFTER the sniffer
        // (so a wait-observer sees the same stream order as the client) and BEFORE the
        // FIFO append (non-destructive — observers only READ the chunk).
        notifyOutputObservers(chunk)
        // ADDITIVE PARALLEL tap — feed the SAME chunk to the per-channel Blocks
        // segmenter and enqueue any type-28 `commandBlock` metadata on the CONTROL sender.
        // Only OBSERVES; the bytes below are forwarded unchanged. `nil` when SLOPDESK_BLOCKS
        // is off, so the pipeline stays byte-identical. Kept OFF the data drain (its own
        // CONTROL FIFO) so block metadata never stalls data sends.
        foldBlocks(blocks)
        // Screen-rule engine tap: APPEND-only on this thread (the scan task owns the grid and
        // all regex work). On overflow the buffer is dropped and the grid marked dirty — the
        // next scan rebuilds from the ring instead of replaying an unbounded backlog here.
        if agentScreenDetectEnabled {
            screenScanLock.lock()
            screenContentSeq &+= 1
            if !screenModelDirty {
                screenPendingBytes.append(chunk)
                if screenPendingBytes.count > Self.screenPendingCap {
                    screenPendingBytes.removeAll(keepingCapacity: false)
                    screenModelDirty = true
                }
            }
            screenScanLock.unlock()
        }
        // Account the chunk in the bounded queue BEFORE enqueueing; if it pushes the FIFO
        // to/over the bound, PAUSE the read loop so the kernel PTY buffer fills and
        // backpressures the shell (the real flood fix).
        enqueueOutput(chunk.count)
        // Which of these ride the FIFO is the fold's answer, decided above in the same pass that
        // latched them. Type-33 is host-gated single-source (see ``deriveProjectKey(from:)``, which
        // just consumed this batch): the raw sniffed OSC-7 `.cwd` is WITHHELD, because pre-warm-up
        // plugin noise would reach the client unfiltered and a probe-beaten stale OSC-7 would arrive
        // at drain time AFTER (and client-side overwrite) the probed truth emitted above. A
        // hook-suppressed type-25 was never made at all.
        let fifoControl = routed.filter { $0.route == .fifo }.map(\.message)
        // Append-then-yield (no lost wake): the pending bufferingNewest(1) wake always
        // observes a complete FIFO. The continuation is read under fifoLock (teardown
        // nils it); yield happens OUTSIDE the lock (it may resume the drain inline).
        fifoLock.lock()
        outbox.append(bytes: chunk, control: fifoControl)
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Fresh-spawn history restore: enqueues the prior life's transcript as the FIRST output
    /// frame, through the normal drain (so it is sequenced into the new ReplayBuffer and rides
    /// ordinary `.output` messages — no wire change). Called by ``startRelay()`` AFTER the
    /// bounded-queue gate exists (the bytes are accounted like any chunk; a >64 KiB preamble
    /// simply starts the read loop paused until the drain ships it) and BEFORE the read loop
    /// starts, so it precedes every live shell byte.
    private func enqueueRestoredScrollback() {
        // One-shot: TAKE the stored preamble so the FIFO copy becomes the only owner. Without
        // the release, the stored property would pin a second up-to-journal-cap copy for the
        // session's entire life — per restored pane.
        fifoLock.lock()
        let restored = restoredScrollback
        restoredScrollback = nil
        fifoLock.unlock()
        guard let restored, !restored.isEmpty else { return }
        enqueueOutput(restored.count)
        fifoLock.lock()
        outbox.append(bytes: restored, control: [])
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Enqueues `.exit` on the output FIFO (the reaper path). `.exit` is a merge BARRIER in
    /// ``PaneOutbox`` — it never coalesces with chunks, so it stays strictly after the
    /// final output tail (the EOF-latch ordering).
    private func enqueueExit(code: Int32) {
        fifoLock.lock()
        outbox.appendExit(code: code)
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Bound on ONE subscriber's pending control-out queue. Control consumers are latest-state folds
    /// (title/activity) or droppable samples (pong), so shedding under a flood is safe —
    /// without a bound, a hostile client spamming `.ping` against its own non-read control
    /// socket (the sender blocks on TCP backpressure) grows its queue without limit. The bound is
    /// PER SUBSCRIBER because that is the only shape that keeps the promise: one shared queue with N
    /// cursors would let the stalled reader hold it at the cap and shed for the healthy ones too.
    private static let maxControlOutQueued = 1024

    /// Hands a PANE-WIDE control fact to every subscriber's sender (title, bell, command status,
    /// echo edge, cwd, project key, agent status). Everybody holding the pane is told.
    private func broadcastControl(_ messages: [WireMessage]) {
        for sub in subscriberList() { enqueueControl(messages, on: sub) }
    }

    /// Hands a REQUEST-SCOPED answer to exactly one subscriber: the peer that asked.
    ///
    /// A pong echoes ONE client's clock stamp (folded by its own `recordPong` into an RTT), and
    /// `metadataRequest`/`requestBlockOutput` carry a requestID minted by a PER-CLIENT counter that
    /// starts at 1 — so an answer delivered to anybody else pops a waiter that asked a different
    /// question and hands it a foreign payload. A subscriber that has already left simply drops its
    /// answer, exactly as a send on its finished channel did.
    private func sendControl(_ messages: [WireMessage], to id: MuxSubscriberID) {
        guard let sub = subscriber(id) else { return }
        enqueueControl(messages, on: sub)
    }

    /// Appends to ONE subscriber's queue and wakes its sender (FIFO per subscriber).
    /// Sheds NEW messages past the bound (the queued ones are older but already ordered;
    /// a shed title/pong is replaced/refreshed by the next one naturally).
    private func enqueueControl(_ messages: [WireMessage], on sub: Subscriber) {
        controlOutLock.lock()
        // Slot-limited append: a merged frame can carry MULTIPLE sniffed control messages, so a bulk
        // `append(contentsOf:)` guarded only by `count < cap` would land at `cap + (K-1)` — overshooting
        // the bound the comment promises. Take only the free slots so the queue never exceeds the cap.
        let free = Self.maxControlOutQueued - sub.controlOut.count
        if free > 0 {
            sub.controlOut.append(contentsOf: messages.prefix(free))
        }
        let wake = sub.controlWake
        controlOutLock.unlock()
        wake?.yield(())
    }

    /// Ingests one received Claude-hook record (raw POST body bytes) for THIS pane and, if it
    /// produced a status change, enqueues the resulting type-27 on the CONTROL sender. Folds through the
    /// SAME ``ClaudePaneDetector`` the foreground poll drives (single source of truth — no second
    /// machine), under ``truthsLock`` because the socket-accept thread is a different context than the
    /// watch task. Validate-then-drop: malformed bytes are silently ignored. The clock is monotonic
    /// uptime (a plain `Double`; the decision logic is in the pure detector, which takes the time).
    func ingestAgentHookRecord(_ bytes: Data) {
        truthsLock.lock()
        let emission = agentDetector.hook(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
        let changed = emission.status != nil
            ? (agentDetector.status, agentDetector.isQuietTransition)
            : nil
        truthsLock.unlock()
        publishAgentEmission(emission)
        if let changed { notifyAgentStatusChanged(changed.0, quiet: changed.1) }
    }

    /// Folds an AGENT SELF-REPORT (the `report` ctl verb) into the ONE ``ClaudePaneDetector``
    /// under ``truthsLock``. The state string has already been validated by the caller; an
    /// unrecognised string is a no-op inside the detector (validate-then-drop). Any resulting
    /// type-27 is enqueued to the (possibly absent) client AND fans the cross-pane
    /// `agent_status_changed` observer (the supervision stream) on a real transition.
    func reportAgentStatusForControl(state: String, message: String?) {
        truthsLock.lock()
        let emission = agentDetector.report(
            state: state, message: message, at: ProcessInfo.processInfo.systemUptime,
        )
        let changed = emission.status != nil
            ? (agentDetector.status, agentDetector.isQuietTransition)
            : nil
        truthsLock.unlock()
        publishAgentEmission(emission)
        if let changed { notifyAgentStatusChanged(changed.0, quiet: changed.1) }
    }

    // MARK: - Agent-control surface (public primitives used by AgentControlListener)

    /// Writes `bytes` to the PTY master fd (control-plane input injection).
    ///
    /// Fire-and-forget on the session's serial `inputQueue`: the blocking `write(2)` on a stalled
    /// PTY must NOT park the control socket's per-connection handler thread (it serves other
    /// verbs). Funnelled through the SAME queue as client `input` writes — an anonymous
    /// global-queue hop would escape ``shutdown()``'s writer drain and could land on a recycled fd
    /// after `closeMaster()`. Uses the same `writeAll` helper (handles `EINTR`, partial writes).
    /// Validate-then-drop: an empty slice, a closed PTY master fd, or a torn-down session is
    /// silently ignored.
    func writeRawForControl(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        enqueuePTYWrite(bytes)
        // Injected keys are the human's proxy (the supervision cockpit routes dialog answers down
        // this verb) — the same unblock edge as a directly-typed keystroke.
        foldUserInput(bytes)
    }

    /// Resizes the PTY for the agent-control `resize` verb.
    ///
    /// An explicit OVERRIDE of the fold rather than a vote — an orchestrator saying "make this pane
    /// 132×50" means it, and a ctl pane often has no contributing subscriber at all. It stands until
    /// a CONTRIBUTING subscriber offers a size of its own, and that offer is what retires it.
    ///
    /// Routed through ``applyResolvedGrid(ifGeneration:)`` — the ONE writer — so the ctl verb gets
    /// the journal size sidecar and the settled redraw nudge that the client path has always had. A
    /// second, independent `TIOCSWINSZ` here is what left the sidecar describing a geometry the PTY
    /// no longer held after every `slopdesk-ctl resize`.
    ///
    /// Called on the control socket's per-connection handler thread. Safe to call there: the apply is
    /// a pair of non-blocking O(1) ioctls, and the only wait it can take is `resizeWriteLock` behind
    /// one other apply of the same shape — bounded by those ioctls, and the reason the override is
    /// the LAST write rather than merely the newest intent.
    func resizeForControl(rows: UInt16, cols: UInt16) {
        resizeLock.lock()
        // Installing the override supersedes any in-flight debounce/settle: it is being applied
        // RIGHT NOW, and a timer that fired afterwards with the older fold would undo it a frame
        // later. The generation bump only retires a timer that has NOT yet resolved;
        // `resizeWriteLock` is what stops one that already did from landing its ioctl after this
        // one's.
        _ = fold.override(PaneResizeFold.Grid(cols: cols, rows: rows))
        resizeLock.unlock()
        applyResolvedGrid()
    }

    /// Returns a plain-text snapshot of the ReplayBuffer scrollback (all acked + live tail).
    ///
    /// Joins every stored output chunk in sequence order, converts to UTF-8 (replacing invalid
    /// sequences with `?`), then optionally strips ANSI escape codes via ``ANSIStripper``.
    /// The snapshot is taken under `replayLock` (same discipline as `snapshotReplayTail`).
    func scrollbackTextForControl(ansiStrip: Bool = true) -> String {
        replayLock.lock()
        let messages = replay.messages(after: 0)
        replayLock.unlock()
        var data = Data()
        for m in messages { data.append(m.bytes) }
        let text: String =
            if let utf8 = String(bytes: data, encoding: .utf8) {
                utf8
            } else {
                String(data.map { $0 < 0x80 ? $0 : UInt8(0x3F) }.map { Character(UnicodeScalar($0)) })
            }
        return ansiStrip ? ANSIStripper.strip(text) : text
    }

    /// Returns the RAW scrollback bytes (all acked + live tail, seq order) for the `screen`
    /// verb's on-demand grid reconstruction. When the ring holds more than `capBytes`, only the
    /// NEWEST whole messages that fit are returned (a full-screen app repaints, so a truncated
    /// prefix converges after one redraw cycle — same property the ring's own truncation relies
    /// on). Snapshot under `replayLock`, same discipline as ``scrollbackTextForControl(ansiStrip:)``.
    func scrollbackRawForControl(capBytes: Int = 8 * 1024 * 1024) -> Data {
        replayLock.lock()
        let messages = replay.messages(after: 0)
        replayLock.unlock()
        var included: [Data] = []
        var total = 0
        for m in messages.reversed() {
            if total + m.bytes.count > capBytes, !included.isEmpty { break }
            included.append(m.bytes)
            total += m.bytes.count
        }
        var data = Data(capacity: total)
        for bytes in included.reversed() { data.append(bytes) }
        return data
    }

    /// Returns the pane's scrollback as an array of LOGICAL lines (the `read --unwrapped` verb).
    ///
    /// The host keeps NO screen buffer and the scrollback ring stores RAW PTY read-chunk byte
    /// slices (NOT terminal-width-aware lines), so TRUE reverse-of-terminal-wrapping is impossible
    /// host-side — a soft-wrapped visual row carries no marker to un-wrap. What this DOES give an
    /// agent regex is robustness to arbitrary read-CHUNK / transport boundaries: it joins every
    /// stored chunk in seq order (so a hard line split across two chunks is one string),
    /// ANSI-strips (same as ``scrollbackTextForControl(ansiStrip:)``), then splits on the hard
    /// `\n` into logical lines. A partial (no trailing newline) last line is DROPPED so a regex
    /// never matches a half-written prompt. When `lines` is non-nil, only the last N are returned.
    func recentUnwrappedTextForControl(lines limit: Int? = nil) -> [String] {
        let text = scrollbackTextForControl(ansiStrip: true)
        return ANSIStripper.logicalLines(text, limit: limit)
    }

    /// The last OSC-sniffed window title for this pane (empty string if none has arrived yet).
    var currentTitle: String {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.title
    }

    /// The current rolled-up Claude detection status for this pane (the supervision API).
    ///
    /// Read under ``truthsLock`` because `agentDetector` is folded from TWO contexts (the
    /// serial `agentWatchTask` foreground poll and the hook socket-accept thread); a bare read
    /// of the private detector would race. Used by ``HostServer/listPanesForControl()`` to surface
    /// per-pane agent state in the `list-panes` verb. A pane whose detector never saw `claude`
    /// returns ``ClaudeStatus/none``.
    var agentStatusForControl: ClaudeStatus {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return agentDetector.status
    }

    /// The detector's status + human label in ONE lock acquisition (the `list-panes` verb reads
    /// both; two separate reads could interleave a transition and pair a stale label with a fresh
    /// state).
    var agentStatusAndMessageForControl: (status: ClaudeStatus, message: String?) {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return (agentDetector.status, agentDetector.statusLabel)
    }

    /// The freshest host-observed cwd truth (OSC-7 sniff / prompt-edge probe), `nil` until observed.
    var cwdForControl: String? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.cwd
    }

    /// The freshest By-Project key (type 34's current value), `nil` until resolved.
    var projectKeyForControl: String? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.projectKey
    }

    /// The freshest OSC-133-D exit code, `nil` until the first code-carrying `D`.
    var lastExitCodeForControl: Int32? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.lastExit
    }

    // MARK: - Workspace-document surface (the CURRENT VALUE behind each edge)

    //
    // Every fact below is already published as an edge-triggered control message. These accessors
    // expose the value that edge left behind, so a client that was not listening at the instant of
    // the edge can still be told what is true — which is the whole point of the document.

    /// ``currentTitle`` and the `systemUptime` it was sniffed at, in ONE lock acquisition: two reads
    /// could interleave a retirement and pair a live title with a cleared stamp.
    var titleAndStampForControl: (title: String, stampedAt: TimeInterval?) {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return (truths.title, truths.titleAt)
    }

    /// The `systemUptime` at which the CURRENT command block opened, `nil` at a prompt. The other
    /// half of the `pane/titleFresh` verdict.
    var commandStartedAtForControl: TimeInterval? {
        commandStatusForReattach()
    }

    /// When the CURRENT command block opened, `nil` at a prompt.
    ///
    /// The reattach re-assert publishes ONLY the running case, and deliberately: idle IS the
    /// client's reconnect reset state, and a synthetic `.idle` would fabricate a `lastCommand`
    /// (exit nil / 0 ms) and a completion edge for a command that never finished.
    private func commandStatusForReattach() -> TimeInterval? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.commandRunningSince
    }

    /// The host's own open command block — the pane's running command line, `nil` at a prompt or
    /// with blocks tracking off.
    ///
    /// This is the fact a client cannot reproduce: `RailRowsBuilder.liveRowTitle(runningCommand:)`
    /// reads the CLIENT's per-materialization `TerminalBlockModel`, so a client that has rendered
    /// zero bytes has no running command at all and its sidebar row falls back to the raw command
    /// line. Publishing the host's block is what lets the host alone render the row.
    var runningCommandForControl: String? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.runningCommand
    }

    /// The last foreground process name the watcher sampled (type 26's current value).
    var foregroundProcessForControl: String? {
        foregroundLock.lock()
        defer { foregroundLock.unlock() }
        return _lastForeground
    }

    /// The type-27 triple the status stream currently stands at, plus the agent's session intent
    /// (type 36) — read in ONE ``truthsLock`` acquisition, like ``agentStatusAndMessageForControl``.
    var agentPublishedStateForControl: (state: UInt8, kind: UInt8, label: String?, intent: String?) {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        let triple = agentDetector.lastEmittedStatusForControl
        return (
            triple?.state ?? 0,
            triple?.kind ?? 0,
            agentDetector.statusLabel,
            agentDetector.sessionIntentForControl,
        )
    }

    /// The freshest OSC 9;4 progress pair, `nil` when cleared or never reported (type 32's value).
    var progressPairForControl: (state: UInt8, percent: UInt8)? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.progress
    }

    /// The host-measured duration of the last completed command, `nil` until the first `D`.
    var lastDurationMSForControl: UInt32? {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.lastDuration
    }

    /// How many `working → done` edges this pane has produced (`pane/completionEpoch`).
    var completionEpochForControl: UInt32 {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return truths.completionEpoch
    }

    // MARK: - Agent-control block surface (the `last-output` / `run --wait` verbs)

    /// The last `limit` closed blocks with their retained output, the running command, and the
    /// `run --wait` baseline — one round trip to superd, which holds all three.
    ///
    /// `nil` when the pane has no tap (`SLOPDESK_BLOCKS=0`, or superd never knew the pane), which
    /// the caller reports differently from "no blocks yet" (an empty `recent`). One call rather than
    /// three because the three are only consistent with each other if superd read them together.
    func blockControlForControl(limit: Int) -> BlocksReply? {
        guard blocksEnabled else { return nil }
        return pty.blockControl(limit: limit)
    }

    /// The retained output bytes for a closed block, `nil` when the pane has no tap and EMPTY when
    /// the block was evicted or never existed.
    func blockOutputBytesForControl(index: UInt32) -> [UInt8]? {
        guard blocksEnabled else { return nil }
        return pty.blockOutput(index: index)
    }

    /// Registers a block observer for the `run --wait` verb (see ``CommandBlockUpdate``).
    /// Replaces any prior observer for the same `id` (idempotent).
    func registerBlockObserver(id: UUID, _ observer: @escaping @Sendable (CommandBlockUpdate) -> Void) {
        observersLock.lock()
        blockObservers[id] = observer
        observersLock.unlock()
    }

    /// Removes the block observer registered under `id`. Idempotent.
    func removeBlockObserver(id: UUID) {
        observersLock.lock()
        blockObservers[id] = nil
        observersLock.unlock()
    }

    /// Registers an output observer for the `wait` verb. The closure is called from the PTY
    /// read-loop thread with each raw output chunk immediately after sniffer processing. The
    /// observer must be non-blocking and short-running (it runs on the read-loop thread).
    /// Replaces any prior observer for the same `id` (idempotent).
    func registerOutputObserver(id: UUID, _ observer: @escaping @Sendable (Data) -> Void) {
        observersLock.lock()
        outputObservers[id] = observer
        observersLock.unlock()
    }

    /// Removes the observer registered under `id`. Idempotent (a missing id is a no-op).
    func removeOutputObserver(id: UUID) {
        observersLock.lock()
        outputObservers[id] = nil
        observersLock.unlock()
    }

    /// Registers a close observer for the `subscribe` verb. Called once when the PTY exits
    /// (after EOF has been drained through the output observers). Replaces any prior observer
    /// for the same `id` (idempotent).
    func registerCloseObserver(id: UUID, _ observer: @escaping @Sendable () -> Void) {
        observersLock.lock()
        closeObservers[id] = observer
        observersLock.unlock()
    }

    /// Removes the close observer registered under `id`. Idempotent.
    func removeCloseObserver(id: UUID) {
        observersLock.lock()
        closeObservers[id] = nil
        observersLock.unlock()
    }

    /// Calls all registered close observers. Called from the exit task after EOF drains.
    private func notifyCloseObservers() {
        observersLock.lock()
        let observers = closeObservers
        observersLock.unlock()
        for (_, observer) in observers { observer() }
    }

    /// Calls all registered output observers with `chunk`. Called from `onChunk` on the
    /// PTY read-loop thread (serial) — snapshot the dict under lock, then call outside.
    private func notifyOutputObservers(_ chunk: Data) {
        observersLock.lock()
        let observers = outputObservers
        observersLock.unlock()
        for (_, observer) in observers { observer(chunk) }
    }

    /// Folds what superd's command-block tap found in THIS chunk into the control stream.
    ///
    /// hostd no longer segments anything: the reader that already holds the bytes does the OSC 133
    /// walk, dedupes the result, and sends the ANSWER on a `0x05` frame that rides immediately ahead
    /// of the chunk that produced it (`rust/slopdesk-superd/src/blocks.rs`). What is left here is
    /// the translation into type-28/type-32 and the two latches those feed.
    ///
    /// An empty batch — the overwhelming majority of chunks — costs the `isEmpty` test and nothing
    /// else, and a pane with no tap never receives one at all.
    ///
    /// The flag is re-checked anyway. It is the same flag the spawn asked the tap for, so in
    /// production this cannot fire; it is here because the flag also gates every block READ, and a
    /// fold that ignored it could publish a block the reads would then refuse to elaborate on.
    private func foldBlocks(_ blocks: [BlockEvent]) {
        guard blocksEnabled, !blocks.isEmpty else { return }
        // ONE pass, like the sniffed batch: the running command line is latched for
        // `PaneLiveness.capture` (which runs for every pane on every reconciler tick and must stay a
        // lock acquisition), and a synthetic badge latches the same reattach truth the sniffed one
        // does — auto-progress is a second type-32 source, never a second latch.
        truthsLock.lock()
        let routed = truths.ingest(blocks: blocks)
        truthsLock.unlock()
        let messages = routed.map(\.message)
        if !messages.isEmpty { broadcastControl(messages) }
        notifyBlockObservers(messages)
    }

    /// Fans each type-28 block-metadata emission in `messages` to the registered block observers
    /// (the ctl `run --wait` verb). Called AFTER the tracker ingest, so a completed block's output
    /// is already retained when its observer fires. Snapshot under `observersLock`, call outside.
    private func notifyBlockObservers(_ messages: [WireMessage]) {
        guard !messages.isEmpty else { return }
        observersLock.lock()
        let observers = blockObservers
        observersLock.unlock()
        guard !observers.isEmpty else { return }
        for message in messages {
            guard case let .commandBlock(index, exitCode, durationMS, complete, _, commandText, _) = message
            else { continue }
            let update = CommandBlockUpdate(
                index: index,
                commandText: commandText,
                exitCode: exitCode,
                durationMS: durationMS,
                complete: complete,
            )
            for (_, observer) in observers { observer(update) }
        }
    }

    /// Host-authoritative By-Project key (type 34) — the change-edge derivation, split so the PTY
    /// read-loop thread never touches the filesystem:
    ///
    /// **Sync (this method — the read-loop thread):** scan `sniffed` for the batch's shape — the
    /// LAST OSC-7 `.cwd`, whether a `.commandStatus(.idle)` marked a prompt boundary (133;B/D,
    /// exactly when a `cd` becomes observable), whether any command edge landed at all — and hand
    /// it to ``PaneTruths/openCwdGate(hasOSC:promptEdge:commandEdge:)``. The gate rules (the
    /// warm-up, the probe preference) are the fold's; what stays HERE is the syscall the fold must
    /// not make: ONE `proc_pidinfo` read (the same class as the input path's `tcgetattr`; never a
    /// subprocess and never a `stat` on this thread), taken with no lock held. Its answer goes
    /// back through ``PaneTruths/latchCwd(_:)``, which is the anchor an unchanged cwd is dropped
    /// at and the one a reattach re-assert reads.
    ///
    /// **Type-33 single-source:** an ACCEPTED change also emits `.cwd` here, synchronously — and
    /// ``ingestPTYChunk(_:)`` strips the raw sniffed OSC-7 from the FIFO ride, so the client only
    /// ever sees warm-up-gated, dedupe-anchored, probe-preferred cwd values and can apply them
    /// ungated (it needs no startup-noise gate of its own).
    ///
    /// **Async (the resolver walk — `metadataQueue`):** a CHANGED cwd hands
    /// ``ProjectKey/of(cwd:)`` — a `stat(2)`-per-ancestor filesystem walk that
    /// can block INDEFINITELY on a hung network mount (NFS/SMB/FUSE) — to
    /// ``scheduleProjectKeyResolve(for:)``, so a wedged mount can never freeze this pane's
    /// terminal output. The type-34 emission happens there, straight onto the CONTROL sender.
    private func deriveProjectKey(from sniffed: [WireMessage]) {
        var oscCwd: String?
        var promptEdge = false
        var commandEdge = false
        for message in sniffed {
            switch message {
            case let .cwd(path): oscCwd = path
            case let .commandStatus(status):
                commandEdge = true
                if case .idle = status { promptEdge = true }
            default: break
            }
        }
        // Common case first (every mid-command chunk): no cwd signal at all — zero probe cost.
        guard oscCwd != nil || promptEdge else { return }
        truthsLock.lock()
        let gate = truths.openCwdGate(
            hasOSC: oscCwd != nil,
            promptEdge: promptEdge,
            commandEdge: commandEdge,
        )
        truthsLock.unlock()
        // The probe is a syscall, so it happens with no lock held — the same window the fold's own
        // dedupe closes below, and the same one this function always had.
        let freshest: String? =
            switch gate {
            case .skip: nil
            case .useOSC: oscCwd
            case .preferProbe: probeCwd() ?? oscCwd
            }
        guard let cwd = freshest else { return }
        truthsLock.lock()
        let accepted = truths.latchCwd(cwd)
        truthsLock.unlock()
        guard accepted else { return }
        // Host-authoritative cwd (type 33): emit the ACCEPTED truth change synchronously, before the
        // async key resolve — the client's tab cwd line must update even while the resolver walk is
        // parked on a hung mount. This is the ONLY live type-33 source (`ingestPTYChunk` strips the
        // raw sniffed OSC-7 from the FIFO ride), so what reaches the client carries the same
        // guarantees as the type-34 it precedes: warm-up-gated, dedupe-anchored, probe-preferred.
        // It also covers OSC-7-less shells (Starship): their prompt-edge probe changes push the cwd
        // with no metadata-RPC dependency, so the tab cwd cannot go stale across a reconnect.
        broadcastControl([.cwd(cwd)])
        scheduleProjectKeyResolve(for: cwd)
    }

    /// Runs ``ProjectKey/of(cwd:)`` — the resolve and the toplevel walk, one crossing — OFF the
    /// read-loop thread, on the
    /// serial `metadataQueue` (the file's home for ALL blocking FileManager/git/lsof work; serial,
    /// so resolves stay ordered), or the injected test executor. On completion,
    /// ``PaneTruths/latchProjectKey(cwd:key:)`` answers under `truthsLock`: the resolve is DROPPED
    /// if a later `cd` superseded it (its `cwd` is no longer the anchor — the newer change's own
    /// resolve is already queued behind this one), and deduped against the latched key. An
    /// accepted key is enqueued as the type-34 directly on the CONTROL sender.
    /// It deliberately does NOT ride the out-FIFO alongside the producing bytes — FIFO ordering is
    /// not load-bearing for this latest-state truth (the client folds the newest key it sees, and
    /// the reattach re-assert reads the latches, not the stream).
    private func scheduleProjectKeyResolve(for cwd: String) {
        let resolve: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let key = ProjectKey.of(cwd: cwd)
            truthsLock.lock()
            let publish = truths.latchProjectKey(cwd: cwd, key: key)
            truthsLock.unlock()
            guard publish else { return }
            broadcastControl([.projectKey(key)])
            onProjectKeyResolved?(key)
        }
        if let projectKeyResolveExecutorOverride {
            projectKeyResolveExecutorOverride(resolve)
        } else {
            metadataQueue.async(execute: resolve)
        }
    }

    /// Seeds the pane's cwd + By-Project truths from the SPAWN directory — the server-provided
    /// `channelOpen` initialCwd / ctl `--cwd`, NOT shell-controlled input, so it safely runs with no
    /// warm-up (the OSC-7 gate exists to drop a plugin manager's pre-first-prompt `cd` noise and
    /// stays latched for OSC-7). Called by ``HostServer`` right after `startRelay()`. Closes two
    /// gaps in the derivation above: a pane whose shell never emits OSC-133/OSC-7 (raw command,
    /// shim disabled) otherwise NEVER resolves a key — the client sections it by raw cwd forever —
    /// and every fresh split/tab otherwise waits a full PTY warm-up + resolve round-trip while the
    /// sidebar shows it under a subdirectory-named section. An already-latched truth wins: the seed
    /// runs strictly before the first prompt in practice, but a lost race must not clobber a real
    /// observation.
    func seedProjectTruthAtSpawn(cwd: String) {
        guard !cwd.isEmpty else { return }
        truthsLock.lock()
        let seeded = truths.seedCwd(cwd)
        truthsLock.unlock()
        guard seeded else { return }
        broadcastControl([.cwd(cwd)])
        scheduleProjectKeyResolve(for: cwd)
    }

    /// ``HostServer``'s type-35 fan-in: enqueue a project git push on this pane's control sender iff
    /// the pane is currently sectioned under the pushed repo (a cheap latch compare — the server
    /// never reads the latch itself, so the lock discipline stays inside this file).
    func pushProjectGitStatusIfMatching(_ status: WireMessage.ProjectGitStatus) {
        truthsLock.lock()
        let matches = truths.projectKeyMatches(status.repoRoot)
        truthsLock.unlock()
        guard matches else { return }
        broadcastControl([.projectGitStatus(status)])
    }

    /// The prompt-edge cwd read: the test seam when set, else the real ``HostMetadataProbe``
    /// `proc_pidinfo` probe (foreground pid, shell-pid fallback — the same resolution the `cwd`
    /// metadata RPC serves). On an unspawned PTY (unit tests) the pids are −1 and the probe answers
    /// `nil` before any syscall.
    private func probeCwd() -> String? {
        if let cwdProbeOverride { return cwdProbeOverride() }
        return HostMetadataProbe(masterFD: pty.masterFD, shellPID: pty.pid).paneWorkingDirectory()
    }

    /// Reattach — RE-SENDS every block the tracker still holds (its metadata) as a burst of type-28
    /// `commandBlock` messages on the CONTROL channel, so a client that (re)attaches to an already-running
    /// session rebuilds its Commands/Outline navigator. Block metadata rides the control channel and is
    /// NEVER replayed by the ReplayBuffer (only raw `.output` is sequenced), so a returning client would
    /// otherwise show an EMPTY navigator even though the host still holds every block. Mirrors
    /// ``reestablishEchoOnReattach`` (echo truth is likewise control-only and re-anchored on reattach).
    /// A no-op when blocks are disabled. Output bytes are fetched on demand (type 15 → 29); this restores
    /// the list only.
    ///
    /// Addressed to the JOINING subscriber — the navigator it is missing is its own.
    private func resendBlocksOnReattach(to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID) {
        guard blocksEnabled else { return }
        let messages = pty.blockSnapshot()?.map(PaneTruths.blockMessage) ?? []
        if !messages.isEmpty { sendControl(messages, to: id) }
    }

    /// Serves a `requestBlockOutput(index)` by enqueueing the block's retained output (type
    /// 29) from the ring on the CONTROL sender. Always replies (an EMPTY `blockOutput` when the
    /// block was evicted / never existed / blocks are disabled) so the client never hangs waiting.
    private func serveBlockOutput(
        index: UInt32,
        to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
    ) {
        let bytes = blockOutputBytesForControl(index: index) ?? []
        sendControl([.blockOutput(index: index, output: Data(bytes))], to: id)
    }

    /// Serves a `metadataRequest(requestID:verb:payload:)` by running the PURE
    /// ``MetadataResponseBuilder`` over THIS pane's ``HostMetadataProbe`` (its `masterFD` + shell pid)
    /// and enqueueing the resulting type-30 `metadataResponse` on the CONTROL sender. The probe's
    /// git/lsof/proc work is BLOCKING, so it runs on ``metadataQueue`` (OFF the serial control loop) —
    /// a slow query must never stall this pane's resize/ack/ping. ALWAYS replies (the builder maps any
    /// failure — unknown verb / confinement rejection / missing cwd / query-nil — to a status byte +
    /// empty payload), so the client's ``MetadataRequestRegistry`` never hangs waiting. Orders against
    /// nothing (like a ping / blockOutput) — deliberately NO `applyResolvedGrid`.
    ///
    /// In-flight work is BOUNDED per session (``MetadataAdmission``): past the cap the request is
    /// answered at once with the standard `.error` status instead of being enqueued — a request
    /// flood on the unwindowed control channel must not grow `metadataQueue` (or fork subprocesses)
    /// without limit. Each admitted work item releases its slot on completion (defer).
    private func serveMetadata(
        requestID: UInt32,
        verb: UInt8,
        payload: Data,
        to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
    ) {
        // Bounded admission: the control sub-channel is deliberately
        // unwindowed, so a hostile/buggy peer streaming back-to-back tiny metadataRequest frames
        // would otherwise queue unbounded closures (each retaining its payload + self) and fork
        // git/lsof without limit. At/over the cap, do NOT enqueue work — reply IMMEDIATELY with
        // the builder's standard `.error` status + empty payload (the exact shape any failed verb
        // replies with), so the "ALWAYS replies, the client never hangs" contract holds.
        metadataInFlightLock.lock()
        let admitted = metadataAdmission.admit()
        metadataInFlightLock.unlock()
        guard admitted else {
            sendControl([.metadataResponse(
                requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
            )], to: id)
            return
        }
        let masterFD = pty.masterFD
        let shellPID = pty.pid
        metadataQueue.async { [weak self] in
            guard let self else { return }
            defer {
                metadataInFlightLock.lock()
                metadataAdmission.release()
                metadataInFlightLock.unlock()
            }
            // WHO serves this verb is ``MetadataAdmission/performer(for:)``'s answer, not a chain of
            // "not mine" replies here: the nine side-effecting verbs actuate on the HOST's own
            // Finder, `~/.claude/settings.json`, pasteboard or a lazily-spawned child, and must
            // never reach the read-only `MetadataResponseBuilder`, which performs no side effects by
            // construction. A verb claimed by nobody and a verb claimed by two are both bugs a chain
            // could not state; the table states them, and it reads the wire's own verb enum.
            let response: WireMessage =
                switch MetadataAdmission.performer(for: verb) {
                case .path:
                    HostPathActionPerformer.response(requestID: requestID, verb: verb, payload: payload)
                case .agent:
                    HostAgentActionPerformer.response(
                        requestID: requestID, verb: verb, payload: payload,
                        hookListenerActive: agentHookListenerActive(),
                    )
                case .clipboard:
                    HostClipboardPerformer.response(requestID: requestID, verb: verb, payload: payload)
                case .codeServer:
                    // Replies IMMEDIATELY with the current state (starting/ready/unavailable) — `ensure`
                    // never waits out a cold boot, so the client's 5 s registry timeout cannot starve.
                    HostCodeServerPerformer.response(requestID: requestID, verb: verb, payload: payload)
                case .simulator:
                    HostSimulatorPerformer.response(requestID: requestID, verb: verb, payload: payload)
                case .android:
                    HostAndroidPerformer.response(requestID: requestID, verb: verb, payload: payload)
                case .builder:
                    MetadataResponseBuilder(query: HostMetadataProbe(masterFD: masterFD, shellPID: shellPID))
                        .response(requestID: requestID, verb: verb, payload: payload)
                }
            sendControl([response], to: id)
        }
    }

    /// Atomically takes ONE subscriber's whole pending control batch; `nil` when empty (its sender
    /// re-parks).
    private func takeControlBatch(for sub: Subscriber) -> [WireMessage]? {
        controlOutLock.lock()
        defer { controlOutLock.unlock() }
        guard !sub.controlOut.isEmpty else { return nil }
        let batch = sub.controlOut
        sub.controlOut.removeAll(keepingCapacity: true)
        return batch
    }

    // MARK: - Per-channel replay bookkeeping (lock-guarded; the value type is not Sendable)

    private func nextSeq(for bytes: Data) -> Int64 {
        replayLock.lock()
        let seq = replay.append(bytes: bytes)
        replayLock.unlock()
        // Appending may push retained bytes over the 256 MiB cap (or the 64 MiB offline gate); feed
        // that into the read-loop pause so the kernel PTY buffer backpressures the shell instead of
        // the host buffering the un-acked stream unboundedly. OR-composed with the bounded-queue
        // source inside the gate (resume only when both clear). The lock is released BEFORE touching
        // the gate to keep the lock order replayLock→gate.
        updateReplayBackpressure()
        return seq
    }

    /// Records ONE subscriber's ack cursor and releases the ReplayBuffer to the FLOOR every
    /// subscriber has confirmed.
    ///
    /// Retention is `min` over the set, not last-writer-wins: the buffer holds what the SLOWEST
    /// reader still needs, so nobody's tail can be released out from under it by somebody else's
    /// progress. With one member the min IS that member's cursor, so this releases exactly what a
    /// bare `replay.ack(upTo: seq)` did.
    ///
    /// An ack from a subscriber that is NOT in the set records nothing and releases only to the min
    /// over the members that remain. A departed member's control relay can still deliver one
    /// buffered `.ack` after `retireSubscriber` dropped it (`Task.cancel()` does not unwind an
    /// iteration already in flight), and honouring that cursor would release the tail of a laggard
    /// that is still here — its later cold reattach then composes from a truncated history. Only an
    /// EMPTY set falls through to `seq`: the ack test seam on a session with no members, where there
    /// is genuinely no laggard left to hold the buffer for.
    ///
    /// The floor is recomputed INSIDE the `backpressureApplyLock` section, together with the pause
    /// decision it feeds: see ``updateReplayBackpressure()`` for why a value computed before the
    /// lock and applied after it can land stale on the gate and wedge the read loop.
    private func acknowledge(upTo seq: Int64, from id: MuxSubscriberID = MuxChannelSession.primarySubscriberID) {
        backpressureApplyLock.lock()
        subscribersLock.lock()
        let floor = fanout.acknowledge(id, upTo: seq) ?? seq
        subscribersLock.unlock()
        replayLock.lock()
        replay.ack(upTo: floor)
        replayLock.unlock()
        // An ack releases retained entries → retained bytes drop → the replay-pause may clear, resuming
        // the read loop (if the bounded queue is also below bound). This is the drain side of the cap.
        applyBackpressureSourcesLocked()
        backpressureApplyLock.unlock()
        // A HEALTHY member's ack is the other half of the laggard check: it recomputes the min, so
        // it is the moment the gap between fastest and slowest is freshest.
        evictLaggingSubscribers()
    }

    /// Marks the client online/offline for the offline (64 MiB) gate, then recomputes backpressure. A
    /// channel-gone usually tears the whole session down moments later, but wiring this keeps the
    /// offline gate honest for the brief window and for when per-channel resume lands.
    private func setClientOnline(_ online: Bool) {
        replayLock.lock()
        replay.isClientOnline = online
        replayLock.unlock()
        updateReplayBackpressure()
    }

    /// Recomputes the ReplayBuffer's drain signal and forwards it to the output gate's
    /// replay-pause source. `nil` gate (flow control off / before `startRelay`) is a no-op.
    ///
    /// RECOMPUTE-AT-APPLY under `backpressureApplyLock` — never carry a value computed inside a
    /// caller's earlier `replayLock` section across to the gate. The output drain (`nextSeq`),
    /// the ack path (`acknowledge`), and detach/rebind (`setClientOnline`) run on independent
    /// tasks; a caller preempted between its compute and its apply would land a STALE value on
    /// the gate after a fresher one (a reattach-backlog drain racing the tail acks can wedge
    /// the read loop paused with nothing left to ack — no future event would recompute).
    /// Serializing the [read fresh truth → apply] pair means the last apply always reflects a
    /// state at least as fresh as the last mutation. Lock order: applyLock → replayLock and
    /// applyLock → gate; nothing takes either in the reverse direction.
    private func updateReplayBackpressure() {
        backpressureApplyLock.lock()
        applyBackpressureSourcesLocked()
        backpressureApplyLock.unlock()
    }

    /// Reads BOTH derived pause sources fresh and applies them to the gate. Caller holds
    /// `backpressureApplyLock` — that is what makes the [read fresh truth → apply] pair atomic
    /// against every other producer of these signals (see ``updateReplayBackpressure()``).
    ///
    /// The gate OR-composes them under its own lock, so the order of the two calls is immaterial;
    /// what matters is that neither is ever computed in one critical section and applied in another.
    private func applyBackpressureSourcesLocked() {
        replayLock.lock()
        let shouldPause = replay.shouldPauseDrain
        replayLock.unlock()
        outputGate?.setReplayPause(shouldPause)
        outputGate?.setFanoutBacklog(fanoutBacklog())
    }

    // MARK: - Exit ordering: EOF latch

    /// Marks the read loop as having drained the master to EOF (called from `onEOF`, and from
    /// ``shutdown()`` so a torn-down exit task never waits the full timeout).
    /// Re-opens this pane's output subscription after the supervisor connection came back.
    ///
    /// Returns whether output is flowing again. See ``PaneOutputStream/resubscribe()`` — the pane
    /// and its shell are untouched by a control-socket drop, but the subscription is not.
    @discardableResult
    func resubscribeSupervisedOutput() -> Bool {
        taskLock.lock()
        let stream = readLoop
        taskLock.unlock()
        return stream?.resubscribe() ?? false
    }

    /// superd came back and does not know this pane: it restarted, so it was the last holder of
    /// this master and the shell went with it. End the session on that fact rather than waiting for
    /// an `exited` notice that nobody is left to send.
    func supervisedPaneVanished() {
        signalEOFReached()
        pty.completeExitFromSupervisorLoss()
    }

    private func signalEOFReached() { life.signalEOF() }

    private func isEOFReached() -> Bool { life.isEOF }

    /// Advances the resume cursor to where the just-ingested chunk ends. The monotonicity and the
    /// `fromNowOn` sentinel are ``PaneLifecycle``'s.
    private func recordStreamOffset(_ endOffset: UInt64) { life.recordOffset(endOffset) }

    /// Awaits the read loop reaching EOF (so the final tail is fully enqueued) OR a bounded timeout —
    /// whichever first — before the exit task yields `.exit`. Polling (2 ms granularity): the exit task
    /// runs once per pane, so the cost is negligible, and polling avoids a cancellation-leaked
    /// continuation. Returns promptly on cancellation (``shutdown()`` cancels the exit task).
    private func awaitEOFOrTimeout(_ timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isEOFReached() || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func signalExitSent() { life.signalExitSent() }

    private func isExitSent() -> Bool { life.isExitSent }

    /// Awaits the drain having SENT `.exit` on the wire (or a bounded timeout / cancellation) before the
    /// exit task fires `onExit`. Mirrors ``awaitEOFOrTimeout`` (2 ms poll, runs once per pane).
    /// A dead client whose credit never arrives times out — the code can't be delivered to it anyway —
    /// and ``shutdown()`` cancels the exit task so a torn-down pane returns at once.
    ///
    /// The 10s budget: with credit-at-consumption the send window tracks the client's RENDER
    /// drain, so a transiently-stalled client (window drag, brief main-thread stall) can
    /// legitimately park the `.exit` send for a few seconds — a 2s window would make dropping a
    /// clean exit code routine instead of exceptional. Still bounded + cancellation-aware,
    /// so teardown never hangs on it.
    private func awaitExitSentOrTimeout(_ timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isExitSent() || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Scrollback env resolution

    /// Resolves a `ReplayBuffer` from the scrollback env vars, called once at channel-open time.
    ///
    /// - `SLOPDESK_SCROLLBACK_PERSIST` — default-ON (`env != "0"`). When `"0"`, the scrollback
    ///   ring is disabled (cap = 0), disabling cold-reattach scrollback replay.
    /// - `SLOPDESK_SCROLLBACK_BYTES` — integer byte cap for the ring. Defaults to
    ///   `ReplayBuffer.defaultScrollbackBytes` (64 MiB). Ignored when scrollback persist is off.
    /// - `SLOPDESK_SCROLLBACK_DISTILL` — default-ON (`env != "0"`). When ON, a distill pass
    ///   (`rust/slopdesk-sanitize/src/distill.rs`)
    ///   is injected so a COLD-reattach scrollback replay collapses the transient B→C line-editor churn
    ///   (tab-completion menus, autosuggestions, per-keystroke redraws) to the committed OSC-133 command
    ///   line — the fresh terminal then re-renders a clean transcript instead of raw editing artifacts.
    ///   Set `"0"` to replay the raw scrollback bytes instead.
    /// - `SLOPDESK_SCROLLBACK_STRIP_QUERIES` — default-ON (`env != "0"`). When ON, a
    ///   query-stripper pass (`rust/slopdesk-sanitize/src/query.rs`) removes terminal queries / echoed responses / stale color
    ///   state from the replayed history, so the client terminal never re-answers a prior life's
    ///   DA/XTVERSION/OSC-color probes into the shell's stdin (the reattach "garbage input" bug).
    /// - `SLOPDESK_SCROLLBACK_STRIP_INPUT_MODES` — default-ON (`env != "0"`). When ON, a
    ///   input-mode-stripper pass (`rust/slopdesk-sanitize/src/inputmode.rs`) removes mouse / kitty-keyboard / in-band-resize mode
    ///   changes from the replayed history (they'd transiently arm the client's input reporting
    ///   mid-replay) and re-asserts only the NET final state after the replay — a live TUI keeps
    ///   its modes, an exited one leaves nothing armed.
    /// - `SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS` — default-ON (`env != "0"`). When ON, a
    ///   prompt-EOL-mark pass (`rust/slopdesk-sanitize/src/prompteol.rs`) normalizes zsh's width-dependent PROMPT_SP mark+fill
    ///   clusters so replay at a different grid width doesn't grow stray `%` lines per prompt.
    /// The env-derived ``SnapshotReplayPolicy`` — `SLOPDESK_SCROLLBACK_SNAPSHOT` default-ON
    /// (`!= "0"`), warm threshold `SLOPDESK_SNAPSHOT_WARM_BYTES` (default 4 MiB). `nil`
    /// (disabled) restores the raw/distilled replay exactly as before.
    static func makeSnapshotReplayPolicy(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
    ) -> SnapshotReplayPolicy? {
        guard env["SLOPDESK_SCROLLBACK_SNAPSHOT"] != "0" else { return nil }
        let threshold: Int =
            if let raw = env["SLOPDESK_SNAPSHOT_WARM_BYTES"], let parsed = Int(raw), parsed >= 0 {
                parsed
            } else {
                4 * 1024 * 1024
            }
        return SnapshotReplayPolicy(
            compose: { raw, rows, cols in
                TerminalReplaySnapshot.compose(raw: raw, rows: rows, cols: cols)
            },
            warmThresholdBytes: threshold,
        )
    }

    static func makeReplayBuffer() -> ReplayBuffer {
        let env = ProcessInfo.processInfo.environment
        let persist = env["SLOPDESK_SCROLLBACK_PERSIST"] != "0"
        let scrollbackCap: Int =
            if !persist {
                0
            } else if let raw = env["SLOPDESK_SCROLLBACK_BYTES"], let parsed = Int(raw), parsed >= 0 {
                parsed
            } else {
                ReplayBuffer.defaultScrollbackBytes
            }
        // The replay passes are `rust/slopdesk-sanitize`, inside the handle — shared with the disk
        // journal's restore so both replay paths stay behaviour-identical (see
        // ``ScrollbackReplayTransform``).
        return ReplayBuffer(
            scrollbackBytes: scrollbackCap,
            distill: ScrollbackReplayTransform.distills(environment: env),
            // reassert: the ring replays into a cold client of a LIVE session — a TUI that is
            // still running needs its input modes re-established after the (stripped) replay.
            reassertInputModes: true,
        )
    }

    // MARK: - Test seams that must live in the BODY (a stored property cannot sit in an extension)

    /// Race seam — invoked by ``rebindRelay(data:control:onExit:)`` immediately after the restarted
    /// output drain has been created and its detached-backlog kick delivered (see the call site).
    /// `nil` in production; tests use it to pin that the control wake continuation/sender are
    /// rebuilt BEFORE the output drain can run.
    var onOutputDrainRestartedForTesting: (() -> Void)?

    /// Race seam — fired inside ``joinSubscriber(id:data:control:sizePassive:)`` with
    /// the joiner already in the set and its DATA sender not yet built: the window in which fanned-out
    /// frames land in an outbox whose wake is nil.
    var onJoinerAdmittedForTesting: (@Sendable () async -> Void)?
}

// MARK: - Test seams (replay-backpressure wiring, and the folds a PTY would otherwise gate)

/// The headless seams, in an extension so the type body stays inside its length budget — every
/// one of these drives PRODUCTION glue (the append/ack/online wiring, the chunk fold, the
/// detection fold) against real collaborators, without a PTY or a running read loop.
///
/// `private` is file-scoped in Swift, so nothing here reaches further than the main body already
/// does. Reached via `@testable import`; never used in production.
extension MuxChannelSession {
    // These drive the append/ack/online glue against a real ``PausableQueueGate`` WITHOUT a PTY or
    // read loop, so the "retained ≥ cap → pause; ack → resume" wiring is provable headlessly. Reached
    // via `@testable import`; never used in production.

    /// Installs a gate to receive the replay-pause signal (production builds it in ``startRelay()``).
    func installGateForTesting(_ gate: PausableQueueGate) { outputGate = gate }
    /// Drives the real ``nextSeq(for:)`` glue (append + recompute + gate). Returns the assigned seq.
    @discardableResult
    func appendForTesting(_ bytes: Data) -> Int64 { nextSeq(for: bytes) }
    /// Drives the real ``acknowledge(upTo:from:)`` glue (per-member cursor + min-fold + gate +
    /// the laggard check).
    func ackForTesting(upTo seq: Int64, from id: MuxSubscriberID = MuxChannelSession.primarySubscriberID) {
        acknowledge(upTo: seq, from: id)
    }

    /// The ReplayBuffer's un-acked total — what the MIN-fold retention releases.
    var retainedBytesForTesting: Int {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.retainedBytes
    }

    /// The retention floor the buffer has actually released to.
    var ackedSeqForTesting: Int64 {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.ackedSeq
    }

    /// Whether the drain is in its fan-out shape (per-member outboxes) rather than the inline
    /// single-send fast path the shipping default never leaves.
    var isFannedOutForTesting: Bool {
        fanoutLock.lock()
        defer { fanoutLock.unlock() }
        return fanoutActive
    }

    /// The event→wire translation, for the suite that pins it against the same JSON superd emits.
    ///
    /// Through a THROWAWAY fold rather than a static twin: the translation is one of the fold's
    /// answers, and a second copy of it for tests to read is exactly the mirror the
    /// one-implementation rule forbids.
    static func wireMessagesForTesting(_ sniffed: [SniffedEvent]) -> [WireMessage] {
        PaneTruths().ingest(
            sniffed: sniffed, reference: 0, uptime: 0, suppressChildNotifications: false,
        ).map(\.message)
    }

    /// How many times the read loop has asked superd to retire the sniffer's title anchor.
    var titleAnchorRetirementsForTesting: Int {
        truthsLock.lock()
        defer { truthsLock.unlock() }
        return Int(truths.titleAnchorRetirements)
    }

    /// Drives the real ``setClientOnline(_:)`` glue (offline-gate side).
    func setClientOnlineForTesting(_ online: Bool) { setClientOnline(online) }
    /// Whether the ReplayBuffer currently regards the pane as reachable — the offline-gate truth
    /// the online recompute writes.
    var isClientOnlineForTesting: Bool {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.isClientOnline
    }

    /// Whether an exit-waiter task exists (regression seam): only ``startRelay()`` may ever create
    /// one — `rebindRelay` must NOT cancel+recreate it, because `PTYProcess.waitForExit()` parks a
    /// plain CheckedContinuation with no cancellation plumbing, so each recreate would leave one
    /// more never-retired waiter that fires a duplicate `.exit` wire frame when the child dies.
    var hasExitTaskForTesting: Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return exitTask != nil
    }

    /// Exit-ordering EOF latch seams.
    func signalEOFForTesting() { signalEOFReached() }
    func isEOFReachedForTesting() -> Bool { isEOFReached() }
    func awaitEOFForTesting(timeout: Duration) async { await awaitEOFOrTimeout(timeout) }

    /// Exit-sent latch seams — the drain signals once `.exit` is on the wire; the exit task
    /// awaits it before firing onExit so teardown can't cancel the drain before the exit code is sent.
    func signalExitSentForTesting() { signalExitSent() }
    func isExitSentForTesting() -> Bool { isExitSent() }
    func awaitExitSentForTesting(timeout: Duration) async { await awaitExitSentOrTimeout(timeout) }

    /// Drain-merge seams: drive the output queue + ``nextOutboundFrame()`` (and the control-out
    /// queue) WITHOUT a PTY or running drain, so merge/barrier/cap semantics are provable
    /// headlessly. The enqueue paths mirror the production producers exactly (append under
    /// the lock; the wake yield is a no-op pre-`startRelay` since the continuation is nil).
    /// Drives the REAL PTY chunk handler (disk-journal hook + sniffer + FIFO append) without a
    /// PTY or read loop — the production `onChunk` closure is exactly this call.
    /// - Parameter sniffed: what superd's sniffer would have found in `chunk`. Supplied rather than
    ///   derived, because deriving it would mean a second OSC state machine in Swift — the very
    ///   thing the port deleted. The parse itself is pinned in `rust/slopdesk-superd`, against the
    ///   same golden corpus; what these callers drive is the FOLD over the answer.
    func ingestPTYChunkForTesting(_ chunk: Data, sniffed: [SniffedEvent] = []) {
        ingestPTYChunk(chunk, sniffed: sniffed)
    }

    func enqueueChunkForTesting(bytes: Data, control: [WireMessage] = []) {
        enqueueOutput(bytes.count)
        fifoLock.lock()
        outbox.append(bytes: bytes, control: control)
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    func enqueueExitForTesting(code: Int32) { enqueueExit(code: code) }
    func enqueueControlForTesting(_ messages: [WireMessage]) { broadcastControl(messages) }
    /// Takes the PRIMARY subscriber's pending batch — the one every headless seam enqueues onto.
    func takeControlBatchForTesting() -> [WireMessage]? {
        guard let sub = subscriber(Self.primarySubscriberID) else { return nil }
        return takeControlBatch(for: sub)
    }

    /// How many subscribers currently hold this pane. One, always — the seam exists so the
    /// single-member invariant is asserted rather than assumed.
    var subscriberCountForTesting: Int {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return fanout.count
    }

    /// Enters a bare second member: ``admitJoiner(reserved:data:control:composedThrough:)``
    /// minus the state transfer and the sender tasks (testing only).
    ///
    /// Every refcounted teardown reads the SUBSCRIBER SET, so a rig that aliases a second live-map
    /// key onto one session without entering a member is not a fan-out to any of them: leaving that
    /// key takes ``removeSubscriber(_:)``'s unknown-id branch, which reports "not emptied" off the
    /// PRIMARY still being there. The refcount assertion then passes for a reason unrelated to
    /// refcounting, and holds just as well for a host that never counted at all.
    ///
    /// Hang-safe: no drain, no sender, no PTY — the set and the population-derived bounds only.
    @discardableResult
    func enterBareSubscriberForTesting(
        data: MuxSubChannel,
        control: MuxSubChannel,
    ) -> MuxSubscriberID {
        subscribersLock.lock()
        let id = fanout.reserveID()
        subscribers[id] = Subscriber(id: id, data: data, control: control)
        fanout.join(id, acked: 0)
        subscribersLock.unlock()
        recomputeClientOnline()
        return id
    }

    static var maxControlOutQueuedForTesting: Int { maxControlOutQueued }

    /// Whether a subscriber's control sender has its wake continuation installed. Read
    /// under `controlOutLock` — the same lock the enqueue reads it under, so this answers
    /// exactly "would an enqueue right now be woken?".
    var hasControlWakeContinuationForTesting: Bool {
        let subs = subscriberList()
        controlOutLock.lock()
        defer { controlOutLock.unlock() }
        return subs.contains { $0.controlWake != nil }
    }

    /// Echo seams — drive the pure echo fold and the reattach re-establishment with an
    /// INJECTED `echoOn` (no PTY probe), so the edge-trigger dedupe AND the reattach re-emit are provable
    /// headlessly via ``takeControlBatchForTesting()``. ``reestablishEchoOnReattachForTesting`` exercises the
    /// EXACT production method ``rebindRelay`` calls, so reverting its re-anchor breaks both together.
    func foldEchoSampleForTesting(echoOn: Bool) { foldEchoSample(echoOn: echoOn) }
    func reestablishEchoOnReattachForTesting(echoOn: Bool) { reestablishEchoOnReattach(echoOn: echoOn) }

    /// Activity-reattach seams (the type-23/26/27/32 sibling of the echo seams above):
    /// drive the pure detector fold with an INJECTED name/clock (no `tcgetpgrp` probe) and the EXACT
    /// production re-assert ``rebindRelay`` calls, so the indicators-survive-a-client-restart truth
    /// is provable headlessly via ``takeControlBatchForTesting()``.
    func foldForegroundSampleForTesting(name: String, at now: TimeInterval) {
        foldForegroundSample(name: name, at: now)
    }

    /// Drives the OSC-title detection fold (the exact code the sniffer loop runs on a title edge)
    /// with an injected title/clock, so the title-corroboration truth is provable headlessly.
    func foldTitleSampleForTesting(title: String, at now: TimeInterval) {
        foldTitleSample(title: title, at: now)
    }

    func reestablishActivityOnReattachForTesting() { reestablishActivityOnReattach() }

    /// Exercises the type-34 change-edge derivation (``deriveProjectKey(from:)``) directly — the
    /// exact code `ingestPTYChunk` runs over each chunk's sniffed batch. The sync part (warm-up
    /// gate, cwd scan, probe preference, the cwd latch) runs inline; the resolver walk runs
    /// via ``projectKeyResolveExecutorOverride`` (tests inject run-inline for deterministic
    /// emission, or a deferred executor to pin that a slow resolve never blocks ingest) and its
    /// emission lands on the control queue — read it with ``takeControlBatchForTesting()``. The
    /// latches it writes are the same ones the reattach re-assert reads.
    func deriveProjectKeyForTesting(from sniffed: [WireMessage]) {
        deriveProjectKey(from: sniffed)
    }

    /// Drives the real ``serveMetadata(requestID:verb:payload:to:)`` glue (the exact call a control
    /// loop makes on an inbound `.metadataRequest`) WITHOUT a running relay, so the always-replies +
    /// bounded-in-flight contracts are provable headlessly via ``takeControlBatchForTesting()``.
    func serveMetadataForTesting(requestID: UInt32, verb: UInt8, payload: Data) {
        serveMetadata(requestID: requestID, verb: verb, payload: payload)
    }

    /// The bounded-admission cap + live in-flight count, so the flood test can pin
    /// "at most `cap` work items queued" and "every slot released when its work item finishes".
    /// Both are ``MetadataAdmission``'s — the session keeps no count of its own.
    static var metadataAdmissionCapForTesting: Int { Int(MetadataAdmission.cap) }
    var metadataAdmissionInFlightForTesting: Int {
        metadataInFlightLock.lock()
        defer { metadataInFlightLock.unlock() }
        return Int(metadataAdmission.inFlight)
    }

    /// Suspend/resume the serial `metadataQueue` so a flood test can hold admitted
    /// work items in-flight deterministically (never spawn/park real probe subprocesses — the
    /// flood uses an unknown verb, which the pure builder answers without a syscall). Tests MUST
    /// balance every suspend with exactly one resume before the session is released (a suspended
    /// dispatch queue traps on dealloc).
    func suspendMetadataQueueForTesting() { metadataQueue.suspend() }
    func resumeMetadataQueueForTesting() { metadataQueue.resume() }

    /// Drives the real `foldBlocks` glue (superd's `0x05` events → broadcastControl) WITHOUT a
    /// PTY/read loop, so the type-28 emission + the byte-identical-when-off contract are provable
    /// headlessly.
    func foldBlocksForTesting(_ blocks: [BlockEvent]) { foldBlocks(blocks) }
    /// The block-event→wire translation, for the suite that pins it against the same JSON superd emits.
    static func wireMessagesForTesting(_ blocks: [BlockEvent]) -> [WireMessage] {
        PaneTruths().ingest(blocks: blocks).map(\.message)
    }

    /// Drives the real `serveBlockOutput` glue (ring lookup → the requester's control queue).
    func serveBlockOutputForTesting(index: UInt32) { serveBlockOutput(index: index) }
    /// Whether the Blocks tap is active for this channel (the tracker was instantiated).
    var blocksEnabledForTesting: Bool { blocksEnabled }

    private static func writeAll(fd: Int32, data: Data) {
        #if canImport(Darwin)
        FileDescriptorWrite.all(fd: fd, data)
        #endif
    }
}

// MARK: - What the shell said, as what a client is told

// MARK: - The subscriber set: join, leave, fan-out, and the laggard

/// The fan-out half of the relay, in an extension so the type body stays readable — `private`
/// members are file-scoped in Swift, so this reaches the same locks and state the main body does
/// with no visibility relaxed.
///
/// Everything here is the identity function on a ONE-member pane: the drain never leaves its
/// inline send, no outbox is built, the min-fold over one cursor is that cursor, and a lone
/// subscriber is never a laggard.
extension MuxChannelSession {
    /// Assigns `bytes` its seq and, when the pane is fanned out, hands the frame to EVERY member's
    /// outbox — both under `fanoutLock`, which is what makes a JOIN indivisible from the stream.
    ///
    /// - Returns: whether the frame was handed off (so the caller must not send it itself), the
    ///   members it targets, and the assigned seq.
    private func sequenceAndFanOut(_ bytes: Data) -> (fannedOut: Bool, targets: [Subscriber], seq: Int64) {
        fanoutLock.lock()
        let fan = fanoutActive
        let targets = subscriberList()
        replayLock.lock()
        let seq = replay.append(bytes: bytes)
        replayLock.unlock()
        if fan {
            let message = WireMessage.output(seq: seq, bytes: bytes)
            for sub in targets { enqueueData([message], on: sub) }
        }
        fanoutLock.unlock()
        // OUTSIDE `fanoutLock`: appending may push retained bytes over the 256 MiB cap (or the
        // 64 MiB offline gate), and the pause is applied through `backpressureApplyLock` — kept off
        // the join-ordering lock so the two never nest.
        updateReplayBackpressure()
        // A laggard is evicted rather than indulged, and the check runs HERE as well as on the ack
        // path: a client that has stopped acking never calls `acknowledge`, so a consumer-side-only
        // check never fires on the exact member it exists to remove.
        evictLaggingSubscribers()
        return (fan, targets, seq)
    }

    /// Delivers `.exit` to EVERY reachable member before the exit task is released.
    ///
    /// Signalling after the FIRST send would release `awaitExitSentOrTimeout` → `onExit` →
    /// `shutdown()` → `outputTask.cancel()`, and members 2..N would never receive the exit code:
    /// their panes hang showing a shell that is already dead. Bounded, so an unreachable member
    /// cannot hold the teardown open.
    private func deliverExit(code: Int32) async {
        let (fan, targets) = handOffExit(code: code)
        guard fan else {
            if let target = targets.first { try? await target.data.send(.exit(code: code)) }
            return
        }
        // Each member's own sender ships its copy; wait (bounded) until every one has either
        // delivered it or died trying. Polling, like the EOF latch: this runs once per pane.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if !hasPendingExitDelivery(among: targets) { return }
            try? await Task.sleep(for: .milliseconds(2))
            if Task.isCancelled { return }
        }
    }

    /// The synchronous half of ``deliverExit(code:)`` (NSLock is unavailable from an async context
    /// — the ``snapshotReplayTailForSend(after:)`` discipline).
    private func handOffExit(code: Int32) -> (fannedOut: Bool, targets: [Subscriber]) {
        fanoutLock.lock()
        defer { fanoutLock.unlock() }
        let fan = fanoutActive
        let targets = subscriberList()
        if fan {
            for sub in targets { enqueueData([.exit(code: code)], on: sub) }
        }
        return (fan, targets)
    }

    private func hasPendingExitDelivery(among targets: [Subscriber]) -> Bool {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return targets.contains { !$0.retired && fanout.isExitPending($0.id) }
    }

    /// Builds `sub`'s outbound DATA sender: one serial drain of ITS outbox onto ITS data
    /// sub-channel. Idempotent — a member already carrying a sender keeps it.
    ///
    /// Every park on an exhausted credit window happens HERE, inside one member's own task, which
    /// is the whole point: a stalled reader delays nobody else's frames and the session drain stays
    /// free to keep sequencing (and to keep noticing that this member has fallen too far behind).
    private func startDataSender(for sub: Subscriber) {
        // Read BEFORE `subscribersLock` — it is this file's innermost lock and never nests outward.
        let head = replayHighestSeqLocked()
        subscribersLock.lock()
        // The transition from inline delivery to an outbox seeds the member's frontier at the HEAD:
        // everything through it has already reached this member — inline, for an incumbent the drain
        // was sending to directly; in the state transfer, for a joiner. A zero here would read as
        // "has shipped nothing", and every join would pause the read loop until the incumbent's
        // sender re-shipped a history it had already delivered.
        //
        // A joiner's seed also claims whatever the drain fanned into its outbox WHILE its snapshot
        // was on the wire. That optimism is bounded and self-correcting: the next capacity's worth
        // of frames re-derives the true backlog, so it costs one gate bound once, at join.
        //
        // Short-circuited on `retired`, so a member whose tasks are already cancelled is never
        // marked as having a sender: the mark and the seed are one indivisible answer over there.
        let alreadyRunning = sub.retired || !fanout.startSender(sub.id, seedingFrontierAt: head)
        subscribersLock.unlock()
        guard !alreadyRunning else { return }
        let (wakeups, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        fifoLock.lock()
        sub.dataWake = wake
        // Read under the SAME section that installs the wake: an enqueue after this point sees the
        // wake and yields for itself, so the two cases are exhaustive with no window between them.
        let hasBacklog = !sub.dataOut.isEmpty
        fifoLock.unlock()
        let data = sub.data
        let sender = Task { [weak self] in
            for await _ in wakeups {
                while let batch = self?.takeDataBatch(for: sub) {
                    for message in batch {
                        try? await data.send(message)
                        if case let .output(seq, _) = message { self?.noteSent(seq, by: sub) }
                        if case .exit = message { self?.markExitDelivered(sub) }
                    }
                }
            }
            // The wake finished (retirement / teardown): anything still queued is undeliverable,
            // and a pending `.exit` must stop blocking the session's bounded wait.
            self?.markExitDelivered(sub)
        }
        install(sender, as: \.dataSendTask, on: sub)
        // Kick ONCE for whatever is already queued. A joiner is entered into the set BEFORE its
        // sender exists (`admitJoiner`), so every frame the drain fans out while its state transfer
        // is on the wire lands in an outbox whose wake is still nil — those producer-side yields go
        // nowhere. Without this kick they wait for the NEXT PTY byte: a pane that goes idle right
        // after a join (a finished build, a returned prompt) leaves the joiner showing the pre-join
        // screen indefinitely. `bufferingNewest(1)` holds the yield until the task reaches its
        // for-await, and a retired member's finished continuation makes it a no-op.
        if hasBacklog { wake.yield(()) }
    }

    /// Appends to ONE member's outbound data queue and wakes its sender. Guarded by `fifoLock` —
    /// the same lock that guards the session's out-FIFO and its wake, because this queue is the
    /// per-member continuation of exactly that pipeline.
    private func enqueueData(_ messages: [WireMessage], on sub: Subscriber) {
        fifoLock.lock()
        sub.dataOut.append(contentsOf: messages)
        let wake = sub.dataWake
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Atomically takes ONE member's whole pending data batch; `nil` when empty (its sender
    /// re-parks).
    private func takeDataBatch(for sub: Subscriber) -> [WireMessage]? {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        guard !sub.dataOut.isEmpty else { return nil }
        let batch = sub.dataOut
        sub.dataOut.removeAll(keepingCapacity: true)
        return batch
    }

    private func markExitDelivered(_ sub: Subscriber) {
        subscribersLock.lock()
        fanout.markExitDelivered(sub.id)
        subscribersLock.unlock()
    }

    /// Records that `sub`'s outbox sender put `seq` on the wire (or died trying — a failed send
    /// still retires the member, and a frontier frozen by a dead channel would pin the producer),
    /// then recomputes the producer bound.
    ///
    /// Per MESSAGE, not per batch: once the fan-out backlog has paused the read loop there is no
    /// producer left to recompute anything, so a sender's own progress is the ONLY thing that can
    /// resume it. Batch-granular updates would leave the pane paused waiting for the very PTY byte
    /// the pause is preventing.
    private func noteSent(_ seq: Int64, by sub: Subscriber) {
        subscribersLock.lock()
        fanout.noteSent(sub.id, seq: seq)
        subscribersLock.unlock()
        updateReplayBackpressure()
    }

    /// Bytes sequenced that not even the FASTEST member has handed to the wire — the producer bound
    /// for a drain that no longer sends inline.
    ///
    /// `0` unless somebody is delivered from an OUTBOX: a pane on the inline path is already bounded
    /// by the out-FIFO's own accounting (the drain parks IN the send, so the bytes stay `outstanding`),
    /// and an EMPTY set has no consumer to lag behind — a parked pane has no subscription at all.
    /// That is what keeps a one-member pane and the whole detach/reattach sequence on the plain
    /// inline path.
    ///
    /// The frontier is a MAX, which is the entire difference between this and "the slowest member":
    /// one parked phone can never assert the pause while a Studio is still consuming. Its cost is
    /// bounded by ``PaneFanout/lagBytes`` eviction instead.
    private func fanoutBacklog() -> Int {
        subscribersLock.lock()
        let frontier = fanout.frontier
        subscribersLock.unlock()
        guard let frontier else { return 0 }
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.retainedBytes(above: frontier)
    }

    // MARK: - The subscriber set: join, leave, and the laggard

    /// Evicts every member whose un-acked backlog exceeds ``PaneFanout/lagBytes``.
    ///
    /// Runs on BOTH sides of the flow — from the producer (`sequenceAndFanOut`) and from the ack
    /// path — because a member that has stopped acking never calls `acknowledge`, so a
    /// consumer-side-only check never fires on the exact client it exists to remove.
    ///
    /// Never with ONE member: a lone subscriber's backpressure is the ReplayBuffer's 64 MiB /
    /// 256 MiB gate, exactly as it has always been, and evicting it would turn a slow link into a
    /// dropped session. The healthiest member is never evicted either, so a pane can never evict
    /// its way to empty.
    ///
    /// The eviction itself is fired from a DETACHED task: the laggard is by definition parked
    /// inside `MuxSubChannel.send`, so closing its channel from the drain that its park is blocking
    /// would deadlock against the very condition it is breaking.
    private func evictLaggingSubscribers() {
        guard let evict = onEvictSubscriber else { return }
        // The set-of-one guard, the healthiest-survives rule and the disabled-threshold early-out
        // are all the fold's; an EMPTY answer means there is nothing worth an O(history) walk. The
        // `retired` filter is this side's, because that latch is about the object's tasks.
        subscribersLock.lock()
        let candidates = fanout.laggingCursors.filter { subscribers[$0.id]?.retired == false }
        subscribersLock.unlock()
        guard !candidates.isEmpty else { return }
        // Priced under `replayLock` and nowhere else: the retained-bytes walk belongs to the buffer,
        // under its own lock, so the fold is handed VALUES rather than reaching for a second handle.
        replayLock.lock()
        let priced = candidates.map {
            (id: $0.id, retainedBytes: replay.retainedBytes(above: $0.acked))
        }
        replayLock.unlock()
        // Latch under the membership lock so a concurrent producer and ack path cannot both decide
        // to evict the same member.
        subscribersLock.lock()
        let doomed = fanout.evict(priced: priced)
        subscribersLock.unlock()
        for id in doomed {
            onLog?("pane subscriber \(id): evicted — more than \(PaneFanout.lagBytes) bytes behind")
            Task.detached { evict(id) }
        }
    }

    /// JOINS a live pane: the Nth client takes its own place in the subscriber set, is
    /// state-transferred the current screen, and follows the live stream from that instant.
    ///
    /// The ordering is `performReattach`'s, reproduced against a drain that is already RUNNING:
    /// the caller sends `channelOpenAck` first (the client awaits it), then this composes the
    /// joiner's snapshot and enters it in the set ATOMICALLY w.r.t. the drain, then ships the
    /// snapshot, then starts the member's own sender so the frames that accumulated meanwhile
    /// follow it in order. Neither a hole nor a duplicate is possible.
    ///
    /// The compose is deliberately NON-DESTRUCTIVE (``composeSnapshotReplay`` `adopting: false`):
    /// the reattach path's version splices the out-FIFO and REPLACES the retained history, which
    /// are safe only because a reattach happens with the drain stopped. Run against a live session
    /// they would delete a window of the incumbent's un-shipped output — bytes that are pre-seq, so
    /// no replay can recover them — and rewrite the seqs it is mid-stream on.
    ///
    /// - Parameter id: the id the caller RESERVED for this join (``reserveSubscriberID()``) inside
    ///   the same critical section that registered its channel key. The key is visible to every
    ///   per-client teardown path the instant it is written, but the member does not exist until
    ///   this method returns — so the reservation is what makes a link drop in that window
    ///   attributable to the JOINER. `nil` mints one at admission: the unit-test shape, where
    ///   nothing else can name the key.
    ///
    /// - Returns: `false` when the pair is already dead (the joining link died mid-open), leaving
    ///   the set untouched so the caller can refuse the channel.
    func joinSubscriber(
        id: MuxSubscriberID? = nil,
        data newData: MuxSubChannel,
        control newControl: MuxSubChannel,
        sizePassive: Bool,
    ) async -> MuxSubscriberID? {
        guard !newData.isFinished, !newControl.isFinished else { return nil }
        // A DETACHED session has no drain to join; that is `rebindRelay`'s job. Re-checked inside
        // `admitJoiner` under the join lock — this early exit only avoids paying for a render that
        // could not be used.
        guard !isDetachedForJoin() else { return nil }

        // Composed OUTSIDE the join lock, deliberately: rendering the screen model is an
        // O(retained history) walk — seconds on a pane with a full scrollback — and holding the
        // drain's ordering lock across it would stall the INCUMBENT's output for that whole window.
        // A join must cost the client already watching nothing.
        let (rendered, composedThrough) = composeJoinSnapshot()
        guard let (sub, catchUp) = admitJoiner(
            reserved: id, data: newData, control: newControl,
            composedThrough: composedThrough,
        ) else { return nil }
        let id = sub.id

        // The joiner is in the set, so live frames are already accumulating in its outbox — its
        // sender is deliberately NOT started yet, so this replay owns the channel until it is done.
        addResizeContributor(id, sizePassive: sizePassive)
        startControlSender(for: sub)
        for message in rendered + catchUp {
            try? await newData.send(message)
        }
        // Race seam: the joiner is IN the set and its data sender does not exist yet, so every frame
        // the drain sequences right now lands in an outbox with a nil wake. Async, so a test can
        // await the drain reaching that state instead of blocking a cooperative thread. `nil` in
        // production — an un-called optional method is not a suspension point.
        await onJoinerAdmittedForTesting?()
        startDataSender(for: sub)

        // JOIN-scoped re-asserts, addressed to the new member only — the incumbents were told these
        // truths when they happened, and re-telling them would flood a client that is up to date.
        reestablishEchoOnReattach(echoOn: PTYEchoProbe.echoEnabled(masterFD: pty.masterFD), to: id)
        resendBlocksOnReattach(to: id)
        reestablishActivityOnReattach(to: id)

        startInputRelay(for: sub)
        startControlRelay(for: sub)
        recomputeClientOnline()
        return id
    }

    /// The synchronous half of ``joinSubscriber(data:control:sizePassive:)``: switches
    /// the drain to fan-out, composes the state transfer, and enters the new member — all under
    /// `fanoutLock`, so no frame can be sequenced between "the drain now fans out" and "every
    /// member can receive a fan-out", nor between the snapshot and the joiner's arrival.
    ///
    /// NSLock is unavailable from an async context (the ``snapshotReplayTailForSend(after:)``
    /// discipline), and the whole point of this section is that it never suspends anyway.
    private func admitJoiner(
        reserved: MuxSubscriberID?,
        data newData: MuxSubChannel,
        control newControl: MuxSubChannel,
        composedThrough: Int64,
    ) -> (Subscriber, [WireMessage])? {
        fanoutLock.lock()
        defer { fanoutLock.unlock() }
        // A session whose set emptied (or detached) while the render ran has no drain to join.
        taskLock.lock()
        let detached = isDetached
        taskLock.unlock()
        guard !detached else { return nil }
        let incumbents = subscriberList()
        guard !incumbents.isEmpty else { return nil }
        for sub in incumbents { startDataSender(for: sub) }
        fanoutActive = true
        // Whatever the drain sequenced WHILE the snapshot was rendering, byte-exact and exactly
        // once: the render covers through `composedThrough`, the joiner's outbox starts collecting
        // at the seq assigned after this lock is taken, and this bridges the two. Without it the
        // joiner's transcript has a hole the width of the render.
        replayLock.lock()
        let catchUp = replay.messages(after: composedThrough).map {
            WireMessage.output(seq: $0.seq, bytes: $0.bytes)
        }
        replayLock.unlock()
        // The joiner starts CURRENT: it is receiving the rendered screen, not the history behind
        // it, so its retention cursor must not hold bytes every other member has already acked.
        // Read BEFORE `subscribersLock` — this file's innermost lock never nests outward — and
        // still exact, because `fanoutLock` is held across both: no frame can be sequenced between.
        let head = replayHighestSeqLocked()
        subscribersLock.lock()
        let id = reserved ?? fanout.reserveID()
        let sub = Subscriber(id: id, data: newData, control: newControl)
        subscribers[id] = sub
        fanout.join(id, acked: head)
        subscribersLock.unlock()
        return (sub, catchUp)
    }

    /// The rendered screen a joiner opens on: the same state transfer a cold reattach receives,
    /// composed WITHOUT consuming the out-FIFO or replacing the retained history. Falls back to the
    /// raw retained tail when no policy is injected or the compose declines.
    ///
    /// - Returns: the messages, and the highest seq they actually cover. That coverage point is
    ///   DERIVED from what was produced rather than read off the buffer afterwards: a frame
    ///   appended between the snapshot source being taken and the read would otherwise be either
    ///   skipped (a hole) or shipped twice, depending on which side of the race won.
    private func composeJoinSnapshot() -> ([WireMessage], Int64) {
        var messages: [WireMessage] = []
        if let policy = snapshotReplay,
           let rendered = composeSnapshotReplay(after: 0, policy: policy, adopting: false)
        {
            messages = rendered
        } else {
            replayLock.lock()
            messages = replay.replay(after: 0)
            replayLock.unlock()
        }
        var covered: Int64 = 0
        for message in messages {
            if case let .output(seq, _) = message { covered = Swift.max(covered, seq) }
        }
        return (messages, covered)
    }

    /// RESERVES the id a pending JOIN will enter the set under, before the join runs.
    ///
    /// The composite key a joining channel registers under is visible to every per-client teardown
    /// path (`handleLinkDown`, a peer `channelClose`, the eviction seam) the instant it is written,
    /// but the member itself does not exist until ``joinSubscriber(id:data:control:sizePassive:)``
    /// has composed an O(retained history) screen and shipped it through the joiner's credit window —
    /// seconds on a pane with a full scrollback. A key naming no id in that window falls back to
    /// ``primarySubscriberID``, and the joiner's link dropping there retires the INCUMBENT and parks
    /// its live pane. Reserving under the same critical section that registers the key is what makes
    /// the window attributable.
    ///
    /// A reservation the join never uses (a refused or failed open) simply skips an id.
    func reserveSubscriberID() -> MuxSubscriberID {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return fanout.reserveID()
    }

    /// Synchronous read of the detach latch — ``PaneLifecycle`` serializes it, so this no longer
    /// needs a lock the async caller cannot take.
    private func isDetachedForJoin() -> Bool { life.isDetached }

    private func replayHighestSeqLocked() -> Int64 {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.highestSeq
    }

    /// The highest sequence number this session has ever assigned — the ceiling of any honest
    /// resume verdict.
    ///
    /// Reattach needs it because a session's numbering is a property of the SESSION OBJECT, and an
    /// adopted pane is a new object around an old shell: its buffer starts at zero while the client
    /// coming back to it is warm and remembers thousands. See `HostServer.performReattach`.
    var highestAssignedSeq: Int64 { replayHighestSeqLocked() }

    /// LEAVES: retires ONE member and reports whether the set is now EMPTY.
    ///
    /// Refcounted, deliberately: with two clients on one pane, one closing its lid must not engage
    /// the offline gate that pauses the PTY drain — the other client's pane would go dead-quiet
    /// while the shell keeps producing, and because the drain's wake continuation is nil'd on
    /// detach even a later chunk could not re-wake it. The session-wide teardown belongs to the set
    /// EMPTYING, and the caller owns that decision.
    @discardableResult
    func removeSubscriber(_ id: MuxSubscriberID) -> Bool {
        guard let sub = subscriber(id) else { return subscriberCount == 0 }
        let emptied = retireSubscriber(sub)
        removeResizeContributor(id)
        // Recomputed from the SET, never asserted: with somebody still holding the pane this reads
        // TRUE and the offline gate stays clear, which is the whole difference between a refcounted
        // leave and today's detach. Only an EMPTIED set reads false.
        recomputeClientOnline()
        // Retention releases to the MIN over the members that REMAIN — a departed member's stale
        // cursor must not keep pinning the buffer for a reader that has gone.
        releaseRetentionToMinimum()
        // The queue bound does NOT follow the population any more: 64 KiB is a LATENCY bound, and it
        // is the only one. An emptied set that has not yet been parked keeps draining (the drain
        // discards a frame with no target, dequeue included), so the bound is never what an idle
        // set backs up against; and once the caller parks it, `detach()` drops the subscription
        // outright and the pane's bytes wait in superd's ring instead of this host's FIFO.
        return emptied
    }

    /// Recomputes the retention floor over the CURRENT set and releases the ReplayBuffer to it.
    /// Called when membership changes (a departure can only ever RAISE the floor).
    ///
    /// The gate is re-applied UNCONDITIONALLY, floor or no floor: a departure also changes the
    /// fan-out frontier, and the member that just left may have been the fastest one holding the
    /// producer open — or the last one, whose exit must clear the source entirely.
    private func releaseRetentionToMinimum() {
        backpressureApplyLock.lock()
        subscribersLock.lock()
        let floor = fanout.retentionFloor
        subscribersLock.unlock()
        if let floor {
            replayLock.lock()
            replay.ack(upTo: floor)
            replayLock.unlock()
        }
        applyBackpressureSourcesLocked()
        backpressureApplyLock.unlock()
    }
}
