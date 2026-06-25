import Foundation

/// The two TCP connections that make up an Aislopdesk session.
///
/// Per `DECISIONS.md`, a session uses **two** TCP connections so that a burst of
/// PTY output on the data channel cannot delay a resize / disconnect intent on the
/// control channel (the Zellij lesson). `TCP_NODELAY` is set on both, but in
/// `AislopdeskTransport` — not here; `AislopdeskProtocol` is transport-agnostic.
///
/// This enum is advisory metadata: ``WireMessage/channel`` states which connection
/// a message is expected to travel on. The framing and decoder are identical on
/// both channels.
public enum Channel: Sendable, Equatable {
    /// PTY byte stream: `output`, `exit` (host -> client) and `input` (client -> host).
    case data
    /// Session lifecycle & sizing: `hello`/`resize`/`ack`/`bye` (client -> host) and
    /// `helloAck`/`title`/`bell` (host -> client).
    case control
}

/// One decoded Aislopdesk protocol message.
///
/// Wire layout of a frame is `[UInt32 BE payloadLength][UInt8 messageType][body...]`
/// where `payloadLength` counts `messageType` + `body` (it excludes the 4 prefix
/// bytes). All multi-byte integers are big-endian. The keystroke/output hot path
/// uses this manual binary encoding — **never** JSON/`Codable`.
///
/// `WireMessage` is `Sendable` so decoded messages can cross actor / task boundaries
/// (the TCP receive loop hands them to the `@MainActor` renderer).
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

    /// Application-layer RTT probe (client → host, CONTROL channel). `timestampMS` is the
    /// CLIENT's monotonic clock — the host echoes it back verbatim in ``pong(timestampMS:)``
    /// (stateless responder), so only the client ever interprets it. Drives the per-pane
    /// smoothed-RTT estimate (typing-lag attribution; the future predictive-echo gate).
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

    /// Per-command semantic status, derived host-side from OSC 133 C/D marks the shell
    /// emits (FinalTerm/iTerm2 shell-integration). Drives the client's per-pane RUNNING vs
    /// IDLE indicator + the long-command completion notification. Rides the CONTROL channel
    /// (like `title`/`bell`) so a flood of PTY `output` on the DATA channel cannot delay a
    /// `running`/`idle` status — the whole point of the two-channel design.
    case commandStatus(CommandStatus)

    /// An EXPLICIT desktop notification the child requested via OSC 9 (`ESC ] 9 ; <body> ST`) or
    /// OSC 777 (`ESC ] 777 ; notify ; <title> ; <body> ST`). Unlike ``commandStatus`` (duration-gated,
    /// implicit), this fires on demand — `make test && printf '\e]9;build done\e\\'` pushes a
    /// notification for ANY command. The client posts it as a local `UNUserNotification`; clicking it
    /// focuses the originating pane. Rides CONTROL like the other inline signals. An OSC 9 with no
    /// explicit title carries an empty `title` (the client falls back to the pane title).
    case notification(title: String, body: String)

    /// RTT probe reply (host → client, CONTROL channel): the client's ``ping(timestampMS:)``
    /// timestamp echoed verbatim. Riding CONTROL (unwindowed, fast-draining) means the
    /// probe measures the network + host control-loop — never a DATA-window stall — so the
    /// estimate stays honest under an output flood.
    case pong(timestampMS: UInt64)

    /// A per-command "Block" METADATA update (WB1, type 28, host → client, CONTROL). The host
    /// segments the OUTBOUND PTY byte stream into Warp-style per-command blocks (via the OSC 133
    /// A/B/C/D marks) and emits this on each block create / update / complete. It carries ONLY the
    /// metadata — NOT the output bytes (those are fetched on demand via ``requestBlockOutput(index:)``
    /// → ``blockOutput(index:output:)``), so the CONTROL channel never floods with command output.
    ///
    /// - `index` is the 0-based block index in the channel's segmenter lifetime (the request key).
    /// - `exitCode` is the command's `$?` (nil while running / if the shell did not report one).
    /// - `durationMS` is the host-measured C→D wall-clock time (nil while still running).
    /// - `complete` is true once the matching OSC 133 `D` arrived.
    /// - `outputLen` is how many output bytes the host currently holds for this block (for the UI to
    ///   show a size / decide whether to fetch); the host caps captured output at the segmenter's
    ///   256 KiB ceiling.
    /// - `commandText` is the typed command line (capped). Rides CONTROL like ``commandStatus``.
    case commandBlock(
        index: UInt32,
        exitCode: Int32?,
        durationMS: UInt32?,
        complete: Bool,
        outputLen: UInt32,
        commandText: String,
    )

    /// A request for a Block's captured OUTPUT bytes (WB1, type 15, client → host, CONTROL). The
    /// client sends this when the user expands / copies a block whose `index` it learned from a
    /// ``commandBlock`` metadata update; the host replies with ``blockOutput(index:output:)`` from
    /// its bounded per-channel block ring (empty output if that block was evicted / never existed).
    case requestBlockOutput(index: UInt32)

    /// A Block's captured OUTPUT bytes (WB1, type 29, host → client, CONTROL), in reply to a
    /// ``requestBlockOutput(index:)``. `output` is the RAW captured VT bytes (control sequences
    /// preserved), capped at the segmenter's 256 KiB ceiling; an empty `output` means the block was
    /// evicted from the ring or never existed. Rides CONTROL like the other inline signals.
    case blockOutput(index: UInt32, output: Data)

    /// The PTY's current foreground-process basename (W9, type 26, host → client, CONTROL).
    /// The COARSE Claude-Code detection path: the host watches the PTY master's foreground
    /// process group (`tcgetpgrp` → `proc_name`, W10) and emits this on a basename edge —
    /// `"claude"` means a `claude` is in the foreground, `""` (or any other name) clears it.
    /// The client derives a `ClaudeStatus` FLOOR from the name (claude present → at least
    /// `.idle`); the richer state arrives via ``claudeStatus(state:kind:label:)``. Rides the
    /// CONTROL channel like ``title``/``commandStatus`` (an output flood can't delay it). The
    /// pane identity is carried by the mux channel envelope, not in this body.
    case foregroundProcess(name: String)

    /// A rich Claude-Code agent-status update (W9, type 27, host → client, CONTROL). The
    /// HOOK path (docs/41 §4.2): the host folds Claude Code hook events (`Notification` /
    /// `Stop` / `SessionEnd`, via `AislopdeskInspector.HookParser`, W8/W10) into a coarse
    /// state + a notification class + an optional human-readable label.
    ///
    /// - `state` is the raw `UInt8` of `AislopdeskAgentDetect.ClaudeStatus.urgency`
    ///   (`0 none / 1 idle / 2 done / 3 working / 4 needsPermission`). The wire layer is kept
    ///   minimal — it carries the raw byte, NOT the enum (`AislopdeskProtocol` does not depend
    ///   on `AislopdeskAgentDetect`); the client maps it back. An unknown future state byte is
    ///   carried verbatim (forward-tolerant) — the consumer, not the decoder, clamps it.
    /// - `kind` is the notification class (`0 none / 1 permission / 2 waitingForInput /
    ///   3 other`), mirroring `ClaudeHookEvent.NotificationKind`; `0` for non-Notification
    ///   transitions (Stop/SessionEnd/SessionStart).
    /// - `label` is the (often empty) Stop `last_assistant_message` / Notification message,
    ///   capped to the wire's UInt16 length field. Carried as length-prefixed UTF-8 so an
    ///   empty label is unambiguous.
    case claudeStatus(state: UInt8, kind: UInt8, label: String)

    /// A generic host-metadata RPC **request** (E4, type 16, client → host, CONTROL). ONE shared
    /// request/response pair (with ``metadataResponse(requestID:status:payload:)``) backs every
    /// Details-Panel surface that reads host-side metadata — processes, listening ports, cwd,
    /// git status/diff, lazy directory listings, agent-session files — instead of adding eight
    /// frozen wire types. It is the exact structural twin of ``requestBlockOutput(index:)`` →
    /// ``blockOutput(index:output:)`` (a client-chosen id + a length-prefixed reply payload).
    ///
    /// - `requestID` is a client-chosen monotonic `UInt32` correlating a reply to one of several
    ///   in-flight requests (the panel may fire processes + ports + gitStatus at once). The host
    ///   echoes it VERBATIM in the response (stateless responder, like ``pong(timestampMS:)``).
    /// - `verb` selects the operation — the raw `UInt8` of ``MetadataVerb`` (`1` processes …
    ///   `8` readAgentSession). The wire carries the RAW byte, NOT the enum (so an unknown future
    ///   verb is forward-tolerantly carried; the host replies `status = unsupportedVerb`).
    /// - `payload` is the verb's length-prefixed request argument (empty for the pane-scoped verbs;
    ///   a UTF-8 path / id for the parameterized ones). It is OPAQUE to this envelope — the per-verb
    ///   `MetadataCodec` validates it; the decoder only validates the declared length before reading.
    ///
    /// The pane identity rides the **mux channel envelope** (the channelID = the pane/PTY), exactly
    /// as for types 26/27 — so the pane-scoped verbs need no pane field in the body. Additive within
    /// wire version 1: a peer that does not know type 16 DROPS the frame (`unknownMessageType`),
    /// never traps.
    case metadataRequest(requestID: UInt32, verb: UInt8, payload: Data)

    /// A generic host-metadata RPC **response** (E4, type 30, host → client, CONTROL), in reply to a
    /// ``metadataRequest(requestID:verb:payload:)``. The host ALWAYS replies (so the client's
    /// pending-request registry never hangs — `status = error` / empty payload on any failure).
    ///
    /// - `requestID` echoes the request's id verbatim (the correlation key).
    /// - `status` is the raw `UInt8` of ``MetadataStatus`` (`0` ok / `1` notFound / `2` error /
    ///   `3` unsupportedVerb). Carried as a raw byte — an unknown future status clamps to error
    ///   client-side (forward-tolerant).
    /// - `payload` is the verb-specific response body (a `MetadataCodec` list encoding, or raw
    ///   opaque bytes for `cwd`/`gitDiff`/`readAgentSession`), length-prefixed and OPAQUE to this
    ///   envelope; the typed `MetadataCodec`/client decoders validate it. The decoder validates the
    ///   declared payload length before reading (never over-reads a hostile body).
    ///
    /// Additive within wire version 1: a peer that does not know type 30 DROPS the frame
    /// (`unknownMessageType`), never traps. Rides CONTROL like the other inline signals.
    case metadataResponse(requestID: UInt32, status: UInt8, payload: Data)

    /// The semantic state of the foreground command in a pane's shell (from OSC 133).

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
             .metadataResponse:
            .control
        }
    }
}
