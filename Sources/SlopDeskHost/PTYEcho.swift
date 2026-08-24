import CSlopDeskFFI
import SlopDeskProtocol

/// Host PTY-echo watch (the AUTO Secure-Keyboard-Entry signal source) — two faces over
/// `slopdesk-ffi`'s `echo_mode` doors.
///
/// The host resolves each terminal pane's termios `ECHO` line-discipline state and drives a type-31
/// ``WireMessage/inputEcho(enabled:)`` on the CONTROL channel, so the macOS client can engage
/// `EnableSecureEventInput` automatically while the remote shell shows a hidden-password prompt
/// (`sudo`, `ssh`, `login`, `read -s`, `getpass`, all of which clear `ECHO` with `tcsetattr`).
///
/// **Why a wire signal at all.** termios `ECHO` is a HOST-side attribute the child sets — it is
/// **not in the output byte stream** (unlike DECSET/DECRST/OSC-133, which the client parses). So the
/// client cannot derive the no-echo state itself; the AUTO path genuinely needs this host→client
/// message. See `docs/20-wire-protocol.md` and `DECISIONS.md`.
///
/// ## What is left here
/// One `Bool` per pane and the `WireMessage` it turns into. Both decisions crossed:
/// `slopdesk_posix::pty::echo_on` is the ECHO-versus-line-editor discrimination — the subtle one,
/// and the one that used to latch the client's pill on every ordinary prompt — and
/// `slopdesk_terminal::echo::is_edge` is the dedupe. Both are tested there, the probe against a real
/// `openpty` master, which ends the deleted file's "compiled and code-reviewed, never spun in a
/// test" exception: `tcgetattr` is a property read, not a `read`, so it neither blocks nor takes a
/// byte from superd.

/// The per-pane PTY-echo edge detector.
///
/// Anchored at echo-on — the canonical default the client also assumes — so it stays SILENT in the
/// steady state and the CONTROL stream is byte-identical to the pre-feature one on a pane that never
/// sees a password prompt. Re-anchoring is constructing a fresh one, which is what the reattach path
/// does.
public struct EchoModeDetector: Sendable {
    /// The last echo state this pane emitted a type-31 for.
    private var lastEmitted: Bool

    /// - Parameter initialEcho: the canonical baseline the client also assumes (echo-on by
    ///   default). The detector stays silent until a sample DIFFERS from it.
    public init(initialEcho: Bool = true) {
        lastEmitted = initialEcho
    }

    /// Fold one termios-`ECHO` sample, returning a type-31 to enqueue ONLY on an edge; `nil` when
    /// unchanged. Idempotent: re-feeding the same sample yields `nil`.
    public mutating func sample(echoOn: Bool) -> WireMessage? {
        guard slopdesk_pty_echo_edge(echoOn, lastEmitted) else { return nil }
        lastEmitted = echoOn
        return .inputEcho(enabled: echoOn)
    }

    /// The last echo state the detector emitted (diagnostics, and the live wiring's per-pane state).
    public var currentEcho: Bool { lastEmitted }
}

/// The PTY master's echo state, as the client's Secure-Keyboard-Entry signal.
public enum PTYEchoProbe {
    /// `true` unless a hidden-password prompt is up.
    ///
    /// A negative descriptor, a descriptor that is not a terminal, or a `tcgetattr` that declines
    /// all read as `true`. That default is safe in one direction only: a probe error must never
    /// spuriously engage Secure Keyboard Entry and lock a user's keyboard.
    public static func echoEnabled(masterFD: Int32) -> Bool {
        slopdesk_pty_echo_enabled(masterFD)
    }
}
