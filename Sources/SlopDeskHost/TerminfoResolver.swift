/// Resolves the **effective** `TERM` to advertise into a spawned PTY, mirroring the ssh / kitty
/// terminfo-bootstrap model (audit finding #17).
///
/// ## The problem
/// The client renders with libghostty, so the host's first instinct is to advertise
/// `TERM=xterm-ghostty` unconditionally — that is what unlocks the kitty keyboard protocol and DEC
/// 2026 synchronized output. But a fresh host almost never has the `xterm-ghostty` terminfo entry:
/// it ships with Ghostty, not with the base OS. On such a host every curses app — `vim`, `htop`,
/// `less`, `tmux`, `top` — calls `setupterm("xterm-ghostty")`, finds nothing, and either refuses to
/// start ("terminal is not fully functional") or degrades to a dumb fallback with the wrong key
/// sequences.
///
/// What the canonical tools do: `ssh` forwards `TERM` verbatim and RELIES on the remote having the
/// entry, which is the failure above; `mosh` forces a `TERM` it ships terminfo for; kitty's `ssh`
/// kitten PUSHES its compiled terminfo and `tic`-installs it under `~/.terminfo` — best fidelity,
/// and the only one that mutates somebody else's machine.
///
/// This is the third option Ghostty itself documents (#54700): keep `xterm-ghostty` when the host
/// resolves it, fall back to the universally-present `xterm-256color` when it does not. Pushing
/// terminfo stays deliberately out of scope; see kitty's `kittens/ssh` for the reference.
///
/// ## Where the work is
/// The search order, the two on-disk layouts, the `infocmp` authority and the decision table all
/// live in `slopdesk-probe` (`docs/DECISIONS.md`, stage 25). What is left here is the one thing that
/// is about hostd: turning the probe's answer back into a ``ClaudeCodeProfile/Term``, and deciding
/// what a host with no probe should advertise.
public enum TerminfoResolver {
    /// The universally-present entry every fallback lands on. It is passed to the probe rather than
    /// known by it: the probe resolves two names it is handed, and hostd owns which two.
    public static let fallback = ClaudeCodeProfile.Term.xterm256

    /// The full resolution: ask the probe, then map its answer back to a ``ClaudeCodeProfile/Term``.
    ///
    /// - Parameters:
    ///   - requested: the `TERM` the launch mode wants (`.ghostty` by default, `.xterm256` when
    ///     `--xterm256` was passed).
    ///   - explicitOverride: whether `requested` came from an explicit operator flag. Unused in the
    ///     decision BY DESIGN — a `.ghostty` request must auto-fall back on a host that cannot
    ///     resolve it whether it was chosen or defaulted, because advertising an unresolvable `TERM`
    ///     helps no one, and an explicit `.xterm256` already wins by being the fallback itself. The
    ///     parameter stays so the override semantics are visible at the call site and a future
    ///     "force ghostty even if unresolvable" lever has a home.
    /// - Returns: the effective `Term` and whether this was an automatic fallback, so the caller can
    ///   log it — gated — exactly once per session.
    public static func resolve(
        requested: ClaudeCodeProfile.Term,
        explicitOverride _: Bool,
    ) -> (term: ClaudeCodeProfile.Term, fellBack: Bool) {
        // Short-circuit the fork for the one case whose answer is already known: a request that IS
        // the fallback is authoritative, and there is nothing to fall back from. The probe agrees,
        // and asking it anyway would spawn a process to be told so.
        if requested == fallback { return (fallback, false) }
        guard let answer = HostProbe.terminfo(requested: requested.rawValue, fallback: fallback.rawValue),
              let term = ClaudeCodeProfile.Term(rawValue: answer.term)
        else {
            // No probe, or an answer naming a `TERM` this build does not carry. Fall back and SAY
            // so: a host that cannot check whether the entry exists is a host where advertising it
            // is a guess, and the fallback is right on every machine either way. Reporting it as a
            // fallback is what gets it into the log instead of silently degrading every TUI app.
            return (fallback, true)
        }
        return (term, answer.fellBack)
    }
}
