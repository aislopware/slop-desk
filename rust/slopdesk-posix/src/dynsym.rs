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
//! something else happened to pull the framework in first. Measured in a bare process: every name
//! below answers null before `dlopen` and a real address after. A lookup that is cached — and it
//! must be cached, because the cursor caller asks at 120 Hz and a `dlsym` MISS walks every image's
//! symbol table — would then freeze whichever answer the first call happened to get. Opening the
//! framework by path makes the answer a fact about the OS rather than about load order, and costs
//! one `dlopen` of a library every process with a window-server connection already maps.
//!
//! Each symbol names the image that actually EXPORTS it, measured rather than assumed: the cursor
//! seed is CoreGraphics', and `_AXUIElementGetWindow` is HIServices' — opening CoreGraphics and
//! asking it for the AX symbol answers null, so a single shared handle would have made the AX door
//! permanently dead.
//!
//! A handle is never closed. These are system frameworks the process uses for its whole life, and
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
/// `DYLD_LIBRARY_PATH` first, and these symbol sources must not be substitutable.
const CORE_GRAPHICS: &CStr = c"/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";

/// `HIServices`, the `ApplicationServices` sub-framework that owns the Accessibility client API —
/// and the only image that exports [`ax_window_id`]'s symbol. Probed: CoreGraphics does not.
const HI_SERVICES: &CStr =
    c"/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices";

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
        let symbol = lookup(&CORE_GRAPHICS_HANDLE, CORE_GRAPHICS, c"CGSCurrentCursorSeed")
            .or_else(|| lookup(&CORE_GRAPHICS_HANDLE, CORE_GRAPHICS, c"SLSCurrentCursorSeed"))?;
        // SAFETY: the function's obligation, discharged above — `symbol` is non-null and came from
        // asking CoreGraphics for one of the two names that denote `int (*)(void)` there.
        Some(unsafe { std::mem::transmute::<*mut c_void, Seed>(symbol) })
    }))?;
    // The call is CoreGraphics', so no fork may land inside it — see `crate::pty::FORK_LOCK`, which
    // holds the measurement. One uncontended lock against a window-server round trip.
    Some(crate::pty::while_no_fork_is_taken(||
        // SAFETY: `resolved` came from the block above, so it is a live function with the declared
        // signature, in an image this process opened and never closes.
        unsafe { resolved() }))
}

/// The `CGWindowID` of an Accessibility window element, or `None` when it cannot be had.
///
/// `element` must be a live `AXUIElement` denoting a WINDOW — the caller owns the reference for the
/// duration of the call. There is no public AX↔`CGWindowID` map, so every window the host tracks by
/// `CGWindowID` is matched to its AX element through this one private symbol; a frame-equality
/// match is the alternative and it mis-binds whenever two windows share an origin, which the
/// virtual display manufactures on purpose.
///
/// `None` covers four different failures on purpose, because every caller treats them the same way:
/// the symbol is gone, the element is not a window, the call failed, or it "succeeded" and wrote
/// zero. That last one is real — on macOS 15+ with the screen locked the SPI answers success and
/// leaves the id at zero (`AeroSpace` #445) — and a caller that trusted it would bind every window
/// in the app to id zero at once.
///
/// # Safety
/// `element` must be a live `AXUIElement`. The callee dereferences it — it reads the element's
/// `CFTypeID` before it will answer — so this cannot be a safe function no matter how opaquely the
/// pointer is passed through HERE. Null is still rejected rather than assumed away, because a null
/// element is what a caller's own failed lookup produces and refusing it is cheaper than a rule.
///
/// `_AXUIElementGetWindow` is declared `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID
/// *)` in every published reverse-engineering of `HIServices`, and the transmute target spells
/// exactly that: two pointer-width arguments in, an `int32` `AXError` back, the platform C ABI.
/// `dlsym` answers null or the address of an externally-linked function in the image asked, and
/// null is checked before the cast. `id` is a live local for the whole call and is only READ after
/// the callee reports success, so an implementation that leaves it untouched cannot make this
/// observe uninitialised memory — `0` is what it holds and `0` is rejected below.
#[must_use]
#[expect(
    unsafe_code,
    reason = "dlsym has no safe wrapper, and calling what it answers is a cast"
)]
pub unsafe fn ax_window_id(element: *const c_void) -> Option<u32> {
    type GetWindow = unsafe extern "C" fn(*const c_void, *mut u32) -> i32;
    static RESOLVED: OnceLock<Option<GetWindow>> = OnceLock::new();

    if element.is_null() {
        return None;
    }
    let resolved = (*RESOLVED.get_or_init(|| {
        let symbol = lookup(&HI_SERVICES_HANDLE, HI_SERVICES, c"_AXUIElementGetWindow")?;
        // SAFETY: the function's obligation, discharged above — `symbol` is non-null and came from
        // asking HIServices for the one name that denotes that signature there.
        Some(unsafe { std::mem::transmute::<*mut c_void, GetWindow>(symbol) })
    }))?;
    let mut id: u32 = 0;
    // The call is HIServices', so no fork may land inside it — `crate::pty::FORK_LOCK` again.
    let status = crate::pty::while_no_fork_is_taken(||
        // SAFETY: `resolved` is a live function with the declared signature in an image this process
        // opened and never closes; `element` is non-null and, by this function's own contract, a
        // live AX element the callee may interpret; `&raw mut id` points at a live, aligned,
        // initialised `u32` that outlives the call.
        unsafe { resolved(element, &raw mut id) });
    (status == 0 && id != 0).then_some(id)
}

/// An image's address for `name`, or `None` when it does not export it.
///
/// Private because the pointer it answers carries an obligation only the function that knows the
/// NAME can discharge — handing it out is the shape the module doc rules out.
///
/// # Safety
/// The handle comes from [`image`], which is either null-checked or `None`, and `name` is a `&CStr`
/// so it is NUL-terminated by construction. Nothing is dereferenced or called here.
#[expect(unsafe_code, reason = "dlsym has no safe wrapper")]
fn lookup(cache: &OnceLock<Option<usize>>, path: &CStr, name: &CStr) -> Option<*mut c_void> {
    let handle = image(cache, path)?;
    // SAFETY: the function's obligation, above.
    let symbol = unsafe { libc::dlsym(handle, name.as_ptr()) };
    (!symbol.is_null()).then_some(symbol)
}

/// CoreGraphics' handle, opened at most once. See [`image`] for why it is stored as an integer.
static CORE_GRAPHICS_HANDLE: OnceLock<Option<usize>> = OnceLock::new();

/// `HIServices`' handle, opened at most once. A SEPARATE cache from CoreGraphics' rather than a map
/// keyed by path: two images is the whole population, and the pair is what makes it impossible to
/// ask one framework for the other's symbol by accident.
static HI_SERVICES_HANDLE: OnceLock<Option<usize>> = OnceLock::new();

/// The handle for `path`, opened once into `cache`, or `None` where there is no such framework.
///
/// # Safety
/// `dlopen` takes a NUL-terminated path — every caller passes a `&CStr` constant — and answers
/// either null or a handle valid until `dlclose`, which is never called. Nothing is dereferenced.
#[expect(unsafe_code, reason = "dlopen has no safe wrapper")]
fn image(cache: &OnceLock<Option<usize>>, path: &CStr) -> Option<*mut c_void> {
    // A `*mut c_void` is not `Send`, and the pointer is a process-wide handle rather than data — so
    // it is cached as the integer it is and handed back as a pointer at the use site. `dlopen` is
    // itself thread-safe and answers the same handle for the same path, so the `OnceLock` is about
    // the COST of a second call, not its correctness.
    let address = (*cache.get_or_init(|| {
        // Loading an image is the loader's own lock, and a `fork` landing inside it hands the child
        // that lock frozen. The rule is `crate::pty::FORK_LOCK`'s and the cost is two uncontended
        // locks per process, ever, because the handle is cached.
        let handle = crate::pty::while_no_fork_is_taken(||
            // SAFETY: the function's obligation, above.
            unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_LAZY) });
        (!handle.is_null()).then(|| handle.addr())
    }))?;
    Some(std::ptr::without_provenance_mut(address))
}

#[cfg(test)]
mod tests {
    use super::{
        CORE_GRAPHICS, CORE_GRAPHICS_HANDLE, HI_SERVICES, HI_SERVICES_HANDLE, ax_window_id, cursor_seed,
        lookup,
    };

    /// The framework opens and the seed is THERE. This is the arm the `RTLD_DEFAULT` version could
    /// not reach — a bare test binary has no CoreGraphics loaded, so a search of the already-loaded
    /// images answered null and every assertion below would have been vacuously skipped.
    #[test]
    #[cfg(target_os = "macos")]
    fn the_seed_resolves_because_the_framework_is_opened_rather_than_searched() {
        assert!(
            lookup(&CORE_GRAPHICS_HANDLE, CORE_GRAPHICS, c"CGSCurrentCursorSeed").is_some()
                || lookup(&CORE_GRAPHICS_HANDLE, CORE_GRAPHICS, c"SLSCurrentCursorSeed").is_some()
        );
        assert!(cursor_seed().is_some());
    }

    /// A name the framework does not export must answer nothing rather than a stale or defaulted
    /// address. This is the arm that decides whether a private API's disappearance degrades or
    /// crashes.
    #[test]
    fn a_symbol_the_framework_does_not_export_is_absent() {
        assert_eq!(
            lookup(
                &CORE_GRAPHICS_HANDLE,
                CORE_GRAPHICS,
                c"slopdesk_a_symbol_that_cannot_exist"
            ),
            None
        );
    }

    /// The two images are asked SEPARATELY, and this is why: the AX symbol is `HIServices`' and
    /// CoreGraphics does not export it. Measured before the split, when one shared handle would
    /// have made [`ax_window_id`] answer `None` forever on a perfectly healthy machine.
    #[test]
    #[cfg(target_os = "macos")]
    fn each_symbol_is_asked_of_the_image_that_actually_exports_it() {
        assert!(lookup(&HI_SERVICES_HANDLE, HI_SERVICES, c"_AXUIElementGetWindow").is_some());
        assert_eq!(
            lookup(&CORE_GRAPHICS_HANDLE, CORE_GRAPHICS, c"_AXUIElementGetWindow"),
            None
        );
    }

    /// A null element is refused BEFORE the SPI sees it. The AX call is documented to tolerate one,
    /// but "documented" for a private symbol is a reverse-engineered header, and the caller's
    /// `Option` already has a place to put the answer.
    #[test]
    #[expect(
        unsafe_code,
        reason = "the door is unsafe; refusing null is the arm being pinned"
    )]
    fn no_element_is_no_window() {
        // SAFETY: null is the one argument the contract does NOT require to be a live element —
        // it is refused before the symbol is asked for, which is what this test pins.
        assert_eq!(unsafe { ax_window_id(std::ptr::null()) }, None);
    }

    /// The null refusal is CHECKED BEFORE resolution, so it holds identically whether or not the
    /// symbol is present, and a thousand of them open no second handle. The other arm — a live
    /// element that is not a window — cannot be exercised here: manufacturing one means creating an
    /// `AXUIElement`, and this crate deliberately has no Accessibility dependency. It is covered
    /// where the elements exist, in `slopdesk-apple-ax`.
    #[test]
    #[expect(
        unsafe_code,
        reason = "the door is unsafe; refusing null is the arm being pinned"
    )]
    fn refusing_no_element_needs_no_symbol() {
        for _ in 0..1_000 {
            // SAFETY: as above — null takes the early return and never reaches the callee.
            assert_eq!(unsafe { ax_window_id(std::ptr::null()) }, None);
        }
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
