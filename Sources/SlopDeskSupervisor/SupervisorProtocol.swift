import Foundation

/// The `slopdesk-superd` ↔ `slopdesk-hostd` message set.
///
/// ## This is the one protocol in the repo that must tolerate version skew
/// The three wire paths (`docs/46`) are golden-pinned at version `1` with no negotiation, and they
/// can be, because both ends ship in the same release. superd cannot: it is a LaunchAgent that
/// outlives not just hostd's process but hostd's **build**. You rebuild hostd all day; superd stays
/// whatever it was at login. So (`docs/51` §3):
///
/// 1. **Append-only.** Verbs and fields are added, never repurposed or removed.
/// 2. **Both sides state a version in `hello`.** Major mismatch is refused with a diagnostic that
///    names the fix, never a silent degradation.
/// 3. **An unknown verb is answered ``Status/unsupported``, not dropped** — a newer hostd detects
///    an older superd by asking, and falls back.
/// 4. **Changing this costs a superd restart, which costs every pane.** So it stays boring. A change
///    that seems to need a new verb almost certainly belongs in hostd instead.
///
/// Verbs are `String`, and payloads are optional fields on ONE struct rather than an enum with
/// associated values, for exactly that reason: an unknown verb must still *decode* so it can be
/// answered. A Swift enum would fail the decode and leave nothing to reply to.
public enum SupervisorProtocol {
    /// Bumped only for a breaking change. A superd refuses a hostd whose major differs.
    public static let versionMajor = 1
    /// Bumped when a verb or field is added. Both sides interoperate freely across minors — that
    /// is what rules 1 and 3 above buy.
    ///
    /// `2` added the output subscription — `subscribe` / `unsubscribe` / `pause` and the binary
    /// output frame (``SupervisorFrame/tagOutput``).
    ///
    /// `3` added the child-facing listeners — `listen` and the `connection` push that hands hostd an
    /// accepted hook/ctl socket over `SCM_RIGHTS`.
    ///
    /// `4` added `owner` on `spawn` and on the pane record — which hostd a pane belongs to, opaque
    /// to superd, so a second daemon can tell a stranger's pane from its own predecessor's.
    ///
    /// `5` added the out-of-band sniff — `shellIntegration` on `spawn` asks for it, the `0x04`
    /// frame (``SupervisorFrame/tagSniff``) carries it, and `forgetTitle` retires its anchor.
    ///
    /// `6` added the command-block tap — `blocks` on `spawn` asks for it, the `0x05` frame
    /// (``SupervisorFrame/tagBlocks``) carries what changed, and `blockOutput` / `blockSnapshot` /
    /// `blockControl` read the retained ring that used to die with each hostd.
    ///
    /// `7` moved the on-disk scrollback journal to superd — `journal` on `spawn` asks for one, and
    /// `journalInfo` / `journalDelete` / `journalSweep` read, remove and bound them. The
    /// `<uuid>.scrollback.resume` sidecar went with it: `journalInfo` answers the same number from
    /// the process that numbers the stream.
    ///
    /// `8` added ``HelloReply/buildVersion`` — the crate version of the superd actually running, so
    /// hostd can tell an upgrade that reached it from one still waiting on a restart. It is a
    /// FIELD, not a verb, precisely because rule 4 applies: asking costs nothing, and the answer
    /// rides a handshake hostd already performs.
    public static let versionMinor = 8

    public enum Verb {
        public static let hello = "hello"
        public static let spawn = "spawn"
        public static let list = "list"
        public static let adopt = "adopt"
        public static let signal = "signal"
        public static let release = "release"
        public static let resize = "resize"
        /// Start receiving a pane's output, resuming from a byte offset.
        public static let subscribe = "subscribe"
        /// Stop receiving a pane's output. Does NOT end the pane and does not stop superd reading
        /// it — a pane nobody reads is a pane whose child blocks.
        public static let unsubscribe = "unsubscribe"
        /// Stop or resume superd's reads on a pane — the backpressure gate.
        public static let pause = "pause"
        /// Claim the child-facing listeners superd binds, by ``SupervisorProtocol/ListenerKind``.
        public static let listen = "listen"
        /// Retire a pane sniffer's title-coalescing anchor, when a detected agent exits.
        public static let forgetTitle = "forgetTitle"
        /// Fetch one finished command block's retained output, by index.
        public static let blockOutput = "blockOutput"
        /// Every block a pane's tap still knows — what a reattaching client is backfilled from.
        public static let blockSnapshot = "blockSnapshot"
        /// The agent-control read: recent blocks with their bytes, the running one, the baseline.
        public static let blockControl = "blockControl"
        /// Where a session's transcript is on disk, how big it is, at what geometry it was written,
        /// and how much of a LIVE pane's stream it already holds.
        public static let journalInfo = "journalInfo"
        /// Remove a session's transcript — the deliberate end of a pane.
        public static let journalDelete = "journalDelete"
        /// Bound the orphans: unlink journals past an age or a count.
        public static let journalSweep = "journalSweep"
    }

    public enum Event {
        /// A supervised child was reaped. Carries the wait status hostd would have observed.
        public static let exited = "exited"
        /// An accepted child-facing connection, riding `SCM_RIGHTS`.
        public static let connection = "connection"
    }

    /// The child-facing sockets superd binds and hostd serves.
    ///
    /// superd owns the `bind` because the address has to outlive hostd's pid — a running `claude`
    /// remembers `SLOPDESK_SOCKET_PATH` from its `execve` and can never be corrected. Everything
    /// that ARRIVES on one is hostd's, and arrives as a descriptor rather than as relayed bytes, so
    /// the hook and ctl protocols still have exactly one implementation each, here.
    public enum ListenerKind {
        /// The Claude-hook socket, advertised to children as `SLOPDESK_SOCKET_PATH`.
        public static let hook = "hook"
        /// The agent-control socket, advertised to children as `SLOPDESK_CONTROL_SOCKET`.
        public static let control = "control"
    }
}

/// `ok` / `error` / `unsupported`, plus whatever a newer superd invents.
///
/// `unsupported` is deliberately distinct from `error`: it is the answer that lets a newer hostd
/// discover an older superd's capability set at runtime instead of guessing from a version number.
///
/// ``unrecognised`` is the other direction, and it is why this decodes by hand rather than through
/// the synthesised `RawRepresentable` initialiser. A closed enum THROWS on a status string it has
/// never seen, and the throw lands in `SupervisorClient`'s read loop, which drops the undecodable
/// frame — without waking the waiter registered under its request id. The caller then sits in
/// `replyArrived.wait()` for a reply that was already delivered and discarded: a pane that never
/// opens, on the exact skew the version-in-`hello` contract exists to absorb (superd newer than
/// hostd, rule 3 of `docs/51` §3). Decoding it as "some status I do not know" costs one case and
/// turns a permanent hang into a reported failure.
public enum SupervisorStatus: String, Decodable, Sendable {
    case ok
    case error
    case unsupported
    /// A status this build has no name for. Treated as a failure, never as success.
    case unrecognised

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognised
    }
}

// MARK: - Requests (hostd → superd)

public struct SupervisorRequest: Encodable, Sendable {
    /// Correlates the reply. Monotonic per connection, never `0` (`0` marks a notification).
    public var id: UInt64
    public var verb: String
    public var hello: HelloRequest?
    public var spawn: SpawnRequest?
    public var adopt: AdoptRequest?
    public var signal: SignalRequest?
    public var release: ReleaseRequest?
    public var resize: ResizeRequest?
    public var subscribe: SubscribeRequest?
    public var unsubscribe: UnsubscribeRequest?
    public var pause: PauseRequest?
    public var listen: ListenRequest?
    public var forgetTitle: ForgetTitleRequest?
    public var blockOutput: BlockOutputRequest?
    public var blockRead: BlockReadRequest?
    public var journal: JournalRequest?

    public init(
        id: UInt64,
        verb: String,
        hello: HelloRequest? = nil,
        spawn: SpawnRequest? = nil,
        adopt: AdoptRequest? = nil,
        signal: SignalRequest? = nil,
        release: ReleaseRequest? = nil,
        resize: ResizeRequest? = nil,
        subscribe: SubscribeRequest? = nil,
        unsubscribe: UnsubscribeRequest? = nil,
        pause: PauseRequest? = nil,
        listen: ListenRequest? = nil,
        forgetTitle: ForgetTitleRequest? = nil,
        blockOutput: BlockOutputRequest? = nil,
        blockRead: BlockReadRequest? = nil,
        journal: JournalRequest? = nil,
    ) {
        self.id = id
        self.verb = verb
        self.hello = hello
        self.spawn = spawn
        self.adopt = adopt
        self.signal = signal
        self.release = release
        self.resize = resize
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
        self.pause = pause
        self.listen = listen
        self.forgetTitle = forgetTitle
        self.blockOutput = blockOutput
        self.blockRead = blockRead
        self.journal = journal
    }
}

/// Ask about, remove, or bound the transcripts in a directory.
///
/// One payload for three verbs because they differ only in which fields they read: the info and the
/// delete want a session, the sweep wants an age and a count. Every field is hostd POLICY — superd
/// owns the file and none of the decisions about it.
public struct JournalRequest: Encodable, Sendable {
    /// Where journals are filed.
    public var directory: String
    /// Which transcript, for `journalInfo` and `journalDelete`.
    public var sessionID: String
    /// For `journalSweep`: anything not written within this many seconds goes.
    public var maxAgeSeconds: UInt64
    /// For `journalSweep`: how many of the newest survive the age cut regardless.
    public var keepNewest: Int

    public init(
        directory: String,
        sessionID: String = "",
        maxAgeSeconds: UInt64 = 0,
        keepNewest: Int = 0,
    ) {
        self.directory = directory
        self.sessionID = sessionID
        self.maxAgeSeconds = maxAgeSeconds
        self.keepNewest = keepNewest
    }
}

/// Fetch one finished block's retained output.
///
/// Answered from superd's ring rather than hostd's, because hostd's did not survive its own
/// restart: a client that clicked a block from before a rebuild got an empty body for output superd
/// had never stopped holding.
public struct BlockOutputRequest: Encodable, Sendable {
    public var paneID: String
    /// Which block. An evicted or unknown index answers with no output rather than an error — a
    /// block that aged out of the ring is an ordinary outcome, not a fault.
    public var index: UInt32

    public init(paneID: String, index: UInt32) {
        self.paneID = paneID
        self.index = index
    }
}

/// Read a pane's block tap — one payload for `blockSnapshot` and `blockControl`.
///
/// They differ only in how much they answer: the snapshot is metadata for every block, the control
/// read is the last `limit` blocks WITH their bytes. `limit` is ignored by the snapshot.
public struct BlockReadRequest: Encodable, Sendable {
    public var paneID: String
    public var limit: Int

    public init(paneID: String, limit: Int = 0) {
        self.paneID = paneID
        self.limit = limit
    }
}

/// Claim the child-facing listeners superd binds.
///
/// All-or-nothing on superd's side: an unknown or unbound kind fails the whole verb, so hostd never
/// half-succeeds into believing it serves something it does not. The most recent claim wins, which
/// is the same rule as ``AdoptRequest`` and for the same reason — the hostd that just started is the
/// one that should get the connections.
///
/// **A kind hostd does not name is a kind superd will not advertise.** That is how the default-off
/// ctl surface survived the move: rather than superd growing a copy of a hostd feature flag, hostd
/// simply does not claim ``SupervisorProtocol/ListenerKind/control``, and no child is told the
/// address.
public struct ListenRequest: Encodable, Sendable {
    /// Which listeners to serve, from ``SupervisorProtocol/ListenerKind``.
    public var kinds: [String]

    public init(kinds: [String]) {
        self.kinds = kinds
    }
}

/// Start receiving a pane's output.
///
/// The reply states where the stream actually resumes (``StreamPosition``), and the backlog follows
/// it immediately as ``SupervisorFrame/tagOutput`` frames, ahead of any live byte.
public struct SubscribeRequest: Encodable, Sendable {
    public var paneID: String
    /// The absolute offset to resume from. In practice an ADOPTING hostd asks for `0` and takes
    /// whatever superd's ring still holds: the offset belongs to a pane life, and the hostd that
    /// knew the old one is the one that just died.
    public var fromOffset: UInt64

    public init(paneID: String, fromOffset: UInt64) {
        self.paneID = paneID
        self.fromOffset = fromOffset
    }
}

/// Stop receiving a pane's output, without ending the pane.
public struct UnsubscribeRequest: Encodable, Sendable {
    public var paneID: String

    public init(paneID: String) {
        self.paneID = paneID
    }
}

/// Retire a pane sniffer's title-coalescing anchor.
///
/// superd's sniffer drops a title identical to the one it last emitted. When a detected agent
/// EXITS, that anchor has to go: the next agent's opening title is very often byte-identical to the
/// one just retired (`✳ Claude Code`), and deduping it away leaves the pane untitled.
///
/// Fire-and-forget, and deliberately so — the anchor is an optimisation, so losing the race costs a
/// stale title rather than a wrong one, and this is sent from the frame-receive thread, which
/// cannot wait for a reply only it can deliver.
public struct ForgetTitleRequest: Encodable, Sendable {
    public var paneID: String

    public init(paneID: String) {
        self.paneID = paneID
    }
}

/// The backpressure gate that used to live inside `PTYReadLoop`.
///
/// hostd asserts a pause when a channel's output queue crosses its high-water mark. superd then
/// issues no reads at all, so the kernel's PTY buffer fills and the shell blocks — which is how
/// this system has always kept its never-drop promise. Nothing is buffered on hostd's behalf and
/// nothing is discarded.
public struct PauseRequest: Encodable, Sendable {
    public var paneID: String
    public var paused: Bool

    public init(paneID: String, paused: Bool) {
        self.paneID = paneID
        self.paused = paused
    }
}

public struct HelloRequest: Encodable, Sendable {
    public var versionMajor: Int
    public var versionMinor: Int
    /// Free-form, for the log only — e.g. `slopdesk-hostd 0.3.0`.
    public var client: String

    public init(
        versionMajor: Int = SupervisorProtocol.versionMajor,
        versionMinor: Int = SupervisorProtocol.versionMinor,
        client: String,
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.client = client
    }
}

/// Fork a shell under a PTY and hand back the master.
///
/// The environment is passed WHOLE rather than curated here: `HostEnvironment.curated` is hostd's
/// job and changes often, and superd must not need a rebuild when it does. superd overlays only the
/// values that are its own to know (the stable socket paths — `docs/51` §1).
public struct SpawnRequest: Encodable, Sendable {
    /// The value baked into the child as `SLOPDESK_PANE_ID`. superd records it so a later hostd can
    /// recover it verbatim instead of re-deriving it from a new connection id (`docs/51` §5).
    public var paneID: String
    /// The client-declared session UUID, recorded so hostd can re-associate a pane with its
    /// scrollback journal after a restart. Opaque to superd.
    public var sessionID: String
    public var executable: String
    public var argv0: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: String?
    public var rows: UInt16
    public var cols: UInt16
    /// Which hostd this pane belongs to — opaque to superd, which stores it and echoes it back in
    /// `list`. `nil` leaves the field off the wire entirely.
    ///
    /// The pane id cannot answer this: after the rekey it is a bare session UUID, so every hostd's
    /// panes look alike, and `attached` goes false for the whole of an owner's restart. Two hostds
    /// on one machine (a dev daemon and the menu-bar host) is an ordinary state, and the pane in
    /// the middle of it is somebody's live `claude`.
    public var owner: String?
    /// Ask superd to install the zsh shell-integration shim for this child.
    ///
    /// A REQUEST, not a policy. hostd knows which panes are interactive user shells — a `cmd` pane
    /// is `$SHELL -c …` with no prompt cycles, and the shim is prompt machinery — while superd
    /// knows whether a shim is possible on this machine and, decisively, owns the generated
    /// directory's lifetime, which is exactly the child's. Held here it needed three cleanup sites
    /// and still leaked whenever hostd was killed.
    public var shellIntegration: Bool
    /// Ask superd to segment this pane's output into command blocks, and with what.
    ///
    /// `nil` — the operator turned blocks off with `SLOPDESK_BLOCKS=0` — means no tap at all: no
    /// segmenter touches the stream, no `0x05` frame is ever sent, and the block verbs answer "not
    /// tapped" rather than "nothing yet".
    public var blocks: BlocksRequest?
    /// Ask superd to journal this pane's output to disk, and with what cap.
    ///
    /// `nil` — a panel backend, a pane with no client-owned session id, or disk scrollback turned
    /// off — means no transcript at all. superd owns the FILE; the directory and the cap here are
    /// hostd's policy, which is why they cross the socket instead of being read from an environment
    /// superd would have to be restarted to see.
    public var journal: JournalSpawnRequest?

    public init(
        paneID: String,
        sessionID: String,
        executable: String,
        argv0: String? = nil,
        arguments: [String] = [],
        environment: [String: String],
        cwd: String? = nil,
        rows: UInt16,
        cols: UInt16,
        owner: String? = nil,
        shellIntegration: Bool = false,
        blocks: BlocksRequest? = nil,
        journal: JournalSpawnRequest? = nil,
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.executable = executable
        self.argv0 = argv0
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
        self.owner = owner
        self.shellIntegration = shellIntegration
        self.blocks = blocks
        self.journal = journal
    }
}

/// Where a pane's transcript lives and how big it may get.
public struct JournalSpawnRequest: Encodable, Sendable {
    /// The directory journals are filed in. Created if it is not there.
    public var directory: String
    /// Per-file byte cap; `0` means "do not journal this pane", so the operator's number can be
    /// passed through without an `if` at the call site.
    public var capBytes: Int

    public init(directory: String, capBytes: Int) {
        self.directory = directory
        self.capBytes = capBytes
    }
}

/// What a pane's command-block tap should be built with.
///
/// The auto-progress list crosses as the RAW env value rather than a parsed list, and that is the
/// point: `nil` means the operator never set `SLOPDESK_AUTO_PROGRESS_COMMANDS` and superd's built-in
/// slow-command list applies, `""` means they cleared it and the feature is off, and anything else
/// is theirs. Sending a parsed list would put the built-in copy back in hostd, which is the second
/// implementation this port exists to remove.
public struct BlocksRequest: Encodable, Sendable {
    /// The verbatim bridge value, absent when unset.
    public var autoProgressCommands: String?
    /// Per-block output ceiling; `0` takes superd's default (256 KiB).
    public var outputCap: Int
    /// How many finished blocks keep their output; `0` takes superd's default (64).
    public var maxBlocks: Int
    /// Total retained output ceiling; `0` takes superd's default (8 MiB).
    public var maxTotalOutputBytes: Int

    public init(
        autoProgressCommands: String? = nil,
        outputCap: Int = 0,
        maxBlocks: Int = 0,
        maxTotalOutputBytes: Int = 0,
    ) {
        self.autoProgressCommands = autoProgressCommands
        self.outputCap = outputCap
        self.maxBlocks = maxBlocks
        self.maxTotalOutputBytes = maxTotalOutputBytes
    }
}

/// Re-acquire a master fd for a pane superd already owns — the restart path.
public struct AdoptRequest: Encodable, Sendable {
    public var paneID: String
    public init(paneID: String) { self.paneID = paneID }
}

/// Signal a supervised child. hostd could `kill(2)` it directly (a non-parent may signal), but
/// routing it through superd keeps superd's view of the pane honest and lets it distinguish a
/// deliberate teardown from a crash.
public struct SignalRequest: Encodable, Sendable {
    public var paneID: String
    public var signal: Int32
    public init(paneID: String, signal: Int32) {
        self.paneID = paneID
        self.signal = signal
    }
}

/// hostd is done with this pane **for good** — not merely detaching.
///
/// This is the distinction the whole design turns on. hostd exiting must NOT release panes, or the
/// restart takes the shells with it; only an explicit close does. `kill: false` is the "the child
/// already exited, just clean up" case.
public struct ReleaseRequest: Encodable, Sendable {
    public var paneID: String
    public var kill: Bool
    public init(paneID: String, kill: Bool) {
        self.paneID = paneID
        self.kill = kill
    }
}

/// Resize a supervised pane's PTY.
///
/// hostd holds the master and could `TIOCSWINSZ` it itself — and does, for latency. This verb exists
/// so superd's record stays truthful, because that record is what a *restarted* hostd reads before
/// it has a size of its own.
public struct ResizeRequest: Encodable, Sendable {
    public var paneID: String
    public var rows: UInt16
    public var cols: UInt16

    public init(paneID: String, rows: UInt16, cols: UInt16) {
        self.paneID = paneID
        self.rows = rows
        self.cols = cols
    }
}

// MARK: - Replies (superd → hostd)

/// One type carries both replies and notifications: `id == 0` means unsolicited, and `event` says
/// which. Keeping them in one type means the read loop has exactly one decode.
public struct SupervisorReply: Decodable, Sendable {
    /// The `id` of the request being answered, or ``notificationID`` for an unsolicited event.
    public var id: UInt64
    public var status: SupervisorStatus
    /// Human-readable diagnostic. Always populated for `.error` / `.unsupported`.
    public var message: String?
    public var hello: HelloReply?
    public var pane: PaneRecord?
    public var panes: [PaneRecord]?
    /// Set only when ``id`` is ``notificationID``; one of ``SupervisorProtocol/Event``.
    public var event: String?
    public var exited: ExitedNotice?
    /// Set for `subscribe`.
    public var stream: StreamPosition?
    /// Set for the `connection` notification. The descriptor rides the frame, not the body.
    public var connection: ConnectionNotice?
    /// Set for the three block-reading verbs. Absent — rather than empty — for a pane with no tap.
    public var blocks: BlocksReply?
    /// Set for `journalInfo`. Absent when that session has no transcript on disk, which is a
    /// different answer from an empty one: only the first may fall back.
    public var journal: JournalReply?

    public static let notificationID: UInt64 = 0

    public init(
        id: UInt64,
        status: SupervisorStatus,
        message: String? = nil,
        hello: HelloReply? = nil,
        pane: PaneRecord? = nil,
        panes: [PaneRecord]? = nil,
        event: String? = nil,
        exited: ExitedNotice? = nil,
        stream: StreamPosition? = nil,
        connection: ConnectionNotice? = nil,
        blocks: BlocksReply? = nil,
        journal: JournalReply? = nil,
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.hello = hello
        self.pane = pane
        self.panes = panes
        self.event = event
        self.exited = exited
        self.stream = stream
        self.connection = connection
        self.blocks = blocks
        self.journal = journal
    }
}

/// What `journalInfo` answers with.
public struct JournalReply: Decodable, Sendable {
    /// Absolute path to the transcript. hostd opens it and hands the bytes to the screen engine —
    /// a multi-megabyte transcript crosses no socket to be rendered by a third process.
    public var path: String
    /// How many bytes are on disk, once everything buffered was flushed.
    public var bytes: UInt64
    /// The last geometry the pane applied, or `0` when the sidecar did not survive. A transcript
    /// parses faithfully only at the width it was emitted for.
    public var rows: UInt16
    /// See ``rows``.
    public var cols: UInt16
    /// How much of the LIVE pane's stream is already in the file, or `nil` when no pane is
    /// journaling there — the ordinary case for a restore, whose process is long gone.
    ///
    /// This is the number `<uuid>.scrollback.resume` used to carry, and the reason that file no
    /// longer exists: a subscribe resumes exactly here, and the process answering is the process
    /// that numbers the offsets.
    public var head: UInt64?

    public init(path: String, bytes: UInt64, rows: UInt16, cols: UInt16, head: UInt64? = nil) {
        self.path = path
        self.bytes = bytes
        self.rows = rows
        self.cols = cols
        self.head = head
    }
}

/// Which child-facing listener an `SCM_RIGHTS` descriptor was accepted on.
public struct ConnectionNotice: Decodable, Sendable {
    /// One of ``SupervisorProtocol/ListenerKind``.
    public var kind: String

    public init(kind: String) {
        self.kind = kind
    }
}

/// Where a subscription actually starts, and how far the pane has already got.
public struct StreamPosition: Decodable, Sendable {
    /// The absolute offset the backlog frames begin at. **Greater** than the requested offset when
    /// superd's ring had already evicted past it.
    public var start: UInt64
    /// The absolute offset just past the newest byte superd has read. Live frames continue here.
    public var head: UInt64
    /// Whether anything was lost between the request and ``start``. The caller is expected to act
    /// on this rather than ignore it — see ``SupervisorFrame/decodeOutput(_:)``.
    public var lossy: Bool
    /// Whether the child is already gone, so ``head`` is the last offset there will ever be.
    ///
    /// The subscriber's only way to know. An ``Event/exited`` notice would normally tell it, but a
    /// pane short-lived enough to finish before the `subscribe` arrives was announced dead before
    /// this connection was watching — so without this the backlog renders and the session then
    /// waits forever for an end that already happened.
    ///
    /// Defaulted, because a superd older than protocol 1.3 does not send it and its absence means
    /// the same thing as `false`: keep waiting for frames.
    public var ended: Bool

    public init(start: UInt64, head: UInt64, lossy: Bool, ended: Bool = false) {
        self.start = start
        self.head = head
        self.lossy = lossy
        self.ended = ended
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(UInt64.self, forKey: .start)
        head = try container.decode(UInt64.self, forKey: .head)
        lossy = try container.decode(Bool.self, forKey: .lossy)
        ended = try container.decodeIfPresent(Bool.self, forKey: .ended) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case head
        case lossy
        case ended
    }
}

public struct HelloReply: Decodable, Sendable {
    public var versionMajor: Int
    public var versionMinor: Int
    public var superdPID: Int32
    /// The STABLE agent-hook socket path children are told about. hostd must advertise this one
    /// into every spawned env, never a path of its own — hostd's pid may not appear in anything a
    /// live child remembers (`docs/51` §1).
    public var hookSocketPath: String?
    /// The stable agent-control socket path, same rule.
    public var controlSocketPath: String?
    /// The crate version of the superd process that answered — `slopdesk-superd`'s own
    /// `CARGO_PKG_VERSION`, compiled in, never read back off disk.
    ///
    /// ``versionMinor`` above cannot answer this. The minor says what superd can *speak* and moves
    /// only on a wire change; a superd rebuilt with a fixed reaper reports the same minor as the one
    /// it replaced. But superd outlives hostd's build, so after an upgrade the binary on disk and
    /// the process on the socket are routinely different code — and restarting it takes every live
    /// pane. `SidecarVersionAudit` compares this against `slopdesk-superd --version` on disk to say
    /// which, and hostd reports rather than acts.
    ///
    /// `nil` from a superd older than minor 8. "Unknown" must stay distinguishable from "same":
    /// reporting a stale superd as current is exactly the silent wrong answer this removes.
    public var buildVersion: String?

    public init(
        versionMajor: Int = SupervisorProtocol.versionMajor,
        versionMinor: Int = SupervisorProtocol.versionMinor,
        superdPID: Int32,
        hookSocketPath: String? = nil,
        controlSocketPath: String? = nil,
        buildVersion: String? = nil,
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.superdPID = superdPID
        self.hookSocketPath = hookSocketPath
        self.controlSocketPath = controlSocketPath
        self.buildVersion = buildVersion
    }
}

/// Everything superd keeps about a pane. Deliberately thin: no screen state, no scrollback, no
/// detection state — those are hostd's and are rebuilt (`docs/51` §6).
public struct PaneRecord: Decodable, Sendable {
    public var paneID: String
    public var sessionID: String
    public var pid: Int32
    public var executable: String
    public var cwd: String?
    public var rows: UInt16
    public var cols: UInt16
    /// Unix seconds. Integer on purpose — no float ever crosses this boundary.
    public var spawnedAt: Int64
    /// True when some hostd currently holds a duplicate of this pane's master fd. A pane that is
    /// live but unattached is the normal state during a hostd restart.
    public var attached: Bool
    /// Which hostd spawned it, verbatim from ``SpawnRequest/owner``. `nil` when the pane predates
    /// the field — "unknown", never "yours".
    public var owner: String?

    public init(
        paneID: String,
        sessionID: String,
        pid: Int32,
        executable: String,
        cwd: String?,
        rows: UInt16,
        cols: UInt16,
        spawnedAt: Int64,
        attached: Bool,
        owner: String? = nil,
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.pid = pid
        self.executable = executable
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
        self.spawnedAt = spawnedAt
        self.attached = attached
        self.owner = owner
    }
}

public struct ExitedNotice: Decodable, Sendable {
    public var paneID: String
    public var pid: Int32
    /// The exit code, or `128 + signal` for a signalled child — the same convention
    /// `PTYProcess`'s reaper already reports, so hostd's exit handling is unchanged.
    public var code: Int32

    public init(paneID: String, pid: Int32, code: Int32) {
        self.paneID = paneID
        self.pid = pid
        self.code = code
    }
}

// MARK: - Codec

/// JSON, not the hand-rolled big-endian codec the wire paths use.
///
/// The golden-pinned manual encoding exists because those paths cross machines and versions and
/// are frozen. This one is local-only (`AF_UNIX`, `0600`, same uid), and its whole design problem
/// is the OPPOSITE — it has to absorb version skew, which is what a self-describing format with
/// ignore-unknown-keys decoding is for. No golden vectors apply here.
///
/// ## One direction each, on purpose
/// hostd encodes requests and decodes replies. It cannot do the reverse, because the types will
/// not let it: ``SupervisorRequest`` is `Encodable` only and ``SupervisorReply`` is `Decodable`
/// only. That is not a convenience — it is the thing that makes a Swift superd impossible to write
/// by accident. `rust/slopdesk-superd/src/protocol.rs` is the mirror image, for the same reason.
public enum SupervisorCodec {
    public static func encode(_ request: SupervisorRequest) throws -> [UInt8] {
        try Array(JSONEncoder().encode(request))
    }

    public static func decodeReply(_ bytes: [UInt8]) throws -> SupervisorReply {
        try JSONDecoder().decode(SupervisorReply.self, from: Data(bytes))
    }
}
