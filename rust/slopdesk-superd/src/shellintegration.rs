//! The per-session zsh shell-integration shim — a generated `ZDOTDIR`.
//!
//! ## Why it exists
//!
//! On a post-resize `SIGWINCH`, zsh — specifically prompt frameworks like powerlevel10k —
//! CONDITIONALLY suppresses the ZLE redisplay depending on whether ZLE is idle at its redisplay
//! point. The terminal's reflow clears the application-owned current line (standard behaviour), but
//! zsh emits NO reprint bytes, so the live prompt blanks to a bare cursor while scrollback
//! survives. Everything downstream forwards every byte zsh produces — it produces nothing — so the
//! fix belongs in the shell, not the transport.
//!
//! ## What the shim does — the iTerm2/VS Code shell-integration pattern
//!
//! `ZDOTDIR` is pointed at a generated directory whose rc files SOURCE the user's real startup
//! files (so nothing in their environment or prompt is lost — p10k still loads fully) and whose
//! `.zshrc` then installs a `TRAPWINCH` wrapper that CHAINS any pre-existing handler and
//! unconditionally runs `zle && zle reset-prompt`. That forces a deterministic full prompt reprint
//! on every resize. The same `.zshrc` installs the OSC 133 command marks and the cursor-shape
//! hooks.
//!
//! ## `ZDOTDIR` chaining — the load-bearing subtlety
//!
//! zsh reads `.zshenv`, then (for a login shell) `.zprofile`, then `.zshrc`, then `.zlogin` — each
//! from the CURRENT `ZDOTDIR`. The user's real `.zshenv` may itself reassign `ZDOTDIR`; if it did,
//! the later files would come from THEIR dir and bypass the hook. So each shim file records the
//! user's effective real `ZDOTDIR` (default `$HOME`), sources the corresponding real startup file
//! from there, and RE-ASSERTS `ZDOTDIR` back to the shim so the next file is still ours. The shim's
//! `.zshrc` restores `ZDOTDIR` to the user's real value as its LAST act, so the running shell sees
//! the environment it expects — only startup-file resolution was intercepted.
//!
//! ## Why this lives in superd rather than in hostd
//!
//! The shim directory's lifetime is exactly one child's lifetime, and superd is the only process
//! that knows that lifetime — including the distinction hostd cannot make on its own: a pane that
//! is RELINQUISHED across a hostd restart keeps its child, and deleting the dir there would be
//! deleting a live shell's startup files, while a pane that is TERMINATED must not leak a directory
//! into tmp. Held in hostd this needed three separate cleanup sites (spawn failure, session
//! teardown, orphan sweep) and still could not survive hostd being killed. Note the deliberate
//! contrast with the curated ENVIRONMENT, which superd passes through whole (`docs/51` §1):
//! curation is a policy that changes often and would force a superd rebuild, whereas the shim is a
//! RESOURCE with an owner.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Opts OUT of the whole shim when set to a falsy value. Any other value, or absence, leaves it on.
pub const OPT_OUT_ENV_KEY: &str = "SLOPDESK_SHELL_INTEGRATION";

/// Opts out of JUST the OSC 133 command marks, keeping the resize-reprint fix.
///
/// Read by the generated `.zshrc` in the CHILD shell (`${SLOPDESK_OSC133:-1}`), so it must survive
/// hostd's curated env allowlist for a daemon-side setting to take effect.
pub const OSC133_ENV_KEY: &str = "SLOPDESK_OSC133";

/// Opts out of JUST the cursor-shape feature. Same child-side contract as [`OSC133_ENV_KEY`].
pub const CURSOR_ENV_KEY: &str = "SLOPDESK_SHELL_CURSOR";

/// Carries the user's real `ZDOTDIR` to the shim's own rc files, which would otherwise have to
/// guess what it would have been.
pub const REAL_ZDOTDIR_ENV_KEY: &str = "SLOPDESK_REAL_ZDOTDIR";

/// The `ZDOTDIR` injected for the survival probe.
///
/// A path that exists nowhere and that no `/etc/zshenv` would ever compute, so `output == sentinel`
/// is exactly "our value survives".
pub const PROBE_SENTINEL: &str = "/nonexistent-slopdesk-zdotdir-probe";

/// The four files zsh reads from `$ZDOTDIR`. Presence of ANY marks an established install.
const STARTUP_FILES: [&str; 4] = [".zshrc", ".zshenv", ".zprofile", ".zlogin"];

/// Distinguishes concurrent shim directories created within the same nanosecond.
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// What the shim asks the caller to layer onto the child's environment, plus the directory whose
/// lifetime the caller now owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shim {
    /// The generated directory. Delete it when the child is gone for good — never on a relinquish.
    pub directory: PathBuf,
    /// The user's real `ZDOTDIR`, forwarded so the shim's rc files can find their startup files.
    pub real_zdotdir: String,
}

impl Shim {
    /// The two environment entries to overlay onto the child's env.
    #[must_use]
    pub fn overrides(&self) -> BTreeMap<String, String> {
        let mut overrides = BTreeMap::new();
        overrides.insert(
            "ZDOTDIR".to_owned(),
            self.directory.to_string_lossy().into_owned(),
        );
        overrides.insert(REAL_ZDOTDIR_ENV_KEY.to_owned(), self.real_zdotdir.clone());
        overrides
    }
}

/// Why a shim was not installed, for the log. Every variant is a graceful fallback, never an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Skipped {
    /// Turned off by [`OPT_OUT_ENV_KEY`].
    OptedOut,
    /// Not a zsh. The hook is `TRAPWINCH` plus `zle reset-prompt`, both zsh-specific.
    NotZsh,
    /// A system `/etc/zshenv` reassigns `ZDOTDIR`, so the injected shim would never load. Carries
    /// what it reassigned to.
    EtcZshenvOverridesZdotdir(String),
    /// A home with zero zsh startup files, left unshimmed so `zsh-newuser-install` can still run.
    FreshZshInstall(String),
    /// The directory or its files could not be written.
    NotWritable,
}

impl core::fmt::Display for Skipped {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::OptedOut => write!(formatter, "disabled by {OPT_OUT_ENV_KEY}"),
            Self::NotZsh => write!(formatter, "the login shell is not zsh"),
            Self::EtcZshenvOverridesZdotdir(target) => {
                write!(
                    formatter,
                    "/etc/zshenv reassigns ZDOTDIR (→ {target}) — the injected shim would never load; \
                     skipping it (resize reprint + OSC 133 marks + cursor shape off for this shell). Source \
                     the integration manually or stop /etc/zshenv from overriding an existing ZDOTDIR."
                )
            },
            Self::FreshZshInstall(dir) => {
                write!(
                    formatter,
                    "no zsh startup files in {dir} — skipping the shim so zsh-newuser-install can run on \
                     this fresh install"
                )
            },
            Self::NotWritable => write!(formatter, "the shim directory could not be written"),
        }
    }
}

/// Asks a shell what `$ZDOTDIR` resolves to under a given environment.
///
/// A seam rather than a direct call, because the two branches that matter — a `/etc/zshenv` that
/// stomps the injected value and one that only fills in an unset one — are otherwise reachable only
/// on a machine that has the file at all, which stock macOS does not.
pub type ZdotdirProbe<'a> = &'a dyn Fn(&str, &BTreeMap<String, String>) -> Option<String>;

/// Everything the decision needs that is not the environment, so a test can drive every branch
/// without a real `/etc/zshenv` or a real zsh.
pub struct Probes<'a> {
    /// The system zshenv whose EXISTENCE gates the probes. `/etc/zshenv` in production.
    pub etc_zshenv: &'a Path,
    /// The directory shim dirs are created under. The system temp dir in production.
    pub tmp_dir: &'a Path,
    /// [`probe_zdotdir`] in production.
    pub probe: ZdotdirProbe<'a>,
    /// Whether a path exists. [`Path::exists`] in production.
    pub exists: &'a dyn Fn(&Path) -> bool,
}

impl core::fmt::Debug for Probes<'_> {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Probes")
            .field("etc_zshenv", &self.etc_zshenv)
            .field("tmp_dir", &self.tmp_dir)
            .finish_non_exhaustive()
    }
}

impl Probes<'_> {
    /// The production seams: the real `/etc/zshenv`, the system temp dir, a real subprocess probe,
    /// and a real `stat`.
    #[must_use]
    pub fn system() -> Probes<'static> {
        Probes {
            etc_zshenv: Path::new("/etc/zshenv"),
            tmp_dir: Path::new("/tmp"),
            probe: &probe_zdotdir_default,
            exists: &Path::exists,
        }
    }
}

fn probe_zdotdir_default(shell_path: &str, environment: &BTreeMap<String, String>) -> Option<String> {
    probe_zdotdir(shell_path, environment, core::time::Duration::from_secs(2))
}

/// Whether the shim is enabled, i.e. unless `parent[OPT_OUT_ENV_KEY]` is an explicit falsy value.
#[must_use]
pub fn is_enabled(parent: &BTreeMap<String, String>) -> bool {
    parent
        .get(OPT_OUT_ENV_KEY)
        .is_none_or(|raw| !matches!(raw.to_lowercase().as_str(), "0" | "false" | "no" | "off"))
}

/// Whether this shell gets a shim. Only zsh does; a bash or fish login shell is left untouched.
#[must_use]
pub fn is_zsh(shell_path: &str) -> bool {
    shell_path.rsplit('/').next() == Some("zsh")
}

/// Generates the shim directory, or explains why it was skipped.
///
/// ## `/etc/zshenv` override detection — kitty parity
///
/// zsh sources `/etc/zshenv` FIRST, unconditionally (even under `NO_RCS`), and only THEN resolves
/// `$ZDOTDIR/.zshenv` — so a system `/etc/zshenv` that reassigns `ZDOTDIR` (Nix, managed fleets)
/// silently defeats the injected shim: the spawned shell never reads our startup files and
/// integration goes dark with no error. When `/etc/zshenv` exists — it does NOT on stock macOS, so
/// the common path costs one `stat` — the shell is probed once with a sentinel `ZDOTDIR`. Sentinel
/// survives, ours will too, shim on; sentinel stomped, the shim would be dead weight, so skip.
///
/// A SECOND probe with `ZDOTDIR` unset recovers the dir an only-if-unset `/etc/zshenv` would pick
/// for a NORMAL shell, so [`REAL_ZDOTDIR_ENV_KEY`] forwards to where the user's rc files actually
/// live instead of a bare `$HOME`. A probe failure — spawn error or timeout — fails OPEN: shim on,
/// status quo.
///
/// ## New-install guard
///
/// zsh offers `zsh-newuser-install` only when no `.zshrc` resolves — and the shim dir always has
/// one, so shimming a home with ZERO zsh startup files would suppress the first-run setup forever.
///
/// # Errors
///
/// Answers [`Skipped`] rather than failing: every rejection here leaves a perfectly usable shell.
pub fn install(
    parent: &BTreeMap<String, String>,
    shell_path: &str,
    probes: &Probes<'_>,
) -> Result<Shim, Skipped> {
    if !is_enabled(parent) {
        return Err(Skipped::OptedOut);
    }
    if !is_zsh(shell_path) {
        return Err(Skipped::NotZsh);
    }

    // The user's real ZDOTDIR: an explicit inherited ZDOTDIR wins, else $HOME (zsh's default).
    let inherited = parent.get("ZDOTDIR").filter(|value| !value.is_empty());
    let mut real_zdotdir = inherited
        .or_else(|| parent.get("HOME"))
        .cloned()
        .unwrap_or_default();

    if (probes.exists)(probes.etc_zshenv) {
        // Survival probe: does an injected ZDOTDIR make it past /etc/zshenv?
        let mut sentinel_env = parent.clone();
        sentinel_env.insert("ZDOTDIR".to_owned(), PROBE_SENTINEL.to_owned());
        if let Some(survived) = (probes.probe)(shell_path, &sentinel_env)
            && survived != PROBE_SENTINEL
        {
            return Err(Skipped::EtcZshenvOverridesZdotdir(survived));
        }
        // Discovery probe: an only-if-unset /etc/zshenv picks the user's real config dir for a
        // NORMAL shell, and our spawn always sets ZDOTDIR, so the shim must forward there by hand.
        if inherited.is_none() {
            let mut unset_env = parent.clone();
            unset_env.remove("ZDOTDIR");
            if let Some(discovered) = (probes.probe)(shell_path, &unset_env)
                && !discovered.is_empty()
            {
                real_zdotdir = discovered;
            }
        }
    }

    if !has_any_startup_file(&real_zdotdir, probes.exists) {
        return Err(Skipped::FreshZshInstall(real_zdotdir));
    }

    let directory = write_shim_directory(probes.tmp_dir).ok_or(Skipped::NotWritable)?;
    Ok(Shim {
        directory,
        real_zdotdir,
    })
}

/// Whether the directory holds any of the four files zsh reads from `$ZDOTDIR`.
fn has_any_startup_file(dir: &str, exists: &dyn Fn(&Path) -> bool) -> bool {
    STARTUP_FILES
        .iter()
        .any(|name| exists(&Path::new(dir).join(name)))
}

/// Runs `<shell> --norcs --interactive -c 'echo -n $ZDOTDIR'` — kitty's exact probe — and answers
/// its stdout, or `None` on spawn failure, non-zero exit or timeout, where the caller fails OPEN.
///
/// `--norcs` suppresses every startup file EXCEPT `/etc/zshenv`, the one under test;
/// `--interactive` makes `[[ -o interactive ]]`-guarded code in it behave as in a real session.
/// stdin and stderr are nulled, since an interactive `-c` zsh may grumble about job control.
///
/// The timeout is tight enough that a hostile or hung `/etc/zshenv` cannot wedge a pane spawn.
#[must_use]
pub fn probe_zdotdir(
    shell_path: &str,
    environment: &BTreeMap<String, String>,
    timeout: core::time::Duration,
) -> Option<String> {
    use std::io::Read as _;
    use std::process::{Command, Stdio};

    let mut child = Command::new(shell_path)
        .args(["--norcs", "--interactive", "-c", "echo -n $ZDOTDIR"])
        .env_clear()
        .envs(environment)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .ok()?;

    // Bounded wait. Polling is fine on this rare path — the probe only runs when /etc/zshenv
    // exists.
    let deadline = std::time::Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {},
            Err(_ignored) => return None,
        }
        if std::time::Instant::now() >= deadline {
            // SIGKILL, not SIGTERM: the probe is an INTERACTIVE zsh, which ignores SIGTERM — it
            // installs that ignore BEFORE sourcing /etc/zshenv, the very file whose hang this
            // timeout guards against. A polite terminate would leak one un-killable probe per
            // pane-spawn attempt for the daemon's whole life. The output is discarded here anyway.
            let _ignored = child.kill();
            let _ignored = child.wait();
            return None;
        }
        std::thread::sleep(core::time::Duration::from_millis(10));
    };
    if !status.success() {
        return None;
    }
    let mut output = String::new();
    child.stdout.as_mut()?.read_to_string(&mut output).ok()?;
    Some(output)
}

/// Writes the four shim rc files into a fresh unique subdirectory of `tmp_dir`.
///
/// The directory is created EXCLUSIVELY at mode 0700: a name that already exists is a failure
/// rather than a reuse, so a pre-planted directory in a shared tmp can never become the startup
/// files of a spawned login shell.
fn write_shim_directory(tmp_dir: &Path) -> Option<PathBuf> {
    use std::os::unix::fs::DirBuilderExt as _;

    let dir = tmp_dir.join(unique_shim_name());
    std::fs::DirBuilder::new().mode(0o700).create(&dir).ok()?;

    let files = [
        (".zshenv", shim_source(".zshenv")),
        (".zprofile", shim_source(".zprofile")),
        (".zshrc", ZSHRC_BODY.to_owned()),
        (".zlogin", shim_source(".zlogin")),
    ];
    for (name, body) in files {
        if std::fs::write(dir.join(name), body).is_err() {
            // Partial-write failure: remove the just-created dir and anything already in it, so a
            // per-pane shim dir is never orphaned in tmp on the error path.
            let _ignored = std::fs::remove_dir_all(&dir);
            return None;
        }
    }
    Some(dir)
}

/// A name no concurrent spawn can collide on: the pid pins the process, the nanosecond clock pins
/// the moment, and the counter pins two spawns that landed in the same nanosecond.
fn unique_shim_name() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("slopdesk-zdotdir-{}-{nanos}-{sequence}", std::process::id())
}

/// A shim rc file that sources the corresponding real startup file from the user's real `ZDOTDIR`
/// and re-asserts `ZDOTDIR` to the shim dir so the NEXT startup file is still resolved from us.
fn shim_source(file_name: &str) -> String {
    let mut body = String::with_capacity(1024);
    body.push_str("# slopdesk shell-integration shim — forwards ");
    body.push_str(file_name);
    body.push_str(" to the user's real startup file.\n");
    body.push_str(concat!(
        "__slopdesk_shim=\"${ZDOTDIR:-$HOME}\"\n",
        "__slopdesk_real=\"${SLOPDESK_REAL_ZDOTDIR:-$HOME}\"\n",
        // Point ZDOTDIR at the user's REAL dir WHILE their startup file runs, so config that
        // derives paths from ${ZDOTDIR:-$HOME} — oh-my-zsh's HISTFILE, say — resolves to the real
        // dir and not the temp shim dir, which silently aimed Ctrl-R history and
        // zsh-autosuggestions at an empty per-session file. Restored to the shim below.
        "if [ \"$__slopdesk_real\" = \"$HOME\" ]; then unset ZDOTDIR; else ZDOTDIR=\"$__slopdesk_real\"; \
         fi\n",
    ));
    body.push_str("[ -f \"$__slopdesk_real/");
    body.push_str(file_name);
    body.push_str("\" ] && source \"$__slopdesk_real/");
    body.push_str(file_name);
    body.push_str("\"\n");
    body.push_str(concat!(
        // Re-capture a ZDOTDIR the user's startup file just REASSIGNED — the XDG layout does exactly
        // this in ~/.zshenv. Export the new value as the effective real dir so the NEXT shim file,
        // and .zshrc's final restore, forward to the user's real config instead of the stale $HOME;
        // otherwise their rc files never load.
        "if [ \"${ZDOTDIR:-$HOME}\" != \"$__slopdesk_real\" ]; then __slopdesk_real=\"${ZDOTDIR:-$HOME}\"; \
         export SLOPDESK_REAL_ZDOTDIR=\"$__slopdesk_real\"; fi\n",
        // Keep startup-file resolution pointed at the shim for the next file, whatever the user's
        // rc just did to ZDOTDIR.
        "ZDOTDIR=\"$__slopdesk_shim\"\n",
        "unset __slopdesk_shim __slopdesk_real\n",
    ));
    body
}

/// The shim `.zshrc`.
///
/// Sources the user's real `.zshrc` — p10k loads here — installs the WINCH reprint hook chaining
/// any pre-existing `TRAPWINCH`, installs the OSC 133 command marks via `add-zsh-hook` so they
/// COMPOSE with starship/omz/p10k rather than overwriting them, installs the cursor-shape hooks,
/// then restores `ZDOTDIR` to the user's real value as the LAST act so the running shell sees the
/// environment it expects.
///
/// A raw string, so what is written here is byte-for-byte what the shell reads: the `\033` and
/// `\007` below are LITERAL backslash-zero-three-three text that zsh's `printf` and `$'…'` turn
/// into the real ESC and BEL bytes. A pre-escaped source string is how this silently emitted a
/// corrupt non-OSC byte run once, and the marks simply never fired.
const ZSHRC_BODY: &str = r#"# slopdesk shell-integration shim — sources the user's real .zshrc, then installs a
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
if [ "${ZDOTDIR:-$HOME}" != "$__slopdesk_real" ]; then __slopdesk_real="${ZDOTDIR:-$HOME}"; export SLOPDESK_REAL_ZDOTDIR="$__slopdesk_real"; fi

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
    # Escape a command line into ONE clean OSC-133 field: `;`, `\`, ESC, BEL, CR, LF become `\xNN`
    # so the payload carries no field-separator or OSC-terminator byte; every other byte (incl.
    # multi-byte UTF-8) passes through. Byte-wise under `LC_ALL=C` (VS Code's shell-integration
    # approach) so a UTF-8 command round-trips exactly. POSIX `[ = ]` is used, NOT `[[ == ]]`, so the
    # target bytes compare as LITERAL strings (no pattern interpretation of a lone backslash). The
    # octal `$'\NNN'` targets keep the backslash unambiguous. Result is left in the (global)
    # `__slopdesk_esc` to avoid a per-command command-substitution fork — this runs on EVERY command,
    # so keep it allocation-cheap.
    __slopdesk_osc133_escape() {
      emulate -L zsh
      local LC_ALL=C in="$1" i c n
      local bs=$'\134' es=$'\033' be=$'\007' cr=$'\015' lf=$'\012'
      n=${#in}
      __slopdesk_esc=''
      for (( i = 1; i <= n; ++i )); do
        c="${in[i]}"
        if [ "$c" = "$bs" ]; then __slopdesk_esc+='\x5c'
        elif [ "$c" = ';' ]; then __slopdesk_esc+='\x3b'
        elif [ "$c" = "$es" ]; then __slopdesk_esc+='\x1b'
        elif [ "$c" = "$be" ]; then __slopdesk_esc+='\x07'
        elif [ "$c" = "$cr" ]; then __slopdesk_esc+='\x0d'
        elif [ "$c" = "$lf" ]; then __slopdesk_esc+='\x0a'
        else __slopdesk_esc+="$c"
        fi
      done
    }
    # preexec: a command line is about to run → E (the EXACT typed command from $1, so the host does
    # NOT reconstruct it from the redraw-polluted terminal echo — zsh-autosuggestions ghost text,
    # zsh-syntax-highlighting re-colors, starship transient redraws all repaint the command region in
    # place, and the echo-built commandText came out garbled) then C (command output start = command
    # started). `%s` (not the format string) carries the escaped command, so a literal `%` in it is
    # never interpreted.
    __slopdesk_osc133_preexec() {
      __slopdesk_osc133_escape "$1"
      printf '\033]133;E;%s\007' "$__slopdesk_esc"
      printf '\033]133;C\007'
    }
    # precmd: a new prompt is about to be drawn. Capture $? FIRST (anything else clobbers it),
    # emit D;<exit> for the command that just finished, then A for the new prompt, then append
    # B to $PROMPT so it fires at the END of the rendered prompt — after the prompt text and
    # before the user starts typing. Bytes between B and C are the echoed command line, captured
    # as commandText by the host's command-block segmenter. PROMPT+= runs after all earlier precmd
    # hooks (p10k, starship, etc.) have set $PROMPT, because add-zsh-hook appends us last.
    # %{…%} marks a zero-width prompt sequence so the terminal's column accounting stays correct.
    # $'\033…\007' is ANSI-C quoting: zsh stores the real ESC/BEL bytes in $PROMPT at assignment
    # time — unlike a printf-escape string that would need a subshell and would be re-expanded.
    __slopdesk_osc133_precmd() {
      local __slopdesk_exit=$?
      printf '\033]133;D;%s\007' "$__slopdesk_exit"
      printf '\033]133;A\007'
      # Append the B (prompt-end / command-start) mark at the END of the rendered prompt. It MUST be a
      # STANDALONE $'…' token: the real ESC/BEL bytes are stored at assignment time. Inside DOUBLE
      # quotes ("%{$'…'%}") zsh does NOT ANSI-C-expand $'…', so the LITERAL text ends up in $PROMPT —
      # visible on screen AND, wrapped in zero-width %{…%}, it corrupts zsh's column accounting.
      # Guard with a containment test so a theme with a STATIC $PROMPT (one that does not rebuild
      # PROMPT each precmd) does not accumulate a fresh copy on every prompt.
      [[ $PROMPT == *$'\033]133;B\007'* ]] || PROMPT+=$'%{\033]133;B\007%}'
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
      printf '\033[5 q'
    }
    __slopdesk_cursor_preexec() {
      printf '\033[0 q'
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
"#;

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};

    use super::{
        CURSOR_ENV_KEY, OPT_OUT_ENV_KEY, OSC133_ENV_KEY, PROBE_SENTINEL, Probes, REAL_ZDOTDIR_ENV_KEY, Shim,
        Skipped, ZSHRC_BODY, install, is_enabled, is_zsh, shim_source, write_shim_directory,
    };

    fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|&(key, value)| (key.to_owned(), value.to_owned()))
            .collect()
    }

    /// A scratch directory that removes itself, so a failing assertion cannot leave tmp dirty.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(label: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("slopdesk-shim-test-{label}-{}", std::process::id()));
            let _ignored = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("scratch dir");
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }

        fn touch(&self, name: &str) {
            std::fs::write(self.0.join(name), "").expect("touch");
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ignored = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A `Probes` with no `/etc/zshenv`, so neither probe ever runs.
    fn probes<'a>(tmp_dir: &'a Path, exists: &'a dyn Fn(&Path) -> bool) -> Probes<'a> {
        Probes {
            etc_zshenv: Path::new("/nonexistent-etc-zshenv"),
            tmp_dir,
            probe: &|_shell, _env| None,
            exists,
        }
    }

    #[test]
    fn the_shim_is_on_unless_the_flag_is_explicitly_falsy() {
        assert!(is_enabled(&env(&[])));
        assert!(is_enabled(&env(&[(OPT_OUT_ENV_KEY, "1")])));
        assert!(is_enabled(&env(&[(OPT_OUT_ENV_KEY, "yes")])));
        for value in ["0", "false", "no", "off", "FALSE", "Off", "NO"] {
            assert!(
                !is_enabled(&env(&[(OPT_OUT_ENV_KEY, value)])),
                "{value} should opt out"
            );
        }
    }

    #[test]
    fn only_a_zsh_login_shell_is_shimmed() {
        assert!(is_zsh("/bin/zsh"));
        assert!(is_zsh("/usr/local/bin/zsh"));
        assert!(is_zsh("zsh"));
        assert!(!is_zsh("/bin/bash"));
        assert!(!is_zsh("/usr/local/bin/fish"));
        assert!(!is_zsh("/bin/zsh5"));
    }

    #[test]
    fn opting_out_and_a_foreign_shell_each_skip_before_anything_is_written() {
        let scratch = Scratch::new("skip");
        let seams = probes(scratch.path(), &|_path| true);
        assert_eq!(
            install(&env(&[(OPT_OUT_ENV_KEY, "0")]), "/bin/zsh", &seams),
            Err(Skipped::OptedOut)
        );
        assert_eq!(install(&env(&[]), "/bin/bash", &seams), Err(Skipped::NotZsh));
        assert_eq!(
            std::fs::read_dir(scratch.path()).expect("read").count(),
            0,
            "a skip writes nothing"
        );
    }

    #[test]
    fn a_home_with_zsh_startup_files_gets_a_shim_pointing_back_at_it() {
        let home = Scratch::new("home");
        home.touch(".zshrc");
        let tmp = Scratch::new("tmp");
        let home_path = home.path().to_string_lossy().into_owned();
        let seams = probes(tmp.path(), &Path::exists);
        let shim = install(&env(&[("HOME", &home_path)]), "/bin/zsh", &seams).expect("a shim");
        assert_eq!(shim.real_zdotdir, home_path);
        let overrides = shim.overrides();
        assert_eq!(
            overrides.get("ZDOTDIR").map(String::as_str),
            shim.directory.to_str()
        );
        assert_eq!(
            overrides.get(REAL_ZDOTDIR_ENV_KEY).map(String::as_str),
            Some(home_path.as_str())
        );
        // The four files zsh will read, all present.
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            assert!(shim.directory.join(name).is_file(), "{name}");
        }
    }

    #[test]
    fn an_inherited_zdotdir_wins_over_home() {
        let config = Scratch::new("config");
        config.touch(".zshenv");
        let tmp = Scratch::new("tmp2");
        let config_path = config.path().to_string_lossy().into_owned();
        let seams = probes(tmp.path(), &Path::exists);
        let shim = install(
            &env(&[("HOME", "/nonexistent-home"), ("ZDOTDIR", &config_path)]),
            "/bin/zsh",
            &seams,
        )
        .expect("a shim");
        assert_eq!(shim.real_zdotdir, config_path);
    }

    #[test]
    fn a_fresh_zsh_install_is_left_unshimmed_so_newuser_install_can_run() {
        let home = Scratch::new("fresh");
        let tmp = Scratch::new("tmp3");
        let home_path = home.path().to_string_lossy().into_owned();
        let seams = probes(tmp.path(), &Path::exists);
        assert_eq!(
            install(&env(&[("HOME", &home_path)]), "/bin/zsh", &seams),
            Err(Skipped::FreshZshInstall(home_path))
        );
        // Any ONE of the four is enough to count as established.
        for marker in [".zshrc", ".zshenv", ".zprofile", ".zlogin"] {
            home.touch(marker);
            let home_path = home.path().to_string_lossy().into_owned();
            assert!(
                install(&env(&[("HOME", &home_path)]), "/bin/zsh", &seams).is_ok(),
                "{marker}"
            );
            std::fs::remove_file(home.path().join(marker)).expect("rm");
        }
    }

    #[test]
    fn an_etc_zshenv_that_stomps_zdotdir_skips_the_shim_rather_than_shipping_dead_weight() {
        let home = Scratch::new("stomped");
        home.touch(".zshrc");
        let tmp = Scratch::new("tmp4");
        let home_path = home.path().to_string_lossy().into_owned();
        let seams = Probes {
            etc_zshenv: Path::new("/etc/zshenv"),
            tmp_dir: tmp.path(),
            probe: &|_shell, _env| Some("/nix/store/zsh".to_owned()),
            exists: &|path| path == Path::new("/etc/zshenv") || path.exists(),
        };
        assert_eq!(
            install(&env(&[("HOME", &home_path)]), "/bin/zsh", &seams),
            Err(Skipped::EtcZshenvOverridesZdotdir("/nix/store/zsh".to_owned()))
        );
        assert_eq!(
            std::fs::read_dir(tmp.path()).expect("read").count(),
            0,
            "nothing written on the skip"
        );
    }

    #[test]
    fn a_surviving_sentinel_leaves_the_shim_on() {
        let home = Scratch::new("survives");
        home.touch(".zshrc");
        let tmp = Scratch::new("tmp5");
        let home_path = home.path().to_string_lossy().into_owned();
        let seams = Probes {
            etc_zshenv: Path::new("/etc/zshenv"),
            tmp_dir: tmp.path(),
            // The survival probe echoes ours back; the discovery probe then answers empty.
            probe: &|_shell, environment| {
                environment
                    .get("ZDOTDIR")
                    .cloned()
                    .or_else(|| Some(String::new()))
            },
            exists: &|path| path == Path::new("/etc/zshenv") || path.exists(),
        };
        let shim = install(&env(&[("HOME", &home_path)]), "/bin/zsh", &seams).expect("a shim");
        assert_eq!(shim.real_zdotdir, home_path, "the empty discovery is ignored");
    }

    #[test]
    fn the_discovery_probe_recovers_the_real_config_dir_an_etc_zshenv_would_pick() {
        let discovered = Scratch::new("discovered");
        discovered.touch(".zshrc");
        let tmp = Scratch::new("tmp6");
        let discovered_path = discovered.path().to_string_lossy().into_owned();
        let answer = discovered_path.clone();
        let seams = Probes {
            etc_zshenv: Path::new("/etc/zshenv"),
            tmp_dir: tmp.path(),
            probe: &move |_shell, environment| {
                // Sentinel survives; with ZDOTDIR unset, /etc/zshenv picks the real config dir.
                environment
                    .get("ZDOTDIR")
                    .cloned()
                    .or_else(|| Some(answer.clone()))
            },
            exists: &|path| path == Path::new("/etc/zshenv") || path.exists(),
        };
        let shim = install(&env(&[("HOME", "/nonexistent-home")]), "/bin/zsh", &seams).expect("a shim");
        assert_eq!(shim.real_zdotdir, discovered_path);
    }

    #[test]
    fn an_inherited_zdotdir_suppresses_the_discovery_probe() {
        let config = Scratch::new("inherited");
        config.touch(".zshrc");
        let tmp = Scratch::new("tmp7");
        let config_path = config.path().to_string_lossy().into_owned();
        let seams = Probes {
            etc_zshenv: Path::new("/etc/zshenv"),
            tmp_dir: tmp.path(),
            probe: &|_shell, environment| {
                // If the discovery probe ran (ZDOTDIR unset) it would answer this instead.
                environment
                    .get("ZDOTDIR")
                    .cloned()
                    .or_else(|| Some("/should-not-win".to_owned()))
            },
            exists: &|path| path == Path::new("/etc/zshenv") || path.exists(),
        };
        let shim = install(
            &env(&[("HOME", "/nonexistent-home"), ("ZDOTDIR", &config_path)]),
            "/bin/zsh",
            &seams,
        )
        .expect("a shim");
        assert_eq!(shim.real_zdotdir, config_path);
    }

    #[test]
    fn a_probe_failure_fails_open() {
        let home = Scratch::new("openfail");
        home.touch(".zshrc");
        let tmp = Scratch::new("tmp8");
        let home_path = home.path().to_string_lossy().into_owned();
        let seams = Probes {
            etc_zshenv: Path::new("/etc/zshenv"),
            tmp_dir: tmp.path(),
            probe: &|_shell, _env| None,
            exists: &|path| path == Path::new("/etc/zshenv") || path.exists(),
        };
        assert!(install(&env(&[("HOME", &home_path)]), "/bin/zsh", &seams).is_ok());
    }

    #[test]
    fn every_shim_directory_is_unique_and_private() {
        use std::os::unix::fs::PermissionsExt as _;

        let tmp = Scratch::new("unique");
        let first = write_shim_directory(tmp.path()).expect("first");
        let second = write_shim_directory(tmp.path()).expect("second");
        assert_ne!(first, second);
        let mode = std::fs::metadata(&first).expect("stat").permissions().mode();
        assert_eq!(mode & 0o777, 0o700, "owner-only");
    }

    #[test]
    fn an_unwritable_tmp_dir_is_a_skip_rather_than_a_failure() {
        let seams = probes(Path::new("/nonexistent-tmp-dir"), &|_path| true);
        assert_eq!(
            install(&env(&[("HOME", "/anywhere")]), "/bin/zsh", &seams),
            Err(Skipped::NotWritable)
        );
    }

    #[test]
    fn each_forwarding_file_sources_its_own_name_and_reasserts_the_shim() {
        for name in [".zshenv", ".zprofile", ".zlogin"] {
            let body = shim_source(name);
            assert!(
                body.contains(&format!("source \"$__slopdesk_real/{name}\"")),
                "{name}"
            );
            assert!(body.contains("ZDOTDIR=\"$__slopdesk_shim\""), "{name}");
            assert!(
                body.ends_with("unset __slopdesk_shim __slopdesk_real\n"),
                "{name}"
            );
            // The real dir is where the user's rc runs, so their $HOME-derived paths resolve there.
            assert!(body.contains("if [ \"$__slopdesk_real\" = \"$HOME\" ]; then unset ZDOTDIR;"));
        }
    }

    #[test]
    fn the_zshrc_carries_the_real_escape_text_rather_than_pre_expanded_bytes() {
        // The literal backslash-033 text is what zsh's printf turns into ESC. A real 0x1B here
        // would be the silent corruption that made the marks never fire.
        assert!(ZSHRC_BODY.contains(r"printf '\033]133;C\007'"));
        assert!(ZSHRC_BODY.contains(r"printf '\033]133;D;%s\007' "));
        assert!(ZSHRC_BODY.contains(r"printf '\033]133;E;%s\007' "));
        assert!(ZSHRC_BODY.contains(r"PROMPT+=$'%{\033]133;B\007%}'"));
        assert!(ZSHRC_BODY.contains(r"printf '\033[5 q'"));
        assert!(ZSHRC_BODY.contains(r"printf '\033[0 q'"));
        assert!(!ZSHRC_BODY.contains('\u{1B}'), "no real ESC byte anywhere");
        assert!(!ZSHRC_BODY.contains('\u{7}'), "no real BEL byte anywhere");
    }

    #[test]
    fn the_zshrc_chains_rather_than_replaces_every_hook_it_installs() {
        assert!(ZSHRC_BODY.contains("functions[__slopdesk_user_winch]=$functions[TRAPWINCH]"));
        assert!(ZSHRC_BODY.contains("zle && zle reset-prompt"));
        // add-zsh-hook APPENDS; a bare precmd() would overwrite starship's.
        assert!(ZSHRC_BODY.contains("add-zsh-hook preexec __slopdesk_osc133_preexec"));
        assert!(ZSHRC_BODY.contains("add-zsh-hook precmd  __slopdesk_osc133_precmd"));
        assert!(ZSHRC_BODY.contains("add-zsh-hook precmd  __slopdesk_cursor_precmd"));
        assert!(ZSHRC_BODY.contains("add-zsh-hook preexec __slopdesk_cursor_preexec"));
        // Both features are individually gated — asserted THROUGH the constants, because the name
        // is spelled twice (here and in the body) and hostd's env allowlist is a third site. A
        // literal here would let a renamed constant pass while the child shell read the old name.
        assert!(ZSHRC_BODY.contains(&format!(r#"case "${{{OSC133_ENV_KEY}:-1}}" in"#)));
        assert!(ZSHRC_BODY.contains(&format!(r#"case "${{{CURSOR_ENV_KEY}:-1}}" in"#)));
        // And the user's rc is sourced BEFORE the hooks are installed, so we append to theirs.
        let sourced = ZSHRC_BODY
            .find("source \"$__slopdesk_real/.zshrc\"")
            .expect("source");
        let hooked = ZSHRC_BODY.find("add-zsh-hook preexec").expect("hook");
        assert!(sourced < hooked);
    }

    #[test]
    fn the_zshrc_repairs_a_histfile_that_etc_zshrc_aimed_into_the_shim_dir() {
        assert!(
            ZSHRC_BODY
                .contains(r#""$__slopdesk_shim"/*) HISTFILE="${__slopdesk_real%/}/${HISTFILE##*/}" ;;"#)
        );
        // The repair must land before the user's rc, so history loads from the real file.
        let repair = ZSHRC_BODY.find("HISTFILE=").expect("repair");
        let sourced = ZSHRC_BODY
            .find("source \"$__slopdesk_real/.zshrc\"")
            .expect("source");
        assert!(repair < sourced);
    }

    #[test]
    fn the_zshrc_restores_zdotdir_as_its_last_act() {
        let tail = ZSHRC_BODY
            .rsplit("# Restore ZDOTDIR to the user's real value")
            .next()
            .expect("tail");
        assert!(tail.contains("unset ZDOTDIR"));
        assert!(tail.contains("ZDOTDIR=\"$__slopdesk_real\""));
        assert!(tail.trim_end().ends_with("unset __slopdesk_shim __slopdesk_real"));
    }

    #[test]
    fn the_probe_sentinel_names_a_path_that_cannot_exist() {
        assert!(!Path::new(PROBE_SENTINEL).exists());
    }

    #[test]
    fn a_skip_reason_reads_as_a_sentence() {
        assert!(Skipped::NotZsh.to_string().contains("not zsh"));
        assert!(
            Skipped::EtcZshenvOverridesZdotdir("/x".to_owned())
                .to_string()
                .contains("/etc/zshenv reassigns ZDOTDIR (→ /x)")
        );
        assert!(
            Skipped::FreshZshInstall("/home".to_owned())
                .to_string()
                .contains("zsh-newuser-install")
        );
    }

    #[test]
    fn the_overrides_name_exactly_the_two_variables_the_shim_needs() {
        let shim = Shim {
            directory: PathBuf::from("/tmp/shim"),
            real_zdotdir: "/home/me".to_owned(),
        };
        let overrides = shim.overrides();
        assert_eq!(overrides.len(), 2);
        assert_eq!(overrides.get("ZDOTDIR").map(String::as_str), Some("/tmp/shim"));
        assert_eq!(
            overrides.get(REAL_ZDOTDIR_ENV_KEY).map(String::as_str),
            Some("/home/me")
        );
    }
}
