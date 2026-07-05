import Darwin
import Foundation
import SlopDeskProtocol

/// E17 / I22 — host PTY-echo watch (the AUTO Secure-Keyboard-Entry signal source). The host
/// resolves each terminal pane/PTY's termios `ECHO` line-discipline flag and drives a type-31
/// ``WireMessage/inputEcho(enabled:)`` on the CONTROL channel so the macOS client can engage
/// `EnableSecureEventInput` automatically while the remote shell shows a hidden-password prompt
/// (`sudo`/`ssh`/`login`/`read -s`/`getpass`, all of which clear `ECHO` with `tcsetattr`).
///
/// **Why a wire signal at all.** termios `ECHO` is a HOST-side line-discipline attribute the child
/// sets — it is **not in the output byte stream** (unlike DECSET/DECRST/OSC-133, which the client
/// parses). So the client cannot derive the no-echo state itself; the AUTO path genuinely needs this
/// host→client message (see `docs/20-wire-protocol.md` / `DECISIONS.md` E17 WI-6).
///
/// **Pure core / thin shim split (hang-safety).** This file is TWO pieces, mirroring
/// ``ForegroundProcessDetector`` / ``PTYForegroundProbe``:
///
/// - ``EchoModeDetector`` — the PURE core. Given an `echoOn` bool from an INJECTED source it
///   edge-detects vs the last emitted value and decides when to emit a type-31
///   ``WireMessage/inputEcho(enabled:)``. It NEVER touches a PTY, syscall, or socket — a
///   deterministic value-in/value-out reducer, unit-tested by feeding bools directly
///   (`EchoModeWatcherTests`).
///
/// - ``PTYEchoProbe`` — the THIN OS shim (compiled + code-reviewed only, NEVER spun in a test per the
///   hang-safety rule). It does the real `tcgetattr(masterFD, …)` read of the `ECHO` flag. It feeds
///   the pure core; the core decides everything.
///
/// **Dedupe / quiet default.** The detector is anchored at `true` (echo-on, the canonical default the
/// client also assumes), so in the common case (echo always on) it is SILENT — it emits ONLY when the
/// child actually deviates (a password prompt clears `ECHO` → `inputEcho(false)`) and again when it
/// restores (→ `inputEcho(true)`). No chatter; the CONTROL stream stays byte-identical to the
/// pre-feature one when no no-echo prompt ever appears. (This deliberately differs from
/// ``ForegroundProcessDetector``'s nil-anchor first-emit: here the default is meaningful and the client
/// already assumes it, so emitting a redundant initial `inputEcho(true)` would be pure noise.)
public struct EchoModeDetector: Sendable {
    /// The last echo state we emitted a type-31 for. Initialized to the canonical default (echo-on)
    /// so the detector emits only on a deviation from — and a restore to — that default.
    private var lastEmitted: Bool

    /// - Parameter initialEcho: the canonical baseline the client also assumes (echo-on by default).
    ///   The detector stays silent until an `echoOn` sample DIFFERS from this.
    public init(initialEcho: Bool = true) {
        lastEmitted = initialEcho
    }

    /// Fold one termios-`ECHO` sample, returning a type-31 ``WireMessage/inputEcho(enabled:)`` to
    /// enqueue ONLY on an edge vs the last emitted value; `nil` when unchanged.
    ///
    /// Pure + idempotent: re-feeding the SAME `echoOn` yields `nil` (the edge anchor absorbs it).
    /// Never traps, never force-unwraps.
    public mutating func sample(echoOn: Bool) -> WireMessage? {
        guard echoOn != lastEmitted else { return nil }
        lastEmitted = echoOn
        return .inputEcho(enabled: echoOn)
    }

    /// The last echo state the detector emitted (diagnostics / the live wiring's per-pane state).
    public var currentEcho: Bool { lastEmitted }
}

/// E17 / I22 — the THIN OS shim that reads a PTY master's termios line-discipline flags and feeds the
/// pure ``EchoModeDetector``. **Compiled + code-reviewed ONLY** — never instantiated in a unit test (the
/// hang-safety rule). A straight translation of a single Darwin syscall into a bool, plus the pure
/// ``echoOn(echoBitSet:canonicalBitSet:)`` classifier (which IS unit-tested).
///
/// ## Resolution — why ECHO alone is NOT enough
/// `tcgetattr(masterFD, &term)` reads the line-discipline `c_lflag`. The naive signal — "no-echo iff
/// `ECHO` is cleared" — is WRONG for an interactive shell, because a LINE EDITOR (zsh `zle` / bash
/// readline) and full-screen TUIs (`vim`/`less`/`htop`) ALSO clear `ECHO`: they switch the tty to RAW
/// mode (`ECHO` AND `ICANON` cleared) and echo characters THEMSELVES. So `tcgetattr` at a NORMAL idle
/// `zsh`/`starship` prompt reads `ECHO=0` — and an ECHO-only probe would latch the client's Secure-Input
/// pill on every ordinary prompt (the live bug this fixes).
///
/// A GENUINE hidden-password prompt (`getpass`/`sudo`/`ssh`/`login`/`read -s`) is different: it clears
/// `ECHO` but stays CANONICAL (`ICANON` SET) — it reads a whole line with echo suppressed by the line
/// discipline. So the discriminator is `ICANON`: report "no-echo" (→ pill) ONLY when `ECHO` is cleared
/// AND the line is still canonical. (Empirically pinned: an idle `zsh -i` prompt reads `ECHO=0 ICANON=0`;
/// a `read -s` / `sudo` prompt reads `ECHO=0 ICANON=1`.)
///
/// On ANY failure (bad fd, the lookup errored) → `true` (echo-on, the SAFE default): a probe error must
/// NEVER spuriously engage Secure Keyboard Entry / lock the client's keyboard. Reading each bit as
/// `!= 0` (never assuming `{0,1}`) matches the untrusted-interop-bool convention.
public enum PTYEchoProbe {
    /// PURE classification of a PTY's termios local-mode bits into the AUTO Secure-Keyboard-Entry
    /// "echo on" signal (`true` = normal, NO pill; `false` = a hidden-password prompt, pill on).
    /// Split out + `internal` (testable via `@testable`) so the ECHO-vs-line-editor discrimination is
    /// unit-tested without a real `tcgetattr` (the OS shim itself is never spun in a test — hang-safety).
    ///
    /// A genuine hidden-password prompt == `ECHO` cleared WHILE canonical (`ICANON` set). Everything else
    /// is echo-on: a cooked child (`ECHO` set), OR a line editor / TUI that cleared `ECHO` together with
    /// `ICANON` (raw mode) and handles its own echo — the normal interactive steady state, NOT a secret.
    static func echoOn(echoBitSet: Bool, canonicalBitSet: Bool) -> Bool {
        let isHiddenPasswordPrompt = !echoBitSet && canonicalBitSet
        return !isHiddenPasswordPrompt
    }

    /// Reads the PTY master's echo state via the ``echoOn(echoBitSet:canonicalBitSet:)`` classifier, or
    /// `true` (echo-on, safe default) on any failure.
    ///
    /// SAFETY: `tcgetattr` is a plain Darwin syscall over an fd the caller owns; `term` is a local
    /// `termios` value (no heap, no over-read).
    public static func echoEnabled(masterFD: Int32) -> Bool {
        guard masterFD >= 0 else { return true }
        var term = termios()
        guard tcgetattr(masterFD, &term) == 0 else { return true }
        let echoBitSet = (term.c_lflag & tcflag_t(ECHO)) != 0
        let canonicalBitSet = (term.c_lflag & tcflag_t(ICANON)) != 0
        return echoOn(echoBitSet: echoBitSet, canonicalBitSet: canonicalBitSet)
    }
}
