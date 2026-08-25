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
/// The PROBE, and nothing else. The pane's echo ANCHOR is one of ``PaneTruths``'s latches now — it
/// is folded from the same batch the rest of them are and read under the same lock, and a detector
/// object holding one `Bool` beside it was a second place for that `Bool` to be. Every decision
/// crossed before it did:
/// `slopdesk_posix::pty::echo_on` is the ECHO-versus-line-editor discrimination — the subtle one,
/// and the one that used to latch the client's pill on every ordinary prompt — and
/// `slopdesk_terminal::echo::is_edge` is the dedupe. Both are tested there, the probe against a real
/// `openpty` master, which ends the deleted file's "compiled and code-reviewed, never spun in a
/// test" exception: `tcgetattr` is a property read, not a `read`, so it neither blocks nor takes a
/// byte from superd.

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
