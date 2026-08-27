import Foundation

// SupervisorMessages — what hostd ASKS superd for and what it LEARNS back, as plain Swift values.
//
// ## There is no wire in this file, and that is the whole point
// There used to be: `SupervisorProtocol.swift` spelled the same JSON vocabulary as
// `rust/slopdesk-superwire/src/protocol.rs`, ~1,660 lines of it, and each file's doc comment opened
// by calling the other a mirror. Unlike the FRAMING — where a disagreement desynchronises a socket
// and is noticed within the second — a disagreement HERE passed both test suites and produced a
// `nil`: the more expensive kind, precisely because nothing reports it.
//
// The vocabulary is `slopdesk_superwire::protocol` now, reached through `slopdesk-ffi`'s
// `slopdesk_supervisor_*` doors (`docs/55`). What is left in this file is the shape hostd wants its
// answers in — no `Codable`, no `CodingKeys`, no key names, no version numbers. Nothing here can
// drift from the wire, because nothing here knows what the wire looks like.
//
// The type and member names are unchanged from the file this replaces: five call sites across hostd
// read them, and a rename would have made this port a diff nobody could review against the thing it
// was replacing.

/// `ok` / `error` / `unsupported`, plus whatever a newer superd invents.
///
/// `unsupported` is deliberately distinct from `error`: it is the answer that lets a newer hostd
/// discover an older superd's capability set at runtime instead of guessing from a version number
/// (`docs/51` §3 rule 3).
///
/// ``unrecognised`` is the other direction. A status word this build has no name for must still
/// DECODE — a frame dropped for its status never wakes the waiter parked under its request id, and
/// the caller then sits in `replyArrived.wait()` for a reply that was already delivered and thrown
/// away: a pane that never opens, on the exact skew the version-in-`hello` contract exists to
/// absorb. It is a failure, never a success.
public enum SupervisorStatus: Sendable, Equatable {
    case ok
    case error
    case unsupported
    /// A status this build has no name for. Treated as a failure, never as success.
    case unrecognised
}

// NOTE: `ListenerKind`, the `listen` verb and the `connection` push are GONE from this target.
// The child-facing sockets superd binds are CLAIMED by hostd, and hostd is Rust since `docs/60`
// F.9 — `slopdesk_superwire::protocol` spells the kinds and `rust/slopdesk-hostd` claims them. A
// Swift copy here would be the cross-language mirror the one-implementation rule bans, and it was
// bound by nobody. A `connection` frame that still arrives at this client has its descriptor
// closed by the read loop (see `SupervisorClient.startReader`), which is the correct answer for an
// end that no longer exists.

// MARK: - What hostd asks for

/// Fork a shell under a PTY and hand back the master.
///
/// The environment is passed WHOLE rather than curated by superd: `HostEnvironment.curated` is
/// hostd's job and changes often, and superd must not need a rebuild when it does. superd overlays
/// only the values that are its own to know (the stable socket paths — `docs/51` §1).
public struct SpawnRequest: Sendable {
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
    /// directory's lifetime, which is exactly the child's.
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
public struct JournalSpawnRequest: Sendable {
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
/// implementation this port exists to remove — so `nil` and `""` must survive the crossing as
/// different things, which on the C side is a null pointer versus a zero length.
public struct BlocksRequest: Sendable {
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

// MARK: - What hostd learns back

/// Everything superd keeps about a pane. Deliberately thin: no screen state, no scrollback, no
/// detection state — those are hostd's and are rebuilt (`docs/51` §6).
public struct PaneRecord: Sendable, Equatable {
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

/// Where a subscription actually starts, and how far the pane has already got.
public struct StreamPosition: Sendable, Equatable {
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
    /// The subscriber's only way to know. An `exited` notice would normally tell it, but a pane
    /// short-lived enough to finish before the `subscribe` arrives was announced dead before this
    /// connection was watching — so without this the backlog renders and the session then waits
    /// forever for an end that already happened.
    public var ended: Bool

    public init(start: UInt64, head: UInt64, lossy: Bool, ended: Bool = false) {
        self.start = start
        self.head = head
        self.lossy = lossy
        self.ended = ended
    }
}

/// What superd said about itself at `hello`.
public struct HelloReply: Sendable, Equatable {
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
    /// ``versionMinor`` cannot answer this. The minor says what superd can *speak* and moves only on
    /// a wire change; a superd rebuilt with a fixed reaper reports the same minor as the one it
    /// replaced. But superd outlives hostd's build, so after an upgrade the binary on disk and the
    /// process on the socket are routinely different code — and restarting it takes every live pane.
    ///
    /// `nil` from a superd older than minor 8. "Unknown" must stay distinguishable from "same":
    /// reporting a stale superd as current is exactly the silent wrong answer this removes.
    public var buildVersion: String?

    public init(
        versionMajor: Int,
        versionMinor: Int,
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

/// A supervised child was reaped.
public struct ExitedNotice: Sendable, Equatable {
    public var paneID: String
    public var pid: Int32
    /// The exit code, or `128 + signal` for a signalled child — the same convention `PTYProcess`'s
    /// reaper already reports, so hostd's exit handling is unchanged.
    public var code: Int32

    public init(paneID: String, pid: Int32, code: Int32) {
        self.paneID = paneID
        self.pid = pid
        self.code = code
    }
}

/// What `journalInfo` answers with.
public struct JournalReply: Sendable, Equatable {
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

// MARK: - Blocks

/// What superd decided a configured slow command's badge should do.
///
/// The two states the auto-progress feature has, and no more: it never reports a percentage,
/// because it does not know one — which is precisely what an indeterminate badge is for.
public enum SyntheticProgress: Sendable, Equatable {
    /// A slow command started; show an indeterminate spinner.
    case indeterminate
    /// Its block closed; take the spinner down.
    case clear
}

/// The wire-relevant facts about one command block.
///
/// A value type with no behaviour on purpose: every judgement about it — whether it is worth an
/// emit, when its output ages out — was made by superd's tap before this crossed the socket.
public struct BlockMetadata: Sendable, Equatable {
    /// The block's index in emission order over the pane's life.
    public var index: UInt32
    /// The command's `$?`, or `nil` when the shell reported none.
    public var exitCode: Int32?
    /// The measured `C`→`D` milliseconds, `nil` while the command is still running.
    public var durationMS: UInt32?
    /// Whether the matching `D` mark has arrived.
    public var complete: Bool
    /// How many output bytes superd holds for this block.
    public var outputLen: UInt32
    /// The typed command line.
    public var commandText: String
    /// The block's prompt-row ordinal, `0` when unknown.
    public var promptOrdinal: UInt32

    public init(
        index: UInt32,
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
        complete: Bool = false,
        outputLen: UInt32 = 0,
        commandText: String = "",
        promptOrdinal: UInt32 = 0,
    ) {
        self.index = index
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.complete = complete
        self.outputLen = outputLen
        self.commandText = commandText
        self.promptOrdinal = promptOrdinal
    }
}

/// One finished block joined with its retained output — what the agent-control verbs read.
public struct BlockRecord: Sendable, Equatable {
    /// The block's index.
    public var index: UInt32
    /// The typed command line.
    public var commandText: String
    /// The command's `$?`, when the shell reported one.
    public var exitCode: Int32?
    /// The measured `C`→`D` milliseconds.
    public var durationMS: UInt32?
    /// Whether the block closed on its own `D` rather than on a fresh prompt.
    public var complete: Bool
    /// The retained output bytes.
    ///
    /// BYTES, not base64: the decode happens on the crate side, where the encoder is, so a
    /// transcript cannot be corrupted by a second decoder disagreeing with the first.
    public var output: [UInt8]

    public init(
        index: UInt32,
        commandText: String = "",
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
        complete: Bool = true,
        output: [UInt8] = [],
    ) {
        self.index = index
        self.commandText = commandText
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.complete = complete
        self.output = output
    }
}

/// The running command, as much of it as any caller has ever wanted.
///
/// Its command line and how much it has printed, never its bytes: a `last-output` call while
/// `tail -f` is running would otherwise ship a quarter of a megabyte to answer a question about the
/// commands BEFORE it.
public struct OpenBlock: Sendable, Equatable {
    /// The typed command line.
    public var commandText: String
    /// How many output bytes it has produced so far.
    public var outputLen: UInt32

    public init(commandText: String, outputLen: UInt32) {
        self.commandText = commandText
        self.outputLen = outputLen
    }
}

/// What a block-reading verb answers with.
///
/// Every field is optional because the three verbs fill different ones. The whole object being
/// absent is itself an answer, and a distinct one: it means the pane has no tap — blocks are off —
/// which a caller reports differently from "this pane has run nothing yet".
public struct BlocksReply: Sendable, Equatable {
    /// `blockOutput`: the retained bytes. Absent for an evicted or unknown index.
    public var output: [UInt8]?
    /// `blockSnapshot`: every block still known, ascending.
    public var snapshot: [BlockMetadata]?
    /// `blockControl`: the last N finished blocks, oldest first, with their bytes.
    public var recent: [BlockRecord]?
    /// `blockControl`: the block still running, if one is.
    public var open: OpenBlock?
    /// `blockControl`: the index the next command typed at this prompt will close under.
    public var nextIndex: UInt32?

    public init(
        output: [UInt8]? = nil,
        snapshot: [BlockMetadata]? = nil,
        recent: [BlockRecord]? = nil,
        open: OpenBlock? = nil,
        nextIndex: UInt32? = nil,
    ) {
        self.output = output
        self.snapshot = snapshot
        self.recent = recent
        self.open = open
        self.nextIndex = nextIndex
    }
}

// MARK: - What superd pushes ahead of a chunk

/// Something a pane's shell said OUT OF BAND, found by superd's sniffer in the chunk it rides with.
///
/// ## Why this is a value and not a parser
/// hostd used to run the OSC state machine itself, over every byte of every pane, on the read-loop
/// thread. It does not any more: superd's pump already holds every byte before anyone else sees one,
/// so the scan happens there, costs no extra copy and no round trip, and hostd receives the ANSWER
/// (`rust/slopdesk-superd/src/sniffer.rs`). The batch decode is
/// `slopdesk_superwire::sniffwire::decode_batch`, reached through `slopdesk_sniff_batch_*`.
///
/// ## Deliberately not `WireMessage`
/// The events are what the shell SAID; a wire message is what a client is TOLD. Those are the same
/// thing today for a title and are not for a cwd (host-gated, resolved into a project key) or a
/// notification (dropped while an agent's hook already banners the edge). Keeping the two
/// vocabularies apart is what lets `MuxChannelSession` keep making those decisions in one place.
public enum SniffedEvent: Sendable, Equatable {
    /// A new window title, already deduplicated against the last one superd emitted for this pane.
    case title(String)
    /// A real terminal bell.
    case bell
    /// A command began executing.
    case commandRunning
    /// The shell returned to a prompt. `exitCode` is `nil` for the code-less `D` mark, which carries
    /// no new truth and must not overwrite a latched one; `durationMS` is superd-measured C→D wall
    /// clock and arrives on every `D`.
    case commandIdle(exitCode: Int32?, durationMS: UInt32)
    /// The shell's working directory, already verified local and percent-decoded.
    case cwd(String)
    /// A desktop notification. `title` is empty when the source gave only a body.
    case notification(title: String, body: String)
    /// The BODY of an OSC 9;4 progress sequence, verbatim after the `9;`.
    ///
    /// Unparsed on purpose, at both ends: the progress vocabulary belongs to `ProgressOSCParser`,
    /// which already owns it, and a second copy of that grammar inside the byte reader is exactly
    /// the drift this port exists to remove.
    case progress(String)
    /// A kind this build has no name for — or a known kind carrying a VALUE it cannot name, which
    /// today means only `status` with an unrecognised `state`. Kept rather than dropped so the
    /// batch stays countable and a skew is visible to a test, never acted on.
    case unknown(kind: String)
}

/// One thing superd's command-block tap found in the chunk this event rides with.
///
/// hostd runs no OSC 133 state machine and holds no captured output: superd's pump has the bytes
/// before anyone else sees one, so the segmenting happens there and the retained ring lives there
/// too — which is what stops the Commands panel going blank across the 0.2 s of a
/// `make host-restart` (`rust/slopdesk-superd/src/blocks.rs`, `docs/51` §6.14).
///
/// ``progress(_:)`` in particular is a decision superd made about a slow command, which hostd still
/// has to turn into the type-32 the protocol spells — superd does not know the protocol and must
/// not learn it.
public enum BlockEvent: Sendable, Equatable {
    /// A block was created, changed, or finished. Already deduped by superd: a running command that
    /// prints steadily is reported once, not once per chunk.
    case block(BlockMetadata)
    /// A synthetic progress badge for a configured slow command should go up, or come down.
    case progress(SyntheticProgress)
    /// A kind this build has no name for. Kept rather than dropped so the batch stays countable and
    /// a skew is visible to a test, never acted on.
    case unknown(kind: String)
}
