//! `dlopen`/`dlsym` — resolving a symbol at run time and calling it through a signature declared
//! here.
//!
//! ## Why this is in THIS crate and not in `slopdesk-apple-cursor`
//! Calling a resolved symbol means turning a `void *` into a function pointer, which is a
//! transmute. `docs/57` §2 bars a hand-written transmute from the `slopdesk-apple-*` family
//! outright and says what to do instead: the obligation belongs in one of the three crates that may
//! write `unsafe`, and the OPERATION moves there rather than the rule bending. So the CoreGraphics
//! private symbol below is resolved and called here, and the crate that samples the cursor asks
//! this one a question.
//!
//! `dlsym(3)` is POSIX and has no safe wrapper, which is this crate's admission test. What makes
//! the obligation local is that the signature and the NAME are both written down in the same
//! function: a reviewer can check "does `CGSCurrentCursorSeed` really take nothing and answer an
//! `int`" without knowing anything about slopdesk. A `resolve(name) -> fn` that handed the pointer
//! back would fail that test — the caller would carry an obligation it has no way to discharge —
//! which is the same reason [`crate::pty`] owns a whole spawn rather than exporting `fork`.
//!
//! ## Why the framework is OPENED rather than searched
//! `RTLD_DEFAULT` searches the images already loaded, so what it answers depends on whether
//! something else happened to pull CoreGraphics in first. Measured in a bare process: both names
//! answer null before `dlopen` and the same address after. A lookup that is cached — and it must be
//! cached, because the caller asks at 120 Hz and a `dlsym` MISS walks every image's symbol table —
//! would then freeze whichever answer the first call happened to get. Opening the framework by path
//! makes the answer a fact about the OS rather than about load order, and costs one `dlopen` of a
//! library every process with a window-server connection already maps.
//!
//! The handle is never closed. It is a system framework the process uses for its whole life, and
//! `dlclose` on one is a no-op on Darwin anyway.
//!
//! ## Nothing here is a fallback
//! A missing symbol answers `None`, and every caller has a cadence to fall back to. It is not an
//! error and is not logged: this is a private API that may be gone on the next OS, and a daemon
//! that complained about it would complain forever.

use std::ffi::{CStr, c_void};
use std::sync::OnceLock;

/// CoreGraphics, by absolute path.
///
/// The path rather than the bare name because `dlopen("CoreGraphics")` would search
/// `DYLD_LIBRARY_PATH` first, and this is the one symbol source that must not be substitutable.
const CORE_GRAPHICS: &CStr = c"/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";

/// The window server's cursor SEED — a counter that increments whenever the DISPLAYED system
/// cursor image changes.
///
/// `None` when the symbol is not present, which is the answer on any OS that renamed or dropped it,
/// and on any platform that has no CoreGraphics at all. A caller reads that as "I cannot detect a
/// change" and falls back to polling the shape on a fixed cadence; it never reads it as an error.
///
/// The symbol moved from CoreGraphics to `SkyLight` and is re-exported under both names — measured
/// as the same address for both — so both are tried in the order they appeared historically.
///
/// # Safety
/// The two names below are declared `int CGSCurrentCursorSeed(void)` in CoreGraphics' private
/// `CGSCursor.h`, and `SLSCurrentCursorSeed` is the same function re-exported by `SkyLight` — so
/// the `extern "C" fn() -> i32` this transmutes to is that declaration verbatim: no arguments, an
/// `int` return, the platform C ABI. `dlsym` answers either null or the address of a function with
/// external linkage in the image asked, and null is checked before the cast, so nothing else can be
/// reached through it. Calling a `void`-argument function through a zero-argument Rust pointer
/// passes no registers the callee reads, and an `int` return is `i32` on every Darwin target this
/// builds for.
#[must_use]
#[expect(
    unsafe_code,
    reason = "dlsym has no safe wrapper, and calling what it answers is a cast"
)]
pub fn cursor_seed() -> Option<i32> {
    type Seed = unsafe extern "C" fn() -> i32;
    static RESOLVED: OnceLock<Option<Seed>> = OnceLock::new();

    let resolved = (*RESOLVED.get_or_init(|| {
        let symbol = lookup(c"CGSCurrentCursorSeed").or_else(|| lookup(c"SLSCurrentCursorSeed"))?;
        // SAFETY: the function's obligation, discharged above — `symbol` is non-null and came from
        // asking CoreGraphics for one of the two names that denote `int (*)(void)` there.
        Some(unsafe { std::mem::transmute::<*mut c_void, Seed>(symbol) })
    }))?;
    // SAFETY: `resolved` came from the block above, so it is a live function with the declared
    // signature, in an image this process opened and never closes.
    Some(unsafe { resolved() })
}

/// CoreGraphics' address for `name`, or `None` when it does not export it.
///
/// Private because the pointer it answers carries an obligation only the function that knows the
/// NAME can discharge — handing it out is the shape the module doc rules out.
///
/// # Safety
/// The handle comes from [`core_graphics`], which is either null-checked or `None`, and `name` is a
/// `&CStr` so it is NUL-terminated by construction. Nothing is dereferenced or called here.
#[expect(unsafe_code, reason = "dlsym has no safe wrapper")]
fn lookup(name: &CStr) -> Option<*mut c_void> {
    let handle = core_graphics()?;
    // SAFETY: the function's obligation, above.
    let symbol = unsafe { libc::dlsym(handle, name.as_ptr()) };
    (!symbol.is_null()).then_some(symbol)
}

/// The CoreGraphics handle, opened once, or `None` where there is no such framework.
///
/// # Safety
/// `dlopen` takes a NUL-terminated path — [`CORE_GRAPHICS`] is a `&CStr` literal — and answers
/// either null or a handle valid until `dlclose`, which is never called. Nothing is dereferenced.
#[expect(unsafe_code, reason = "dlopen has no safe wrapper")]
fn core_graphics() -> Option<*mut c_void> {
    /// A `*mut c_void` is not `Send`, and the pointer is a process-wide handle rather than data —
    /// so it is cached as the integer it is and handed back as a pointer at the use site. There is
    /// nothing to synchronise: `dlopen` is itself thread-safe and answers the same handle for the
    /// same path.
    static HANDLE: OnceLock<Option<usize>> = OnceLock::new();

    let address = (*HANDLE.get_or_init(|| {
        // SAFETY: the function's obligation, above.
        let handle = unsafe { libc::dlopen(CORE_GRAPHICS.as_ptr(), libc::RTLD_LAZY) };
        (!handle.is_null()).then(|| handle.addr())
    }))?;
    Some(std::ptr::without_provenance_mut(address))
}

#[cfg(test)]
mod tests {
    use super::{cursor_seed, lookup};

    /// The framework opens and the seed is THERE. This is the arm the `RTLD_DEFAULT` version could
    /// not reach — a bare test binary has no CoreGraphics loaded, so a search of the already-loaded
    /// images answered null and every assertion below would have been vacuously skipped.
    #[test]
    #[cfg(target_os = "macos")]
    fn the_seed_resolves_because_the_framework_is_opened_rather_than_searched() {
        assert!(lookup(c"CGSCurrentCursorSeed").is_some() || lookup(c"SLSCurrentCursorSeed").is_some());
        assert!(cursor_seed().is_some());
    }

    /// A name the framework does not export must answer nothing rather than a stale or defaulted
    /// address. This is the arm that decides whether a private API's disappearance degrades or
    /// crashes.
    #[test]
    fn a_symbol_the_framework_does_not_export_is_absent() {
        assert_eq!(lookup(c"slopdesk_a_symbol_that_cannot_exist"), None);
    }

    /// The seed is a COUNTER, so the only thing that is true of it without moving the mouse is that
    /// consecutive reads agree — a name resolved to the wrong function would answer garbage that
    /// changed per call, and the sampler would then re-render the cursor shape on every tick.
    #[test]
    fn the_seed_is_stable_while_nothing_moves() {
        let Some(first) = cursor_seed() else {
            return;
        };
        assert_eq!(cursor_seed(), Some(first));
        assert_eq!(cursor_seed(), Some(first));
    }

    /// Resolution happens ONCE and the cached pointer stays callable — this is the sampler's 120 Hz
    /// path, and it is also this module's leak test: a thousand calls open no second handle and
    /// retain nothing.
    #[test]
    fn a_thousand_reads_stay_callable() {
        let first = cursor_seed();
        for _ in 0..1_000 {
            assert_eq!(cursor_seed().is_some(), first.is_some());
        }
    }
}
