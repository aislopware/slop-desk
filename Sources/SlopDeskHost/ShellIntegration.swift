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
    public static let optOutEnvKey = "SLOPDESK_SHELL_INTEGRATION"

    /// Env var that opts OUT of JUST the OSC-133 command marks (keeping the resize-reprint fix) when set
    /// to `0` / `false` / `no` / `off`. Evaluated in the CHILD shell by the generated `.zshrc`
    /// (`${SLOPDESK_OSC133:-1}`), so it must be FORWARDED across the curated env allowlist
    /// (``HostEnvironment/curated(parent:term:agentSocketPath:paneID:controlSocketPath:)``) for a
    /// daemon-side setting to take effect.
    public static let osc133EnvKey = "SLOPDESK_OSC133"

    /// Env var that opts OUT of JUST the cursor-shape feature (bar caret at the prompt, configured
    /// default while a command runs — ghostty/kitty's "cursor" shell-integration feature) when set
    /// to `0` / `false` / `no` / `off`. Evaluated in the CHILD shell by the generated `.zshrc`
    /// (`${SLOPDESK_SHELL_CURSOR:-1}`), so it must be FORWARDED across the curated env allowlist
    /// (``HostEnvironment/curated(parent:term:agentSocketPath:paneID:controlSocketPath:)``) — same
    /// contract as ``osc133EnvKey``.
    public static let cursorEnvKey = "SLOPDESK_SHELL_CURSOR"

    /// A private env var the shim's `.zshenv` reads to learn the user's *real* `ZDOTDIR`
    /// before we overrode it (defaults to `$HOME` inside the script when unset). Carrying it
    /// explicitly means the shim never has to guess what `ZDOTDIR` would have been.
    static let realZDotDirEnvKey = "SLOPDESK_REAL_ZDOTDIR"

    /// Returns `true` unless `parent[optOutEnvKey]` is an explicit falsy value.
    public static func isEnabled(parent: [String: String]) -> Bool {
        guard let raw = parent[optOutEnvKey]?.lowercased() else { return true }
        switch raw {
        case "0",
             "false",
             "no",
             "off": return false
        default: return true
        }
    }

    /// Only zsh gets the shim. The hook is `TRAPWINCH` + `zle reset-prompt`, both zsh-specific;
    /// a bash/fish login shell is left untouched (its own startup is unaffected).
    public static func isZsh(shellPath: String) -> Bool {
        shellPath.split(separator: "/").last.map(String.init) == "zsh"
    }

    /// Generates the shim directory and returns the env mutations the caller must layer onto the
    /// child env: `ZDOTDIR` → the shim dir, and `SLOPDESK_REAL_ZDOTDIR` → the user's real ZDOTDIR
    /// (so the shim can find/forward the real startup files). Returns `nil` (no mutation) when the
    /// shim is disabled, the shell is not zsh, `/etc/zshenv` would stomp the injected `ZDOTDIR`
    /// (see below), or the home is a fresh zsh install — the caller then spawns with the env
    /// unchanged.
    ///
    /// ## `/etc/zshenv` override detection (kitty parity)
    /// zsh sources `/etc/zshenv` FIRST, unconditionally (even under `NO_RCS`), and only *then*
    /// resolves `$ZDOTDIR/.zshenv` — so a system `/etc/zshenv` that reassigns `ZDOTDIR` (Nix,
    /// managed fleets) silently defeats the injected shim: the spawned shell never reads our
    /// startup files and integration goes dark with no error. When `/etc/zshenv` exists (it does
    /// NOT on stock macOS, so the common path costs one `stat`), we probe the shell once with a
    /// sentinel `ZDOTDIR` (`<shell> --norcs --interactive -c 'echo -n $ZDOTDIR'` — `--norcs`
    /// suppresses every startup file EXCEPT `/etc/zshenv`, isolating exactly the file we care
    /// about). Sentinel survives → our value will too, shim on. Sentinel stomped → the shim would
    /// be dead weight: skip it (`nil`) and `warn` — the same graceful-fallback-not-workaround
    /// answer kitty/ghostty document. A second probe with `ZDOTDIR` *unset* recovers the dir an
    /// only-if-unset `/etc/zshenv` would pick for a NORMAL shell, so `SLOPDESK_REAL_ZDOTDIR`
    /// forwards to where the user's rc files actually live instead of a bare `$HOME`. A probe
    /// failure (spawn error / timeout) fails OPEN: shim on, status quo.
    ///
    /// ## New-install guard (kitty's `is_new_zsh_install`)
    /// zsh offers `zsh-newuser-install` only when no `.zshrc` resolves — and the shim dir always
    /// has one, so shimming a home with ZERO zsh startup files would suppress the first-run setup
    /// forever. Such a home is left unshimmed.
    ///
    /// - Parameters:
    ///   - parent: the parent environment (read for the opt-out flag, `HOME`, and any inherited
    ///     `ZDOTDIR`).
    ///   - shellPath: the login shell that will be spawned (only `zsh` is shimmed).
    ///   - tmpDir: where the shim dir is created (defaults to the system temp dir).
    ///   - etcZshenvPath: the system zshenv whose existence gates the probes (test seam;
    ///     `/etc/zshenv` in production).
    ///   - probe: `(shellPath, environment) → $ZDOTDIR-output` (test seam; `nil` → the real
    ///     ``probeZDotDir(shellPath:environment:)`` subprocess probe).
    ///   - warn: sink for the human-readable reason when the shim is skipped on a guard path.
    /// - Returns: env overrides to merge into the child env, or `nil` to leave it unchanged.
    public static func makeEnvironmentOverrides(
        parent: [String: String],
        shellPath: String,
        tmpDir: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        etcZshenvPath: String = "/etc/zshenv",
        probe: ((_ shellPath: String, _ environment: [String: String]) -> String?)? = nil,
        warn: ((String) -> Void)? = nil,
    ) -> [String: String]? {
        guard isEnabled(parent: parent), isZsh(shellPath: shellPath) else { return nil }

        // The user's real ZDOTDIR: an explicit inherited ZDOTDIR wins, else $HOME (zsh's default).
        let inheritedZDotDir = parent["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
        var realZDotDir = inheritedZDotDir
            ?? parent["HOME"]
            ?? NSHomeDirectory()

        if FileManager.default.fileExists(atPath: etcZshenvPath) {
            let runProbe = probe ?? { probeZDotDir(shellPath: $0, environment: $1) }
            // Survival probe: does an injected ZDOTDIR make it past /etc/zshenv?
            var sentinelEnv = parent
            sentinelEnv["ZDOTDIR"] = zdotdirProbeSentinel
            if let survived = runProbe(shellPath, sentinelEnv), survived != zdotdirProbeSentinel {
                warn?(
                    "shell-integration: \(etcZshenvPath) reassigns ZDOTDIR (→ \(survived)) — the injected "
                        + "shim would never load; skipping it (resize reprint + OSC 133 marks + cursor shape "
                        + "off for this shell). Source the integration manually or stop \(etcZshenvPath) "
                        + "from overriding an existing ZDOTDIR.",
                )
                return nil
            }
            // Discovery probe: an only-if-unset /etc/zshenv picks the user's real config dir for a
            // NORMAL shell (our spawn always sets ZDOTDIR, so the shim must forward there by hand).
            if inheritedZDotDir == nil {
                var unsetEnv = parent
                unsetEnv["ZDOTDIR"] = nil
                if let discovered = runProbe(shellPath, unsetEnv), !discovered.isEmpty {
                    realZDotDir = discovered
                }
            }
        }

        // New-install guard: zero startup files in the effective real dir → leave unshimmed so
        // zsh-newuser-install still fires.
        if !hasAnyZshStartupFile(in: realZDotDir) {
            warn?(
                "shell-integration: no zsh startup files in \(realZDotDir) — skipping the shim so "
                    + "zsh-newuser-install can run on this fresh install.",
            )
            return nil
        }

        guard let shimDir = writeShimDirectory(into: tmpDir) else { return nil }

        return [
            "ZDOTDIR": shimDir.path,
            realZDotDirEnvKey: realZDotDir,
        ]
    }

    /// The sentinel `ZDOTDIR` injected for the survival probe — a path that exists nowhere and that
    /// no `/etc/zshenv` would ever compute, so `output == sentinel` ⟺ "our value survives".
    static let zdotdirProbeSentinel = "/nonexistent-slopdesk-zdotdir-probe"

    /// The four files zsh reads from `$ZDOTDIR` — presence of ANY marks an established install
    /// (kitty checks exactly this set).
    static func hasAnyZshStartupFile(in dir: String) -> Bool {
        let fm = FileManager.default
        return [".zshrc", ".zshenv", ".zprofile", ".zlogin"]
            .contains { fm.fileExists(atPath: dir + "/" + $0) }
    }

    /// Runs `<shellPath> --norcs --interactive -c 'echo -n $ZDOTDIR'` (kitty's exact probe) and
    /// returns its stdout, or `nil` on spawn failure / non-zero exit / timeout (the caller
    /// fails OPEN). `--norcs` suppresses every startup file EXCEPT `/etc/zshenv` — the one under
    /// test; `--interactive` makes `[[ -o interactive ]]`-guarded code in it behave as in a real
    /// session. stderr/stdin are nulled (an interactive `-c` zsh may grumble about job control).
    /// `timeout` defaults to 2s — tight enough that a hostile/hung `/etc/zshenv` cannot wedge pane
    /// spawn; tests pass a generous value so a loaded machine doesn't fail the assertion.
    static func probeZDotDir(
        shellPath: String,
        environment: [String: String],
        timeout: TimeInterval = 2,
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["--norcs", "--interactive", "-c", "echo -n $ZDOTDIR"]
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Bounded wait: a hostile/hung /etc/zshenv must not wedge pane spawn. Polling is fine on
        // this rare path (the probe only runs when /etc/zshenv exists).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: Shim generation

    /// Writes the 4 shim rc files into a fresh unique subdirectory of `tmpDir` and returns it,
    /// or `nil` if the directory / files could not be written (the caller then skips the shim).
    static func writeShimDirectory(into tmpDir: URL) -> URL? {
        let dir = tmpDir.appendingPathComponent("slopdesk-zdotdir-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
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
    /// `${SLOPDESK_REAL_ZDOTDIR:-$HOME}` — the real dir, defaulting to `$HOME` when the var is unset.
    /// `${ZDOTDIR:-$HOME}` (`__slopdesk_shim`) — captured at the TOP so we can restore it after the
    /// user's rc runs (the user's rc may have reassigned `ZDOTDIR`).
    static func shimSource(forwarding fileName: String, reassertZDotDir: Bool) -> String {
        var lines = [
            "# slopdesk shell-integration shim — forwards \(fileName) to the user's real startup file.",
            "__slopdesk_shim=\"${ZDOTDIR:-$HOME}\"",
            "__slopdesk_real=\"${SLOPDESK_REAL_ZDOTDIR:-$HOME}\"",
            // Point ZDOTDIR at the user's REAL dir WHILE their startup file runs, so config that
            // derives paths from ${ZDOTDIR:-$HOME} (e.g. oh-my-zsh's HISTFILE) resolves to the real
            // dir — not the temp shim dir, which silently aimed Ctrl-R history + zsh-autosuggestions
            // at an empty per-session file. Restored to the shim below (reassert) for the NEXT file.
            "if [ \"$__slopdesk_real\" = \"$HOME\" ]; then unset ZDOTDIR; else ZDOTDIR=\"$__slopdesk_real\"; fi",
            "[ -f \"$__slopdesk_real/\(fileName)\" ] && source \"$__slopdesk_real/\(fileName)\"",
            // Re-capture a ZDOTDIR the user's startup file just REASSIGNED (the XDG layout does exactly
            // this in ~/.zshenv: `export ZDOTDIR=\"$HOME/.config/zsh\"`). Export the new value as the
            // effective real dir so the NEXT shim file (and .zshrc's final restore) forward to the user's
            // real config instead of the stale $HOME — otherwise their rc files never load.
            "if [ \"${ZDOTDIR:-$HOME}\" != \"$__slopdesk_real\" ]; then __slopdesk_real=\"${ZDOTDIR:-$HOME}\"; "
                + "export SLOPDESK_REAL_ZDOTDIR=\"$__slopdesk_real\"; fi",
        ]
        if reassertZDotDir {
            // Keep startup-file resolution pointed at the shim for the next file, regardless of
            // what the user's rc just did to ZDOTDIR.
            lines.append("ZDOTDIR=\"$__slopdesk_shim\"")
        }
        lines.append("unset __slopdesk_shim __slopdesk_real")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The shim `.zshrc`: source the user's real `.zshrc` (p10k loads here), install the WINCH
    /// reprint hook chaining any pre-existing `TRAPWINCH`, install the OSC 133 command marks via
    /// `add-zsh-hook` (composes with starship/omz/p10k; gated by `SLOPDESK_OSC133`), install the
    /// cursor-shape hooks (bar at prompt / default while running — ghostty/kitty parity; gated by
    /// `SLOPDESK_SHELL_CURSOR`), then restore `ZDOTDIR` to the user's real value as the LAST act
    /// so the running shell sees the env it expects.
    static let zshrcBody: String = """
    # slopdesk shell-integration shim — sources the user's real .zshrc, then installs a
    # SIGWINCH prompt-reprint hook so the prompt is redrawn after a remote resize.
    __slopdesk_shim="${ZDOTDIR:-$HOME}"
    __slopdesk_real="${SLOPDESK_REAL_ZDOTDIR:-$HOME}"
    # macOS's system /etc/zshrc runs BETWEEN our .zprofile and this file with ZDOTDIR STILL set to
    # the shim, and it does `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history` — so history (Ctrl-R recall +
    # zsh-autosuggestions, which read $HISTFILE) silently landed in the throwaway per-session shim
    # dir, i.e. always empty. We can't intercept /etc/zshrc, so repair it HERE (we run right after):
    # a HISTFILE that points INTO the shim dir is redirected back to the user's real ZDOTDIR, keeping
    # the same basename. A HISTFILE the user sets explicitly in their own .zshrc (sourced below) still
    # wins. Done BEFORE sourcing the user rc so history loads from the real file. (Same root cause as
    # the autosuggestion-color report: not color — the suggestions just had no history to draw from.)
    case "$HISTFILE" in
      "$__slopdesk_shim"/*) HISTFILE="${__slopdesk_real%/}/${HISTFILE##*/}" ;;
    esac
    # Point ZDOTDIR at the user's REAL dir WHILE their .zshrc runs so config that derives paths from
    # ${ZDOTDIR:-$HOME} (oh-my-zsh's ZSH_COMPDUMP, etc.) resolves to the real dir, not the shim. The
    # final block below re-restores ZDOTDIR to the real value for the running shell.
    if [ "$__slopdesk_real" = "$HOME" ]; then unset ZDOTDIR; else ZDOTDIR="$__slopdesk_real"; fi
    [ -f "$__slopdesk_real/.zshrc" ] && source "$__slopdesk_real/.zshrc"
    # Re-capture a ZDOTDIR the user's real .zshrc just reassigned so the final restore below (and any
    # later .zlogin) land on the user's real dir, not the stale one (mirrors the .zshenv re-capture).
    if [ "${ZDOTDIR:-$HOME}" != "$__slopdesk_real" ]; then __slopdesk_real="${ZDOTDIR:-$HOME}"; \
    export SLOPDESK_REAL_ZDOTDIR="$__slopdesk_real"; fi

    # Chain any pre-existing TRAPWINCH (e.g. powerlevel10k's) so the user's handler still runs,
    # then unconditionally redraw the prompt. `zle && zle reset-prompt` is a no-op when ZLE is not
    # active, so it never corrupts a non-interactive moment or the input buffer.
    if (( $+functions[TRAPWINCH] )); then
      functions[__slopdesk_user_winch]=$functions[TRAPWINCH]
    fi
    TRAPWINCH() {
      (( $+functions[__slopdesk_user_winch] )) && __slopdesk_user_winch "$@"
      zle && zle reset-prompt
    }

    # slopdesk OSC 133 shell integration — emit FinalTerm/iTerm2 semantic command marks so the
    # client can show a per-pane running/idle state and notify on long-running commands. We use
    # `add-zsh-hook` so these COMPOSE with the user's starship / oh-my-zsh / p10k precmd+preexec
    # hooks (it APPENDS to the hook arrays — it never overwrites a bare precmd()/preexec()).
    # Installed AFTER the user's real .zshrc is sourced above (so we append to their hooks, not
    # the other way round). Opt out of JUST the marks (keeping the resize reprint fix) with
    # SLOPDESK_OSC133=0; the whole shim is already gated by SLOPDESK_SHELL_INTEGRATION upstream.
    case "${SLOPDESK_OSC133:-1}" in
      0|false|no|off) ;;
      *)
        autoload -Uz add-zsh-hook
        # Escape a command line into ONE clean OSC-133 field: `;`, `\\`, ESC, BEL, CR, LF become `\\xNN`
        # so the payload carries no field-separator or OSC-terminator byte; every other byte (incl.
        # multi-byte UTF-8) passes through. Byte-wise under `LC_ALL=C` (VS Code's shell-integration
        # approach) so a UTF-8 command round-trips exactly. POSIX `[ = ]` is used, NOT `[[ == ]]`, so the
        # target bytes compare as LITERAL strings (no pattern interpretation of a lone backslash). The
        # octal `$'\\NNN'` targets avoid an ambiguous literal `'\\'` in this Swift string. Result is left in
        # the (global) `__slopdesk_esc` to avoid a per-command command-substitution fork — this runs on
        # EVERY command, so keep it allocation-cheap.
        __slopdesk_osc133_escape() {
          emulate -L zsh
          local LC_ALL=C in="$1" i c n
          local bs=$'\\134' es=$'\\033' be=$'\\007' cr=$'\\015' lf=$'\\012'
          n=${#in}
          __slopdesk_esc=''
          for (( i = 1; i <= n; ++i )); do
            c="${in[i]}"
            if [ "$c" = "$bs" ]; then __slopdesk_esc+='\\x5c'
            elif [ "$c" = ';' ]; then __slopdesk_esc+='\\x3b'
            elif [ "$c" = "$es" ]; then __slopdesk_esc+='\\x1b'
            elif [ "$c" = "$be" ]; then __slopdesk_esc+='\\x07'
            elif [ "$c" = "$cr" ]; then __slopdesk_esc+='\\x0d'
            elif [ "$c" = "$lf" ]; then __slopdesk_esc+='\\x0a'
            else __slopdesk_esc+="$c"
            fi
          done
        }
        # preexec: a command line is about to run → E (the EXACT typed command from $1, so the host does
        # NOT reconstruct it from the redraw-polluted terminal echo — zsh-autosuggestions ghost text,
        # zsh-syntax-highlighting re-colors, starship transient redraws all repaint the command region in
        # place, and the echo-built commandText came out garbled) then C (command output start = command
        # started). NOTE: the escapes are written with a DOUBLE backslash so this Swift string literal emits
        # the LITERAL shell text backslash-033 / backslash-007 (a single backslash) — zsh's printf then
        # turns those into the real ESC (0x1B) / BEL (0x07) bytes. A SINGLE backslash here would be a Swift
        # octal/NUL escape, producing a corrupt non-OSC byte run the host parser never recognizes (the
        # marks would silently never fire). `%s` (not the format string) carries the escaped command, so a
        # literal `%` in it is never interpreted.
        __slopdesk_osc133_preexec() {
          __slopdesk_osc133_escape "$1"
          printf '\\033]133;E;%s\\007' "$__slopdesk_esc"
          printf '\\033]133;C\\007'
        }
        # precmd: a new prompt is about to be drawn. Capture $? FIRST (anything else clobbers it),
        # emit D;<exit> for the command that just finished, then A for the new prompt, then append
        # B to $PROMPT so it fires at the END of the rendered prompt — after the prompt text and
        # before the user starts typing. Bytes between B and C are the echoed command line, captured
        # as commandText by the host CommandBlockSegmenter. PROMPT+= runs after all earlier precmd
        # hooks (p10k, starship, etc.) have set $PROMPT, because add-zsh-hook appends us last.
        # %{…%} marks a zero-width prompt sequence so the terminal's column accounting stays correct.
        # $'\\033…\\007' is ANSI-C quoting: zsh stores the real ESC/BEL bytes in $PROMPT at assignment
        # time — unlike a printf-escape string that would need a subshell and would be re-expanded.
        __slopdesk_osc133_precmd() {
          local __slopdesk_exit=$?
          printf '\\033]133;D;%s\\007' "$__slopdesk_exit"
          printf '\\033]133;A\\007'
          # Append the B (prompt-end / command-start) mark at the END of the rendered prompt. It MUST be a
          # STANDALONE $'…' token: the real ESC/BEL bytes are stored at assignment time. Inside DOUBLE
          # quotes ("%{$'…'%}") zsh does NOT ANSI-C-expand $'…', so the LITERAL text $'\\033]133;B\\007'
          # ends up in $PROMPT — visible on screen AND, wrapped in zero-width %{…%}, it corrupts zsh's
          # column accounting. Guard with a containment test so a theme with a STATIC $PROMPT (one that
          # does not rebuild PROMPT each precmd) does not accumulate a fresh copy on every prompt.
          [[ $PROMPT == *$'\\033]133;B\\007'* ]] || PROMPT+=$'%{\\033]133;B\\007%}'
        }
        add-zsh-hook preexec __slopdesk_osc133_preexec
        add-zsh-hook precmd  __slopdesk_osc133_precmd
        ;;
    esac

    # slopdesk cursor-shape shell integration — the ghostty/kitty "cursor" feature: a BAR caret
    # while the shell is at its prompt (no foreground command) and the terminal's configured
    # default (block) while a command runs. DECSCUSR (CSI Ps SP q) is handled natively by the
    # client's libghostty renderer, so the shim only emits the bytes: precmd fires right before
    # the prompt draws → 5 (blinking bar, ghostty's exact sequence); preexec fires as the command
    # starts → 0 (reset to the configured cursor-style). A full-screen program (vim) that sets its
    # own DECSCUSR is naturally restored on exit by the next precmd. Same add-zsh-hook composition
    # and octal-escape rules as the OSC 133 block above. Opt out with SLOPDESK_SHELL_CURSOR=0.
    case "${SLOPDESK_SHELL_CURSOR:-1}" in
      0|false|no|off) ;;
      *)
        autoload -Uz add-zsh-hook
        __slopdesk_cursor_precmd() {
          printf '\\033[5 q'
        }
        __slopdesk_cursor_preexec() {
          printf '\\033[0 q'
        }
        add-zsh-hook precmd  __slopdesk_cursor_precmd
        add-zsh-hook preexec __slopdesk_cursor_preexec
        ;;
    esac

    # Restore ZDOTDIR to the user's real value: only startup-file resolution was intercepted.
    if [ "$__slopdesk_real" = "$HOME" ]; then
      unset ZDOTDIR
    else
      ZDOTDIR="$__slopdesk_real"
    fi
    unset __slopdesk_shim __slopdesk_real

    """
}
