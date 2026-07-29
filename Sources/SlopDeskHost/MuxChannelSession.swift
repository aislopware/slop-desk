import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import SlopDeskTransport

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
/// - OUTPUT: a no-buffer ``PTYReadLoop`` → an ordered FIFO → one sequential awaiter that assigns a
///   seq via the per-channel `ReplayBuffer` and writes `output` on the channel's DATA sub-channel;
///   `.title`/`.bell` sniffed non-destructively and written on the CONTROL sub-channel after.
/// - INPUT: the DATA sub-channel's inbound `input` → master fd.
/// - RESIZE/BYE/ACK: the CONTROL sub-channel's inbound → `TIOCSWINSZ` / offline / (ack is a no-op
///   beyond release; there is no per-channel reconnect replay so it just keeps the buffer bounded).
/// - EXIT: the reaper enqueues `exit(code:)` on the same FIFO so it follows the final output tail.
///
/// ### Bounded output queue (always on)
/// The DATA send window SUSPENDS the drain when a flooding channel runs out of credit — but without
/// an upstream bound that just moves the unboundedness one hop: the `PTYReadLoop` would buffer the
/// whole `yes` flood into the FIFO. So the queue is BOUNDED by a
/// ``SlopDeskProtocol/BoundedQueuePolicy`` (byte high-water mark): when enqueued-not-yet-sent bytes
/// cross the bound the ``PTYReadLoop`` is PAUSED (its `NSCondition` gate stops issuing `read()`, so
/// the kernel PTY buffer fills and backpressures the shell — the real flood fix); it RESUMES when
/// the drain brings the queue back under the bound.
///
/// ### Detach / reattach (tmux-style survival)
/// On client disconnect with detach enabled, ``detach()`` runs instead of
/// ``shutdown()``: it cancels the relay tasks and engages the ReplayBuffer's offline gate to pause
/// the PTY drain, but does NOT stop/close the ``PTYReadLoop`` — `stop()` is irreversible. The shell
/// (and the paused read loop) survive. On return, ``rebindRelay(data:control:)`` swaps the stale
/// sub-channels, KEEPS the out-FIFO (its chunks were never sequenced into the ReplayBuffer — they
/// are the detached-window output the restarted drain must ship), clears the stateless control-out,
/// rebuilds the wake streams, and restarts the relay tasks.
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

    /// Whether this session is currently in the detached state (client gone, shell alive).
    /// Guarded by `taskLock`. A detached session must NOT be `shutdown()`'d — use
    /// ``detach()`` / ``shutdownDetached()`` from ``DetachedSessionStore.evict`` paths.
    private(set) var isDetached: Bool = false

    /// One subscriber's half of the relay: the sub-channel PAIR it rides, the three tasks bound to
    /// that pair, its own control-out queue, and its own ack cursor.
    ///
    /// The channels are `let` — a subscriber IS its pair. A returning client REPLACES the member
    /// instead of having new channels swapped in underneath it, so every task a subscriber owns is
    /// bound to a pair that cannot change under it. That is what makes it safe for the inbound loops
    /// to read their own channel directly: there is no "the session's channel" for half the relay to
    /// follow and the other half to stay pinned to.
    ///
    /// Locks: `subscribersLock` guards membership, the three task references and `retired`;
    /// `controlOutLock` guards the queue + its wake (the same lock those fields had as session
    /// state); `replayLock` guards `lastAckedSeq`.
    final class Subscriber: @unchecked Sendable {
        let id: MuxSubscriberID
        let data: MuxSubChannel
        let control: MuxSubChannel

        /// The three tasks bound to this pair, and whether the pair has been retired. All four are
        /// guarded by `subscribersLock`: a relay builder and a retire can genuinely race (a channel
        /// that finishes the instant it is handed over), and the flag is what stops the loser of
        /// that race from installing a task on a member nobody will ever cancel.
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
        /// ``MuxChannelSession/subscriberLagBytes`` caps it at 32 MiB per member before eviction
        /// takes the member out.
        var dataOut: [WireMessage] = []
        var dataWake: AsyncStream<Void>.Continuation?
        var dataSendTask: Task<Void, Never>?

        /// One-shot latch: this member has already been handed to ``onEvictSubscriber``.
        ///
        /// Eviction is asynchronous by necessity (the laggard is parked in a send, so the close
        /// runs on a detached task), and the condition that triggered it stays true until the close
        /// lands. Without the latch every subsequent appended frame would fire another
        /// `closeChannel` and another log line for a member already on its way out.
        var evicting = false

        /// Whether this member's `.exit` frame has left the sender (or the member died trying).
        /// The exit task must not release `onExit` → `shutdown()` until every reachable member has
        /// been told, or members 2..N watch a shell that is already dead with no exit code.
        var exitDelivered = false

        /// This subscriber's OWN pending control queue + wake. One queue per member, deliberately:
        /// the ``MuxChannelSession/maxControlOutQueued`` newest-shed promises a bound per reader, and
        /// a single shared queue with N cursors would let one stalled reader hold it at the cap and
        /// shed messages for the healthy ones.
        var controlOut: [WireMessage] = []
        var controlWake: AsyncStream<Void>.Continuation?

        /// The highest seq THIS subscriber has confirmed. Retention releases to the MIN across the
        /// set, so no member's tail can be dropped by another member's progress.
        var lastAckedSeq: Int64 = 0

        /// The highest seq this member's OUTBOX SENDER has handed to the wire (or died trying).
        ///
        /// Distinct from ``lastAckedSeq`` — which is the peer's confirmation, an RTT later — because
        /// the producer bound is about what the HOST is still holding, not about what the client has
        /// rendered. The MAX across the set is the fastest member's delivery frontier, and
        /// ``MuxChannelSession/fanoutBacklog()`` turns it into the pause signal that replaces the
        /// out-FIFO's accounting once the drain stops sending inline.
        ///
        /// Meaningful only while ``dataSendTask`` exists: an inline-delivered member has no outbox
        /// and never advances this.
        var lastSentSeq: Int64 = 0

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
    private var subscribers: [MuxSubscriberID: Subscriber] = [:]

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

    /// Mints the next JOIN's subscriber id. `primarySubscriberID` (0) belongs to the channel the
    /// session was opened for; joiners count up from 1. Guarded by `subscribersLock`.
    private var nextSubscriberID: MuxSubscriberID = 1

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
        return subscribers.keys.sorted().compactMap { subscribers[$0] }
    }

    /// How many members hold this pane right now (the fold's and the gate's population).
    var subscriberCount: Int {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return subscribers.count
    }

    private func subscriber(_ id: MuxSubscriberID) -> Subscriber? {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return subscribers[id]
    }

    /// The per-session ZDOTDIR shim directory, if the zsh shell-integration shim was installed for
    /// this pane. Deleted in ``shutdown()`` once the child has exited — safe because the shell read
    /// its rc files at exec time. Without this, every opened pane leaks one `slopdesk-zdotdir-*`
    /// dir + 4 files into temp for the host's long-lived lifetime.
    private let shimDir: URL?

    /// Whether host-side Claude-Code agent detection (the foreground process-watch) is enabled for
    /// this channel. When true, ``startRelay()`` spins a low-rate poll that resolves
    /// the PTY's foreground basename and drives ``ForegroundProcessDetector`` → type-26/27.
    private let agentDetectEnabled: Bool

    /// The interval between foreground-process samples (~1 Hz; injected so a future test could
    /// drive it, though the poll itself is never run in a unit test — hang-safety).
    private let agentPollInterval: Duration

    /// LIVE probe of the host's agent-hook listener bind state, injected by ``HostServer``
    /// (`{ agentHookListener?.isListening ?? false }`). Read per
    /// `agentHookStatus` (verb 13) request so the reply reports whether hooks are ACTUALLY flowing,
    /// not just installed on disk. Defaults `false` (no listener wired — the honest answer).
    private let agentHookListenerActive: @Sendable () -> Bool

    /// Whether the additive "Blocks" tap runs for this channel. When false the byte pipeline
    /// + the live ``HostOutputSniffer`` are byte-identical (the segmenter is never instantiated, no
    /// type-28/29 ever emitted). Resolved from `SLOPDESK_BLOCKS` (default-ON) by the owner.
    private let blocksEnabled: Bool

    /// The per-channel "Blocks" tracker (the segmenter + bounded output ring + dedup), or
    /// `nil` when ``blocksEnabled`` is false. Touched from TWO contexts — the serial read-loop
    /// thread (`ingest` in `onChunk`) and the control task (`serveOutput` on a `requestBlockOutput`)
    /// — so it is guarded by ``blocksLock``. A pure value type, so it lives behind the lock.
    private let blocksLock = NSLock()
    private var blockTracker: CommandBlockTracker?

    /// The SINGLE per-pane Claude detector (ONE ``ClaudeStatusMachine``). Fed by ALL detection
    /// inputs — the foreground poll's `processPresent`, the per-poll `tick` (drives the `.done→.idle`
    /// decay), and the hook socket's bytes — so the host is the single source of truth. Touched from
    /// TWO contexts (the serial `agentWatchTask` and the socket-accept thread when a hook POSTs), so
    /// it is guarded by `agentDetectLock`. ONE machine, deliberately: a pair of independent machines
    /// (`foregroundDetector` + `agentHookHandler`) would fight over the one type-27 stream.
    private let agentDetectLock = NSLock()
    private var agentDetector = ClaudePaneDetector()

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

    /// The pure per-pane PTY-echo edge detector (the AUTO Secure-Keyboard-Entry signal).
    /// Driven by ``PTYEchoProbe`` from TWO contexts — the input task (opportunistically right after a
    /// client keystroke is written to the PTY, where `ECHO` flips fastest around a password prompt) and
    /// the foreground-watch poll (a low-rate backstop, when `agentDetectEnabled`) — so it is guarded by
    /// `echoDetectLock`. Anchored at echo-on, so it is SILENT until the child actually clears `ECHO`
    /// (the CONTROL stream stays byte-identical when no no-echo prompt ever appears).
    private let echoDetectLock = NSLock()
    private var echoDetector = EchoModeDetector()

    /// Connect-time warm-up guard for the echo edge (guarded by `echoDetectLock`). A freshly
    /// connected PTY master can read `ECHO`-cleared for a sample or two right after attach — before the
    /// line discipline settles to echo-on — and folding that transient as a real edge would emit a
    /// spurious `inputEcho(false)` that LATCHES the client's Secure-Input pill on a normal prompt. So
    /// ``foldEchoSample(echoOn:)`` HONORS a no-echo edge only AFTER first observing a confirmed echo-ON
    /// sample. The reattach path (``reestablishEchoOnReattach(echoOn:to:)``) is SEPARATE — it re-asserts
    /// the current echo truth immediately and is NOT gated by this flag.
    private var echoWarmedUp = false

    // MARK: - Agent-control surface state

    /// The last OSC-0/2 title sniffed from the PTY output stream. Updated on the PTY
    /// read-loop thread under `titleLock`; read by the agent-control `list-panes` verb.
    private let titleLock = NSLock()
    private var _currentTitle: String = ""

    /// When ``_currentTitle`` was sniffed, `nil` when no title has arrived or the agent retired the
    /// one it owned. Half of the `pane/titleFresh` verdict (docs/45 §4.4) — the host decides
    /// freshness and ships the ANSWER, because the client's own two-stamp comparison reset to empty
    /// on every cold start and so failed permanently.
    ///
    /// Stamped on `timeIntervalSinceReferenceDate`, deliberately matching
    /// ``HostOutputSniffer/commandRunningSince()`` rather than the `systemUptime` the detector folds
    /// on. The two stamps are COMPARED; on two different clocks — one of which stops during sleep —
    /// the comparison would be meaningless in exactly the case (a laptop that slept) where the user
    /// notices.
    private var _currentTitleAt: TimeInterval?

    /// Set when the detector retired an exiting agent's title (see ``ClaudePaneDetector/Emission``)
    /// and consumed by the PTY read loop before its next sniffer pass. The retirement can be folded
    /// from ANY of the detector's feeds — the foreground poll, the scan task, the hook socket — but
    /// the sniffer's coalescing anchor belongs to the read-loop thread, so the request crosses over
    /// as a flag under `titleLock` rather than as a direct call.
    private var pendingTitleCoalescingReset = false

    /// Reattach truth — the last NON-CLEAR OSC 9;4 progress message emitted for this pane
    /// (`nil` when cleared / never reported). Latched at BOTH emit points — the sniffer's chunk pass
    /// and the Blocks segmenter's auto-progress — so a reattaching client (which reset its progress
    /// mirror on disconnect) can be re-told the live state: progress is control-only, never in the
    /// replayed output bytes — the same class as the echo truth. Guarded by `progressLock` (written
    /// on the read-loop thread; read by the reattach path).
    private let progressLock = NSLock()
    private var lastProgress: WireMessage?

    /// The freshest OSC 9;4 pair, latched beside ``lastProgress`` so the document can publish the
    /// VALUE rather than re-deriving it from a message.
    private var lastProgressPair: (state: UInt8, percent: UInt8)?

    /// The last foreground process name the watcher sampled (`pane/foregroundProcess`). Latched
    /// here rather than re-probed per read: `PTYForegroundProbe.foregroundName` is a syscall, and
    /// the reconciler would pay it per pane per tick.
    private let foregroundLock = NSLock()
    private var _lastForeground: String?

    /// Monotone count of FINISHED TURNS (`pane/completionEpoch`), and the status the count last
    /// stood at (the transition, not the state, is what mints one — see
    /// ``isCompletionTransition(previous:next:)``).
    ///
    /// The host holds ZERO per-client acknowledgement state: it publishes how many turns have
    /// finished, and each viewer compares that against its own device-local `seenCompletionEpoch`.
    /// Clients agree on the FACT and are free to disagree about the ACKNOWLEDGEMENT — which is
    /// what makes "unseen" per-device without any of it crossing the wire.
    private let completionLock = NSLock()
    private var _completionEpoch: UInt32 = 0
    private var _lastCompletionStatus: ClaudeStatus = .none

    /// Host-authoritative By-Project key (type 34) — the reattach/dedupe latches. `lastCwdTruth` is
    /// the freshest cwd this session has observed (OSC-7 sniff, else the prompt-edge `proc_pidinfo`
    /// probe), latched at the SNIFF point on the read-loop thread (like `lastProgress` — a detached
    /// window's change must be visible to the reattach re-assert immediately). `lastProjectKey` is
    /// the last EMITTED type-34 (git toplevel containing that cwd, else the cwd itself —
    /// ``ProjectKeyResolver``), latched at RESOLVE COMPLETION on `metadataQueue`: the resolver's
    /// `stat(2)`-per-ancestor walk is blocking filesystem work (a hung network mount can park it
    /// indefinitely), so ``deriveProjectKey(from:)`` dispatches it off the read-loop thread and the
    /// emission goes straight to ``broadcastControl(_:)``. Both latches are re-asserted by
    /// ``reestablishActivityOnReattach(to:)`` so a reconnecting client renders the FINAL sidebar
    /// sections immediately, with zero client-side re-derivation. `projectKeyWarmedUp` gates
    /// OSC-7-only derivation until the first command edge (see ``deriveProjectKey(from:)``).
    /// All guarded by `projectKeyLock` (written on the read-loop thread + `metadataQueue`; read by
    /// the reattach path).
    private let projectKeyLock = NSLock()
    private var lastCwdTruth: String?
    private var lastProjectKey: String?
    private var projectKeyWarmedUp = false

    /// Test seam for the prompt-edge cwd probe (the ``HostMetadataProbe`` `proc_pidinfo` read):
    /// unit tests drive ``ingestPTYChunkForTesting(_:)`` on an UNSPAWNED PTY (hang-safety rule), where
    /// the real probe answers `nil` (pid −1 guards out before any syscall) — injecting a fake here
    /// lets them exercise the non-OSC-7 derivation path deterministically. `nil` (production) uses
    /// the real probe.
    var cwdProbeOverride: (() -> String?)?

    /// Test seam for the async project-key resolve hop: production dispatches the
    /// ``ProjectKeyResolver`` stat-walk onto the serial `metadataQueue` (resolves stay ordered);
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
    /// ``feedBlocks(_:)`` (the PTY read-loop thread) with each type-28 block-metadata emission,
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

    /// The freshest OSC-133-D exit code this session has observed (`133;D;<code>` from the
    /// sniffer's `.commandStatus(.idle(exitCode:))`), latched at the sniff point like
    /// `lastProgress`. Guarded by `commandExitLock` (written on the read-loop thread; read by
    /// the ctl `list-panes` handler threads). `nil` until the first code-carrying `D`.
    private let commandExitLock = NSLock()
    private var lastExitTruth: Int32?

    /// The host-measured C→D duration of the last completed command (`pane/lastDurationMS`).
    private var lastDurationTruth: UInt32?

    /// A dedicated serial queue for the host metadata RPC's BLOCKING probe work (git/lsof/proc/
    /// FileManager). Kept OFF the serial control loop so a slow `lsof` / `git` can never stall this
    /// pane's resize/ack/ping; ``sendControl(_:to:)`` (lock-guarded) carries the answer back to the
    /// peer that asked. Serial so concurrent metadata requests for one pane don't pile up
    /// subprocesses.
    private let metadataQueue = DispatchQueue(label: "slopdesk.host.metadata", qos: .userInitiated)

    /// The number of metadata work items currently admitted onto
    /// `metadataQueue` for this session (guarded by `metadataInFlightLock`; incremented at
    /// admission in ``serveMetadata(requestID:verb:payload:)``, decremented when the work item
    /// finishes). The control sub-channel is deliberately unwindowed, so this counter is the ONLY
    /// bound between a hostile/buggy peer streaming back-to-back tiny `.metadataRequest` frames
    /// and an unbounded pile of queued closures (each retaining its payload + self) forking
    /// `git`/`lsof` without limit.
    private let metadataInFlightLock = NSLock()
    private var metadataInFlight = 0

    /// The per-session cap on admitted-not-yet-finished metadata work items. At/over the cap a
    /// request is NOT enqueued — it is answered IMMEDIATELY with the builder's standard `.error`
    /// status byte + empty payload (the same shape as any other failed verb), so the "ALWAYS
    /// replies, the client never hangs" contract holds under a flood.
    private static let maxMetadataInFlight = 32

    /// ONE fused non-destructive sniffer for the PTY chunk path (title/bell + OSC 133 command
    /// status — one pass, not two per-byte machines scanning the hot thread twice). Touched only
    /// on the read-loop thread via ``ingestPTYChunk(_:)``.
    private let sniffer = HostOutputSniffer()

    /// Disk scrollback journal for this session (nil = disk persistence off). Fed ONLY by
    /// ``ingestPTYChunk(_:)`` — genuine PTY output — so a restored preamble (which enters via the
    /// out-FIFO) is never re-journaled and transcripts don't double across daemon restarts.
    /// Internal (not private): `HostServer`'s end-of-life paths pass THIS instance to the
    /// store's identity-guarded `release(sessionID:instance:)`/`delete(sessionID:instance:)`,
    /// so a stale teardown of a same-UUID ghost can never close the live successor's writer.
    let scrollbackJournal: ScrollbackJournal?

    /// The prior life's distilled transcript (fresh-spawn restore, `HostServer.spawnFreshShell`).
    /// Enqueued as the FIRST output frame(s) by ``startRelay()`` — before the read loop starts —
    /// so it precedes every live shell byte. `nil`/empty = nothing to restore. RELEASED (nil'd)
    /// by ``enqueueRestoredScrollback()`` once handed to the out-FIFO: a stored session-lifetime
    /// copy pinned up to the journal cap of bytes per restored pane. Guarded by `fifoLock`
    /// (written once post-init; the test seam reads it cross-thread).
    private var restoredScrollback: Data?

    private let taskLock = NSLock()
    private var replay: ReplayBuffer
    private let replayLock = NSLock()
    /// The replay transform (``ScrollbackReplayTransform``), captured at init from the injected
    /// ``ReplayBuffer/scrollbackDistiller`` so ``compactDetachedBacklogForColdClient()`` can run
    /// the SAME pipeline over the out-FIFO's detached-window backlog without touching `replay`
    /// under a lock (the field is immutable; the pre-concurrency init read is race-free).
    private let coldBacklogTransform: (@Sendable (Data) -> Data)?

    /// State-transfer replay (docs/DECISIONS.md 2026-07-25): compose the reattach replay by
    /// RENDERING the screen model once instead of replaying (however distilled) byte history.
    struct SnapshotReplayPolicy: Sendable {
        /// `(raw chronological history, rows, cols) -> rendered snapshot stream`
        /// (``TerminalReplaySnapshot/compose(raw:rows:cols:)`` in production).
        let compose: @Sendable (Data, Int, Int) -> Data
        /// A WARM reconnect whose pending raw replay (un-acked tail + detached FIFO backlog)
        /// meets this many bytes is snapshotted (the rendered preamble wipes the live grid);
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
    private var readLoop: PTYReadLoop?
    private var started = false

    /// The output FIFO: a lock-guarded deque (NOT an AsyncStream of items — iterators
    /// cannot peek, and the drain needs to MERGE adjacent chunks). Producers append under
    /// `fifoLock` then yield the bufferingNewest(1) wake; the single drain pops merged
    /// frames until empty before re-parking (the proven ConnectionViewModel outQueue
    /// discipline — append-then-yield, drain-until-empty, no lost wake, no Task-per-item).
    private let fifoLock = NSLock()
    private var outFIFO: [OutputItem] = []

    /// Index-cursor deque head for `outFIFO` (guarded by `fifoLock`, like the array). Producers
    /// APPEND only; the drain pops by advancing this cursor instead of `Array.removeFirst()` —
    /// which is an O(count) memmove per pop, and a DETACHED session accumulates one entry per
    /// PTY `read()` (nothing drains) up to the 64 MiB budget, so the reattach drain would pay
    /// O(n²) element shifts (~10^11 at a full kernel-chunk backlog — a huge reattach stall).
    /// ``advanceFIFOHead()`` bulk-compacts the consumed prefix (amortized O(1) per pop).
    /// Invariant: `0 <= fifoHead <= outFIFO.count`; entries below `fifoHead` are consumed.
    /// `outFIFO` is never cleared/reassigned anywhere else, so no other reset site is needed.
    private var fifoHead = 0

    /// Threshold for bulk-compacting the consumed FIFO prefix: only once the dead prefix is
    /// both non-trivial (≥ 64 slots) AND at least half the array does one `removeFirst(k)`
    /// memmove reclaim it — amortized O(1) per pop, bounded slack. A fully-drained FIFO is
    /// emptied outright in ``advanceFIFOHead()`` so consumed chunks' `Data` never lingers.
    private static let fifoCompactThresholdSlots = 64

    /// Advances the deque cursor past a consumed head entry and compacts when warranted.
    /// MUST be called with `fifoLock` held.
    private func advanceFIFOHead() {
        fifoHead += 1
        if fifoHead >= outFIFO.count {
            // Fully drained (the interactive steady state lands here every pop): drop the
            // storage so consumed chunks' Data is released promptly and the cursor resets.
            outFIFO.removeAll(keepingCapacity: false)
            fifoHead = 0
        } else if fifoHead >= Self.fifoCompactThresholdSlots, fifoHead >= outFIFO.count / 2 {
            outFIFO.removeFirst(fifoHead)
            fifoHead = 0
        }
    }

    /// Guards every subscriber's ``Subscriber/controlOut`` + ``Subscriber/controlWake`` — one queue
    /// and one wake per member (same teardown race as ``outputWakeContinuation``).
    ///
    /// Sniffed control is split from the data drain so a slow/stalled CONTROL socket (or per-redraw
    /// title churn) can never stall data sends — a shared drain would make data wait on control.
    /// Per-subscriber control FIFO still holds (running→idle, successive titles); cross-socket order
    /// vs data is NOT guaranteed (different TCP connections).
    private let controlOutLock = NSLock()

    /// One merged data frame popped off the FIFO by the drain. Internal (not private) so the
    /// drain-merge tests can assert on popped frames via the `_…ForTesting` seams.
    enum MergedFrame {
        case output(bytes: Data, byteCount: Int, control: [WireMessage])
        case exit(code: Int32)
    }

    /// Pops the next merged frame under `fifoLock`. `.exit` is a merge BARRIER (it must
    /// stay strictly after the final tail chunks — the EOF-latch ordering).
    /// Single-chunk fast path returns the chunk's `Data` UNCHANGED (zero added copy — the
    /// interactive steady state stays byte-identical work); only a multi-chunk backlog
    /// pays one concatenation, amortized by skipping N−1 seq/encode/envelope/send rounds.
    ///
    /// FRAME BOUND (credit progress invariant): every emitted `.output` payload is capped
    /// at ``MuxFlowControl/maxOutputFramePayloadBytes`` — window/2 minus the frame-header
    /// margin, cross-clamped against the merge cap. An over-cap HEAD chunk (a raw read
    /// chunk, or env-tuned extremes) is SPLIT: the prefix ships now, the remainder is
    /// reinserted at the FIFO head (byte order preserved; the gate accounting still sums
    /// to the producer's enqueued total because each emitted frame dequeues exactly its
    /// own byteCount). Without this, a max-size frame's 13-byte encode overhead could park
    /// the sender permanently just below the receiver's grant threshold — the 13-byte
    /// dead-zone stall.
    func takeMergedFrame() -> MergedFrame? {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        let cap = MuxFlowControl.maxOutputFramePayloadBytes
        guard fifoHead < outFIFO.count else { return nil }
        let head = outFIFO[fifoHead]
        if case let .exit(code) = head {
            advanceFIFOHead()
            return .exit(code: code)
        }
        // Head is a chunk: pop it, then greedily absorb following chunks up to the cap.
        guard case var .chunk(bytes, control) = head else { return nil }
        if bytes.count > cap {
            // SPLIT an over-cap head chunk: ship the prefix (with the chunk's sniffed
            // control — per-channel control FIFO holds), overwrite the unconsumed HEAD
            // SLOT with the remainder (O(1); a removeFirst + insert(at: 0) pair would be
            // two O(count) memmoves per emitted frame) so byte order is untouched.
            let prefix = Data(bytes.prefix(cap))
            let remainder = Data(bytes.dropFirst(cap))
            outFIFO[fifoHead] = .chunk(bytes: remainder, control: [])
            return .output(bytes: prefix, byteCount: prefix.count, control: control)
        }
        advanceFIFOHead()
        var byteCount = bytes.count
        if fifoHead < outFIFO.count,
           case let .chunk(nextBytes, _) = outFIFO[fifoHead],
           byteCount + nextBytes.count <= cap
        {
            // Multi-chunk merge: one mutable accumulator, reserve once.
            var merged = Data(capacity: min(cap, byteCount + nextBytes.count))
            merged.append(bytes)
            while fifoHead < outFIFO.count,
                  case let .chunk(more, moreControl) = outFIFO[fifoHead],
                  byteCount + more.count <= cap
            {
                advanceFIFOHead()
                merged.append(more)
                byteCount += more.count
                control.append(contentsOf: moreControl)
            }
            bytes = merged
        }
        return .output(bytes: bytes, byteCount: byteCount, control: control)
    }

    /// Replaces the out-FIFO's detached-window chunk backlog with its replay-transformed
    /// equivalent — the un-sequenced counterpart of ``ReplayBuffer/replay(after:)``'s cold path.
    ///
    /// Called ONLY from ``rebindRelay`` with `transformDetachedBacklog: true` (a COLD client),
    /// BEFORE the output drain restarts: bytes produced while detached live in the out-FIFO (seq
    /// assignment happens at drain time), so the ring/tail transform inside the ReplayBuffer
    /// never sees them — without this pass a client whose Claude Code ran detached for hours
    /// receives up to the detached budget (64 MiB) of raw repaint churn AFTER the clean replay.
    ///
    /// The chunk prefix is snapshotted under `fifoLock`, transformed UNLOCKED (the transform is
    /// seconds-scale on a full budget; producers may append meanwhile), then spliced back under
    /// the lock. The splice range stays valid across the unlock: only the drain advances
    /// `fifoHead` (not running yet) and producers only append past the snapshot — appended
    /// chunks stay chronologically AFTER the transformed block. Sniffed control messages ride
    /// the single replacement chunk in order (same coalescing `takeMergedFrame` performs).
    /// The queue-gate accounting is rebalanced by the size delta so the books still sum to zero
    /// after the backlog ships (a leaked positive residue would wedge the read loop paused).
    private func compactDetachedBacklogForColdClient() {
        guard let transform = coldBacklogTransform else { return }
        fifoLock.lock()
        var chunkEnd = fifoHead
        var raw = Data()
        var control: [WireMessage] = []
        while chunkEnd < outFIFO.count, case let .chunk(bytes, chunkControl) = outFIFO[chunkEnd] {
            raw.append(bytes)
            control.append(contentsOf: chunkControl)
            chunkEnd += 1
        }
        let spliceRange = fifoHead..<chunkEnd
        fifoLock.unlock()
        guard !raw.isEmpty else { return }
        let cleaned = transform(raw)
        var replacement: [OutputItem] = []
        // An all-churn backlog can clean to zero bytes; the sniffed control must still ship.
        if !cleaned.isEmpty || !control.isEmpty {
            replacement.append(.chunk(bytes: cleaned, control: control))
        }
        fifoLock.lock()
        outFIFO.replaceSubrange(spliceRange, with: replacement)
        fifoLock.unlock()
        let delta = raw.count - cleaned.count
        if delta > 0 {
            outputGate?.dequeue(delta)
        } else if delta < 0 {
            outputGate?.enqueue(-delta)
        }
    }

    /// EOF latch: set true by ``PTYReadLoop``'s `onEOF` once the read loop has drained the
    /// master to EOF — which, per the read-loop contract, happens only AFTER every buffered output chunk
    /// has been yielded into the FIFO. The exit task awaits this before yielding `.exit`, so the
    /// reaper-driven exit can never overtake the final output tail on the shared FIFO (which would
    /// truncate the client's last screen). Guarded by `eofLock`.
    private let eofLock = NSLock()
    private var eofReached = false

    /// Set true once the drain has actually SENT the `.exit(code:)` frame on the DATA channel.
    /// The exit task awaits this between yielding `.exit` and calling `onExit` (which triggers teardown),
    /// so `shutdown()` can never cancel the drain before the buffered exit code reaches the wire. Guarded
    /// by `exitSentLock`.
    private let exitSentLock = NSLock()
    private var exitSent = false

    /// Bounded-queue backpressure GATE: fuses the ``BoundedQueuePolicy`` accounting with the
    /// read-loop pause/resume action ATOMICALLY under one lock (see ``PausableQueueGate``).
    /// Built in ``startRelay()`` once the `readLoop` exists (so the gate can drive it). `nil` until then.
    private var outputGate: PausableQueueGate?

    // MARK: - The resolved grid (a min-fold over contributors, applied by ONE writer)

    /// One subscriber's standing offer to the PTY-size fold (docs/45 §8.3).
    ///
    /// The offer is `nil` until that subscriber sends its first wire-11 `resize` — a channel that
    /// has opened but not yet said how big it is votes for nothing rather than for 0×0.
    struct ResizeContribution {
        /// tmux's `ignore-size`: present in the set, folded into nothing while anybody who VOTES
        /// holds the pane. **iOS is size-passive**, so a phone in a pocket can never crush a Studio's
        /// nvim to its own width.
        var sizePassive: Bool
        var offer: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?
    }

    /// One contributor as the workspace roster publishes it — who, whether they vote, and what they
    /// offered (0×0 for a subscriber that holds the pane but has not said how big it is).
    struct ResizeAttachment {
        var subscriber: MuxSubscriberID
        var contributes: Bool
        var cols: UInt16
        var rows: UInt16
    }

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
    /// Every subscriber's standing offer. The fold's input, and the ONLY input: presence is
    /// 100 ms-throttled, per-connection, newest-clock-wins NETWORK state, and folding it would let a
    /// WireGuard flap reflow a terminal.
    private var resizeContributions: [MuxSubscriberID: ResizeContribution] = [:]
    /// The grid the fold last resolved — published to the workspace roster so a client can render
    /// "120×40 · sized by MacBook Pro" instead of guessing. **Never** consulted to decide whether an
    /// apply is needed; see ``applyResolvedGrid(ifGeneration:)``.
    private var resolvedGrid: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?
    /// The ctl socket's `resize` verb. An orchestrator saying "make this pane 132×50" is an
    /// OVERRIDE, not a vote — and it stands until the NEXT CLIENT OFFER, which is what the ctl verb
    /// has always done.
    ///
    /// Superseded by a contributing subscriber's `.resize` (``scheduleResize(from:cols:rows:px:py:)``)
    /// and by nothing else. Retiring it on the next APPLY instead would make the verb inert: every
    /// `.ack` flushes the fold, the SIGWINCH the override itself delivers makes the shell repaint,
    /// and the repaint's ack lands within tens of milliseconds — so the orchestrator's size would be
    /// undone by the output it caused.
    private var ctlGridOverride: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?
    /// The in-flight debounce task (cancel-replace, à la `WorkspaceStore.scheduleSave`).
    private var resizeDebounceTask: Task<Void, Never>?
    /// The in-flight contributor-set settle task, and whether one is outstanding. While it is, an
    /// ordinary offer joins the fold WITHOUT arming the 16 ms debounce — arming it there is exactly
    /// what would make a burst of joins resolve N times instead of once.
    private var sizeSettleTask: Task<Void, Never>?
    private var sizeSettlePending = false
    /// Generation guard: every scheduled apply bumps it; a task PAST its sleep re-checks it and
    /// bails if a newer one superseded it. `Task.cancel()` cannot interrupt a task already past
    /// its `sleep`, so the generation — not cancellation alone — is what makes the LATEST size win.
    private var resizeGeneration: UInt64 = 0
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
    /// invoked OUTSIDE `agentDetectLock` to avoid holding the detector lock across the server's
    /// observer fan-out. Deduping consecutive identical states is the server's responsibility.
    var onAgentStatusChanged: (@Sendable (ClaudeStatus) -> Void)?

    /// Invokes ``onAgentStatusChanged`` (if set) with `status`. Called from the detector-folding
    /// sites AFTER `agentDetectLock` is released, only on a real status transition.
    private func notifyAgentStatusChanged(_ status: ClaudeStatus) {
        // A finished turn is a TRANSITION, counted here — at the ONE place every detector fold
        // funnels a real transition through — which is why the count cannot be double-bumped by two
        // feeds observing the same edge.
        completionLock.lock()
        let previous = _lastCompletionStatus
        _lastCompletionStatus = status
        if Self.isCompletionTransition(previous: previous, next: status) { _completionEpoch &+= 1 }
        completionLock.unlock()
        onAgentStatusChanged?(status)
    }

    /// Whether `previous → next` is one finished turn (herdr `is_background_completion_transition`).
    ///
    /// `.done` is the AUTHORITATIVE finish and only a `Stop` hook (or a ctl self-report) ever
    /// produces it. Hooks are opt-in and off by default, and the screen-manifest engine — the
    /// fallback that actually runs on most panes — has no `done` verdict at all: its states are
    /// `unknown`/`working`/`blocked`/`idle`. Counting only `.done` therefore meant that on a
    /// hook-free host a turn ending was indistinguishable from a turn never having happened, and the
    /// finished-turn marker could not exist. The pane simply went grey.
    ///
    /// herdr never had that gap because it never had a `done` STATE: it derives `Done` as
    /// `Idle && !seen` and mints the unread bit on `Working|Blocked → Idle`. Ported exactly, with
    /// `.done` kept as an additional mint so a hook-driven host still counts the finish at the edge
    /// the hook announces it (`.done → .idle`, the decay, is then the same turn ending twice and
    /// mints nothing).
    ///
    /// `.none → .idle` is the presence FLOOR lifting — an agent appearing, not a turn ending — and
    /// is deliberately not a completion. (herdr's second clause, `Unknown → Idle` guarded by an
    /// unchanged agent label, has no equivalent here: this codebase's `.none` means "no agent
    /// detected", so honouring it would mint a finish every time an agent was first seen.)
    static func isCompletionTransition(previous: ClaudeStatus, next: ClaudeStatus) -> Bool {
        if next == .done { return previous != .done }
        guard next == .idle else { return false }
        return previous == .working || previous == .needsPermission
    }

    private enum OutputItem {
        case chunk(bytes: Data, control: [WireMessage])
        case exit(code: Int32)
    }

    // MARK: - Serial PTY-input writer (ONE queue for every write path)

    /// The ONE serial queue every PTY input write lands on — client `input` frames (live relay AND
    /// the rebound relay after a reattach) and the agent-control `write`/`send-keys` raw injection.
    /// A dedicated serial queue (mirroring PTYReadLoop's dedicated read thread) because the master
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
        shimDir: URL? = nil,
        agentDetectEnabled: Bool = false,
        agentPollInterval: Duration = .seconds(1),
        agentHookListenerActive: @escaping @Sendable () -> Bool = { false },
        blocksEnabled: Bool = true,
        scrollbackJournal: ScrollbackJournal? = nil,
        restoredScrollback: Data? = nil,
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
        self.sessionID = sessionID
        self.resizeDebounce = resizeDebounce
        self.sizeSettle = sizeSettle
        openedSizePassive = isSizePassive
        self.replay = replay
        self.snapshotReplay = snapshotReplay
        coldBacklogTransform = replay.scrollbackDistiller
        self.shimDir = shimDir
        self.agentDetectEnabled = agentDetectEnabled
        agentScreenDetectEnabled = agentDetectEnabled
        self.agentPollInterval = agentPollInterval
        self.agentHookListenerActive = agentHookListenerActive
        self.blocksEnabled = blocksEnabled
        self.scrollbackJournal = scrollbackJournal
        self.restoredScrollback = restoredScrollback
        inputQueue = DispatchQueue(label: "slopdesk.host.pty-input.\(channelID)", qos: .userInitiated)
        // Instantiate the per-channel Blocks tracker only when enabled — otherwise the byte
        // pipeline + sniffer stay byte-identical (no segmenter touches the stream, no emit).
        // The tracker's segmenter carries the resolved auto-progress prefix list (from
        // `SLOPDESK_AUTO_PROGRESS_COMMANDS`, default the built-in slow-command list) so a matched
        // slow command auto-drives a synthetic OSC-9;4 spinner alongside the type-28 block metadata.
        blockTracker = blocksEnabled
            ? CommandBlockTracker(autoProgressPrefixes: HostEnvironment.autoProgressPrefixes())
            : nil
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
                while let frame = self?.takeMergedFrame() {
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
                        // which is what `subscriberLagBytes` eviction exists to bound.
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
    /// PTYReadLoop's dedicated read thread): the PTY master fd is deliberately blocking, so on the
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
        let isIncumbent = subscribers[sub.id] === sub
        if isIncumbent { subscribers.removeValue(forKey: sub.id) }
        let emptied = subscribers.isEmpty
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

    func startRelay() {
        taskLock.lock()
        guard !started else { taskLock.unlock()
            return
        }
        started = true
        taskLock.unlock()

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

        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { [weak self] chunk in self?.ingestPTYChunk(chunk) },
            onEOF: { [weak self] in self?.signalEOFReached() },
        )
        self.readLoop = readLoop
        // Build the bounded-queue gate now that the read loop exists, so pause/resume is
        // applied ATOMICALLY with the accounting (no lost-wakeup freeze).
        outputGate = PausableQueueGate(capacity: MuxFlowControl.hostQueueCapacityBytes) { paused in
            readLoop.setPaused(paused)
        }
        // Fresh-spawn history restore MUST land between the gate build (so its bytes are
        // accounted) and the read-loop start (so it precedes every live shell byte).
        enqueueRestoredScrollback()
        // Seed the journal's size sidecar with the spawn-time winsize: a pane whose client
        // never sends a `.resize` (headless CLI, scripts) still restores via snapshot in the
        // next daemon life. Overwriting the PRIOR life's sidecar is safe — the restore read
        // it back in `spawnFreshShell`, before this session existed.
        if let size = pty.currentWindowSize() {
            scrollbackJournal?.recordWindowSize(rows: Int(size.rows), cols: Int(size.cols))
        }
        readLoop.start()

        startInputRelay(for: sub)
        startControlRelay(for: sub)

        let id = channelID
        exitTask = Task { [weak self] in
            let code = await pty.waitForExit()
            // Gate the exit yield on the read loop having drained the master to EOF, so the
            // FINAL output tail is enqueued AHEAD of `.exit` on the shared FIFO. `onEOF` is called by
            // PTYReadLoop only AFTER it has yielded every buffered chunk, so awaiting the EOF latch here
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
        // the PTY's foreground basename and folds it through the pure ``ForegroundProcessDetector``,
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
        jobProbeCachedAgent = ForegroundJobProbe.job(masterFD: masterFD)
            .flatMap { AgentJobIdentifier.identify(job: $0)?.agent }
        return jobProbeCachedAgent
    }

    /// Folds one published screen detection through the detector and enqueues the resulting
    /// type-27 (the detector dedupes). Split so tests drive the pure fold with an injected clock.
    private func foldScreenDetection(_ detection: AgentScreenDetection, at now: TimeInterval) {
        agentDetectLock.lock()
        let emission = agentDetector.screenDetection(detection, at: now)
        let newStatus = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        publishAgentEmission(emission)
        if let newStatus { notifyAgentStatusChanged(newStatus) }
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
    /// one machine under `agentDetectLock` (the hook socket-accept thread also folds into it).
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
        agentDetectLock.lock()
        // Tick FIRST so the decay is evaluated at this `now`, then the presence sample; both emit
        // type-27 only on a real triple change (the detector dedupes), so at most one status frame ships.
        let tickEmission = agentDetector.tick(at: now)
        let sampleEmission = agentDetector.sample(name: name, at: now)
        // A status transition (from EITHER fold) → notify the cross-pane supervision observer.
        // Both folds share the one machine, so the final `status` is the post-fold value.
        let statusChanged = (tickEmission.status != nil || sampleEmission.status != nil)
        let newStatus = statusChanged ? agentDetector.status : nil
        agentDetectLock.unlock()
        publishAgentEmission(tickEmission)
        publishAgentEmission(sampleEmission)
        if let newStatus { notifyAgentStatusChanged(newStatus) }
    }

    /// Ships one detector emission: enqueues its control messages and, when it carries a TITLE
    /// RETIREMENT, drops the pane's cached title and asks the read loop to forget its coalescing
    /// anchor. Every fold site goes through here so the retirement can never ship down one path and
    /// be missed on another.
    private func publishAgentEmission(_ emission: ClaudePaneDetector.Emission) {
        guard !emission.isEmpty else { return }
        if emission.title != nil {
            titleLock.lock()
            _currentTitle = ""
            // No title, no stamp: an ownership retirement must not leave a freshness verdict behind
            // for a title that no longer exists.
            _currentTitleAt = nil
            pendingTitleCoalescingReset = true
            titleLock.unlock()
        }
        broadcastControl(emission.messages)
    }

    /// Folds one sniffed OSC 0/2 title through the detector and enqueues the resulting type-27
    /// (the detector dedupes — an unchanged status triple emits nothing). The title is Claude
    /// Code's own busy/rest telltale; the machine's conservative precedence decides what (if
    /// anything) it changes. Split from the sniffer loop so tests drive the pure fold with an
    /// injected clock.
    private func foldTitleSample(title: String, at now: TimeInterval) {
        agentDetectLock.lock()
        let emission = agentDetector.title(title, at: now)
        let newStatus = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        publishAgentEmission(emission)
        if let newStatus { notifyAgentStatusChanged(newStatus) }
    }

    /// Folds one client→PTY input chunk through the detector — the Esc-cancel unblock edge (a
    /// keystroke into a blocked pane demotes `.needsPermission` to `.idle`; every other state, and
    /// every automatic terminal reply, is a no-op inside the detector). Called after each relayed
    /// `input` frame AND after each agent-control raw injection (the cockpit's routed answer).
    /// Cheap on the steady path: the detector bails on the status check before touching the bytes.
    private func foldUserInput(_ bytes: Data) {
        guard agentDetectEnabled else { return }
        agentDetectLock.lock()
        let emission = agentDetector.userInput(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
        let newStatus = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        publishAgentEmission(emission)
        if let newStatus { notifyAgentStatusChanged(newStatus) }
    }

    /// Probes the PTY master's termios `ECHO` flag via the thin ``PTYEchoProbe`` shim,
    /// folds it through the pure ``EchoModeDetector``, and enqueues a type-31 ``WireMessage/inputEcho``
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
        echoDetectLock.lock()
        // Until a confirmed echo-ON sample has been seen on THIS connection, suppress a no-echo
        // reading entirely (don't fold, don't emit) — a transient startup no-echo (termios not yet
        // settled to echo-on) must not latch the client's Secure-Input pill. The first echo-on sample
        // warms the path up; thereafter a genuine echo→no-echo edge folds normally. (Reattach has its
        // own un-gated re-assert path.)
        if !echoWarmedUp {
            guard echoOn else {
                echoDetectLock.unlock()
                return
            }
            echoWarmedUp = true
        }
        let message = echoDetector.sample(echoOn: echoOn)
        echoDetectLock.unlock()
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
        echoDetectLock.lock()
        echoDetector = EchoModeDetector(initialEcho: true)
        let message = echoDetector.sample(echoOn: echoOn)
        echoDetectLock.unlock()
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
    private func reestablishActivityOnReattach(
        to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
    ) {
        var messages: [WireMessage] = []
        if let running = sniffer.commandStatusForReattach() { messages.append(running) }
        progressLock.lock()
        let progress = lastProgress
        progressLock.unlock()
        if let progress { messages.append(progress) }
        agentDetectLock.lock()
        let agentEmission = agentDetector.reestablishOnReattach()
        agentDetectLock.unlock()
        messages.append(contentsOf: agentEmission.messages)
        // Host-authoritative cwd + By-Project key (type 33/34): re-tell the latched truths so the
        // returning client's sidebar sections and cwd mirror are correct IMMEDIATELY — no client-side
        // RPC pull, no cwd-fallback→toplevel re-bucketing flash. `nil` (never observed) contributes
        // nothing, keeping the ordinary idle reconnect chatter-free.
        projectKeyLock.lock()
        let cwdTruth = lastCwdTruth
        let key = lastProjectKey
        projectKeyLock.unlock()
        if let cwdTruth { messages.append(.cwd(cwdTruth)) }
        if let key { messages.append(.projectKey(key)) }
        // Host-authoritative window TITLE (type 21): the pane's CURRENT title, re-told so a
        // returning client's row keeps `main.go - NVIM` instead of falling back to the raw command
        // line (`vi .`) for the rest of the session. Every other activity truth here was already
        // re-asserted; this one's absence WAS the bug.
        //
        // ORDERING IS LOAD-BEARING: `commandStatusForReattach()` is appended at the TOP of this
        // function, so the title lands AFTER it in the same batch and the client's freshness
        // comparison (title stamp vs command-start stamp) passes. Pinned by
        // `testTitleIsEnqueuedAfterCommandStatus`. Dies with the stamp comparison itself when
        // `pane/titleFresh` ships the host's verdict (docs/45 §4.4).
        //
        // Empty is skipped, not sent: `publishAgentEmission` clears `_currentTitle` to "" as the
        // ownership-RETIREMENT signal (:1027), so an empty here means "the agent handed the title
        // back" — re-asserting it would resurrect a dead agent's title on every reconnect.
        titleLock.lock()
        let title = _currentTitle
        titleLock.unlock()
        if !title.isEmpty { messages.append(.title(title)) }
        if !messages.isEmpty { sendControl(messages, to: id) }
    }

    // MARK: - Detach / reattach (tmux-style survival)

    /// Non-destructively detaches the relay from its current client connection.
    ///
    /// **The read loop is NOT stopped.** `PTYReadLoop.stop()` sets a PERMANENT `stopped`
    /// flag (irreversible) and would prevent rebinding. Instead, `setClientOnline(false)`
    /// engages the ReplayBuffer's 64 MiB offline gate which causes `PausableQueueGate` to
    /// pause the read loop via its replay-pause source. The shell stays alive; the loop
    /// parks on the `NSCondition` gate consuming zero syscalls.
    ///
    /// **onExit is rewired before detach completes** so a shell that exits WHILE IN THE
    /// STORE fires `onDetachedExit` (provided by the caller) rather than a handler the
    /// HostServer may have installed for a since-gone connection. Pass a closure that calls
    /// `store.remove(sessionID)` + `session.shutdownDetached()`.
    func detach(onDetachedExit: @escaping @Sendable (UUID) -> Void) {
        taskLock.lock()
        let alreadyDetached = isDetached
        isDetached = true
        // Rewire onExit: if the child exits while we are in the store, fire the detached-exit
        // handler instead of whatever the previous connection wired.
        let id = sessionID
        onExit = { _ in onDetachedExit(id) }
        // Idempotence: a second detach on an already-detached session — the failed-rebind re-park
        // racing handleLinkDown's own detach — must be a no-op past the exit-handler refresh above.
        // The relay tasks/continuations are already torn down, the offline gate engaged, and the
        // queue bound already re-sized; re-running the teardown would only churn state another
        // thread may be inspecting.
        if alreadyDetached {
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
        taskLock.unlock()
        // Engage the offline gate so the PTY drain pauses: the read loop parks on its
        // NSCondition and the kernel PTY buffer backpressures the shell.
        recomputeClientOnline()
        // Re-size the queue bound for detached life. The set is empty here, so this resolves to the
        // "output while away" budget (``MuxFlowControl/detachedHostQueueCapacityBytes``, default
        // 64 MiB) rather than the 64 KiB latency bound; a join restores the attached sizing. Routed
        // through the population helper so the capacity is a function of who is listening, not of
        // which lifecycle method last ran.
        applyQueueCapacityForPopulation()
        // With the client gone this is the one moment a multi-second render is FREE — fold the
        // ring now so the eventual reattach compose is O(canonical + delta), not O(raw churn).
        scheduleDetachedRingFold()
    }

    /// Rebinds the relay to a fresh pair of sub-channels from a returning client.
    ///
    /// **Keeps the out-FIFO, clears only control-out.** FIFO chunks are never in
    /// the ReplayBuffer (seq assignment happens at drain time, AFTER the pop), so the FIFO holds
    /// exactly the output produced WHILE DETACHED — the restarted drain ships it after the
    /// caller's `replayTail` (fresh seqs above every replayed seq → byte order preserved) and
    /// dequeues its ``PausableQueueGate`` accounting as it sends, un-pausing a read loop the
    /// detached backlog parked. Control-out IS cleared: control is stateless/re-derived (the
    /// echo truth and block metadata are re-asserted below).
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
    ///   - transformDetachedBacklog: `true` for a COLD client (`channelOpen.lastReceivedSeq == 0`
    ///     — a fresh surface that has rendered nothing). The detached-window backlog in the
    ///     out-FIFO is then replay-transformed before the drain restarts (see
    ///     ``compactDetachedBacklogForColdClient()``); a WARM client keeps the raw backlog —
    ///     its live grid needs byte-exact continuation.
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
        transformDetachedBacklog: Bool = false,
    ) -> Bool {
        // Lock order `fanoutLock` → `taskLock`, matching ``admitJoiner`` — the only two places that
        // hold both. Taken across the guards as well as the clear below, so the decision "this
        // session is detached, so its set is empty" cannot be invalidated by a concurrent join
        // between reading it and acting on it.
        fanoutLock.lock()
        taskLock.lock()
        guard isDetached else { taskLock.unlock()
            fanoutLock.unlock()
            return false
        }
        // Refuse DEAD sub-channels: `MuxNWConnection.finishLink` finishes every sub-channel BEFORE
        // firing `linkDownHandler`, so already-finished targets mean the NEW connection died while
        // the reattach was still replaying — and `handleLinkDown` has re-parked (or is about to
        // re-park) this session in the DetachedSessionStore. Rebinding would flip
        // `isDetached = false` onto channels every send throws on, leaving a stored session that
        // reads as "attached" — the next claim then fails its rebind and the session is orphaned
        // (live agent unreachable by every map, store, TTL, and stop()). Refusing keeps the session
        // detached and claimable; the caller re-parks/reaps via its failed-rebind path.
        guard !newData.isFinished, !newControl.isFinished else { taskLock.unlock()
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
        subscribersLock.unlock()
        isDetached = false

        // CRITICAL — assign onExit FIRST, while taskLock is still held and BEFORE exitTask is
        // (re)started below. This atomically replaces the detached-exit handler that detach()
        // installed (which calls store.remove + shutdownDetached) with the new reattach handler
        // (which calls removeMuxSession → the new connection's teardown). Without this, a shell
        // that exits between rebindRelay returning and the caller's post-call `session.onExit =`
        // assignment could fire the stale detached-exit handler and kill the just-reattached PTY.
        onExit = newOnExit

        // ONLY the control-out queue is dropped — the out-FIFO is KEPT (see the doc comment).
        // Clearing the FIFO here would drop the detached-window bytes permanently (`replayTail`
        // cannot replay them — they were never sequenced → silent transcript gap) AND leak their
        // PausableQueueGate accounting (no matching dequeue → a ≥64 KiB detached burst would leave
        // the read loop paused FOREVER — a frozen pane). The queue goes with the retired member,
        // which is the REPLACE-path-only semantics this wipe always had: control is
        // stateless/re-derived (the echo truth and block metadata are re-asserted below), and the
        // joining member starts with an empty one.

        // Restore the ATTACHED queue sizing (detach() raised it to the detached budget — the set
        // now has a member again, so the population helper resolves to the latency bound). With a
        // >64 KiB detached backlog outstanding this immediately re-pauses the read loop; the
        // restarted drain ships the backlog, dequeues its accounting, and resumes it — the exact
        // rebalance the note above describes.
        applyQueueCapacityForPopulation()

        // COLD client: the detached-window backlog is history to a terminal that has rendered
        // nothing — run the replay transform over it BEFORE the drain restarts (the drain would
        // otherwise ship up to the detached budget of raw live-TUI churn, seconds of stale
        // Claude Code repaint frames rendering wrong at the new geometry). Placed after the
        // capacity restore so the gate rebalance below acts on the attached sizing.
        if transformDetachedBacklog { compactDetachedBacklogForColdClient() }

        // Build the joining member's control sender FIRST — BEFORE the output drain below exists.
        // The restarted drain pops the detached backlog and hands its sniffed control to
        // `broadcastControl`, which reads each member's wake; were the output drain built + kicked
        // first, it could run in the window before this member has one and strand a detached-window
        // control message (e.g. an OSC-0/2 title change) in its queue with no wake.
        // `reestablishActivityOnReattach(to:)` re-asserts `.title`, so a stranded one is no longer
        // unrecoverable — but it would still arrive a beat late and out of order with the batch, so
        // the ordering below stands. Starting the control sender this early is safe in the other
        // direction: it simply parks on its fresh wake stream until the first enqueue.
        startControlSender(for: sub)

        // Rebuild the output wake stream and restart the session's output drain (AFTER the control
        // sender above — its sniffed-control hand-off needs the member's wake already installed).
        startOutputDrain()

        // Kick the restarted drain ONCE if detached-window chunks are already waiting: their
        // producer-side wakes landed on the FINISHED old continuation (detach() nil'd it), and a
        // shell that has gone idle since produces no future chunk to re-wake the drain — without
        // this the retained backlog (and its gate accounting) would sit undelivered until the next
        // PTY read. bufferingNewest(1) holds the yield until the drain task starts its for-await.
        fifoLock.lock()
        let hasDetachedBacklog = fifoHead < outFIFO.count // deque-aware "not empty"
        let backlogWake = outputWakeContinuation
        fifoLock.unlock()
        if hasDetachedBacklog { backlogWake?.yield(()) }
        // Race seam: fired at the EARLIEST instant the restarted output drain can be running —
        // it has been created and its backlog kick delivered. The drain's
        // first act on a detached backlog is takeMergedFrame → broadcastControl(sniffed control),
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

    /// Builds the RENDERED-snapshot replay: ring + un-acked tail + the detached-window
    /// out-FIFO backlog fed through the screen model at the live PTY size, rendered once, and
    /// re-chunked across the replay seqs. On success the FIFO backlog is CONSUMED (spliced
    /// out with its sniffed control preserved and its queue-gate accounting released) — its
    /// bytes are inside the snapshot, so the restarted drain must not ship them again.
    ///
    /// Returns `nil` (compose nothing, caller falls back) when:
    /// - there are no replay seqs to carry the stream (nothing retained above
    ///   `lastReceivedSeq` — e.g. an idle warm reconnect, or a backlog-only session);
    /// - the client is WARM and the pending raw replay is under the policy threshold
    ///   (byte-exact continuation is worth more than a wipe+re-render);
    /// - the rendered bytes exceed the seq budget's frame-cap ceiling (pathological tiny-
    ///   session expansion — the raw path is cheap there anyway).
    ///
    /// `adopting: false` is the JOIN mode: read-only. Both destructive acts above belong to the
    /// caller sequence [detached → drain stopped → replay → rebind] and are justified by the drain
    /// NOT running (see ``peekDetachedBacklog()``). A join to a live session has no such window, so
    /// it neither splices the FIFO (deleting a window of the incumbent's un-shipped, pre-seq output
    /// that no replay could recover) nor adopts the history (rewriting the seqs the incumbent is
    /// mid-stream on). The read-only compose therefore ignores the FIFO backlog entirely — those
    /// bytes reach the joiner the ordinary way, on the live drain it has just joined.
    private func composeSnapshotReplay(
        after lastReceivedSeq: Int64,
        policy: SnapshotReplayPolicy,
        adopting: Bool = true,
    ) -> [WireMessage]? {
        // Cheap eligibility first — the warm-below-threshold case is EVERY ordinary
        // reconnect, and must not pay the backlog/history copies just to say "no".
        let cold = lastReceivedSeq == 0
        if !cold {
            replayLock.lock()
            let tailBytes = replay.retainedBytes
            replayLock.unlock()
            guard tailBytes + pendingDetachedBacklogBytes() >= policy.warmThresholdBytes else {
                return nil
            }
        }
        replayLock.lock()
        let source = replay.snapshotSource(after: lastReceivedSeq)
        replayLock.unlock()
        guard !source.replaySeqs.isEmpty else { return nil }
        // A JOIN never touches the FIFO — not even to READ it, because bytes it rendered into the
        // snapshot would ALSO reach the joiner when the live drain ships them.
        let backlog = adopting ? peekDetachedBacklog() : DetachedBacklogPeek.empty
        guard cold || source.replayBytes + backlog.bytes.count >= policy.warmThresholdBytes else {
            return nil
        }
        var input = source.history
        input.append(backlog.bytes)
        guard !input.isEmpty else { return nil }
        let size = pty.currentWindowSize()
        let rows = Int(size?.rows ?? 24)
        let cols = Int(size?.cols ?? 80)
        let rendered = policy.compose(input, rows, cols)
        // Credit-progress invariant: rechunk caps per-frame payloads, so the rendered bytes
        // must fit the seq budget or the LAST chunk would exceed the cap.
        guard rendered.count <= source.replaySeqs.count * MuxFlowControl.maxOutputFramePayloadBytes
        else { return nil }
        let messages = ReplayBuffer.rechunkSnapshot(rendered, across: source.replaySeqs)
        guard adopting else { return messages }
        consumeDetachedBacklog(backlog)
        // Adopt the rendered stream AS the retained history ("as if the host had emitted it
        // all along"): the consumed backlog got no seqs of its own — without this it would
        // exist only in the delivered bytes and vanish from every later cold replay — and the
        // next compose parses the small canonical history instead of re-walking the raw ring.
        replayLock.lock()
        replay.adoptSnapshotReplay(messages)
        replayLock.unlock()
        return messages
    }

    /// Below this many ring bytes a detach-time fold isn't worth a render (the next compose
    /// walks a ring this small in well under a frame's time).
    private static let ringFoldFloorBytes = 128 * 1024

    /// Detach-time ring canonicalization: render the acked ring ONCE while nobody is waiting
    /// (the client just left) and splice the rendered bytes back in as the ring's content.
    /// The next cold compose — the moment the user is staring at an empty pane — then parses
    /// O(rendered + delta) instead of the raw history (up to 64 MiB of build/test churn:
    /// seconds of stall at the measured ~20 MiB/s model walk). The splice is
    /// generation-guarded; any concurrent ring mutation drops the fold harmlessly.
    private func scheduleDetachedRingFold() {
        guard let policy = snapshotReplay else { return }
        replayLock.lock()
        let source = replay.ringFoldSource()
        replayLock.unlock()
        guard let source, source.bytes.count >= Self.ringFoldFloorBytes else { return }
        let size = pty.currentWindowSize()
        let rows = Int(size?.rows ?? 24)
        let cols = Int(size?.cols ?? 80)
        Task.detached(priority: .utility) { [weak self] in
            let rendered = policy.compose(source.bytes, rows, cols)
            // A render that GREW the ring would be pathological (the floor above makes it
            // implausible) — keeping the raw bytes is strictly better then.
            guard rendered.count < source.bytes.count else { return }
            self?.spliceFoldedRing(rendered, from: source)
        }
    }

    /// The sync half of ``scheduleDetachedRingFold()`` — NSLock is unavailable from async
    /// contexts (the `snapshotReplayTailForSend` discipline).
    private func spliceFoldedRing(_ rendered: Data, from source: ReplayBuffer.RingFoldSource) {
        replayLock.lock()
        replay.adoptFoldedRing(rendered, from: source)
        replayLock.unlock()
    }

    /// A non-destructive read of the detached-window chunk backlog (the
    /// ``compactDetachedBacklogForColdClient()`` snapshot discipline: the drain is not
    /// running, producers only append PAST the recorded range, so the range stays valid
    /// until ``consumeDetachedBacklog(_:)`` splices under the lock).
    private struct DetachedBacklogPeek {
        let bytes: Data
        let control: [WireMessage]
        let range: Range<Int>

        /// The "read nothing, consume nothing" peek a JOIN composes against.
        static let empty = Self(bytes: Data(), control: [], range: 0..<0)
    }

    /// Byte count of the detached-window chunk backlog WITHOUT copying it (the warm-threshold
    /// pre-check).
    private func pendingDetachedBacklogBytes() -> Int {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        var total = 0
        var index = fifoHead
        while index < outFIFO.count, case let .chunk(bytes, _) = outFIFO[index] {
            total += bytes.count
            index += 1
        }
        return total
    }

    private func peekDetachedBacklog() -> DetachedBacklogPeek {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        var end = fifoHead
        var raw = Data()
        var control: [WireMessage] = []
        while end < outFIFO.count, case let .chunk(bytes, chunkControl) = outFIFO[end] {
            raw.append(bytes)
            control.append(contentsOf: chunkControl)
            end += 1
        }
        return DetachedBacklogPeek(bytes: raw, control: control, range: fifoHead..<end)
    }

    /// Splices the peeked backlog out of the FIFO. Sniffed control still ships (an empty
    /// replacement chunk carries it, the compactor's all-churn idiom) and the queue-gate
    /// accounting is released for every consumed byte — a leaked positive residue would
    /// wedge the read loop paused.
    private func consumeDetachedBacklog(_ peek: DetachedBacklogPeek) {
        guard !peek.range.isEmpty else { return }
        fifoLock.lock()
        let replacement: [OutputItem] = peek.control.isEmpty
            ? []
            : [.chunk(bytes: Data(), control: peek.control)]
        outFIFO.replaceSubrange(peek.range, with: replacement)
        fifoLock.unlock()
        if !peek.bytes.isEmpty { outputGate?.dequeue(peek.bytes.count) }
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
    /// `HostServer.stop()` (daemon stopping) and `HostServer.removeMuxSession()` — itself
    /// reached only from the child's own exit, a peer `channelClose`, or a whole-link drop
    /// (peer crash / TCP reset). There is NO per-channel reconnect/resume, so none of those is
    /// keep-alive: the shell MUST die here, or the PTY + master fd leak on every disconnect.
    /// WHEN PER-CHANNEL RESUME LANDS, a resume-able disconnect must route to a NEW `detach()`
    /// that stops the read loop + closes the master WITHOUT killing the child — it must NOT
    /// come through here (this path SIGKILLs the shell).
    ///
    /// ### Why the child is killed BEFORE `closeMaster()` (the latent-hang fix)
    /// `closeMaster()` → `close(masterFD)` BLOCKS on macOS while the `PTYReadLoop` is parked
    /// inside an in-flight kernel `read()` on that same fd. `readLoop?.stop()` signals the
    /// loop's `NSCondition` gate but CANNOT interrupt a `read()` already in the kernel — that
    /// read only returns when the slave closes, i.e. when the child dies. For a self-exiting
    /// child the reader is already at EOF, but an INTERACTIVE shell (`/bin/sh` awaiting input)
    /// never exits on its own, so without killing it `close()` hangs FOREVER. So: `hangup()`
    /// (SIGHUP — "terminal closed"; an interactive zsh exits AND persists its command history
    /// to `$HISTFILE`, which it never does under SIGTERM→SIGKILL) + `terminate()` (SIGTERM,
    /// for children that catch it for graceful cleanup but treat SIGHUP as a reload) → bounded
    /// wait for the reaper → `forceTerminate()` (SIGKILL) if neither took → short re-wait.
    /// Once the child is dead the slave closes, the parked `read()` returns EOF/EIO, the loop
    /// exits, and `closeMaster()` is non-blocking.
    func shutdown() {
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
        sizeSettlePending = false
        // Nobody holds a dead pane at a size.
        resizeContributions.removeAll()
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
        // and re-wait briefly. This GUARANTEES the parked read() returns before
        // close(masterFD), so close() never hangs.
        pty.hangup()
        pty.terminate()
        // Drain the master while waiting: the read loop is already stopped, and a shell caught
        // mid-prompt-redraw blocks in tcsetattr(TCSADRAIN) until its pending output is consumed
        // — undrained, it never processes the SIGHUP (no history save) and eats the SIGKILL.
        if !pty.waitUntilExitedDrainingMaster(timeout: 0.25) {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 0.25)
        }
        // Quiesce the PTY WRITER before closing the master — the write-side sibling of the
        // read-loop discipline above. Every input write runs as a blocking `write(2)` block on the
        // serial `inputQueue`; close the gate (any block enqueued from here on is a no-op), then
        // sync-drain the queue so an in-flight write COMPLETES before `close(masterFD)` — otherwise
        // the freed fd number could be recycled by a concurrent `openpty()` and the stale write
        // would inject bytes into an unrelated pane's PTY (the write-path TOCTOU). Bounded: the
        // child is already dead (SIGHUP/SIGTERM→SIGKILL above), so a write parked on a full kernel
        // PTY buffer returns EIO once the slave side is gone — the drain cannot hang.
        inputGateLock.lock()
        inputWritesClosed = true
        inputGateLock.unlock()
        inputQueue.sync {}
        pty.closeMaster()
        // The child has exited, so its ZDOTDIR shim dir is dead — delete it so the host's temp dir
        // does not accumulate one `slopdesk-zdotdir-*` dir per opened pane forever.
        if let shimDir { try? FileManager.default.removeItem(at: shimDir) }
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
        let before = contributingCountLocked()
        if var existing = resizeContributions[subscriber] {
            existing.sizePassive = sizePassive
            resizeContributions[subscriber] = existing
        } else {
            resizeContributions[subscriber] = ResizeContribution(sizePassive: sizePassive, offer: nil)
        }
        armSizeSettleIfSetChangedLocked(from: before)
        resizeLock.unlock()
    }

    /// Drops `subscriber` from the contributing set. A pane whose set EMPTIES keeps its last size —
    /// it does not snap back to 80×24 (docs/45 §8.3 rule 4).
    func removeResizeContributor(_ subscriber: MuxSubscriberID = MuxChannelSession.primarySubscriberID) {
        resizeLock.lock()
        // Counted BEFORE the removal, not reconstructed after it: a size-PASSIVE leaver changes the
        // membership without changing the FOLD, and there is nothing to settle when the arithmetic
        // cannot have moved.
        let before = contributingCountLocked()
        guard resizeContributions.removeValue(forKey: subscriber) != nil else {
            resizeLock.unlock()
            return
        }
        armSizeSettleIfSetChangedLocked(from: before)
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
        var contribution = resizeContributions[subscriber]
            ?? ResizeContribution(sizePassive: openedSizePassive, offer: nil)
        contribution.offer = (cols, rows, px, py)
        resizeContributions[subscriber] = contribution
        // "The next client offer still wins" — and this is that offer. Only a CONTRIBUTING one: a
        // size-passive member's offer wins nothing over the fold either, so letting it retire an
        // orchestrator's override would hand a pocketed phone a vote by the back door.
        //
        // CONTRIBUTING is what ``fold(_:)`` actually credits, not the passivity flag alone. A pane no
        // voter holds is sized by its passive members, so on an iOS-only setup the phone IS the next
        // client offer — and keying this on the flag left a lone phone locked out of its own pane for
        // good after one `slopdesk-ctl resize`: no rotation, split or font change could move that
        // shell again. The offer is already stored, so `contributingCountLocked()` reads 0 exactly
        // when the fold falls through to the passive pass.
        if Self.creditsOffer(contribution, passiveDecides: contributingCountLocked() == 0) {
            ctlGridOverride = nil
        }
        // A contributor-set change is still settling: this offer simply joins the fold the settle
        // will resolve. Arming the short debounce here is precisely what would make a burst of joins
        // SIGWINCH the shell once per arrival.
        guard !sizeSettlePending else {
            resizeLock.unlock()
            return
        }
        resizeGeneration &+= 1
        let generation = resizeGeneration
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
    /// **Idempotence is a comparison against the LIVE `TIOCGWINSZ`, never against `resolvedGrid`.**
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
    ///   `resizeGeneration` — a stale already-past-sleep task must not apply an old fold. The flush
    ///   paths (ack/bye/close) pass `nil` to apply UNCONDITIONALLY (they must never strand a size).
    func applyResolvedGrid(ifGeneration generation: UInt64? = nil) {
        resizeWriteLock.lock()
        defer { resizeWriteLock.unlock() }

        resizeLock.lock()
        if let generation, resizeGeneration != generation {
            resizeLock.unlock()
            return
        }
        let resolved: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)? =
            ctlGridOverride ?? Self.fold(resizeContributions)
        guard let grid = resolved else {
            // Nobody is holding this pane at a size — it keeps the one it has.
            resizeLock.unlock()
            return
        }
        resolvedGrid = grid
        resizeLock.unlock()
        resizeApplyStallForTesting?()

        if let live = pty.currentWindowSizeWithPixels(),
           live.cols == grid.cols, live.rows == grid.rows,
           live.pxWidth == grid.px, live.pxHeight == grid.py
        {
            return // the PTY already holds exactly this grid.
        }
        pty.setWindowSize(cols: grid.cols, rows: grid.rows, pxWidth: grid.px, pxHeight: grid.py)
        // Persist the RESOLVED size next to the disk journal — not the requester's offer. A later
        // daemon life's snapshot restore parses the journaled bytes at the geometry they were
        // emitted for, and a sidecar naming a width no client ever had re-wraps every line. Inside
        // the writer section for the same reason as the ioctl: the sidecar describes the size the
        // PTY holds, so it takes its order from the same total order.
        scrollbackJournal?.recordWindowSize(rows: Int(grid.rows), cols: Int(grid.cols))
        // The resident screen grid is fixed-size — a geometry change rebuilds it from the ring
        // on the next scan (full-screen apps repaint at the new size anyway).
        markScreenModelDirty()
        scheduleRedrawNudge()
    }

    /// `min(cols)` / `min(rows)` over the contributors that are neither size-passive nor silent.
    ///
    /// Monotone, so it settles. An input-keyed "whoever typed last drives" latch has no hysteresis:
    /// two clients typing alternately would flap `TIOCSWINSZ` + `SIGWINCH` + a full TUI repaint on
    /// every exchange.
    ///
    /// **A pane no VOTER holds is sized by its size-passive members instead.** "A phone must never
    /// crush a Mac" (docs/45 §8.3 rule 3) is a statement about a Mac that is THERE: with an iOS-only
    /// setup every subscriber is passive, and folding them all away leaves the shell at the
    /// `openpty` default 80×24 for its whole life — a phone unable to size its own pane. The
    /// fallback keys on the contributing set being EMPTY, not on it having made no offer, so a Mac
    /// that has opened its channel but not yet said how big it is still shuts the phone out.
    private static func fold(
        _ contributions: [MuxSubscriberID: ResizeContribution],
    ) -> (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)? {
        let voters = contributions.filter { !$0.value.sizePassive }
        if !voters.isEmpty { return foldOffers(voters) }
        return foldOffers(contributions)
    }

    /// `min(cols)` / `min(rows)` over whichever slice of the set the fold decided votes.
    private static func foldOffers(
        _ contributions: [MuxSubscriberID: ResizeContribution],
    ) -> (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)? {
        var folded: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?
        // Deterministic order so the pixel fields (which are NOT folded — they describe one client's
        // cell metrics, and a min over them is meaningless) come from a stable contributor.
        for subscriber in contributions.keys.sorted() {
            guard let offer = contributions[subscriber]?.offer else { continue }
            guard let current = folded else {
                folded = offer
                continue
            }
            folded = (
                cols: Swift.min(current.cols, offer.cols),
                rows: Swift.min(current.rows, offer.rows),
                px: current.px,
                py: current.py,
            )
        }
        return folded
    }

    /// How many contributors currently vote. Caller holds `resizeLock`.
    private func contributingCountLocked() -> Int {
        resizeContributions.values.count { !$0.sizePassive }
    }

    /// Whether ``fold(_:)`` credits this member's offer right now — the ONE definition of
    /// "contributing", shared by the roster readout and the ctl-override retirement so the two can
    /// never drift into disagreeing about who counts.
    ///
    /// - Parameter passiveDecides: whether the contributing set is EMPTY, i.e. the fold has fallen
    ///   through to its size-passive pass.
    private static func creditsOffer(_ contribution: ResizeContribution, passiveDecides: Bool) -> Bool {
        !contribution.sizePassive || passiveDecides
    }

    /// Arms the settle when the contributing set moved BETWEEN two non-empty states — a join into a
    /// pane somebody already holds, or a leave that still leaves somebody.
    ///
    /// A set going 0→1 or 1→0 has exactly one possible fold, so there is nothing to coalesce: making
    /// the first client of a fresh pane wait 750 ms for a size it alone decides would be latency for
    /// nothing. Caller holds `resizeLock`.
    private func armSizeSettleIfSetChangedLocked(from before: Int) {
        let after = contributingCountLocked()
        guard before != after, before > 0, after > 0 else { return }
        resizeGeneration &+= 1
        let generation = resizeGeneration
        sizeSettlePending = true
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
        if resizeGeneration == generation {
            sizeSettlePending = false
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
        let resolved = resolvedGrid
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
        let passiveDecides = contributingCountLocked() == 0
        return resizeContributions.keys.sorted().compactMap { subscriber in
            guard let contribution = resizeContributions[subscriber] else { return nil }
            return ResizeAttachment(
                subscriber: subscriber,
                contributes: Self.creditsOffer(contribution, passiveDecides: passiveDecides),
                cols: contribution.offer?.cols ?? 0,
                rows: contribution.offer?.rows ?? 0,
            )
        }
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
        return sizeSettlePending
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
    /// the `onChunk` closure so the disk-journal + sniffer + FIFO path is drivable headlessly
    /// (no PTY) via ``ingestPTYChunkForTesting(_:)``.
    private func ingestPTYChunk(_ chunk: Data) {
        // Disk journal FIRST (fire-and-forget onto the journal's serial queue — no file I/O on
        // this hot thread). Only genuine PTY output lands here, so the restored preamble (which
        // enters via ``enqueueRestoredScrollback()``) is never re-journaled.
        scrollbackJournal?.append(chunk)
        // A title RETIREMENT folded on another thread since the last chunk (a detected agent
        // exited) also retires the sniffer's coalescing anchor — otherwise the NEXT agent's
        // opening title, which is very often byte-identical to the one just retired
        // (`✳ Claude Code`), would be deduped away and the pane would stay untitled.
        titleLock.lock()
        let forgetTitle = pendingTitleCoalescingReset
        pendingTitleCoalescingReset = false
        titleLock.unlock()
        if forgetTitle { sniffer.forgetTitleCoalescing() }
        // ONE fused non-destructive sniffer pass over the chunk (title/bell + OSC 133
        // command status — one pass, not two per-byte machines scanning this hot thread
        // twice). It only OBSERVES; the bytes are forwarded unchanged below. Emission
        // order is byte-faithful interleaved (consumers fold each type independently).
        let controlMsgs = sniffer.observe(chunk)
        // Agent-control: cache the latest title from any sniffed title message so
        // `list-panes` can return it without an extra sniffer pass. Runs on the PTY
        // read-loop thread (serial) — update under titleLock (read from control socket
        // handler threads). O(N) over the tiny `controlMsgs` list; happens at most once
        // per chunk (title dedup is inside HostOutputSniffer).
        for msg in controlMsgs {
            if case let .title(t) = msg {
                titleLock.lock()
                _currentTitle = t
                _currentTitleAt = Date().timeIntervalSinceReferenceDate
                titleLock.unlock()
                // Agent-detection: the title carries Claude Code's own busy/rest telltale (the
                // Braille spinner / `✳` prefix) — fold the EDGE into the ONE detector (the sniffer
                // dedupes titles, so this fires only on a real change; the fold is a lock + a pure
                // reduce, cheap enough for the read loop). Gated like every other detection input.
                if agentDetectEnabled {
                    foldTitleSample(title: t, at: ProcessInfo.processInfo.systemUptime)
                }
            }
            // Agent-control: latch the freshest `133;D;<code>` exit so `list-panes` can answer
            // `lastExitCode` even with blocks tracking off. A code-less `D` keeps the prior latch
            // (the shim always reports `$?`; a bare `D` carries no new truth to replace it with).
            if case let .commandStatus(.idle(_, durationMS)) = msg {
                // The duration is host-measured C→D wall clock and arrives on EVERY `D`, including
                // the code-less one the exit latch below deliberately ignores.
                commandExitLock.lock()
                lastDurationTruth = durationMS
                commandExitLock.unlock()
            }
            if case let .commandStatus(.idle(exitCode, _)) = msg, let exitCode {
                commandExitLock.lock()
                lastExitTruth = exitCode
                commandExitLock.unlock()
            }
        }
        // Reattach truth: latch the pane's current OSC 9;4 progress at the sniff point (NOT at the
        // control drain — sniffed control rides the out-FIFO and a detached window's messages only
        // reach the sender after the backlog ships, long after the reattach re-assert reads this).
        latchProgress(controlMsgs)
        // Host-authoritative By-Project key (type 34): scan THIS chunk's sniffed batch for a cwd
        // change (the OSC-7 sniff when present, else the prompt-edge probe — cheap, sync) and, on
        // a change, hand the resolver's blocking stat-walk to the metadataQueue; the emission
        // lands on the CONTROL sender when the resolve completes. Never a filesystem touch on
        // this read-loop thread — a cwd on a hung network mount must not freeze the pane's
        // output. `lastCwdTruth` is still latched at the sniff point, for the same reattach
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
        feedBlocks(chunk)
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
        // Type-33 is host-gated single-source (see ``deriveProjectKey(from:)``, which just consumed
        // this batch): the raw sniffed OSC-7 `.cwd` must not ALSO ride the FIFO — pre-warm-up plugin
        // noise would reach the client unfiltered, and a probe-beaten stale OSC-7 would arrive at
        // drain time AFTER (and client-side overwrite) the probed truth emitted above.
        // Type-25 is likewise hook-gated: while the pane's agent status is hook-established, the
        // agent's OWN terminal notification (OSC 9/777/99) duplicates the type-27 edge the client
        // already banners — drop it here so one blocked prompt raises ONE notification. A hook-free
        // pane keeps the OSC path (its only signal). The lock is taken only when a notification is
        // actually in the batch, so the steady chunk stream never pays it.
        let dropChildNotifications: Bool = {
            let hasNotification = controlMsgs.contains { message in
                if case .notification = message { return true }
                return false
            }
            guard hasNotification else { return false }
            agentDetectLock.lock()
            defer { agentDetectLock.unlock() }
            return agentDetector.suppressesChildNotifications
        }()
        let fifoControl = controlMsgs.filter { message in
            if case .cwd = message { return false }
            if case .notification = message, dropChildNotifications { return false }
            return true
        }
        // Append-then-yield (no lost wake): the pending bufferingNewest(1) wake always
        // observes a complete FIFO. The continuation is read under fifoLock (teardown
        // nils it); yield happens OUTSIDE the lock (it may resume the drain inline).
        fifoLock.lock()
        outFIFO.append(.chunk(bytes: chunk, control: fifoControl))
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
        outFIFO.append(.chunk(bytes: restored, control: []))
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Enqueues `.exit` on the output FIFO (the reaper path). `.exit` is a merge BARRIER in
    /// ``takeMergedFrame()`` — it never coalesces with chunks, so it stays strictly after the
    /// final output tail (the EOF-latch ordering).
    private func enqueueExit(code: Int32) {
        fifoLock.lock()
        outFIFO.append(.exit(code: code))
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
    /// machine), under `agentDetectLock` because the socket-accept thread is a different context than the
    /// watch task. Validate-then-drop: malformed bytes are silently ignored. The clock is monotonic
    /// uptime (a plain `Double`; the decision logic is in the pure detector, which takes the time).
    func ingestAgentHookRecord(_ bytes: Data) {
        agentDetectLock.lock()
        let emission = agentDetector.hook(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
        let changed = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        publishAgentEmission(emission)
        if let changed { notifyAgentStatusChanged(changed) }
    }

    /// Folds an AGENT SELF-REPORT (the `report` ctl verb) into the ONE ``ClaudePaneDetector``
    /// under `agentDetectLock`. The state string has already been validated by the caller; an
    /// unrecognised string is a no-op inside the detector (validate-then-drop). Any resulting
    /// type-27 is enqueued to the (possibly absent) client AND fans the cross-pane
    /// `agent_status_changed` observer (the supervision stream) on a real transition.
    func reportAgentStatusForControl(state: String, message: String?) {
        agentDetectLock.lock()
        let emission = agentDetector.report(
            state: state, message: message, at: ProcessInfo.processInfo.systemUptime,
        )
        let changed = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        publishAgentEmission(emission)
        if let changed { notifyAgentStatusChanged(changed) }
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
        ctlGridOverride = (cols: cols, rows: rows, px: 0, py: 0)
        // Supersede any in-flight debounce/settle: the override is being applied RIGHT NOW, and a
        // timer that fired afterwards with the older fold would undo it a frame later. The bump only
        // retires a timer that has NOT yet resolved; `resizeWriteLock` is what stops one that already
        // did from landing its ioctl after this one's.
        resizeGeneration &+= 1
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
        return Self.unwrapLogicalLines(text, lines: limit)
    }

    /// Pure logical-line split (the `read --unwrapped` verb): split `text` on hard `\n`, keep blank
    /// lines, and optionally keep only the last `limit`. Extracted as a `static` so it is
    /// unit-testable with no PTY/ReplayBuffer.
    ///
    /// Trailing-element handling: only DROP the final element when the text ended in `\n` (so the
    /// split's trailing `""` is a separator artifact, not content). When the text does NOT end in
    /// `\n`, the final element is a complete-but-unterminated logical line — which host-side is
    /// INDISTINGUISHABLE from the very signal an orchestrator scrapes (a live shell prompt or a
    /// Claude "awaiting input" line that carries no trailing newline). Dropping it unconditionally
    /// would silently swallow the freshest line, so we KEEP it. (A genuine half-written partial is
    /// rare and harmless to include; losing the prompt is the worse failure.)
    static func unwrapLogicalLines(_ text: String, lines limit: Int? = nil) -> [String] {
        guard !text.isEmpty else { return [] }
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop ONLY the empty trailing artifact of a terminating newline; keep an unterminated
        // final logical line (the prompt / awaiting-input cue).
        if text.hasSuffix("\n"), !rows.isEmpty, rows[rows.count - 1].isEmpty {
            rows.removeLast()
        }
        if let limit, limit > 0, rows.count > limit { rows = Array(rows.suffix(limit)) }
        return rows
    }

    /// The last OSC-sniffed window title for this pane (empty string if none has arrived yet).
    var currentTitle: String {
        titleLock.lock()
        defer { titleLock.unlock() }
        return _currentTitle
    }

    /// The current rolled-up Claude detection status for this pane (the supervision API).
    ///
    /// Read under `agentDetectLock` because `agentDetector` is folded from TWO contexts (the
    /// serial `agentWatchTask` foreground poll and the hook socket-accept thread); a bare read
    /// of the private detector would race. Used by ``HostServer/listPanesForControl()`` to surface
    /// per-pane agent state in the `list-panes` verb. A pane whose detector never saw `claude`
    /// returns ``ClaudeStatus/none``.
    var agentStatusForControl: ClaudeStatus {
        agentDetectLock.lock()
        defer { agentDetectLock.unlock() }
        return agentDetector.status
    }

    /// The detector's status + human label in ONE lock acquisition (the `list-panes` verb reads
    /// both; two separate reads could interleave a transition and pair a stale label with a fresh
    /// state).
    var agentStatusAndMessageForControl: (status: ClaudeStatus, message: String?) {
        agentDetectLock.lock()
        defer { agentDetectLock.unlock() }
        return (agentDetector.status, agentDetector.statusLabel)
    }

    /// The freshest host-observed cwd truth (OSC-7 sniff / prompt-edge probe), `nil` until observed.
    var cwdForControl: String? {
        projectKeyLock.lock()
        defer { projectKeyLock.unlock() }
        return lastCwdTruth
    }

    /// The freshest By-Project key (type 34's current value), `nil` until resolved.
    var projectKeyForControl: String? {
        projectKeyLock.lock()
        defer { projectKeyLock.unlock() }
        return lastProjectKey
    }

    /// The freshest OSC-133-D exit code, `nil` until the first code-carrying `D`.
    var lastExitCodeForControl: Int32? {
        commandExitLock.lock()
        defer { commandExitLock.unlock() }
        return lastExitTruth
    }

    // MARK: - Workspace-document surface (the CURRENT VALUE behind each edge)

    //
    // Every fact below is already published as an edge-triggered control message. These accessors
    // expose the value that edge left behind, so a client that was not listening at the instant of
    // the edge can still be told what is true — which is the whole point of the document.

    /// ``currentTitle`` and the `systemUptime` it was sniffed at, in ONE lock acquisition: two reads
    /// could interleave a retirement and pair a live title with a cleared stamp.
    var titleAndStampForControl: (title: String, stampedAt: TimeInterval?) {
        titleLock.lock()
        defer { titleLock.unlock() }
        return (_currentTitle, _currentTitleAt)
    }

    /// The `systemUptime` at which the CURRENT command block opened, `nil` at a prompt. The other
    /// half of the `pane/titleFresh` verdict.
    var commandStartedAtForControl: TimeInterval? {
        sniffer.commandRunningSince()
    }

    /// The host's own open command block — the pane's running command line, `nil` at a prompt or
    /// with blocks tracking off.
    ///
    /// This is the fact a client cannot reproduce: `RailRowsBuilder.liveRowTitle(runningCommand:)`
    /// reads the CLIENT's per-materialization `TerminalBlockModel`, so a client that has rendered
    /// zero bytes has no running command at all and its sidebar row falls back to the raw command
    /// line. Publishing the host's block is what lets the host alone render the row.
    var runningCommandForControl: String? {
        blocksLock.lock()
        defer { blocksLock.unlock() }
        guard let open = blockTracker?.openBlockForControl() else { return nil }
        let text = open.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The last foreground process name the watcher sampled (type 26's current value).
    var foregroundProcessForControl: String? {
        foregroundLock.lock()
        defer { foregroundLock.unlock() }
        return _lastForeground
    }

    /// The type-27 triple the status stream currently stands at, plus the agent's session intent
    /// (type 36) — read in ONE `agentDetectLock` acquisition, like ``agentStatusAndMessageForControl``.
    var agentPublishedStateForControl: (state: UInt8, kind: UInt8, label: String?, intent: String?) {
        agentDetectLock.lock()
        defer { agentDetectLock.unlock() }
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
        progressLock.lock()
        defer { progressLock.unlock() }
        return lastProgressPair
    }

    /// The host-measured duration of the last completed command, `nil` until the first `D`.
    var lastDurationMSForControl: UInt32? {
        commandExitLock.lock()
        defer { commandExitLock.unlock() }
        return lastDurationTruth
    }

    /// How many `working → done` edges this pane has produced (`pane/completionEpoch`).
    var completionEpochForControl: UInt32 {
        completionLock.lock()
        defer { completionLock.unlock() }
        return _completionEpoch
    }

    // MARK: - Agent-control block surface (the `last-output` / `run --wait` verbs)

    /// The last `limit` closed blocks with retained output, or `nil` when blocks tracking is
    /// disabled (`SLOPDESK_BLOCKS=0`) — the caller distinguishes "no blocks yet" (`[]`) from
    /// "feature off" (`nil`).
    func recentBlocksForControl(limit: Int) -> [CommandBlockTracker.ControlBlock]? {
        blocksLock.lock()
        defer { blocksLock.unlock() }
        return blockTracker?.recentBlocksForControl(limit: limit)
    }

    /// The still-RUNNING block snapshot (saw `C`, no `D`), `nil` when none / blocks disabled.
    func openBlockForControl() -> CommandBlockSegmenter.CommandBlock? {
        blocksLock.lock()
        defer { blocksLock.unlock() }
        return blockTracker?.openBlockForControl()
    }

    /// The `run --wait` baseline: the block index the next shell command will close under,
    /// `nil` when blocks tracking is disabled.
    func expectedNextBlockIndexForControl() -> UInt32? {
        blocksLock.lock()
        defer { blocksLock.unlock() }
        return blockTracker?.expectedNextCommandIndex
    }

    /// The retained output bytes for a closed block, `nil` when evicted / unknown / disabled.
    func blockOutputBytesForControl(index: UInt32) -> [UInt8]? {
        blocksLock.lock()
        defer { blocksLock.unlock() }
        return blockTracker?.outputBytes(index: index)
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

    /// Feeds one outbound chunk to the per-channel Blocks tracker (under ``blocksLock``) and
    /// enqueues any resulting type-28 `commandBlock` metadata on the CONTROL sender. A no-op when
    /// blocks are disabled (`blockTracker == nil`), so the byte pipeline stays byte-identical.
    private func feedBlocks(_ chunk: Data) {
        guard blocksEnabled else { return }
        blocksLock.lock()
        let messages = blockTracker?.ingest(chunk) ?? []
        blocksLock.unlock()
        latchProgress(messages) // auto-progress is a second type-32 source — same reattach truth
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
    /// **Sync (this method — the read-loop thread):** scan `sniffed` for the freshest cwd truth.
    /// The LAST OSC-7 `.cwd` is the shell-declared value; a shell that emits no OSC-7 (Starship /
    /// hookless) is covered by the prompt-edge probe: a `.commandStatus(.idle)` in the batch marks
    /// a prompt boundary (133;B/D) — exactly when a `cd` becomes observable — and triggers ONE
    /// `proc_pidinfo` read (a single syscall, the same class as the input path's `tcgetattr`;
    /// never a subprocess and never a `stat` on this thread). At a prompt edge the PROBE is
    /// preferred over a same-batch OSC-7 (the probe is ground truth at exactly that moment; a
    /// possibly-stale OSC-7 loses), falling back to the batch's OSC-7 when the probe fails
    /// (unspawned/gone shell). An unchanged cwd is dropped at the `lastCwdTruth` anchor, which is
    /// latched HERE (sniff time) so a reattach re-assert always sees the newest cwd.
    ///
    /// **Warm-up gate (mirrors `echoWarmedUp`):** OSC-7-only batches are IGNORED until the first
    /// command edge (`.commandStatus(.idle)` or `.running`) has been observed on this session. A
    /// plugin manager that `cd`s into its git-cloned cache dir BEFORE the first prompt emits OSC-7
    /// for a directory the user was never in — latching it would persist a bogus sidebar section
    /// client-side. The first prompt edge itself derives from the probe (ground truth); after
    /// warm-up OSC-7 changes flow normally (a mid-command `cd` in a script still re-groups, no
    /// prompt edge required).
    ///
    /// **Type-33 single-source:** an ACCEPTED change also emits `.cwd` here, synchronously — and
    /// ``ingestPTYChunk(_:)`` strips the raw sniffed OSC-7 from the FIFO ride, so the client only
    /// ever sees warm-up-gated, dedupe-anchored, probe-preferred cwd values and can apply them
    /// ungated (it needs no startup-noise gate of its own).
    ///
    /// **Async (the resolver walk — `metadataQueue`):** a CHANGED cwd hands
    /// ``ProjectKeyResolver/projectKey(forCwd:)`` — a `stat(2)`-per-ancestor filesystem walk that
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
        projectKeyLock.lock()
        if !projectKeyWarmedUp {
            guard commandEdge else {
                projectKeyLock.unlock()
                return // pre-first-prompt OSC-7 (plugin-manager cd noise): do not latch, do not emit
            }
            projectKeyWarmedUp = true
        }
        projectKeyLock.unlock()
        // At a prompt edge, ground truth (the probe) beats a possibly-stale same-batch OSC-7;
        // a probe failure falls back to the OSC-7 value. Mid-command (no edge) only OSC-7 can
        // speak — the probe is never consulted.
        let freshest = promptEdge ? (probeCwd() ?? oscCwd) : oscCwd
        guard let cwd = freshest, !cwd.isEmpty else { return }
        projectKeyLock.lock()
        guard cwd != lastCwdTruth else {
            projectKeyLock.unlock()
            return
        }
        lastCwdTruth = cwd
        projectKeyLock.unlock()
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

    /// Runs the ``ProjectKeyResolver`` toplevel walk for the CANONICALIZED `cwd`
    /// (``canonicalCwd(_:)`` — logical OSC-7 paths and physical probe paths must land on ONE key)
    /// OFF the read-loop thread — on the
    /// serial `metadataQueue` (the file's home for ALL blocking FileManager/git/lsof work; serial,
    /// so resolves stay ordered), or the injected test executor. On completion, under
    /// `projectKeyLock`, the resolve is DROPPED if a later `cd` superseded it (`cwd` is no longer
    /// `lastCwdTruth` — the newer change's own resolve is already queued behind this one), deduped
    /// against `lastProjectKey`, latched, and the type-34 enqueued directly on the CONTROL sender.
    /// It deliberately does NOT ride the out-FIFO alongside the producing bytes — FIFO ordering is
    /// not load-bearing for this latest-state truth (the client folds the newest key it sees, and
    /// the reattach re-assert reads the latches, not the stream).
    private func scheduleProjectKeyResolve(for cwd: String) {
        let resolve: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let key = ProjectKeyResolver.projectKey(forCwd: Self.canonicalCwd(cwd))
            projectKeyLock.lock()
            guard cwd == lastCwdTruth, key != lastProjectKey else {
                projectKeyLock.unlock()
                return
            }
            lastProjectKey = key
            projectKeyLock.unlock()
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
        projectKeyLock.lock()
        guard lastCwdTruth == nil else {
            projectKeyLock.unlock()
            return
        }
        lastCwdTruth = cwd
        projectKeyLock.unlock()
        broadcastControl([.cwd(cwd)])
        scheduleProjectKeyResolve(for: cwd)
    }

    /// ``HostServer``'s type-35 fan-in: enqueue a project git push on this pane's control sender iff
    /// the pane is currently sectioned under the pushed repo (a cheap latch compare — the server
    /// never reads the latch itself, so the lock discipline stays inside this file).
    func pushProjectGitStatusIfMatching(_ status: WireMessage.ProjectGitStatus) {
        projectKeyLock.lock()
        let matches = lastProjectKey == status.repoRoot
        projectKeyLock.unlock()
        guard matches else { return }
        broadcastControl([.projectGitStatus(status)])
    }

    /// `realpath(3)` of `cwd` for KEY RESOLUTION only — the type-33 cwd stays the path the shell
    /// reported. OSC-7 carries the shell's LOGICAL `$PWD` (symlink components intact) while the
    /// prompt-edge probe reports the kernel's PHYSICAL vnode path; the same directory would
    /// otherwise resolve to two DIFFERENT key strings depending on which source spoke last, and the
    /// client (which cannot stat host paths) would render one repo as two sidebar sections — or,
    /// worse, walk a symlink ANCESTOR whose target has a `.git` and mint a third. Blocking (stats
    /// every component) — callers are already off the read-loop thread, on `metadataQueue`. A
    /// failed resolution (dir vanished, erroring mount) falls back to the raw path.
    static func canonicalCwd(_ cwd: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(cwd, &buffer) != nil else { return cwd }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? cwd
    }

    /// The prompt-edge cwd read: the test seam when set, else the real ``HostMetadataProbe``
    /// `proc_pidinfo` probe (foreground pid, shell-pid fallback — the same resolution the `cwd`
    /// metadata RPC serves). On an unspawned PTY (unit tests) the pids are −1 and the probe answers
    /// `nil` before any syscall.
    private func probeCwd() -> String? {
        if let cwdProbeOverride { return cwdProbeOverride() }
        return HostMetadataProbe(masterFD: pty.masterFD, shellPID: pty.pid).paneWorkingDirectory()
    }

    /// Latches the pane's CURRENT OSC 9;4 progress truth (see `lastProgress`) from a batch of
    /// outbound control messages: a `.clear` latches `nil`, any other progress state latches its
    /// message verbatim; the last one in the batch wins (latest-state fold, same as the client's).
    private func latchProgress(_ messages: [WireMessage]) {
        for message in messages {
            guard case let .progress(state, percent) = message else { continue }
            progressLock.lock()
            lastProgress = state == ProgressState.clear.rawValue ? nil : message
            lastProgressPair = state == ProgressState.clear.rawValue ? nil : (state, percent)
            progressLock.unlock()
        }
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
        blocksLock.lock()
        let messages = blockTracker?.snapshotForResync() ?? []
        blocksLock.unlock()
        if !messages.isEmpty { sendControl(messages, to: id) }
    }

    /// Serves a `requestBlockOutput(index)` by enqueueing the block's retained output (type
    /// 29) from the ring on the CONTROL sender. Always replies (an EMPTY `blockOutput` when the
    /// block was evicted / never existed / blocks are disabled) so the client never hangs waiting.
    private func serveBlockOutput(
        index: UInt32,
        to id: MuxSubscriberID = MuxChannelSession.primarySubscriberID,
    ) {
        blocksLock.lock()
        let message = blockTracker?.serveOutput(index: index) ?? .blockOutput(index: index, output: Data())
        blocksLock.unlock()
        sendControl([message], to: id)
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
    /// In-flight work is BOUNDED per session (``maxMetadataInFlight``): past the cap the request is
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
        guard metadataInFlight < Self.maxMetadataInFlight else {
            metadataInFlightLock.unlock()
            sendControl([.metadataResponse(
                requestID: requestID, status: MetadataStatus.error.rawValue, payload: Data(),
            )], to: id)
            return
        }
        metadataInFlight += 1
        metadataInFlightLock.unlock()
        let masterFD = pty.masterFD
        let shellPID = pty.pid
        metadataQueue.async { [weak self] in
            guard let self else { return }
            defer {
                metadataInFlightLock.lock()
                metadataInFlight -= 1
                metadataInFlightLock.unlock()
            }
            // The side-effecting path verbs (openPath = 9 / revealPath = 10) actuate on the
            // HOST's own Finder / Launch Services via `HostPathActionPerformer` and reply with an
            // empty-payload status. They are handled HERE — BEFORE, and never reach, the read-only
            // `MetadataResponseBuilder` (which performs NO side effects). `response` returns nil for
            // every OTHER verb, so the read verbs fall through to the pure builder unchanged.
            if let response = HostPathActionPerformer.response(requestID: requestID, verb: verb, payload: payload) {
                sendControl([response], to: id)
                return
            }
            // The agent-hooks verbs (installAgentHooks = 11 / uninstallAgentHooks = 12 write or
            // strip our entries in ~/.claude/settings.json via `AgentInstaller`; agentHookStatus = 13 is a
            // pure read returning the 2-byte `[installed][listenerActive]` flags — the second byte is the
            // LIVE hook-listener bind state so the client can show installed-but-inactive). Handled
            // HERE — BEFORE, and never reaching, the read-only `MetadataResponseBuilder`. `response`
            // returns nil for every OTHER verb, so the read verbs fall through to the pure builder
            // unchanged.
            if let response = HostAgentActionPerformer.response(
                requestID: requestID, verb: verb, payload: payload,
                hookListenerActive: agentHookListenerActive(),
            ) {
                sendControl([response], to: id)
                return
            }
            // The clipboard-sync verbs (setClipboard = 15 writes the client's clip onto the host's
            // general pasteboard; readClipboard = 16 ships the host's clip back, with changeCount
            // dedupe + echo suppression) actuate on host-global pasteboard state via
            // `HostClipboardPerformer`. Handled HERE — BEFORE, and never reaching, the read-only
            // `MetadataResponseBuilder`. `response` returns nil for every OTHER verb.
            if let response = HostClipboardPerformer.response(
                requestID: requestID, verb: verb, payload: payload,
            ) {
                sendControl([response], to: id)
                return
            }
            let probe = HostMetadataProbe(masterFD: masterFD, shellPID: shellPID)
            let response = MetadataResponseBuilder(query: probe)
                .response(requestID: requestID, verb: verb, payload: payload)
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
        subscribers[id]?.lastAckedSeq = seq
        let floor = subscribers.values.map(\.lastAckedSeq).min() ?? seq
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
    private func signalEOFReached() { eofLock.lock()
        eofReached = true
        eofLock.unlock()
    }

    private func isEOFReached() -> Bool { eofLock.lock()
        defer { eofLock.unlock() }
        return eofReached
    }

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

    private func signalExitSent() { exitSentLock.lock()
        exitSent = true
        exitSentLock.unlock()
    }

    private func isExitSent() -> Bool { exitSentLock.lock()
        defer { exitSentLock.unlock() }
        return exitSent
    }

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
    /// - `SLOPDESK_SCROLLBACK_DISTILL` — default-ON (`env != "0"`). When ON, a ``ScrollbackDistiller``
    ///   is injected so a COLD-reattach scrollback replay collapses the transient B→C line-editor churn
    ///   (tab-completion menus, autosuggestions, per-keystroke redraws) to the committed OSC-133 command
    ///   line — the fresh terminal then re-renders a clean transcript instead of raw editing artifacts.
    ///   Set `"0"` to replay the raw scrollback bytes instead.
    /// - `SLOPDESK_SCROLLBACK_STRIP_QUERIES` — default-ON (`env != "0"`). When ON, a
    ///   ``TerminalQueryStripper`` pass removes terminal queries / echoed responses / stale color
    ///   state from the replayed history, so the client terminal never re-answers a prior life's
    ///   DA/XTVERSION/OSC-color probes into the shell's stdin (the reattach "garbage input" bug).
    /// - `SLOPDESK_SCROLLBACK_STRIP_INPUT_MODES` — default-ON (`env != "0"`). When ON, a
    ///   ``TerminalInputModeStripper`` pass removes mouse / kitty-keyboard / in-band-resize mode
    ///   changes from the replayed history (they'd transiently arm the client's input reporting
    ///   mid-replay) and re-asserts only the NET final state after the replay — a live TUI keeps
    ///   its modes, an exited one leaves nothing armed.
    /// - `SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS` — default-ON (`env != "0"`). When ON, a
    ///   ``PromptEOLMarkStripper`` pass normalizes zsh's width-dependent PROMPT_SP mark+fill
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
        // Distill + query-strip composition — shared with the disk journal's restore so both
        // replay paths stay behaviour-identical (see ``ScrollbackReplayTransform``).
        return ReplayBuffer(
            scrollbackBytes: scrollbackCap,
            // reassert: the ring replays into a cold client of a LIVE session — a TUI that is
            // still running needs its input modes re-established after the (stripped) replay.
            scrollbackDistiller: ScrollbackReplayTransform.make(environment: env, reassertInputModes: true),
        )
    }

    // MARK: - Test seams (replay-backpressure wiring)

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

    /// Drives the real ``setClientOnline(_:)`` glue (offline-gate side).
    func setClientOnlineForTesting(_ online: Bool) { setClientOnline(online) }
    /// Whether the ReplayBuffer currently regards the pane as reachable — the offline-gate truth
    /// the online recompute writes.
    var isClientOnlineForTesting: Bool {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.isClientOnline
    }

    /// The ring's current byte total — the detach-time fold's observability seam (the splice
    /// lands asynchronously; tests wait for the ring to shrink instead of sleeping).
    func scrollbackRingBytesForTesting() -> Int {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.scrollbackRingBytesForTesting
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

    /// Drain-merge seams: drive the output FIFO + ``takeMergedFrame()`` (and the control-out
    /// queue) WITHOUT a PTY or running drain, so merge/barrier/cap semantics are provable
    /// headlessly. The enqueue paths mirror the production producers exactly (append under
    /// the lock; the wake yield is a no-op pre-`startRelay` since the continuation is nil).
    /// Drives the REAL PTY chunk handler (disk-journal hook + sniffer + FIFO append) without a
    /// PTY or read loop — the production `onChunk` closure is exactly this call.
    func ingestPTYChunkForTesting(_ chunk: Data) { ingestPTYChunk(chunk) }

    /// Drives ``foldScreenDetection(_:at:)`` — the screen-rule verdict fold — with an injected
    /// clock, mirroring the production scan-task call site.
    func foldScreenDetectionForTesting(_ detection: AgentScreenDetection, at now: TimeInterval) {
        foldScreenDetection(detection, at: now)
    }

    /// Drives the REAL fresh-spawn restore enqueue (the exact call ``startRelay()`` makes)
    /// without needing a spawned PTY's master fd.
    func enqueueRestoredScrollbackForTesting() { enqueueRestoredScrollback() }

    /// Whether the fresh-spawn restore preamble is still pinned on the session. Must read
    /// `false` after ``enqueueRestoredScrollback()`` — the out-FIFO copy is the only owner
    /// from then on; a session-lifetime stored copy pinned up to the journal cap per pane.
    var hasRestoredScrollbackForTesting: Bool {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        return restoredScrollback != nil
    }

    func enqueueChunkForTesting(bytes: Data, control: [WireMessage] = []) {
        enqueueOutput(bytes.count)
        fifoLock.lock()
        outFIFO.append(.chunk(bytes: bytes, control: control))
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
        return subscribers.count
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
        let id = mintSubscriberIDLocked()
        subscribers[id] = Subscriber(id: id, data: data, control: control)
        subscribersLock.unlock()
        recomputeClientOnline()
        applyQueueCapacityForPopulation()
        return id
    }

    static var maxControlOutQueuedForTesting: Int { maxControlOutQueued }

    /// Race seam — invoked by ``rebindRelay(data:control:onExit:)`` immediately after the restarted
    /// output drain has been created and its detached-backlog kick delivered (see the call site).
    /// `nil` in production; tests use it to pin that the control wake continuation/sender are
    /// rebuilt BEFORE the output drain can run.
    var onOutputDrainRestartedForTesting: (() -> Void)?

    /// Race seam — fired inside ``joinSubscriber(id:data:control:sizePassive:)`` with
    /// the joiner already in the set and its DATA sender not yet built: the window in which fanned-out
    /// frames land in an outbox whose wake is nil.
    var onJoinerAdmittedForTesting: (@Sendable () async -> Void)?

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
    /// gate, cwd scan, probe preference, `lastCwdTruth` latch) runs inline; the resolver walk runs
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
    static var maxMetadataInFlightForTesting: Int { maxMetadataInFlight }
    var metadataInFlightForTesting: Int {
        metadataInFlightLock.lock()
        defer { metadataInFlightLock.unlock() }
        return metadataInFlight
    }

    /// Suspend/resume the serial `metadataQueue` so a flood test can hold admitted
    /// work items in-flight deterministically (never spawn/park real probe subprocesses — the
    /// flood uses an unknown verb, which the pure builder answers without a syscall). Tests MUST
    /// balance every suspend with exactly one resume before the session is released (a suspended
    /// dispatch queue traps on dealloc).
    func suspendMetadataQueueForTesting() { metadataQueue.suspend() }
    func resumeMetadataQueueForTesting() { metadataQueue.resume() }

    /// Drives the real `feedBlocks` glue (segmenter tap → broadcastControl) WITHOUT a PTY/read loop,
    /// so the type-28 emission + the byte-identical-when-off contract are provable headlessly.
    func feedBlocksForTesting(_ chunk: Data) { feedBlocks(chunk) }
    /// Drives the real `serveBlockOutput` glue (ring lookup → the requester's control queue).
    func serveBlockOutputForTesting(index: UInt32) { serveBlockOutput(index: index) }
    /// Whether the Blocks tap is active for this channel (the tracker was instantiated).
    var blocksEnabledForTesting: Bool { blocksEnabled }

    private static func writeAll(fd: Int32, data: Data) {
        #if canImport(Darwin)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    return
                } else {
                    return
                }
            }
        }
        #endif
    }
}

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
        return targets.contains { !$0.exitDelivered && !$0.retired }
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
        let alreadyRunning = sub.dataSendTask != nil || sub.retired
        // The transition from inline delivery to an outbox seeds the member's frontier at the HEAD:
        // everything through it has already reached this member — inline, for an incumbent the drain
        // was sending to directly; in the state transfer, for a joiner. A zero here would read as
        // "has shipped nothing", and every join would pause the read loop until the incumbent's
        // sender re-shipped a history it had already delivered.
        //
        // A joiner's seed also claims whatever the drain fanned into its outbox WHILE its snapshot
        // was on the wire. That optimism is bounded and self-correcting: the next capacity's worth
        // of frames re-derives the true backlog, so it costs one gate bound once, at join.
        if !alreadyRunning { sub.lastSentSeq = head }
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
        sub.exitDelivered = true
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
        if seq > sub.lastSentSeq { sub.lastSentSeq = seq }
        subscribersLock.unlock()
        updateReplayBackpressure()
    }

    /// Bytes sequenced that not even the FASTEST member has handed to the wire — the producer bound
    /// for a drain that no longer sends inline.
    ///
    /// `0` unless somebody is delivered from an OUTBOX: a pane on the inline path is already bounded
    /// by the out-FIFO's own accounting (the drain parks IN the send, so the bytes stay `outstanding`),
    /// and an EMPTY set is the detached budget's business, not this source's. That is what keeps a
    /// one-member pane and the whole detach/reattach sequence on the plain inline path.
    ///
    /// The frontier is a MAX, which is the entire difference between this and "the slowest member":
    /// one parked phone can never assert the pause while a Studio is still consuming. Its cost is
    /// bounded by ``subscriberLagBytes`` eviction instead.
    private func fanoutBacklog() -> Int {
        subscribersLock.lock()
        let frontier = subscribers.values
            .compactMap { $0.dataSendTask == nil ? nil : $0.lastSentSeq }
            .max()
        subscribersLock.unlock()
        guard let frontier else { return 0 }
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.retainedBytes(above: frontier)
    }

    /// Sizes the bounded output queue for the CURRENT population.
    ///
    /// 64 KiB attached is a LATENCY bound (head-of-line delay to a consuming client); the detached
    /// budget (default 64 MiB) is the "output while away" allowance that keeps a working agent from
    /// stalling at 64 KiB plus one kernel buffer. Which one applies is a function of the subscriber
    /// set being EMPTY — not of a detach/rebind pair — because with a fan-out one member leaving
    /// says nothing about whether anybody is still consuming.
    ///
    /// This gate is a SECOND ledger, distinct from the ReplayBuffer's: it accounts the out-FIFO
    /// (enqueued-not-yet-sent, single-consumer), while ``ReplayBuffer/retainedBytes`` accounts
    /// sent-not-yet-acked. Their thresholds mean different things and must not be conflated.
    private func applyQueueCapacityForPopulation() {
        let capacity = subscriberList().isEmpty
            ? MuxFlowControl.detachedHostQueueCapacityBytes
            : MuxFlowControl.hostQueueCapacityBytes
        outputGate?.setCapacity(capacity)
    }

    // MARK: - The subscriber set: join, leave, and the laggard

    /// How far behind the head one member may fall before it is EVICTED rather than buffered for.
    ///
    /// Default 32 MiB (`SLOPDESK_SUB_LAG_BYTES`), deliberately BELOW the ReplayBuffer's 64 MiB
    /// offline gate: with N members, evicting the laggard replaces buffering for it, and the gate's
    /// pause-the-PTY semantics stay reserved for the case where they still mean what they always
    /// meant — nobody is listening. Without this, one sleeping iPhone freezes a build for two Macs.
    /// `0` disables eviction.
    static let subscriberLagBytes: Int = {
        guard let raw = ProcessInfo.processInfo.environment["SLOPDESK_SUB_LAG_BYTES"],
              let value = Int(raw), value >= 0
        else { return 32 * 1024 * 1024 }
        return value
    }()

    /// Evicts every member whose un-acked backlog exceeds ``subscriberLagBytes``.
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
        guard Self.subscriberLagBytes > 0, let evict = onEvictSubscriber else { return }
        let subs = subscriberList()
        guard subs.count > 1 else { return }
        subscribersLock.lock()
        let cursors = subs.map { (sub: $0, acked: $0.lastAckedSeq) }
        subscribersLock.unlock()
        // The furthest-ahead member is the survivor by construction — if EVERY member is behind
        // the threshold nobody is consuming, which is the offline gate's job, not eviction's.
        guard let healthiest = cursors.map(\.acked).max() else { return }
        replayLock.lock()
        let lagging = cursors.filter {
            $0.acked != healthiest && replay.retainedBytes(above: $0.acked) > Self.subscriberLagBytes
        }
        replayLock.unlock()
        guard !lagging.isEmpty else { return }
        // Latch under the membership lock so a concurrent producer and ack path cannot both decide
        // to evict the same member.
        subscribersLock.lock()
        let doomed = lagging.filter { !$0.sub.evicting && !$0.sub.retired }.map(\.sub)
        for sub in doomed { sub.evicting = true }
        subscribersLock.unlock()
        for sub in doomed {
            onLog?("pane subscriber \(sub.id): evicted — more than \(Self.subscriberLagBytes) bytes behind")
            let id = sub.id
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
        applyQueueCapacityForPopulation()
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
        subscribersLock.lock()
        let id = reserved ?? mintSubscriberIDLocked()
        let sub = Subscriber(id: id, data: newData, control: newControl)
        // The joiner starts CURRENT: it is receiving the rendered screen, not the history behind
        // it, so its retention cursor must not hold bytes every other member has already acked.
        sub.lastAckedSeq = replayHighestSeqLocked()
        subscribers[id] = sub
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
        return mintSubscriberIDLocked()
    }

    /// Caller holds `subscribersLock`.
    private func mintSubscriberIDLocked() -> MuxSubscriberID {
        let id = nextSubscriberID
        nextSubscriberID &+= 1
        return id
    }

    /// Synchronous read of the detach latch (NSLock is unavailable from an async context).
    private func isDetachedForJoin() -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return isDetached
    }

    private func replayHighestSeqLocked() -> Int64 {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.highestSeq
    }

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
        // The queue bound follows the population: still attached → the 64 KiB latency bound;
        // emptied → the detached "output while away" budget, which is what `detach()` would set
        // anyway when the caller parks the session.
        applyQueueCapacityForPopulation()
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
        let floor = subscribers.values.map(\.lastAckedSeq).min()
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
