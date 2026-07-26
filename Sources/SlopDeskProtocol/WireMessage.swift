import Foundation

/// The two TCP connections that make up an SlopDesk session.
///
/// Per `DECISIONS.md`, a session uses **two** TCP connections so a burst of PTY
/// output on the data channel can't delay a resize / disconnect on the control
/// channel (the Zellij lesson). `TCP_NODELAY` is set on both — in
/// `SlopDeskTransport`, not here (`SlopDeskProtocol` is transport-agnostic).
///
/// Advisory metadata: ``WireMessage/channel`` states which connection a message
/// travels on. Framing and decoder are identical on both channels.
public enum Channel: Sendable, Equatable {
    /// PTY byte stream: `output`, `exit` (host -> client) and `input` (client -> host).
    case data
    /// Session lifecycle & sizing: `hello`/`resize`/`ack`/`bye` (client -> host) and
    /// `helloAck`/`title`/`bell` (host -> client).
    case control
}

/// One decoded SlopDesk protocol message.
///
/// Frame layout: `[UInt32 BE payloadLength][UInt8 messageType][body...]`, where
/// `payloadLength` counts `messageType` + `body` (excludes the 4 prefix bytes).
/// All multi-byte integers are big-endian. The hot path uses manual binary
/// encoding — **never** JSON/`Codable`.
///
/// `Sendable` so decoded messages cross actor / task boundaries (the TCP receive
/// loop hands them to the `@MainActor` renderer).
public enum WireMessage: Equatable, Sendable {
    // MARK: DATA channel, host -> client

    /// PTY output. `seq` is a **monotonic per-message index starting at 1** (NOT a
    /// byte offset); `bytes` is the raw VT payload. See `docs/20-wire-protocol.md`
    /// for the seq/ack/replay contract.
    case output(seq: Int64, bytes: Data)

    /// Child process exited with the given status `code`.
    case exit(code: Int32)

    // MARK: DATA channel, client -> host

    /// Bytes to write to the PTY's stdin (keystrokes, pasted text, etc.).
    case input(Data)

    // MARK: CONTROL channel, client -> host

    /// Session handshake. `sessionID` all-zero means "open a NEW session";
    /// a non-zero UUID means "resume this session". `lastReceivedSeq` is the
    /// highest contiguous output seq the client already has, so the host can
    /// replay only `seq > lastReceivedSeq`.
    case hello(protocolVersion: UInt16, sessionID: UUID, lastReceivedSeq: Int64)

    /// Terminal resize. Character cells (`cols`/`rows`) plus optional pixel
    /// dimensions (`pxWidth`/`pxHeight`, 0 if unknown) — maps to `TIOCSWINSZ`.
    case resize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16)

    /// Acknowledge receipt of output up to and including `seq` (the highest
    /// contiguous output seq the client has durably received). Lets the host
    /// release replay-buffer entries.
    case ack(seq: Int64)

    /// Client is leaving cleanly (empty body).
    case bye

    /// Application-layer RTT probe (client → host, CONTROL). `timestampMS` is the
    /// CLIENT's monotonic clock — the host echoes it verbatim in ``pong(timestampMS:)``
    /// (stateless responder), so only the client interprets it. Drives the per-pane
    /// smoothed-RTT estimate.
    case ping(timestampMS: UInt64)

    // MARK: CONTROL channel, host -> client

    /// Handshake reply. `sessionID` is the authoritative session id (echoes the
    /// client's, or a freshly minted one for a new session). `resumeFromSeq` is the
    /// seq the host will replay from. `returningClient` is **decided by the host**
    /// (true = this is a recognized resuming client; the host replays the tail).
    case helloAck(sessionID: UUID, resumeFromSeq: Int64, returningClient: Bool)

    /// Window/title text (UTF-8). Driven by OSC 0/2 from the child.
    case title(String)

    /// Terminal bell (empty body).
    case bell

    /// Per-command semantic status, derived host-side from OSC 133 C/D marks
    /// (FinalTerm/iTerm2 shell-integration). Drives the per-pane RUNNING vs IDLE
    /// indicator + long-command completion notification. Rides CONTROL (like
    /// `title`/`bell`) so a DATA-channel `output` flood can't delay a `running`/`idle`.
    case commandStatus(CommandStatus)

    /// An EXPLICIT desktop notification the child requested via OSC 9 (`ESC ] 9 ; <body> ST`) or
    /// OSC 777 (`ESC ] 777 ; notify ; <title> ; <body> ST`). Unlike ``commandStatus`` (duration-gated,
    /// implicit), this fires on demand for ANY command. The client posts it as a local
    /// `UNUserNotification`; clicking it focuses the originating pane. Rides CONTROL. An OSC 9 with
    /// no explicit title carries an empty `title` (client falls back to the pane title).
    case notification(title: String, body: String)

    /// RTT probe reply (host → client, CONTROL): the client's ``ping(timestampMS:)``
    /// timestamp echoed verbatim. Riding CONTROL (unwindowed, fast-draining) means the
    /// probe measures network + host control-loop — never a DATA-window stall — so the
    /// estimate stays honest under an output flood.
    case pong(timestampMS: UInt64)

    /// A per-command "Block" METADATA update (WB1, type 28, host → client, CONTROL). The host
    /// segments the OUTBOUND PTY stream into Warp-style per-command blocks (via OSC 133 A/B/C/D
    /// marks) and emits this on each block create / update / complete. Carries ONLY metadata —
    /// NOT the output bytes (fetched on demand via ``requestBlockOutput(index:)`` →
    /// ``blockOutput(index:output:)``), so CONTROL never floods with command output.
    ///
    /// - `index`: 0-based block index in the channel's segmenter lifetime (the request key).
    /// - `exitCode`: the command's `$?` (nil while running / if the shell did not report one).
    /// - `durationMS`: host-measured C→D wall-clock time (nil while still running).
    /// - `complete`: true once the matching OSC 133 `D` arrived.
    /// - `outputLen`: output bytes the host currently holds for this block (UI shows a size /
    ///   decides whether to fetch); capped at the segmenter's 256 KiB ceiling.
    /// - `commandText`: the typed command line (capped). Rides CONTROL like ``commandStatus``.
    /// - `promptOrdinal`: 1-based count of OSC 133 `A` prompt-start marks the segmenter had seen
    ///   when this block's cycle began — the block's PROMPT-ROW ordinal, counting EVERY prompt
    ///   cycle (including empty-Enter / Ctrl-C cycles that produce no block), exactly as
    ///   libghostty counts `.prompt` rows for `jump_to_prompt`. `0` = unknown (mid-stream join
    ///   with no `A` seen) — the client skips the outline jump rather than mis-landing.
    case commandBlock(
        index: UInt32,
        exitCode: Int32?,
        durationMS: UInt32?,
        complete: Bool,
        outputLen: UInt32,
        commandText: String,
        promptOrdinal: UInt32,
    )

    /// Request for a Block's captured OUTPUT bytes (WB1, type 15, client → host, CONTROL). Sent
    /// when the user expands / copies a block whose `index` it learned from a ``commandBlock``
    /// update; the host replies with ``blockOutput(index:output:)`` from its bounded per-channel
    /// block ring (empty output if that block was evicted / never existed).
    case requestBlockOutput(index: UInt32)

    /// A Block's captured OUTPUT bytes (WB1, type 29, host → client, CONTROL), replying to a
    /// ``requestBlockOutput(index:)``. `output` is the RAW captured VT bytes (control sequences
    /// preserved), capped at the segmenter's 256 KiB ceiling; empty `output` means the block was
    /// evicted or never existed. Rides CONTROL like the other inline signals.
    case blockOutput(index: UInt32, output: Data)

    /// The PTY's current foreground-process basename (W9, type 26, host → client, CONTROL).
    /// The COARSE Claude-Code detection path: the host watches the PTY master's foreground
    /// process group (`tcgetpgrp` → `proc_name`, W10) and emits this on a basename edge —
    /// `"claude"` means a `claude` is foreground, `""` (or any other name) clears it. The
    /// client derives a `ClaudeStatus` FLOOR from the name (claude present → at least `.idle`);
    /// richer state arrives via ``claudeStatus(state:kind:label:)``. Rides CONTROL like
    /// ``title``/``commandStatus``. Pane identity rides the mux channel envelope, not this body.
    case foregroundProcess(name: String)

    /// A rich Claude-Code agent-status update (W9, type 27, host → client, CONTROL). The
    /// HOOK path (docs/41 §4.2): the host folds Claude Code hook events (`Notification` /
    /// `Stop` / `SessionEnd`, via `SlopDeskInspector.HookParser`, W8/W10) into a coarse
    /// state + notification class + optional human-readable label.
    ///
    /// - `state`: raw `UInt8` of `SlopDeskAgentDetect.ClaudeStatus.urgency`
    ///   (`0 none / 1 idle / 2 done / 3 working / 4 needsPermission`). Carries the raw byte,
    ///   NOT the enum (`SlopDeskProtocol` does not depend on `SlopDeskAgentDetect`); the client
    ///   maps it back. An unknown future state byte is carried verbatim (forward-tolerant) —
    ///   the consumer, not the decoder, clamps it.
    /// - `kind`: notification class (`0 none / 1 permission / 2 waitingForInput / 3 other`),
    ///   mirroring `ClaudeHookEvent.NotificationKind`; `0` for non-Notification transitions
    ///   (Stop/SessionEnd/SessionStart).
    /// - `label`: the (often empty) Stop `last_assistant_message` / Notification message, capped
    ///   to the wire's UInt16 length field. Length-prefixed UTF-8 so an empty label is unambiguous.
    case claudeStatus(state: UInt8, kind: UInt8, label: String)

    /// A generic host-metadata RPC **request** (E4, type 16, client → host, CONTROL). ONE shared
    /// request/response pair (with ``metadataResponse(requestID:status:payload:)``) backs every
    /// Details-Panel surface reading host-side metadata — processes, ports, cwd, git status/diff,
    /// directory listings, agent-session files — instead of eight frozen wire types. The exact
    /// structural twin of ``requestBlockOutput(index:)`` → ``blockOutput(index:output:)``
    /// (client-chosen id + length-prefixed reply payload).
    ///
    /// - `requestID`: client-chosen monotonic `UInt32` correlating a reply to one of several
    ///   in-flight requests (the panel may fire processes + ports + gitStatus at once). The host
    ///   echoes it VERBATIM (stateless responder, like ``pong(timestampMS:)``).
    /// - `verb`: raw `UInt8` of ``MetadataVerb`` (`1` processes … `8` readAgentSession). Carries
    ///   the RAW byte, NOT the enum (an unknown future verb is forward-tolerantly carried; the host
    ///   replies `status = unsupportedVerb`).
    /// - `payload`: the verb's length-prefixed request argument (empty for pane-scoped verbs; a
    ///   UTF-8 path / id for parameterized ones). OPAQUE to this envelope — the per-verb
    ///   `MetadataCodec` validates it; the decoder only validates the declared length before reading.
    ///
    /// Pane identity rides the **mux channel envelope** (channelID = pane/PTY), as for types 26/27,
    /// so pane-scoped verbs need no pane field. Additive within wire version 1: a peer that does not
    /// know type 16 DROPS the frame (`unknownMessageType`), never traps.
    case metadataRequest(requestID: UInt32, verb: UInt8, payload: Data)

    /// A generic host-metadata RPC **response** (E4, type 30, host → client, CONTROL), replying to a
    /// ``metadataRequest(requestID:verb:payload:)``. The host ALWAYS replies (so the client's
    /// pending-request registry never hangs — `status = error` / empty payload on any failure).
    ///
    /// - `requestID`: echoes the request's id verbatim (the correlation key).
    /// - `status`: raw `UInt8` of ``MetadataStatus`` (`0` ok / `1` notFound / `2` error /
    ///   `3` unsupportedVerb). An unknown future status clamps to error client-side (forward-tolerant).
    /// - `payload`: verb-specific response body (a `MetadataCodec` list encoding, or raw opaque bytes
    ///   for `cwd`/`gitDiff`/`readAgentSession`), length-prefixed and OPAQUE to this envelope; the
    ///   typed `MetadataCodec`/client decoders validate it. The decoder validates the declared payload
    ///   length before reading (never over-reads a hostile body).
    ///
    /// Additive within wire version 1: a peer that does not know type 30 DROPS the frame
    /// (`unknownMessageType`), never traps. Rides CONTROL like the other inline signals.
    case metadataResponse(requestID: UInt32, status: UInt8, payload: Data)

    /// A WORKSPACE-DOCUMENT request (type 17, client → host, CONTROL) — docs/45 §5.2.
    ///
    /// Verb-multiplexed exactly like ``metadataRequest(requestID:verb:payload:)``, and for the same
    /// reason: **every future workspace verb costs zero type numbers** and never shifts the
    /// unknown-type probe again. Verbs are `0 subscribe · 1 ack · 2 presence · 3 intent`.
    ///
    /// - `requestSeq`: the client's monotone request counter (correlation only; the host echoes
    ///   nothing for fire-and-forget verbs).
    /// - `verb`: unknown values are a `malformedBody` DROP, never a trap.
    /// - `payload`: verb-specific, length-prefixed and OPAQUE to this envelope. `SlopDeskProtocol`
    ///   never parses workspace state — `WorkspaceStateCodec` in `SlopDeskWorkspaceModel` does,
    ///   exactly as this target never parses a `metadataRequest` body.
    ///
    /// Rides the workspace mux channel (`channelClass == 1`), whose CONTROL sub-channel is unwindowed.
    case workspaceRequest(requestSeq: UInt32, verb: UInt8, payload: Data)

    /// A WORKSPACE-DOCUMENT event (type 37, host → client, CONTROL) — docs/45 §5.2.
    ///
    /// The epoch and BOTH state numbers are hoisted into the envelope so a client can drop a
    /// mis-based frame after a fixed-size header read, without parsing the payload at all. That is
    /// load-bearing: a delta computed against a different document applies CLEANLY and corrupts
    /// silently (pinned by `WorkspaceStateAlgebraTests.testDiffAgainstAForeignBaseSilentlyDiverges`),
    /// so cheap rejection is the whole defence.
    ///
    /// - `kind`: `0 snapshot · 1 diff · 2 presence · 3 intentResult · 4 reset`. Only kinds 0 and 1
    ///   may advance a client's `stateNum` or trigger an ack — a kind-2/3 frame that advanced it
    ///   would make the host retire, via its `assumedAcked` base, a diff it never sent.
    /// - `epoch`: minted at every hostd start. A foreign epoch means reset-then-snapshot, which is
    ///   the same code path as a missed frame and as a four-hour reconnect.
    /// - `baseStateNum` / `newStateNum`: `Int64`, matching `output.seq` / `ack.seq` /
    ///   `resumeFromSeq` — one seq idiom in the codebase.
    case workspaceEvent(
        kind: UInt8, epoch: UUID, baseStateNum: Int64, newStateNum: Int64, payload: Data,
    )

    /// The PTY's canonical-echo state (E17/I22, type 31, host → client, CONTROL). The host watches the
    /// PTY master's termios `ECHO` line-discipline flag (`tcgetattr`, cleared by `sudo`/`ssh`/`login`/
    /// `read -s`/`getpass`) and emits this on a state EDGE — `enabled: true` is canonical echo (default),
    /// `enabled: false` is a no-echo password prompt. termios `ECHO` is a HOST-side attribute the child
    /// sets with `tcsetattr`, **invisible to the output byte stream** (libghostty / DECSET / OSC-133
    /// parsing never see it), so AUTO-Secure-Keyboard-Entry genuinely requires this host→client signal —
    /// the client engages `EnableSecureEventInput` while `enabled == false`. 1-byte body (`enabled ? 1 : 0`),
    /// decoded as `byte != 0` (untrusted-bool rule). Additive within wire version 1 (host accepts only v1,
    /// no negotiation → host + client redeploy together); a peer that does not know type 31 DROPS the frame
    /// (`unknownMessageType`), never traps. Rides CONTROL like the other inline signals. Pane identity rides
    /// the mux channel envelope, not this body.
    case inputEcho(enabled: Bool)

    /// An OSC 9;4 taskbar-style PROGRESS update (E14/K1, type 32, host → client, CONTROL). iTerm2 /
    /// ConEmu / winget / long builds emit `ESC ] 9 ; 4 ; <state> [ ; <pct> ] <terminator>` to drive a
    /// per-window progress bar; the host parses that subtype out of the OSC-9 stream (NOT a desktop
    /// ``notification`` — surfacing `"4;1;50"` as an alert would flood the user) and forwards it so the
    /// client can light the rail-row spinner / determinate badge (app chrome, NOT terminal content —
    /// hence a control message, not a VT byte).
    ///
    /// - `state`: RAW `UInt8` of ``ProgressState`` (`0` clear / `1` in-progress / `2` error /
    ///   `3` indeterminate). Carries the raw byte (NOT the enum) so the codec stays a faithful 2-byte
    ///   round-trip and the golden vector is stable; the CLIENT re-validates via `ProgressState(wire:)`
    ///   and DROPS an unknown discriminant (forward-tolerant idiom shared with
    ///   `claudeStatus`/`metadataResponse`).
    /// - `percent`: `0…100` (host clamps in `ProgressOSCParser`); meaningful for state `1`/`2`,
    ///   `0` for clear/indeterminate.
    ///
    /// Flat 2-byte body `[UInt8 state][UInt8 percent]` (no BE needed for single bytes). Additive within
    /// wire version 1 (host accepts only v1, no negotiation → host + client redeploy together); a peer
    /// that does not know type 32 DROPS the frame (`unknownMessageType`), never traps. Rides CONTROL like
    /// the other inline signals. Pane identity rides the mux channel envelope, not this body.
    case progress(state: UInt8, percent: UInt8)

    /// The pane's current working directory (OSC 7, type 33, host → client, CONTROL). Shells emit
    /// `ESC ] 7 ; file://<host>/<absolute-path> ST/BEL` on prompt redraw / `cd`; the host forwards only
    /// the decoded absolute path. The client persists it into ``PaneSpec/lastKnownCwd`` so new
    /// tabs/splits inherit the live cwd immediately.
    case cwd(String)

    /// The pane's By-Project sidebar key (type 34, host → client, CONTROL): the git worktree TOPLEVEL
    /// containing the pane's cwd, else the cwd itself. HOST-computed — the single source of truth for
    /// the sidebar's By-Project sectioning, so every client (and every reconnect of the same client)
    /// renders identical sections with ZERO client-side re-derivation: no `gitStatus` RPC sweep, no
    /// cwd-fallback→toplevel re-bucketing flash. The host derives the cwd from its OSC-7 sniff and the
    /// prompt-edge `proc_pidinfo` probe, resolves the toplevel with a pure filesystem walk (no `git`
    /// subprocess on the read loop), emits on CHANGE edges only (dedupe-anchored), and re-asserts the
    /// latched truth on reattach (the type-23/26/27/31/32 sibling). The client persists it into
    /// ``PaneSpec`` so a cold relaunch renders the final sections immediately from disk.
    ///
    /// UTF-8 path body (same single-trailing-string shape as ``title``/``cwd``). Additive within wire
    /// version 1 (host accepts only v1, no negotiation → host + client redeploy together); a peer that
    /// does not know type 34 DROPS the frame (`unknownMessageType`), never traps. Pane identity rides
    /// the mux channel envelope, not this body.
    case projectKey(String)

    /// One PROJECT's folded git status (type 35, host → client, CONTROL): the EVENT-DRIVEN sibling of
    /// the pull-only `gitStatus` metadata RPC. The host's per-repo FSEvents watcher debounces a
    /// filesystem change burst, re-probes `git status` ONCE for the repo, folds the porcelain file
    /// list into counts HOST-side, and pushes this summary to every attached session sectioned under
    /// the repo — so a background project's section header updates within ~a second of an external
    /// edit (an editor save, another terminal's commit) with zero client polling. The client books it
    /// per PROJECT (``repoRoot`` — the same identity as wire type 34) and backs its poll cadence off
    /// while pushes stay fresh. The FILE LIST never rides this push (the RPC serves detail on
    /// demand). Additive within wire version 1 (same rule as type 34): an old peer DROPS the frame
    /// (`unknownMessageType`), never traps.
    case projectGitStatus(ProjectGitStatus)

    /// The pane's AGENT-SESSION INTENT (type 36, host → client, CONTROL): a sticky one-line "why
    /// this session exists" — the first real prompt of the pane's agent session, latched by the
    /// host's hook detector and re-derived only when the SESSION changes (a new `claude` run,
    /// `/clear`), never per turn — so the sidebar can title an agent row by its task ("fix the
    /// flaky CI test") instead of the process name every agent row shares. The Claude-Code /
    /// Conductor session-naming idiom, host-computed from the `UserPromptSubmit` hook's `prompt`
    /// field (no transcript reads). EMPTY string = the session ended / no intent — the client
    /// clears its mirror and the row falls back down the title chain.
    ///
    /// UTF-8 body, single trailing string (same shape as ``cwd``/``projectKey``), clamped by the
    /// host at derivation. Additive within wire version 1 (host + client redeploy
    /// together); an old peer DROPS the frame (`unknownMessageType`), never traps. Pane identity
    /// rides the mux channel envelope, not this body. Change-edge deduped + re-asserted on
    /// reattach (the type-23/26/27/32/33/34 sibling).
    case agentSessionIntent(String)

    /// The type-35 body: the repo identity + branch strings (each `[UInt16 BE len][UTF-8]`) followed
    /// by fixed BE counts. All counts are already folded (staged/modified/untracked count each file's
    /// X/Y nibble INDEPENDENTLY — an `MM` file is both staged and modified — matching
    /// ``MetadataCodec/GitStatusPayload/foldedCounts``).
    public struct ProjectGitStatus: Equatable, Sendable {
        /// The repo's absolute toplevel — the By-Project section key this summary books under.
        public var repoRoot: String
        /// The current branch name (empty = detached HEAD).
        public var branch: String
        /// Commits ahead of / behind the upstream (0 when no upstream).
        public var ahead: Int32
        public var behind: Int32
        /// The repo's stash depth (`git stash list` count).
        public var stashCount: Int32
        /// The folded porcelain breakdown + the raw changed-file total.
        public var staged: UInt32
        public var modified: UInt32
        public var untracked: UInt32
        public var conflicted: UInt32
        public var changedCount: UInt32

        public init(
            repoRoot: String, branch: String, ahead: Int32, behind: Int32, stashCount: Int32,
            staged: UInt32, modified: UInt32, untracked: UInt32, conflicted: UInt32, changedCount: UInt32,
        ) {
            self.repoRoot = repoRoot
            self.branch = branch
            self.ahead = ahead
            self.behind = behind
            self.stashCount = stashCount
            self.staged = staged
            self.modified = modified
            self.untracked = untracked
            self.conflicted = conflicted
            self.changedCount = changedCount
        }
    }

    /// The semantic state of the foreground command in a pane's shell (from OSC 133).
    public enum CommandStatus: Equatable, Sendable {
        /// OSC 133;C — a command began executing (preexec). The pane is RUNNING.
        case running
        /// OSC 133;D — the command finished (precmd of the next prompt). The pane is IDLE
        /// again. `exitCode` is the command's `$?` (nil if the shell did not report one);
        /// `durationMS` is the host-measured C→D wall-clock time, used for the long-command
        /// notification threshold.
        case idle(exitCode: Int32?, durationMS: UInt32)
    }

    /// The on-wire message-type byte (`UInt8`) for this case.
    public var messageType: UInt8 {
        switch self {
        case .output: 1
        case .exit: 2
        case .input: 3
        case .hello: 10
        case .resize: 11
        case .ack: 12
        case .bye: 13
        case .ping: 14
        case .requestBlockOutput: 15
        case .metadataRequest: 16
        case .helloAck: 20
        case .title: 21
        case .bell: 22
        case .commandStatus: 23
        case .pong: 24
        case .notification: 25
        case .foregroundProcess: 26
        case .claudeStatus: 27
        case .commandBlock: 28
        case .blockOutput: 29
        case .metadataResponse: 30
        case .inputEcho: 31
        case .progress: 32
        case .cwd: 33
        case .projectKey: 34
        case .projectGitStatus: 35
        case .agentSessionIntent: 36
        case .workspaceRequest: 17
        case .workspaceEvent: 37
        }
    }

    /// The channel this message is expected to travel on (advisory; see ``Channel``).
    public var channel: Channel {
        switch self {
        case .output,
             .exit,
             .input:
            .data
        case .hello,
             .resize,
             .ack,
             .bye,
             .ping,
             .requestBlockOutput,
             .metadataRequest,
             .helloAck,
             .title,
             .bell,
             .commandStatus,
             .pong,
             .notification,
             .foregroundProcess,
             .claudeStatus,
             .commandBlock,
             .blockOutput,
             .metadataResponse,
             .inputEcho,
             .progress,
             .cwd,
             .projectKey,
             .projectGitStatus,
             .workspaceRequest,
             .workspaceEvent,
             .agentSessionIntent:
            .control
        }
    }
}
