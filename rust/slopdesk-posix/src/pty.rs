//! `openpty` + `fork` + `execve` — the largest single obligation in this crate.
//!
//! Ported from the deleted `SlopDeskSupervisor.ForkExecWindow`, whose contract this module
//! inherits whole. That file is gone, so the rule is restated in full below — it was paid for
//! with ten `.ips` crash reports in a single day.
//!
//! ## Why the whole spawn is here and not a `fork` primitive
//! `slopdesk-posix` admits a syscall only when its safety obligation is local (see the crate
//! header), and `fork(2)` on its own does not qualify: calling it is always sound, and what is
//! unsound is whatever the child does next. Exporting a `fork()` would hand a caller an obligation
//! it has no way to discharge — the rule covers instructions the *compiler* emits, not lines
//! anyone writes. So the window is owned here, whole, with [`crate::fork_window_contract`]
//! disassembling it on every test run.
//!
//! ## The window is a contract, not a comment
//! Between `fork(2)` and `execve(2)` in a MULTI-THREADED process, only async-signal-safe raw
//! syscalls are legal. The child inherits the parent's entire address space and exactly ONE thread,
//! so every lock some other thread happened to hold at the instant of the fork is frozen HELD, by
//! an owner that does not exist. superd is emphatically multi-threaded — one reaper per pane, one
//! reader per connection — so this is not a hypothetical.
//!
//! Rust has no metadata cache to deadlock on, which is what killed the Swift version, but it has
//! the same underlying hazard: **`malloc` is not async-signal-safe**. A `CString::new`, a `Vec`
//! push, a `format!`, or a panic (the panic machinery allocates) in the child can wedge it against
//! an allocator lock a dead thread still owns. So the discipline is unchanged and the reason it is
//! unchanged is worth stating: the *language* changed, the *kernel* did not.
//!
//! In [`exec_in_forked_child`]: no allocation, no `String`, no `Vec`, no formatting, no panic, no
//! `?` on anything that builds an error. Every value is a pointer or an `i32` that [`spawn_pty`]
//! materialised BEFORE the fork.

use std::ffi::{CStr, CString};
use std::os::fd::{AsRawFd as _, OwnedFd, RawFd};
use std::sync::Mutex;

use nix::errno::Errno;

/// What went wrong before the child ever existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpawnError {
    /// `openpty(3)` failed.
    Openpty(Errno),
    /// `fork(2)` failed.
    Fork(Errno),
    /// A path or argument contained an interior NUL, so it cannot become a `char *`.
    /// Caught in the parent — the child never sees a half-built vector.
    InteriorNul,
}

impl std::fmt::Display for SpawnError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Openpty(errno) => write!(formatter, "openpty failed: {errno}"),
            Self::Fork(errno) => write!(formatter, "fork failed: {errno}"),
            Self::InteriorNul => {
                write!(formatter, "an argument or path contained an interior NUL byte")
            },
        }
    }
}

impl std::error::Error for SpawnError {}

/// Serialises `openpty` → `fork` against everything another thread must not be INSIDE at that
/// instant.
///
/// Two hazards, one lock, because both are the same shape: `fork(2)` copies whatever the rest of
/// the process was in the middle of, and the child is alone with it. The second one is stated first
/// because it is the one that was measured, and it is why [`while_no_fork_is_taken`] exists and why
/// [`crate::dynsym`] calls it.
///
/// ## No Apple framework call may be in flight while a fork is taken
/// A child forked while another thread is inside a CoreGraphics call dies before the window can
/// report anything: `SIGKILL`, which no path in [`exec_in_forked_child`] can produce — every
/// refusal there is `_exit(127)` — with the master's foreground process group still `0`, so the
/// death is at or before the `TIOCSCTTY` two calls in. What runs in the child ahead of the window
/// is the `pthread_atfork` child handlers those frameworks register, and making those re-entrant is
/// not available to this crate. Not forking while one of their calls is open is.
///
/// Every number here is from this crate's own suite, which is the only process that both forks and
/// calls a framework. Before: the whole suite failed 1 run in 40, the pty tests plus the two
/// [`crate::dynsym`] tests that CALL through their symbol 4 in 40, the pty tests alone 0 in 40, the
/// suite with `dynsym` skipped 0 in 40, and `--test-threads=1` 0 in 12. After: 0 in 40 for the pair
/// and 0 in 40 for the whole suite.
///
/// What is NOT established is a reproducer smaller than the suite. Two threads calling
/// [`crate::dynsym::cursor_seed`] against 30 forks, barrier-aligned so the first fork meets the
/// first call, survived 20 runs with this lock removed — so the trigger wants the whole binary's
/// concurrency, and a regression here will show up as the suite going flaky again rather than as
/// one test going red. Read that as the limit of the evidence, not as a reason to loosen the rule.
///
/// Production does not rest on any of it: superd is the only process that forks, and it calls no
/// framework. The lock makes the rule hold for the calls this crate itself owns, which is what the
/// suite exercises and what a future process that did both would inherit.
///
/// The guard is dropped immediately after the fork rather than held across the exec, because a
/// child is a separate process from the moment `fork` returns — what the parent does afterwards
/// cannot reach it, and holding it longer would serialise superd's panes against each other for no
/// reason.
///
/// ## No descriptor may be born unmarked while a fork is taken
/// **Not** about the fork window's async-signal-safety (that is [`exec_in_forked_child`]'s
/// contract). This closes a descriptor-inheritance race that `FD_CLOEXEC` alone cannot: Darwin's
/// `openpty(3)` takes no `O_CLOEXEC`, so there are a few instructions between "the master exists"
/// and "the master is marked close-on-exec", and a `fork` on another thread landing in that gap
/// breeds a shell holding a duplicate of somebody else's master.
///
/// What that costs is the whole point of this daemon: superd's close would no longer be the LAST
/// close of that master, so the pane's shell never receives its hangup and survives as an orphan
/// with no supervisor — and in the other direction, a leaked SLAVE keeps the master from ever
/// reaching EOF, so [`crate::registry`]'s reaper blocks forever on a pane that is already dead.
///
/// The child inherits this mutex LOCKED, which is fine and is the same reasoning as everywhere else
/// in the window: the child touches nothing but raw syscalls and then `execve`s.
static FORK_LOCK: Mutex<()> = Mutex::new(());

/// Runs `body` with no `fork(2)` able to land in the middle of it.
///
/// The other end of [`FORK_LOCK`], for the callers that are not spawning anything: a `dlopen`, and
/// a call into an Apple framework. Poisoning is meaningless for a `()` guard — a panicking body
/// leaves no shared state behind — so the guard is taken either way.
pub(crate) fn while_no_fork_is_taken<T>(body: impl FnOnce() -> T) -> T {
    let fork_guard = FORK_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let answer = body();
    drop(fork_guard);
    answer
}

/// A freshly forked child under a fresh PTY.
#[derive(Debug)]
pub struct Spawned {
    /// The PTY master. Blocking, `O_NONBLOCK` cleared. superd holds this for the pane's whole life
    /// and hands hostd duplicates — being the last holder is what stops a hostd restart from
    /// `SIGHUP`ing the shell.
    pub master: OwnedFd,
    /// The child's pid. Only superd may `waitpid` it; anyone with the same uid may `kill` it.
    pub pid: i32,
}

/// What the child is asked to become. Every field is already a `String`; the C strings are built
/// from them in [`spawn_pty`], in the parent.
#[derive(Debug, Clone)]
pub struct SpawnPlan<'a> {
    /// Absolute path to the binary.
    pub executable: &'a str,
    /// `argv[0]`, when it must differ from `executable` — a login shell wants a leading `-`.
    pub argv0: Option<&'a str>,
    /// `argv[1..]`.
    pub arguments: &'a [String],
    /// The child's whole environment, already overlaid with superd's stable socket paths.
    pub environment: &'a [String],
    /// Working directory, ALREADY validated by the caller. This function does not check it: the
    /// child's pre-`execve` `chdir` is best-effort and cannot fall back, so an unvalidated path
    /// here is a dead pane.
    pub cwd: Option<&'a str>,
    /// Initial window size.
    pub rows: u16,
    /// Initial window size.
    pub cols: u16,
}

/// `openpty` + `fork` + [`exec_in_forked_child`].
///
/// # Errors
/// [`SpawnError::InteriorNul`] before any syscall, [`SpawnError::Openpty`], or
/// [`SpawnError::Fork`]. On any of them nothing has been forked and no fd is leaked.
#[expect(
    unsafe_code,
    reason = "fork(2) and the pre-exec window have no safe equivalent; see the module header"
)]
pub fn spawn_pty(plan: &SpawnPlan<'_>) -> Result<Spawned, SpawnError> {
    // --- Build ALL C strings AND the argv/envp vectors in the PARENT, before fork() ---
    // The child must not allocate, so nothing below this point may be deferred into it.
    let path = CString::new(plan.executable).map_err(|_ignored| SpawnError::InteriorNul)?;
    let cwd = plan
        .cwd
        .map(|value| CString::new(value).map_err(|_ignored| SpawnError::InteriorNul))
        .transpose()?;

    let mut argv_owned = Vec::with_capacity(plan.arguments.len() + 1);
    argv_owned.push(
        CString::new(plan.argv0.unwrap_or(plan.executable)).map_err(|_ignored| SpawnError::InteriorNul)?,
    );
    for argument in plan.arguments {
        argv_owned.push(CString::new(argument.as_str()).map_err(|_ignored| SpawnError::InteriorNul)?);
    }
    let mut envp_owned = Vec::with_capacity(plan.environment.len());
    for entry in plan.environment {
        envp_owned.push(CString::new(entry.as_str()).map_err(|_ignored| SpawnError::InteriorNul)?);
    }
    let argv = null_terminated(&argv_owned);
    let envp = null_terminated(&envp_owned);

    // Held from before the PTY exists until after the fork — see `FORK_LOCK`. Poisoning is
    // meaningless for a `()`: a panicking spawn leaves no shared state behind, so take the guard.
    let fork_guard = FORK_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let pty = open_pty(plan.rows, plan.cols)?;
    // Clear O_NONBLOCK on the master before the fork — a non-blocking master breaks hostd's
    // blocking read relay, and hostd receives this fd already in whatever mode we leave it.
    set_blocking(pty.master.as_raw_fd());

    let master_raw = pty.master.as_raw_fd();
    let slave_raw = pty.slave.as_raw_fd();
    // Flattened HERE and not at the call site. `Option::as_deref` and `CString`'s `Deref` are real
    // calls in a debug build, and at the call site they would sit between the `cbz` and the window
    // — on the CHILD's path, which `fork_window_contract` pins to no calls at all. By the time the
    // fork happens, every value the child needs is a plain machine word.
    let cwd_raw = cwd.as_deref().map_or(std::ptr::null(), CStr::as_ptr);
    let path_raw = path.as_ptr();
    let argv_raw = argv.as_ptr();
    let envp_raw = envp.as_ptr();

    // SAFETY: `fork` itself is always sound to call; the obligation is on what the child does
    // before `execve`, which is entirely `exec_in_forked_child` and is documented there. Every
    // pointer handed to it was materialised above, in this process, and stays alive because
    // `argv_owned`/`envp_owned`/`path`/`cwd` are still in scope below.
    let child = unsafe { libc::fork() };
    if child == 0 {
        // ===== CHILD ===== nothing here allocates, formats, or can panic.
        // SAFETY: the pointers are all parent-materialised and the fds are open in this child.
        unsafe { exec_in_forked_child(slave_raw, master_raw, cwd_raw, path_raw, argv_raw, envp_raw) }
    }

    // Capture fork()'s errno IMMEDIATELY, before any other syscall can overwrite it — dropping the
    // slave fd below issues a `close(2)` that sets errno on its own failure.
    let fork_errno = Errno::last();
    // The window is over: another thread may open its own PTY now.
    drop(fork_guard);

    // ===== PARENT ===== uses only the master.
    drop(pty.slave);
    if child < 0 {
        return Err(SpawnError::Fork(fork_errno));
    }
    Ok(Spawned {
        master: pty.master,
        pid: child,
    })
}

/// Everything the forked child does before `execve` — and nothing else.
///
/// It is ONE function so the contract has an address, exactly as on the Swift side. Read the module
/// header before adding a line here; "it is only a log statement" is how this becomes a hang.
///
/// # Safety
/// Callable only in a process created by `fork(2)` microseconds earlier, with `slave` and `master`
/// open and every pointer materialised by the parent. Never returns.
#[expect(
    unsafe_code,
    reason = "this IS the pre-exec window; every call in it is a raw async-signal-safe syscall"
)]
#[inline(never)]
unsafe fn exec_in_forked_child(
    slave: RawFd,
    master: RawFd,
    cwd: *const libc::c_char,
    path: *const libc::c_char,
    argv: *const *const libc::c_char,
    envp: *const *const libc::c_char,
) -> ! {
    // SAFETY: raw syscalls only, in the order the Swift original established. Each `unsafe` fact is
    // the same one: these are async-signal-safe libc entry points taking parent-owned pointers.
    unsafe {
        // Reset inherited signal state BEFORE exec. A SIG_IGN disposition and a blocked signal mask
        // both survive fork+execve — so a daemon launched under launchd (which does ignore some
        // signals) would breed shells that NEVER receive the destroy-path hangup, and zsh then
        // skips its history save on pane teardown. A terminal emulator hands every child a clean
        // slate. (SIGKILL/SIGSTOP reject SIG_DFL — harmless.)
        // `= 0` rather than `mem::zeroed()`: Darwin's `sigset_t` IS a `u32`, and `zeroed()`
        // compiles to a `write_bytes` whose debug-only precondition check is a CALL that
        // can panic — inside this window (`ForkWindowContractTests`). The literal has no
        // such edge.
        let mut empty: libc::sigset_t = 0;
        libc::sigemptyset(&raw mut empty);
        libc::sigprocmask(libc::SIG_SETMASK, &raw const empty, std::ptr::null_mut());
        // `wrapping_add`, not `+= 1`, for the same reason: a plain add emits an overflow check in a
        // debug build, and that check's failure arm is `core::panicking::panic_const_add_overflow`.
        // The counter cannot reach `i32::MAX` here — the point is that the CALL is not emitted.
        let mut signal_number = 1_i32;
        while signal_number <= 31 {
            libc::signal(signal_number, libc::SIG_DFL);
            signal_number = signal_number.wrapping_add(1);
        }

        // `login_tty(slave)`, spelled out: this is what makes the slave the CONTROLLING terminal,
        // so SIGWINCH and job control reach the shell. Written by hand rather than called, because
        // `login_tty` is not exposed for Darwin by the `libc` crate — and the three steps are the
        // whole of it.
        if libc::setsid() == -1 {
            libc::_exit(127);
        }
        if libc::ioctl(slave, libc::c_ulong::from(libc::TIOCSCTTY), 0) == -1 {
            libc::_exit(127);
        }
        if libc::dup2(slave, 0) == -1 || libc::dup2(slave, 1) == -1 || libc::dup2(slave, 2) == -1 {
            libc::_exit(127);
        }
        if slave > 2 {
            libc::close(slave);
        }

        // Best-effort chdir: the caller already validated the directory, so this normally succeeds.
        // A TOCTOU (directory deleted between validate and here) must NOT kill the pane — leave the
        // child in the inherited cwd rather than `_exit`ing into a dead pane.
        // `as usize != 0` rather than `.is_null()`: the latter is a real call in a debug build, and
        // no call may appear here (`fork_window_contract`). This compiles to a compare-and-branch.
        if cwd as usize != 0 {
            libc::chdir(cwd);
        }

        // The child must never hold the master, or its EOF would never arrive on superd's read.
        libc::close(master);

        libc::execve(path, argv, envp);
        // execve only returns on failure.
        libc::_exit(127)
    }
}

/// The master/slave pair from `openpty(3)`.
#[derive(Debug)]
struct Pty {
    master: OwnedFd,
    slave: OwnedFd,
}

/// `openpty` with slopdesk's cooked-mode termios and the requested window size.
#[expect(
    unsafe_code,
    reason = "openpty(3) is not wrapped for Darwin with a termios argument by nix"
)]
fn open_pty(rows: u16, cols: u16) -> Result<Pty, SpawnError> {
    let mut master: RawFd = -1;
    let mut slave: RawFd = -1;
    let mut term = cooked_termios();
    let mut size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: all four out-parameters are live locals of the right type for the duration.
    let result = unsafe {
        libc::openpty(
            &raw mut master,
            &raw mut slave,
            std::ptr::null_mut(),
            &raw mut term,
            &raw mut size,
        )
    };
    if result != 0 {
        return Err(SpawnError::Openpty(Errno::last()));
    }
    // Both ends, immediately. The master must not reach another pane's child (see `FORK_LOCK`);
    // the slave must not either, and marking it is free — the child's own `dup2(slave, 0/1/2)`
    // produces fresh descriptors that do NOT inherit the flag, which is exactly what stdio needs.
    set_cloexec(master);
    set_cloexec(slave);
    Ok(Pty {
        master: adopt(master),
        slave: adopt(slave),
    })
}

/// Sane cooked-mode termios: echo on, canonical mode, signals, CR/NL mapping, plus `IUTF8`
/// (correct backspace over a multi-byte character). The shell flips to raw mode itself when it
/// needs to. A byte-for-byte port of `ForkExecWindow.spawnPTY`'s block — the values are load-
/// bearing, not defaults.
fn cooked_termios() -> libc::termios {
    // Every field is set below or is a control character; zeroing first keeps the padding defined.
    let mut term: libc::termios = unsafe_zeroed_termios();
    term.c_iflag =
        tcflag(libc::ICRNL | libc::IXON | libc::IXANY | libc::IMAXBEL | libc::BRKINT | libc::IUTF8);
    term.c_oflag = tcflag(libc::OPOST | libc::ONLCR);
    term.c_cflag = tcflag(libc::CREAD | libc::CS8 | libc::HUPCL);
    term.c_lflag = tcflag(
        libc::ICANON
            | libc::ISIG
            | libc::IEXTEN
            | libc::ECHO
            | libc::ECHOE
            | libc::ECHOK
            | libc::ECHOKE
            | libc::ECHOCTL,
    );
    term.c_ispeed = libc::B38400;
    term.c_ospeed = libc::B38400;
    set_control_characters(&mut term);
    term
}

/// The standard control characters (`VINTR`, `VEOF`, `VERASE`, …), so cooked-mode editing behaves
/// like a normal login terminal.
fn set_control_characters(term: &mut libc::termios) {
    let mut set = |index: usize, value: u8| {
        if let Some(slot) = term.c_cc.get_mut(index) {
            *slot = value;
        }
    };
    set(libc::VEOF, 4); // ^D
    set(libc::VEOL, 0xFF);
    set(libc::VEOL2, 0xFF);
    set(libc::VERASE, 0x7F); // DEL
    set(libc::VWERASE, 23); // ^W
    set(libc::VKILL, 21); // ^U
    set(libc::VREPRINT, 18); // ^R
    set(libc::VINTR, 3); // ^C
    set(libc::VQUIT, 28); // ^\
    set(libc::VSUSP, 26); // ^Z
    set(libc::VDSUSP, 25); // ^Y
    set(libc::VSTART, 17); // ^Q
    set(libc::VSTOP, 19); // ^S
    set(libc::VLNEXT, 22); // ^V
    set(libc::VDISCARD, 15); // ^O
    set(libc::VMIN, 1);
    set(libc::VTIME, 0);
}

/// Clears `O_NONBLOCK` on `fd`.
#[expect(unsafe_code, reason = "fcntl(2) takes a variadic third argument")]
pub fn set_blocking(fd: RawFd) {
    // SAFETY: `fd` is open for the duration; both calls are plain fcntl commands.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK);
        }
    }
}

/// Marks `fd` close-on-exec, so no child superd forks later inherits it.
///
/// Every long-lived descriptor in this process wants this: a PTY master, a pump's wake pipe, a
/// listening socket, an accepted connection. The one exception is a descriptor deliberately being
/// handed to a child, and superd has none — the child's stdio comes from `dup2`, which clears the
/// flag on the copy.
#[expect(unsafe_code, reason = "F_SETFD has no nix wrapper taking a bare RawFd")]
pub fn set_cloexec(fd: RawFd) {
    // SAFETY: `fd` is open for the duration; both calls are plain fcntl commands.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}

/// The window size a terminal actually holds, pixel fields included.
///
/// Reading is unrestricted — it is an observation, and observations do not race.
///
/// # Errors
/// The `TIOCGWINSZ` errno.
#[expect(unsafe_code, reason = "TIOCGWINSZ has no nix wrapper taking a bare RawFd")]
pub fn window_size(terminal: RawFd) -> Result<libc::winsize, Errno> {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: `size` is a live local of the right type for the call, and a closed or non-terminal
    // descriptor is answered by the kernel with `EBADF`/`ENOTTY` rather than by misbehaving.
    let result = unsafe { libc::ioctl(terminal, libc::TIOCGWINSZ, &raw mut size) };
    if result == -1 {
        return Err(Errno::last());
    }
    Ok(size)
}

/// Sets a terminal's window size, which also delivers `SIGWINCH` to its foreground group.
///
/// **superd may not call this**, and the feature gate is how that is enforced rather than asked
/// for. `TIOCSWINSZ` after the spawn belongs to hostd and to hostd alone (`docs/51` §6.9): hostd is
/// the side that knows the client's PIXEL geometry, and a second writer on one terminal is a lost
/// update, not a duplicate. superd's `resize` verb only RECORDS the numbers hostd reports, and
/// `openpty` is given the initial size, so its spawn path needs no ioctl either.
///
/// Two crates enable `winsize-set`, and which kind of dependency they enable it on IS the rule.
/// `slopdesk-hostpane` is hostd's half of a pane — the one writer — so it enables it as an ordinary
/// dependency. superd enables it in `[dev-dependencies]` only, because its tests have to stand in
/// for hostd's ioctl to check that the recording is truthful: `cargo build --release` of the daemon
/// then does not compile this function at all, and a production caller inside superd is a link
/// failure rather than a review comment.
///
/// # Errors
/// The `TIOCSWINSZ` errno.
#[cfg(feature = "winsize-set")]
#[expect(unsafe_code, reason = "TIOCSWINSZ has no nix wrapper taking a bare RawFd")]
pub fn set_window_size(terminal: RawFd, size: libc::winsize) -> Result<(), Errno> {
    // SAFETY: `size` outlives the call and a bad descriptor is answered with an errno.
    let result = unsafe { libc::ioctl(terminal, libc::TIOCSWINSZ, &raw const size) };
    if result == -1 {
        return Err(Errno::last());
    }
    Ok(())
}

/// The foreground process group of a PTY master.
///
/// This is the primary zero-config agent-detection signal (`docs/50`), and it is a property of the
/// *terminal*, not of who opened it — so it keeps working on a master that arrived over
/// `SCM_RIGHTS`, in a process that never forked the child. That fact is why detection did not have
/// to move into superd.
///
/// # Errors
/// The `tcgetpgrp` errno.
#[expect(unsafe_code, reason = "tcgetpgrp on a raw fd")]
pub fn foreground_process_group(master: RawFd) -> Result<i32, Errno> {
    // SAFETY: `master` is a live PTY master fd.
    let group = unsafe { libc::tcgetpgrp(master) };
    if group == -1 {
        return Err(Errno::last());
    }
    Ok(group)
}

/// The DEVICE NUMBER of a PTY master's slave side — `ptsname` + `stat`.
///
/// This is what defines a pane's process SET. A process's controlling terminal is recorded in its
/// `proc_bsdinfo` as `e_tdev`, a device number and not a path, so "which processes belong to this
/// pane" is answered by comparing that field against this — never by walking names.
///
/// `None` for a descriptor that is not a master, and for a slave that has been unlinked. Both mean
/// the pane has no process set rather than that it has an empty one, but the census reports the
/// same empty list either way: a pane whose PTY is gone has no processes to show.
///
/// # Safety
/// `ptsname` answers a pointer into a static per-process buffer, valid until the next `ptsname` on
/// any thread — so it is copied into a `CString` before anything else runs, and never held. It is
/// checked for null first, and a null answer is the documented failure. `stat` fills the struct
/// whose pointer it is given; the local is fully initialised (zeroed) beforehand and read only when
/// the call reports success.
#[must_use]
#[expect(
    unsafe_code,
    reason = "ptsname and stat on a raw fd have no wrapper that answers st_rdev"
)]
pub fn slave_device(master: RawFd) -> Option<u32> {
    if master < 0 {
        return None;
    }
    // SAFETY: `master` is a live fd; the answer is a static buffer this copies out of immediately.
    let name = unsafe {
        let raw = libc::ptsname(master);
        if raw.is_null() {
            return None;
        }
        CStr::from_ptr(raw).to_owned()
    };
    // SAFETY: a fully-initialised local of exactly `stat`'s type, and a path that is live for the
    // call because `name` owns it. `stat` is a plain C struct of integers — all-zero is a valid
    // inhabitant, so a failed call cannot leave a field holding whatever was on the stack.
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    let got = unsafe { libc::stat(name.as_ptr(), &raw mut status) };
    if got != 0 {
        return None;
    }
    // `e_tdev` is a `u32` while `st_rdev` is a `dev_t`; the low 32 bits are the whole device number
    // on Darwin, and truncating is what makes the two fields comparable at all.
    Some(status.st_rdev.cast_unsigned())
}

/// Borrows the `char *` out of each `CString` and NUL-terminates the vector, the exact shape
/// `execve` takes. The returned pointers borrow `owned`, which must outlive them.
fn null_terminated(owned: &[CString]) -> Vec<*const libc::c_char> {
    let mut vector: Vec<*const libc::c_char> = Vec::with_capacity(owned.len() + 1);
    vector.extend(owned.iter().map(|value| value.as_ptr()));
    vector.push(std::ptr::null());
    vector
}

/// Takes ownership of a descriptor a C function just produced.
#[expect(unsafe_code, reason = "openpty returns raw fds")]
fn adopt(raw: RawFd) -> OwnedFd {
    // SAFETY: `openpty` just created this descriptor in this process and returned it once.
    unsafe { <OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(raw) }
}

/// `termios` has private padding on Darwin and no `Default`, so it is zeroed.
///
/// `pub(crate)` for [`crate::rawmode`], which fills one the same way from the other end of the same
/// terminal: this module builds the attributes a CHILD is born with, that one saves the attributes
/// a LOCAL terminal already had. Two zeroed `termios` literals would be the same line twice.
#[expect(unsafe_code, reason = "libc::termios is a plain C struct with no Default")]
pub(crate) const fn unsafe_zeroed_termios() -> libc::termios {
    // SAFETY: `termios` is a POD struct of integers; all-zero is a valid (if useless) value, and
    // every field that matters is overwritten by the caller.
    unsafe { std::mem::zeroed() }
}

/// Widens a control-flag constant to `tcflag_t` without an `as` cast clippy would reject.
const fn tcflag(value: libc::tcflag_t) -> libc::tcflag_t {
    value
}

/// Does this PTY master's line discipline mean "a person can see what they are typing"?
///
/// The host drives the client's automatic Secure Keyboard Entry off this: `false` means a hidden-
/// password prompt is up (`sudo`, `ssh`, `login`, `read -s`, `getpass`), and the client engages
/// `EnableSecureEventInput` for the duration. It is a HOST-side termios attribute the child sets
/// with `tcsetattr` and it is not in the output byte stream at all, so the client cannot derive it
/// — which is why there is a wire message for it (`docs/20`, type 31).
///
/// A negative descriptor, or a `tcgetattr` that declines, reads as echo-on. That default is the
/// safe one in one direction only: a probe error must never SPURIOUSLY lock a user's keyboard.
///
/// See [`echo_on`] for why the `ECHO` bit alone is the wrong question.
#[expect(
    unsafe_code,
    reason = "tcgetattr fills a local termios through a descriptor the caller owns"
)]
#[must_use]
pub fn echo_enabled(master_fd: RawFd) -> bool {
    if master_fd < 0 {
        return true;
    }
    let mut term = unsafe_zeroed_termios();
    // SAFETY: `term` is a live local of exactly the type the call fills, and `master_fd` is only
    // READ — the obligation is the caller's that it is a descriptor this process holds open, which
    // is `slopdesk-posix`'s usual one and local to this call.
    if unsafe { libc::tcgetattr(master_fd, &raw mut term) } != 0 {
        return true;
    }
    echo_on(
        term.c_lflag & tcflag(libc::ECHO) != 0,
        term.c_lflag & tcflag(libc::ICANON) != 0,
    )
}

/// Two termios local-mode bits, classified. `true` is the normal state; `false` is a secret.
///
/// ## Why `ECHO` alone is NOT the question
/// The naive rule — no-echo iff `ECHO` is cleared — is wrong for an interactive shell, because a
/// LINE EDITOR (zsh's `zle`, bash's readline) and every full-screen TUI (`vim`, `less`, `htop`)
/// also clear `ECHO`: they put the tty in RAW mode and echo characters THEMSELVES. So `tcgetattr`
/// at an ordinary idle prompt reads `ECHO` cleared, and an `ECHO`-only probe latched the client's
/// Secure-Input pill on every normal prompt. That was the live bug.
///
/// A genuine hidden-password prompt is different: it clears `ECHO` but stays CANONICAL — it reads a
/// whole line with echo suppressed by the line discipline. So `ICANON` is the discriminator, and
/// the rule is empirical rather than derived: an idle `zsh -i` prompt reads `ECHO=0 ICANON=0`; a
/// `read -s` or `sudo` prompt reads `ECHO=0 ICANON=1`.
///
/// Both bits arrive as `!= 0` rather than as `{0, 1}`, which is what a C flag word actually
/// promises.
#[must_use]
pub const fn echo_on(echo_bit_set: bool, canonical_bit_set: bool) -> bool {
    // The minimised form of "NOT (echo cleared AND still canonical)": a cooked child is echo-on
    // because it echoes, and a line editor is echo-on because it left canonical mode and does its
    // own echoing. Only the two together are a secret.
    echo_bit_set || !canonical_bit_set
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::io::Read as _;
    use std::os::fd::AsRawFd as _;

    use super::{
        SpawnPlan, echo_enabled, echo_on, foreground_process_group, open_pty, slave_device, spawn_pty,
        tcflag, unsafe_zeroed_termios,
    };

    /// One `read` on a master returns whatever the kernel has buffered at that instant, which is
    /// NOT the same as everything the child will ever write: the child is a separate process, so
    /// the first read can land before `execve` has produced a byte and answer a short prefix — or
    /// on a loaded machine, nothing at all. Asserting on it makes a scheduling race look like a
    /// broken `argv0`. Drain instead, until the NEEDLE arrives.
    ///
    /// The loop must not be ended by the child's exit, which is what it used to lean on: when the
    /// last slave closes, macOS FLUSHES the tty's output queue and the master answers `EIO`, so a
    /// child that finished before the parent's first read took its own output with it and this
    /// returned `""`. That is a scheduling race — it fired during a `just check` whose Swift half
    /// was compiling — dressed as a broken contract. Every caller therefore hands the child a
    /// trailing `sleep` and kills it afterwards, the same shape the two terminal-fact tests below
    /// already use, so the slave stays open and only the needle ends the loop.
    ///
    /// An implementation that never writes the needle hangs here rather than failing, which is the
    /// bargain the polls below make too: a deadline that a loaded machine can exhaust is a suite
    /// that goes red for being busy.
    ///
    /// `Interrupted` is RESUMED for the same reason. A blocking read on the master is exactly the
    /// syscall a signal lands in the middle of, and `std`'s `Read for File` hands `EINTR` back
    /// rather than retrying it — so a suite busy enough to be signalled read a scheduling artefact
    /// as an empty transcript. Only a real end of stream ends the loop without the needle.
    ///
    /// The end it stopped at is APPENDED to what it collected. A caller's assertion prints this
    /// string, and `""` names no cause at all — which is precisely the shape a flake arrives in.
    fn drain_until(file: &mut std::fs::File, needle: &str) -> String {
        let mut text = String::new();
        let mut buffer = [0_u8; 256];
        loop {
            match file.read(&mut buffer) {
                Err(why) if why.kind() == std::io::ErrorKind::Interrupted => {},
                Ok(0) => {
                    text.push_str("\n[master read: end of stream]");
                    return text;
                },
                Err(why) => {
                    text.push_str("\n[master read: ");
                    text.push_str(&why.to_string());
                    text.push(']');
                    return text;
                },
                Ok(got) => {
                    text.push_str(&String::from_utf8_lossy(buffer.get(..got).unwrap()));
                    if text.contains(needle) {
                        return text;
                    }
                },
            }
        }
    }

    /// Both terminal facts below become true only once the CHILD reaches `setsid` + `TIOCSCTTY`,
    /// and that is a different process on a machine which — during `just quick`, or the commit
    /// hook that runs every workspace's suite — is busy compiling. The fixed 200 × 10 ms budget
    /// these polls used to carry read that scheduling delay as a broken contract and failed the
    /// suite for it. Poll against a WALL-CLOCK deadline instead, generous enough that only a real
    /// failure can exhaust it: the loop leaves the instant the answer arrives, so a budget nobody
    /// needs costs nothing. The children sleep longer than the deadline on purpose — a child that
    /// exited first would take the fact being polled for with it.
    fn poll_for<T>(mut answer: impl FnMut() -> Option<T>) -> Option<T> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        loop {
            if let Some(value) = answer() {
                return Some(value);
            }
            if std::time::Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn plan<'a>(executable: &'a str, arguments: &'a [String]) -> SpawnPlan<'a> {
        SpawnPlan {
            executable,
            argv0: None,
            arguments,
            environment: &[],
            cwd: None,
            rows: 24,
            cols: 80,
        }
    }

    #[test]
    fn spawned_child_writes_to_the_pty_master() {
        // The `sleep` is what keeps the slave open past the parent's first read — see
        // `drain_until`.
        let arguments = vec!["-c".to_owned(), "echo 'hello superd'; sleep 60".to_owned()];
        let spawned = spawn_pty(&plan("/bin/sh", &arguments)).unwrap();

        let mut file = std::fs::File::from(spawned.master);
        let text = drain_until(&mut file, "hello superd");
        assert!(text.contains("hello superd"), "{text:?}");

        // Only the forking process may reap, and this test IS it.
        let _ignored = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(spawned.pid),
            nix::sys::signal::Signal::SIGKILL,
        );
        let _ignored = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(spawned.pid), None);
    }

    /// `argv0` must be honoured separately from the executable — a login shell needs the leading
    /// `-` and would otherwise silently start non-login.
    #[test]
    fn argv0_is_passed_independently_of_the_executable() {
        // The `sleep` is what keeps the slave open past the parent's first read — see
        // `drain_until`.
        let arguments = vec!["-c".to_owned(), "printf %s \"$0\"; sleep 60".to_owned()];
        let mut spawn_plan = plan("/bin/sh", &arguments);
        spawn_plan.argv0 = Some("-sh");
        let spawned = spawn_pty(&spawn_plan).unwrap();

        let mut file = std::fs::File::from(spawned.master);
        let text = drain_until(&mut file, "-sh");
        assert!(text.contains("-sh"), "{text:?}");
        let _ignored = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(spawned.pid),
            nix::sys::signal::Signal::SIGKILL,
        );
        let _ignored = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(spawned.pid), None);
    }

    /// The child must have the slave as its CONTROLLING terminal, or job control and SIGWINCH never
    /// reach it — and `tcgetpgrp`, the detection signal, would return nothing useful.
    #[test]
    fn child_owns_the_terminal_so_tcgetpgrp_answers() {
        let arguments = vec!["-c".to_owned(), "sleep 60".to_owned()];
        let spawned = spawn_pty(&plan("/bin/sh", &arguments)).unwrap();
        let master = spawned.master.as_raw_fd();

        // The foreground group is the child's own, because `setsid` + `TIOCSCTTY` ran — but the
        // child is a separate process, so poll rather than read once. Between the fork returning
        // and the child reaching `setsid`, the master has NO foreground group and `tcgetpgrp`
        // answers 0, which is not an error and must not be read as one.
        let group = poll_for(|| {
            match foreground_process_group(master).unwrap() {
                0 => None,
                answered => Some(answered),
            }
        });
        assert_eq!(
            group,
            Some(spawned.pid),
            "the child should lead its own foreground group"
        );

        let _ignored = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(spawned.pid),
            nix::sys::signal::Signal::SIGKILL,
        );
        let _ignored = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(spawned.pid), None);
    }

    /// The device number the master reports for its slave must be the one the CHILD carries as its
    /// controlling terminal, because comparing those two numbers is the entire definition of "the
    /// processes belonging to this pane". If they ever disagreed the census would be empty and the
    /// pane's process list would read as a pane with nothing running in it — a silent wrong answer,
    /// not an error.
    #[test]
    fn the_masters_slave_device_is_what_the_child_carries_as_its_terminal() {
        let arguments = vec!["-c".to_owned(), "sleep 60".to_owned()];
        let spawned = spawn_pty(&plan("/bin/sh", &arguments)).unwrap();
        let master = spawned.master.as_raw_fd();
        let device = slave_device(master).unwrap();

        // Same poll as above: the child has no controlling terminal until it reaches `TIOCSCTTY`.
        let child_device = poll_for(|| {
            crate::proc::tty_and_start(spawned.pid)
                .map(|(tty, _start)| tty)
                .filter(|tty| *tty == device)
        });
        assert_eq!(
            child_device,
            Some(device),
            "the child's e_tdev must equal the master's slave st_rdev"
        );

        let _ignored = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(spawned.pid),
            nix::sys::signal::Signal::SIGKILL,
        );
        let _ignored = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(spawned.pid), None);
    }

    /// A descriptor that is not a PTY master has no slave, and must say so rather than answer a
    /// device number the census would then match every process on the machine against.
    #[test]
    fn a_descriptor_that_is_not_a_master_has_no_slave_device() {
        assert_eq!(slave_device(-1), None);
        assert_eq!(slave_device(0), None);
    }

    /// A nonexistent binary must fail as a dead child, not as a hung parent. `execve` failing
    /// `_exit(127)`s, which closes the slave and gives the master EOF.
    #[test]
    fn missing_executable_exits_the_child_rather_than_hanging() {
        let arguments: Vec<String> = Vec::new();
        let spawned = spawn_pty(&plan("/nonexistent/slopdesk-superd-test", &arguments)).unwrap();
        let status = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(spawned.pid), None).unwrap();
        assert!(
            matches!(status, nix::sys::wait::WaitStatus::Exited(_, 127)),
            "{status:?}"
        );
    }

    #[test]
    fn interior_nul_is_refused_before_anything_forks() {
        let arguments: Vec<String> = Vec::new();
        let result = spawn_pty(&plan("/bin/ec\0ho", &arguments));
        assert!(matches!(result, Err(super::SpawnError::InteriorNul)));
    }

    // MARK: the echo probe
    //
    // These run against a REAL `openpty` master, which the hang-safety rule the Swift original
    // cited does not bar: `tcgetattr` is a property read on a descriptor this process already
    // holds. It does not block, it does not wait on a child, and — the part that mattered for the
    // Swift version — it is not a `read`, so it cannot steal a byte from superd, which owns `read`
    // on every PTY master. The shim was therefore "compiled and code-reviewed, never spun in a
    // test" for a reason that never applied to it. Here it is spun.

    /// The classifier, as a table. The `ECHO=0 ICANON=0` row is the one that used to latch the
    /// client's Secure-Input pill on an ordinary zsh prompt.
    #[test]
    fn the_classifier_tells_a_line_editor_from_a_password_prompt() {
        // A cooked child: echoing, canonical. Normal.
        assert!(echo_on(true, true));
        // A raw child that does its own echoing — a line editor or a full-screen TUI. Normal.
        assert!(echo_on(false, false));
        // `ECHO` set while raw: still nothing hidden.
        assert!(echo_on(true, false));
        // Canonical AND silent: the line discipline is suppressing echo. THIS is the secret.
        assert!(!echo_on(false, true));
    }

    /// A freshly opened master carries `cooked_termios`, which sets both bits — so the probe reads
    /// the same "normal" a person at a shell prompt would expect.
    #[test]
    fn a_cooked_master_reads_as_echo_on() {
        let pty = open_pty(24, 80).unwrap();
        assert!(echo_enabled(pty.master.as_raw_fd()));
    }

    /// Clear `ECHO` on the line discipline while leaving it CANONICAL — which is exactly what
    /// `getpass(3)` does — and the probe reports a secret. Restoring the bit takes it back.
    ///
    /// The write goes through the MASTER because master and slave share one line discipline, which
    /// is the same reason the live probe reads the master rather than opening the slave again.
    #[expect(
        unsafe_code,
        reason = "the fixture has to SET the line discipline the probe reads, and tcsetattr is the only way \
                  to say it"
    )]
    #[test]
    fn a_canonical_master_with_echo_cleared_reads_as_a_secret() {
        let pty = open_pty(24, 80).unwrap();
        let fd = pty.master.as_raw_fd();
        let mut term = unsafe_zeroed_termios();
        // SAFETY: `term` is a live local of the right type and `fd` is a descriptor this test
        // holds.
        assert_eq!(unsafe { libc::tcgetattr(fd, &raw mut term) }, 0);
        assert!(
            term.c_lflag & tcflag(libc::ICANON) != 0,
            "the fixture starts canonical"
        );

        term.c_lflag &= !tcflag(libc::ECHO);
        // SAFETY: same descriptor, and `term` was filled by the matching `tcgetattr` above.
        assert_eq!(unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw const term) }, 0);
        assert!(
            !echo_enabled(fd),
            "canonical with ECHO cleared is a password prompt"
        );

        term.c_lflag |= tcflag(libc::ECHO);
        // SAFETY: as above.
        assert_eq!(unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw const term) }, 0);
        assert!(echo_enabled(fd), "restoring ECHO ends the prompt");
    }

    /// Every way the probe can fail reads as echo-on, because the alternative is locking a user's
    /// keyboard over a bad descriptor.
    #[test]
    fn a_descriptor_the_probe_cannot_read_is_echo_on() {
        assert!(echo_enabled(-1), "a negative fd never reaches the syscall");
        assert!(echo_enabled(i32::MAX), "EBADF is not a secret");
        // A real descriptor that is not a terminal at all — `tcgetattr` answers ENOTTY.
        let file = std::fs::File::open("/dev/null").unwrap();
        assert!(echo_enabled(file.as_raw_fd()), "ENOTTY is not a secret either");
    }
}
