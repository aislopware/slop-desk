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

    /// RTT probe reply (host → client, CONTROL channel): the client's ``ping(timestampMS:)``
    /// timestamp echoed verbatim. Riding CONTROL (unwindowed, fast-draining) means the
    /// probe measures the network + host control-loop — never a DATA-window stall — so the
    /// estimate stays honest under an output flood.
    case pong(timestampMS: UInt64)

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
        case .output: return 1
        case .exit: return 2
        case .input: return 3
        case .hello: return 10
        case .resize: return 11
        case .ack: return 12
        case .bye: return 13
        case .ping: return 14
        case .helloAck: return 20
        case .title: return 21
        case .bell: return 22
        case .commandStatus: return 23
        case .pong: return 24
        }
    }

    /// The channel this message is expected to travel on (advisory; see ``Channel``).
    public var channel: Channel {
        switch self {
        case .output, .exit, .input:
            return .data
        case .hello, .resize, .ack, .bye, .ping, .helloAck, .title, .bell, .commandStatus, .pong:
            return .control
        }
    }
}
