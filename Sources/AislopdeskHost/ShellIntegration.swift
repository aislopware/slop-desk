import Foundation

/// Builds a per-session **zsh shell-integration shim** (a generated `ZDOTDIR`) that makes the
/// host's spawned interactive zsh reliably **reprint its prompt after a window resize**.
///
/// ## Why this exists (WF4 root cause)
/// On a post-resize `SIGWINCH`, zsh — specifically prompt frameworks like powerlevel10k —
/// **conditionally suppresses** the ZLE redisplay depending on whether ZLE is idle at its
/// redisplay point. The terminal's reflow clears the application-owned current line (standard
/// behavior), but zsh emits **no** reprint bytes, so the live prompt line blanks to a bare
/// cursor while scrollback survives. The host forwards every byte zsh produces — it produces
/// nothing — so the fix belongs in the shell, not the transport.
///
/// ## What the shim does (the iTerm2/VSCode shell-integration pattern)
/// We point `ZDOTDIR` at a generated directory whose rc files **source the user's real startup
/// files** (so nothing in their environment / prompt is lost — p10k still loads fully) and whose
/// `.zshrc` then installs a `TRAPWINCH` wrapper that **chains** any pre-existing handler and
/// unconditionally runs `zle && zle reset-prompt`. That forces a deterministic full prompt
/// reprint on every resize (validated on a hardware-equivalent PTY harness).
///
/// ## ZDOTDIR chaining (the load-bearing subtlety)
/// zsh reads `.zshenv`, then (for a login shell) `.zprofile`, then `.zshrc`, then `.zlogin` —
/// each from the *current* `ZDOTDIR`. The user's real `.zshenv` may itself reassign `ZDOTDIR`;
/// if it did, the later files would come from *their* dir and bypass our hook. So each shim file:
///   1. records the user's effective real ZDOTDIR (default `$HOME`),
///   2. sources the corresponding real startup file from there (if it exists), and
///   3. **re-asserts** `ZDOTDIR` back to the shim so the next file is still ours.
/// The shim's `.zshrc` restores `ZDOTDIR` to the user's real value as its **last** act, so the
/// running shell sees the environment it expects — only startup-file resolution was intercepted.
///
/// `@MainActor`-free, dependency-free, deterministic: generation is pure string assembly + file
/// writes, so it is unit-testable without a HostServer (see `ShellIntegrationTests`).
public enum ShellIntegration {
    /// Env var that opts OUT of the shim when set to `0` / `false` / `no` (case-insensitive).
    /// Any other value (or absence) leaves the shim ENABLED.
    public static let optOutEnvKey = "AISLOPDESK_SHELL_INTEGRATION"

    /// A private env var the shim's `.zshenv` reads to learn the user's *real* `ZDOTDIR`
    /// before we overrode it (defaults to `$HOME` inside the script when unset). Carrying it
    /// explicitly means the shim never has to guess what `ZDOTDIR` would have been.
    static let realZDotDirEnvKey = "AISLOPDESK_REAL_ZDOTDIR"

    /// Returns `true` unless `parent[optOutEnvKey]` is an explicit falsy value.
    public static func isEnabled(parent: [String: String]) -> Bool {
        guard let raw = parent[optOutEnvKey]?.lowercased() else { return true }
        switch raw {
        case "0", "false", "no", "off": return false
        default: return true
        }
    }

    /// Only zsh gets the shim. The hook is `TRAPWINCH` + `zle reset-prompt`, both zsh-specific;
    /// a bash/fish login shell is left untouched (its own startup is unaffected).
    public static func isZsh(shellPath: String) -> Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }

    /// Generates the shim directory and returns the env mutations the caller must layer onto the
    /// child env: `ZDOTDIR` → the shim dir, and `AISLOPDESK_REAL_ZDOTDIR` → the user's real ZDOTDIR
    /// (so the shim can find/forward the real startup files). Returns `nil` (no mutation) when the
    /// shim is disabled or the shell is not zsh — the caller then spawns with the env unchanged.
    ///
    /// - Parameters:
    ///   - parent: the parent environment (read for the opt-out flag, `HOME`, and any inherited
    ///     `ZDOTDIR`).
    ///   - shellPath: the login shell that will be spawned (only `zsh` is shimmed).
    ///   - tmpDir: where the shim dir is created (defaults to the system temp dir).
    /// - Returns: env overrides to merge into the child env, or `nil` to leave it unchanged.
    public static func makeEnvironmentOverrides(
        parent: [String: String],
        shellPath: String,
        tmpDir: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) -> [String: String]? {
        guard isEnabled(parent: parent), isZsh(shellPath: shellPath) else { return nil }

        // The user's real ZDOTDIR: an explicit inherited ZDOTDIR wins, else $HOME (zsh's default).
        let realZDotDir = parent["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? parent["HOME"]
            ?? NSHomeDirectory()

        guard let shimDir = writeShimDirectory(into: tmpDir) else { return nil }

        return [
            "ZDOTDIR": shimDir.path,
            realZDotDirEnvKey: realZDotDir,
        ]
    }

    // MARK: Shim generation

    /// Writes the 4 shim rc files into a fresh unique subdirectory of `tmpDir` and returns it,
    /// or `nil` if the directory / files could not be written (the caller then skips the shim).
    static func writeShimDirectory(into tmpDir: URL) -> URL? {
        let dir = tmpDir.appendingPathComponent("aislopdesk-zdotdir-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        } catch {
            return nil
        }

        let files: [(name: String, body: String)] = [
            (".zshenv", shimSource(forwarding: ".zshenv", reassertZDotDir: true)),
            (".zprofile", shimSource(forwarding: ".zprofile", reassertZDotDir: true)),
            (".zshrc", zshrcBody),
            (".zlogin", shimSource(forwarding: ".zlogin", reassertZDotDir: true)),
        ]
        for file in files {
            let url = dir.appendingPathComponent(file.name)
            guard (try? file.body.write(to: url, atomically: true, encoding: .utf8)) != nil else {
                // Partial-write failure: remove the just-created dir (+ any files already written) so a
                // per-pane shim dir is not orphaned in tmp — restores the no-leaked-shim-dir guarantee on
                // the error path (the success path is byte-for-byte unchanged) (R13).
                try? fm.removeItem(at: dir)
                return nil
            }
        }
        return dir
    }

    /// A shim rc file that sources the corresponding real startup file from the user's real
    /// `ZDOTDIR` and (optionally) re-asserts `ZDOTDIR` to the shim dir so the next startup file
    /// is still resolved from us.
    ///
    /// `${AISLOPDESK_REAL_ZDOTDIR:-$HOME}` — the real dir, defaulting to `$HOME` when the var is unset.
    /// `${ZDOTDIR:-$HOME}` (`__aislopdesk_shim`) — captured at the TOP so we can restore it after the
    /// user's rc runs (the user's rc may have reassigned `ZDOTDIR`).
    static func shimSource(forwarding fileName: String, reassertZDotDir: Bool) -> String {
        var lines = [
            "# aislopdesk shell-integration shim — forwards \(fileName) to the user's real startup file.",
            "__aislopdesk_shim=\"${ZDOTDIR:-$HOME}\"",
            "__aislopdesk_real=\"${AISLOPDESK_REAL_ZDOTDIR:-$HOME}\"",
            // Point ZDOTDIR at the user's REAL dir WHILE their startup file runs, so config that
            // derives paths from ${ZDOTDIR:-$HOME} (e.g. oh-my-zsh's HISTFILE) resolves to the real
            // dir — not the temp shim dir, which silently aimed Ctrl-R history + zsh-autosuggestions
            // at an empty per-session file. Restored to the shim below (reassert) for the NEXT file.
            "if [ \"$__aislopdesk_real\" = \"$HOME\" ]; then unset ZDOTDIR; else ZDOTDIR=\"$__aislopdesk_real\"; fi",
            "[ -f \"$__aislopdesk_real/\(fileName)\" ] && source \"$__aislopdesk_real/\(fileName)\"",
        ]
        if reassertZDotDir {
            // Keep startup-file resolution pointed at the shim for the next file, regardless of
            // what the user's rc just did to ZDOTDIR.
            lines.append("ZDOTDIR=\"$__aislopdesk_shim\"")
        }
        lines.append("unset __aislopdesk_shim __aislopdesk_real")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The shim `.zshrc`: source the user's real `.zshrc` (p10k loads here), install the WINCH
    /// reprint hook chaining any pre-existing `TRAPWINCH`, install the OSC 133 command marks via
    /// `add-zsh-hook` (composes with starship/omz/p10k; gated by `AISLOPDESK_OSC133`), then restore
    /// `ZDOTDIR` to the user's real value as the LAST act so the running shell sees the env it
    /// expects.
    static let zshrcBody: String = """
    # aislopdesk shell-integration shim — sources the user's real .zshrc, then installs a
    # SIGWINCH prompt-reprint hook so the prompt is redrawn after a remote resize.
    __aislopdesk_shim="${ZDOTDIR:-$HOME}"
    __aislopdesk_real="${AISLOPDESK_REAL_ZDOTDIR:-$HOME}"
    # macOS's system /etc/zshrc runs BETWEEN our .zprofile and this file with ZDOTDIR STILL set to
    # the shim, and it does `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history` — so history (Ctrl-R recall +
    # zsh-autosuggestions, which read $HISTFILE) silently landed in the throwaway per-session shim
    # dir, i.e. always empty. We can't intercept /etc/zshrc, so repair it HERE (we run right after):
    # a HISTFILE that points INTO the shim dir is redirected back to the user's real ZDOTDIR, keeping
    # the same basename. A HISTFILE the user sets explicitly in their own .zshrc (sourced below) still
    # wins. Done BEFORE sourcing the user rc so history loads from the real file. (Same root cause as
    # the autosuggestion-color report: not color — the suggestions just had no history to draw from.)
    case "$HISTFILE" in
      "$__aislopdesk_shim"/*) HISTFILE="${__aislopdesk_real%/}/${HISTFILE##*/}" ;;
    esac
    # Point ZDOTDIR at the user's REAL dir WHILE their .zshrc runs so config that derives paths from
    # ${ZDOTDIR:-$HOME} (oh-my-zsh's ZSH_COMPDUMP, etc.) resolves to the real dir, not the shim. The
    # final block below re-restores ZDOTDIR to the real value for the running shell.
    if [ "$__aislopdesk_real" = "$HOME" ]; then unset ZDOTDIR; else ZDOTDIR="$__aislopdesk_real"; fi
    [ -f "$__aislopdesk_real/.zshrc" ] && source "$__aislopdesk_real/.zshrc"

    # Chain any pre-existing TRAPWINCH (e.g. powerlevel10k's) so the user's handler still runs,
    # then unconditionally redraw the prompt. `zle && zle reset-prompt` is a no-op when ZLE is not
    # active, so it never corrupts a non-interactive moment or the input buffer.
    if (( $+functions[TRAPWINCH] )); then
      functions[__aislopdesk_user_winch]=$functions[TRAPWINCH]
    fi
    TRAPWINCH() {
      (( $+functions[__aislopdesk_user_winch] )) && __aislopdesk_user_winch "$@"
      zle && zle reset-prompt
    }

    # aislopdesk OSC 133 shell integration — emit FinalTerm/iTerm2 semantic command marks so the
    # client can show a per-pane running/idle state and notify on long-running commands. We use
    # `add-zsh-hook` so these COMPOSE with the user's starship / oh-my-zsh / p10k precmd+preexec
    # hooks (it APPENDS to the hook arrays — it never overwrites a bare precmd()/preexec()).
    # Installed AFTER the user's real .zshrc is sourced above (so we append to their hooks, not
    # the other way round). Opt out of JUST the marks (keeping the resize reprint fix) with
    # AISLOPDESK_OSC133=0; the whole shim is already gated by AISLOPDESK_SHELL_INTEGRATION upstream.
    case "${AISLOPDESK_OSC133:-1}" in
      0|false|no|off) ;;
      *)
        autoload -Uz add-zsh-hook
        # preexec: a command line is about to run → C (command output start = command started).
        # NOTE: the escapes are written with a DOUBLE backslash so this Swift string literal emits
        # the LITERAL shell text backslash-033 / backslash-007 (a single backslash) — zsh's printf
        # then turns those into the real ESC (0x1B) / BEL (0x07) bytes. A SINGLE backslash here
        # would be a Swift octal/NUL escape, producing a corrupt non-OSC byte run the host parser
        # never recognizes (the marks would silently never fire).
        __aislopdesk_osc133_preexec() { printf '\\033]133;C\\007' }
        # precmd: a new prompt is about to be drawn. Capture $? FIRST (anything else clobbers it),
        # emit D;<exit> for the command that just finished, then A for the new prompt.
        __aislopdesk_osc133_precmd() {
          local __aislopdesk_exit=$?
          printf '\\033]133;D;%s\\007' "$__aislopdesk_exit"
          printf '\\033]133;A\\007'
        }
        add-zsh-hook preexec __aislopdesk_osc133_preexec
        add-zsh-hook precmd  __aislopdesk_osc133_precmd
        ;;
    esac

    # Restore ZDOTDIR to the user's real value: only startup-file resolution was intercepted.
    if [ "$__aislopdesk_real" = "$HOME" ]; then
      unset ZDOTDIR
    else
      ZDOTDIR="$__aislopdesk_real"
    fi
    unset __aislopdesk_shim __aislopdesk_real

    """
}
