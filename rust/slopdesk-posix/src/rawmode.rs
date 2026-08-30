//! A LOCAL terminal's line discipline, and putting it back on every exit path.
//!
//! Ported whole from the deleted `SlopDeskTTY.TerminalRawMode`, whose contract this
//! module inherits: **the user's terminal must never be left in raw mode.** A process that dies
//! holding `cfmakeraw` attributes leaves a shell with no echo and no line editing, and the person
//! at the keyboard has no way to type the command that would fix it.
//!
//! ## Why this is an admission and not just three `tcsetattr` calls
//! [`attributes`], [`raw_attributes`] and [`set_attributes`] on their own are the ordinary
//! `slopdesk-posix` obligation — a bare `RawFd` the caller holds open, the same one
//! [`crate::pty::echo_enabled`] carries. The reason the module exists is the half below them: the
//! restore has to work from an ASYNCHRONOUS SIGNAL HANDLER, and that is a genuinely different
//! obligation.
//!
//! A handler may call only async-signal-safe functions. `tcsetattr(3)` is one; taking a lock is
//! not. A `Mutex` (or the `os_unfair_lock` the Swift used) held by the interrupted thread at the
//! instant the signal lands would self-deadlock the handler and hang the process WITH the terminal
//! still raw — the exact failure the module exists to prevent. So the handler reads three lock-free
//! atomics and calls one syscall, and the locked path below is fenced against it with
//! `pthread_sigmask`.
//!
//! ## What the handler reads, and why it cannot tear
//! The saved attributes reach the handler as an `AtomicPtr` to a LEAKED, never-mutated `termios`,
//! published with a `Release` store before `ACTIVE` becomes 1 and loaded with `Acquire` after
//! `ACTIVE` reads non-zero. The handler never dereferences it in Rust — it hands the pointer
//! straight to `tcsetattr`, which is what wants a `*const termios` anyway.
//!
//! That is stricter than the Swift, which mirrored the struct into a plain process-global the
//! handler read without any ordering at all. Its fence was `pthread_sigmask`, which is PER-THREAD:
//! a signal delivered to some other thread — and `slopdesk-client` has several — could read the
//! mirror mid-write. Publishing an immutable copy by pointer closes that, at the cost of one leaked
//! `termios` per entry into raw mode. A process enters raw mode once.

use std::os::fd::RawFd;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicI32, AtomicPtr, Ordering};
use std::sync::{Mutex, PoisonError};

use nix::errno::Errno;
use nix::sys::signal::{SaFlags, SigAction, SigHandler, SigSet, SigmaskHow, Signal, pthread_sigmask};

use crate::pty::unsafe_zeroed_termios;

/// The signals a restoring handler is installed for.
///
/// The four a terminal session actually dies of: `^C`, a `kill`, `^\`, and the hangup a closing
/// terminal window sends. `SIGKILL` and `SIGSEGV` are deliberately absent — the first cannot be
/// caught, and catching the second to touch shared state is how a crash becomes a hang.
const HANDLED: [Signal; 4] = [Signal::SIGINT, Signal::SIGTERM, Signal::SIGQUIT, Signal::SIGHUP];

/// What the terminal looked like before raw mode, for the NON-signal path.
#[derive(Clone, Copy)]
struct Saved {
    /// The attributes to write back.
    attributes: libc::termios,
    /// The descriptor they belong to.
    terminal: RawFd,
}

/// The authoritative record, and the lock that serialises [`enter`] against [`restore`].
///
/// The handler never touches this — see the module header for why a lock in a signal handler is the
/// bug rather than the fix.
static SAVED: Mutex<Option<Saved>> = Mutex::new(None);

/// The handler's copy of the attributes: leaked, immutable, published by pointer.
static SIGNAL_ATTRIBUTES: AtomicPtr<libc::termios> = AtomicPtr::new(null_mut());

/// The handler's copy of the descriptor.
static SIGNAL_TERMINAL: AtomicI32 = AtomicI32::new(-1);

/// 1 while raw mode is engaged, so the handler is a no-op otherwise.
///
/// The flag the restore RACES on: whoever swaps it 1 → 0 owns the `tcsetattr`, so a handler firing
/// while [`restore`] is midway through cannot write the attributes back twice.
static ACTIVE: AtomicI32 = AtomicI32::new(0);

// ---------------------------------------------------------------------------- //
// The pure primitives: one terminal, no process-global state.

/// A terminal's current attributes.
///
/// # Errors
/// `ENOTTY` when the descriptor is not a terminal — including when it is not open at all, which the
/// Swift this replaces also folded into its one `notATTY` case. Otherwise the `tcgetattr` errno.
#[expect(
    unsafe_code,
    reason = "isatty/tcgetattr have no nix wrapper taking a bare RawFd"
)]
pub fn attributes(terminal: RawFd) -> Result<libc::termios, Errno> {
    // SAFETY: `isatty` only inspects the descriptor table; a closed, bad or non-terminal descriptor
    // is answered with 0 rather than by misbehaving.
    if unsafe { libc::isatty(terminal) } == 0 {
        return Err(Errno::ENOTTY);
    }
    let mut term = unsafe_zeroed_termios();
    // SAFETY: `term` is a live local of exactly the type the call fills, and `terminal` is only
    // READ — the caller's obligation is that it is a descriptor this process holds open, which is
    // this crate's usual one and local to this call.
    if unsafe { libc::tcgetattr(terminal, &raw mut term) } != 0 {
        return Err(Errno::last());
    }
    Ok(term)
}

/// `original` with `cfmakeraw(3)` applied, then `VMIN = 1` / `VTIME = 0`.
///
/// `cfmakeraw` is what decides WHICH bits move — no echo, no canonical mode, no signal generation,
/// no CR/NL mapping, no output post-processing, 8 bits with no parity — and it is called rather
/// than spelled so this cannot drift from the libc that the shell on the other end was written
/// against.
///
/// The two control characters are set on top and are load-bearing: `VMIN = 1` with `VTIME = 0` is a
/// blocking read that returns the instant one byte arrives, which is the whole latency budget of a
/// keystroke relay. `cfmakeraw` already sets that pair on Darwin; writing it here is the assertion
/// that it stays true.
///
/// Note what is NOT restored afterwards: `ISIG` stays cleared. `^C` is delivered to the REMOTE pty
/// as a byte, where that shell's own line discipline raises the signal; the local disconnect key is
/// `^]`, read out of the byte stream by the caller, not a signal.
#[expect(unsafe_code, reason = "cfmakeraw(3) fills a termios through a pointer")]
#[must_use]
pub fn raw_attributes(original: libc::termios) -> libc::termios {
    let mut raw = original;
    // SAFETY: `raw` is a live local of exactly the type `cfmakeraw` rewrites, and the call touches
    // nothing else.
    unsafe { libc::cfmakeraw(&raw mut raw) };
    if let Some(slot) = raw.c_cc.get_mut(libc::VMIN) {
        *slot = 1;
    }
    if let Some(slot) = raw.c_cc.get_mut(libc::VTIME) {
        *slot = 0;
    }
    raw
}

/// Applies `attributes` to `terminal` with `TCSAFLUSH`.
///
/// `TCSAFLUSH` rather than `TCSANOW`: the change waits for pending output to drain and then
/// DISCARDS unread input, so a keystroke typed under the old discipline is not re-interpreted under
/// the new one.
///
/// # Errors
/// The `tcsetattr` errno.
#[expect(unsafe_code, reason = "tcsetattr has no nix wrapper taking a bare RawFd")]
pub fn set_attributes(terminal: RawFd, attributes: &libc::termios) -> Result<(), Errno> {
    // SAFETY: `attributes` is a live reference for the whole call and is only READ; a closed or
    // non-terminal descriptor is answered with an errno.
    if unsafe { libc::tcsetattr(terminal, libc::TCSAFLUSH, attributes) } != 0 {
        return Err(Errno::last());
    }
    Ok(())
}

// ---------------------------------------------------------------------------- //
// The process-global half.

/// Puts `terminal` into raw mode, saving what it looked like first.
///
/// Returns the SAVED attributes, so a caller can restore them itself.
///
/// **Entering twice is idempotent, and that is a deliberate divergence from the Swift.** The Swift
/// re-read the terminal on every call and overwrote its saved copy with whatever it found — which,
/// on a second entry, is the RAW set it wrote itself. The restore then wrote raw attributes back
/// and reported success, leaving the terminal broken with every test still green. Here a second
/// entry answers the first entry's saved attributes and touches no state.
///
/// # Errors
/// `ENOTTY` when `terminal` is not a terminal, or the `tcgetattr`/`tcsetattr` errno. A failure to
/// apply the raw attributes rolls the saved state back, so a caller that retries is not restoring
/// against a terminal it never changed.
pub fn enter(terminal: RawFd) -> Result<libc::termios, Errno> {
    // Before the fence, because it can fail and a failure must leave nothing behind.
    let original = attributes(terminal)?;

    // Block the handled signals across the whole critical section: a signal delivered mid-update
    // must not run the handler against a half-published mirror, and it must not land on the thread
    // holding the lock.
    let blocked = BlockedSignals::block();
    let mut record = SAVED.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(existing) = *record {
        return Ok(existing.attributes);
    }
    *record = Some(Saved {
        attributes: original,
        terminal,
    });
    publish_to_handler(original, terminal);
    drop(record);

    let raw = raw_attributes(original);
    if let Err(failure) = set_attributes(terminal, &raw) {
        // Could not actually enter raw mode: retract, so nothing later writes attributes back to a
        // terminal this call never changed.
        let mut record = SAVED.lock().unwrap_or_else(PoisonError::into_inner);
        *record = None;
        drop(record);
        ACTIVE.store(0, Ordering::Release);
        return Err(failure);
    }
    drop(blocked);
    Ok(original)
}

/// Writes the saved attributes back. Idempotent, and a no-op when raw mode was never entered.
///
/// This is the NON-signal path. The handler uses its own lock-free one — see the module header.
pub fn restore() {
    let _blocked = BlockedSignals::block();
    let mut record = SAVED.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(saved) = record.take() else {
        return;
    };
    // Whoever swaps this 1 → 0 owns the write-back. A handler that got there first has already
    // restored the terminal, and a second `tcsetattr` with the same attributes would be harmless
    // anyway — but the swap is what makes that a fact rather than a hope.
    let was_active = ACTIVE.swap(0, Ordering::AcqRel);
    drop(record);
    if was_active == 0 {
        return;
    }
    // Outside the lock: the syscall can block until pending output drains, and nothing it touches
    // is shared.
    let _ignored = set_attributes(saved.terminal, &saved.attributes);
}

/// Whether raw mode is currently engaged.
#[must_use]
pub fn is_raw() -> bool {
    ACTIVE.load(Ordering::Acquire) != 0
}

/// Installs handlers for [`HANDLED`] that restore the terminal and then die of the signal.
///
/// Safe to call BEFORE [`enter`], and that is the point: the handler is a no-op while raw mode is
/// not engaged, so installing first closes the window where a `SIGTERM` arriving after the raw
/// attributes took effect but before a handler existed would kill the process with the terminal
/// broken.
///
/// `sa_mask` blocks all four while the handler runs, so a second `SIGTERM` cannot pre-empt a
/// restore in progress. `sigaction(2)` rather than `signal(3)`, for the portable semantics.
#[expect(
    unsafe_code,
    reason = "sigaction's wrapper is unsafe: what the handler may call is the caller's obligation"
)]
pub fn restore_on_signals() {
    let action = SigAction::new(
        SigHandler::Handler(restore_and_reraise),
        SaFlags::empty(),
        handled_set(),
    );
    for signal in HANDLED {
        // SAFETY: `restore_and_reraise` calls only `tcsetattr`, `signal` and `raise`, each of which
        // POSIX lists as async-signal-safe, and reads only lock-free atomics. It allocates nothing,
        // takes no lock and can neither unwind nor return into Rust code that would.
        let _ignored = unsafe { nix::sys::signal::sigaction(signal, &action) };
    }
}

/// The installed handler: put the terminal back, then die the way the signal meant.
///
/// Re-raising under the DEFAULT disposition is what makes the exit status truthful — a process
/// killed by `SIGTERM` must look killed by `SIGTERM` to whatever is waiting on it, not exit 0.
extern "C" fn restore_and_reraise(signal: libc::c_int) {
    restore_from_signal_handler();
    reraise_with_default_disposition(signal);
}

/// `SIG_DFL` then `raise`, in a handler.
#[expect(
    unsafe_code,
    reason = "signal(3)/raise(3) have no nix wrapper that is callable from a handler"
)]
fn reraise_with_default_disposition(signal: libc::c_int) {
    // SAFETY: both calls are on POSIX's async-signal-safe list. `SIG_DFL` is a valid disposition
    // for every signal, and `raise` on the signal currently being handled is delivered when the
    // handler returns and the mask that `sa_mask` installed is lifted.
    unsafe {
        libc::signal(signal, libc::SIG_DFL);
        libc::raise(signal);
    }
}

/// The async-signal-safe restore: three atomic loads and one syscall, no lock anywhere.
#[expect(
    unsafe_code,
    reason = "tcsetattr from a signal handler is what this module exists to make sound"
)]
fn restore_from_signal_handler() {
    if ACTIVE.swap(0, Ordering::AcqRel) == 0 {
        return;
    }
    let terminal = SIGNAL_TERMINAL.load(Ordering::Acquire);
    let attributes = SIGNAL_ATTRIBUTES.load(Ordering::Acquire);
    if terminal < 0 || attributes.is_null() {
        return;
    }
    // SAFETY: `attributes` points at a leaked `termios` that was fully written before it was
    // published, is never mutated afterwards, and outlives the process; the `Acquire` load here
    // pairs with the `Release` store in `publish_to_handler`, so the write is visible. `tcsetattr`
    // only reads through it, and is async-signal-safe.
    let _ignored = unsafe { libc::tcsetattr(terminal, libc::TCSAFLUSH, attributes) };
}

/// Hands the handler an immutable copy of what it will have to write back.
///
/// The store ORDER is the contract: the attributes and the descriptor are published before `ACTIVE`
/// becomes 1, so a handler that sees `ACTIVE == 1` cannot then read a stale descriptor or a null
/// pointer.
fn publish_to_handler(attributes: libc::termios, terminal: RawFd) {
    // Leaked on purpose: the handler may run at any instant until the process ends, so there is no
    // moment at which freeing this would be safe. One `termios` per entry into raw mode, and a
    // process enters once.
    let published: &'static mut libc::termios = Box::leak(Box::new(attributes));
    SIGNAL_ATTRIBUTES.store(published, Ordering::Release);
    SIGNAL_TERMINAL.store(terminal, Ordering::Release);
    ACTIVE.store(1, Ordering::Release);
}

/// The four handled signals as a set, for a mask.
fn handled_set() -> SigSet {
    let mut set = SigSet::empty();
    for signal in HANDLED {
        set.add(signal);
    }
    set
}

/// Blocks the handled signals on this thread for as long as it lives.
///
/// The fence around the locked critical sections: while one is held, a handler on THIS thread
/// cannot run, so it cannot observe a half-updated record. Cross-thread delivery is covered by the
/// publication order instead — see the module header.
struct BlockedSignals(SigSet);

impl BlockedSignals {
    /// Blocks, remembering the mask to put back.
    fn block() -> Self {
        let mut previous = SigSet::empty();
        let _ignored = pthread_sigmask(SigmaskHow::SIG_BLOCK, Some(&handled_set()), Some(&mut previous));
        Self(previous)
    }
}

impl Drop for BlockedSignals {
    fn drop(&mut self) {
        let _ignored = pthread_sigmask(SigmaskHow::SIG_SETMASK, Some(&self.0), None);
    }
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::os::fd::RawFd;
    use std::sync::{Mutex, MutexGuard, PoisonError};

    use nix::errno::Errno;

    use super::{
        attributes, enter, is_raw, raw_attributes, restore, restore_from_signal_handler, set_attributes,
    };

    /// The process-global tests mutate ONE terminal discipline between them, and `cargo test` runs
    /// a module's tests on several threads. Without this they would interleave and the failures
    /// would read as flakes.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn serialised() -> MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A real pty pair — the only fixture that answers `isatty` and honours `tcsetattr`.
    #[expect(
        unsafe_code,
        reason = "openpty(3) is the fixture; nix's wrapper is behind a feature this crate does not take"
    )]
    fn open_pty_pair() -> (RawFd, RawFd) {
        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;
        // SAFETY: both out-parameters are live locals of the right type for the call, and the three
        // optional arguments are legally null.
        let result = unsafe {
            libc::openpty(
                &raw mut master,
                &raw mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(result, 0, "openpty: {}", Errno::last());
        (master, slave)
    }

    /// Closes a descriptor the fixture opened.
    #[expect(unsafe_code, reason = "the fixture's own openpty descriptors")]
    fn close(fd: RawFd) {
        // SAFETY: `fd` came from this module's `open_pty_pair` and is closed exactly once.
        let _ignored = unsafe { libc::close(fd) };
    }

    /// A pipe read end — a real descriptor that is emphatically not a terminal.
    #[expect(unsafe_code, reason = "pipe(2) is the fixture")]
    fn open_pipe() -> (RawFd, RawFd) {
        let mut ends: [RawFd; 2] = [-1, -1];
        // SAFETY: `ends` is a live local array of exactly the two ints `pipe` fills.
        let result = unsafe { libc::pipe(ends.as_mut_ptr()) };
        assert_eq!(result, 0, "pipe: {}", Errno::last());
        (ends.first().copied().unwrap(), ends.get(1).copied().unwrap())
    }

    /// `cfmakeraw` really clears the two bits a person would notice, and the control characters
    /// land. A `raw_attributes` that quietly returned its argument would leave the keystroke
    /// relay echoing every character twice and reading a line at a time.
    #[test]
    fn raw_attributes_clear_echo_and_canonical_mode() {
        let (master, slave) = open_pty_pair();
        let cooked = attributes(slave).unwrap();
        let raw = raw_attributes(cooked);

        assert_ne!(cooked.c_lflag, raw.c_lflag, "cfmakeraw must move local flags");
        assert_eq!(raw.c_lflag & libc::ECHO, 0, "raw mode must clear ECHO");
        assert_eq!(raw.c_lflag & libc::ICANON, 0, "raw mode must clear ICANON");
        assert_eq!(raw.c_cc.get(libc::VMIN).copied(), Some(1), "VMIN must be 1");
        assert_eq!(raw.c_cc.get(libc::VTIME).copied(), Some(0), "VTIME must be 0");

        close(master);
        close(slave);
    }

    /// The round trip is byte-exact on all four flag words. "Mostly restored" is a terminal the
    /// user still has to fix by hand.
    #[test]
    fn applying_and_restoring_returns_the_exact_attributes() {
        let (master, slave) = open_pty_pair();
        let cooked = attributes(slave).unwrap();

        set_attributes(slave, &raw_attributes(cooked)).unwrap();
        let while_raw = attributes(slave).unwrap();
        assert_eq!(while_raw.c_lflag & libc::ECHO, 0, "ECHO off once raw is applied");

        set_attributes(slave, &cooked).unwrap();
        let restored = attributes(slave).unwrap();
        assert_eq!(restored.c_iflag, cooked.c_iflag);
        assert_eq!(restored.c_oflag, cooked.c_oflag);
        assert_eq!(restored.c_cflag, cooked.c_cflag);
        assert_eq!(restored.c_lflag, cooked.c_lflag);
        assert_eq!(restored.c_cc, cooked.c_cc);

        close(master);
        close(slave);
    }

    /// A descriptor that is not a terminal is `ENOTTY`, not a silent success that would then be
    /// "restored" over the caller's stdin.
    #[test]
    fn a_pipe_is_not_a_terminal() {
        let (read_end, write_end) = open_pipe();
        assert_eq!(attributes(read_end), Err(Errno::ENOTTY));
        close(read_end);
        close(write_end);
    }

    /// A descriptor that is not open at all reads the same way, which is the one case the Swift
    /// folded into `notATTY` and this keeps.
    #[test]
    fn a_closed_descriptor_is_not_a_terminal_either() {
        assert_eq!(attributes(-1), Err(Errno::ENOTTY));
    }

    /// `enter` really changes the terminal and `restore` really puts it back — the whole promise,
    /// end to end, on a descriptor a test can read.
    #[test]
    fn entering_and_restoring_round_trips_the_terminal() {
        let _serial = serialised();
        let (master, slave) = open_pty_pair();
        let cooked = attributes(slave).unwrap();

        let saved = enter(slave).unwrap();
        assert_eq!(
            saved.c_lflag, cooked.c_lflag,
            "enter answers the COOKED attributes"
        );
        assert!(is_raw());
        assert_eq!(attributes(slave).unwrap().c_lflag & libc::ECHO, 0);

        restore();
        assert!(!is_raw());
        assert_eq!(attributes(slave).unwrap().c_lflag, cooked.c_lflag);

        close(master);
        close(slave);
    }

    /// **The regression the Swift had.** A second `enter` while already raw must not adopt the RAW
    /// attributes as the thing to restore — that is how a session ends with a terminal nobody can
    /// type into. It answers the first entry's cooked set, and the restore is still exact.
    #[test]
    fn entering_twice_does_not_adopt_the_raw_attributes_as_the_saved_ones() {
        let _serial = serialised();
        let (master, slave) = open_pty_pair();
        let cooked = attributes(slave).unwrap();

        let first = enter(slave).unwrap();
        let second = enter(slave).unwrap();
        assert_eq!(
            second.c_lflag, first.c_lflag,
            "a re-entry answers the first entry's saved attributes"
        );
        assert_eq!(second.c_lflag, cooked.c_lflag);

        restore();
        assert_eq!(
            attributes(slave).unwrap().c_lflag,
            cooked.c_lflag,
            "the terminal is COOKED after one restore, however many entries there were"
        );

        close(master);
        close(slave);
    }

    /// Restoring twice, or without ever entering, is a no-op rather than a `tcsetattr` against a
    /// descriptor this module never touched.
    #[test]
    fn restoring_is_idempotent_and_a_no_op_when_never_entered() {
        let _serial = serialised();
        restore();
        assert!(!is_raw());

        let (master, slave) = open_pty_pair();
        let cooked = attributes(slave).unwrap();
        enter(slave).unwrap();
        restore();
        restore();
        assert_eq!(attributes(slave).unwrap().c_lflag, cooked.c_lflag);

        close(master);
        close(slave);
    }

    /// Entering against something that is not a terminal fails and leaves NO state behind — a later
    /// `restore` must not write attributes back to a descriptor this module never changed.
    #[test]
    fn a_failed_entry_leaves_nothing_to_restore() {
        let _serial = serialised();
        let (read_end, write_end) = open_pipe();
        assert_eq!(enter(read_end), Err(Errno::ENOTTY));
        assert!(!is_raw());
        restore();
        close(read_end);
        close(write_end);
    }

    /// The SIGNAL path, driven directly. Raising a real `SIGTERM` here would re-raise under
    /// `SIG_DFL` and kill the test binary, so what is exercised is the half that is actually
    /// delicate: the lock-free restore the handler performs before it dies.
    #[test]
    fn the_signal_handlers_restore_reaches_the_terminal_without_the_lock() {
        let _serial = serialised();
        let (master, slave) = open_pty_pair();
        let cooked = attributes(slave).unwrap();
        enter(slave).unwrap();
        assert_eq!(attributes(slave).unwrap().c_lflag & libc::ECHO, 0);

        restore_from_signal_handler();
        assert!(!is_raw(), "the handler clears the flag it swapped");
        assert_eq!(
            attributes(slave).unwrap().c_lflag,
            cooked.c_lflag,
            "the handler's tcsetattr put the cooked attributes back"
        );

        // And the non-signal path afterwards is a no-op rather than a second write-back.
        restore();
        assert_eq!(attributes(slave).unwrap().c_lflag, cooked.c_lflag);

        close(master);
        close(slave);
    }

    /// The handler with nothing saved does nothing at all — it is installed BEFORE raw mode is
    /// entered, so this is its normal state for most of a process's life.
    #[test]
    fn the_handlers_restore_is_a_no_op_before_raw_mode() {
        let _serial = serialised();
        restore();
        restore_from_signal_handler();
        assert!(!is_raw());
    }
}
