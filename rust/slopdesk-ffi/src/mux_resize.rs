//! The PTY size fold of docs/45 §8.3 — who votes on a pane's grid, and what that folds to.
//!
//! `rust/slopdesk-muxsession`'s `resize_fold` owns the decisions. This is the door.
//!
//! ## Why this one is a HANDLE and `mux_flow` is not
//! A flow policy is two `i64`s that fit in the call. This state is a map of every attached
//! subscriber's standing offer plus the latches around it, it lives as long as the pane does, and
//! the caller mutates it from four contexts under one `NSLock`. That is exactly the shape
//! [`crate::replay`] set the handle convention for.
//!
//! ## What did NOT cross
//! The `TIOCSWINSZ`. Every entry point here answers what the grid SHOULD be; hostd owns the
//! descriptor, compares against the live `TIOCGWINSZ` and performs the one write. So does every
//! timer: the fold says whether to ARM a debounce or a settle and hands back the generation that
//! decides whether a task already past its sleep still speaks for the newest state, and the `Task`
//! stays in Swift.

use slopdesk_muxsession::resize_fold::{Grid, ResizeFold, SubscriberId};

/// One client's offer, or one resolved fold: a character grid and the pixel metrics of ITS cells.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskResizeGrid {
    /// Columns.
    pub cols: u16,
    /// Rows.
    pub rows: u16,
    /// Pixel width of the whole grid, as the offering client measured it.
    pub px: u16,
    /// Pixel height of the whole grid.
    pub py: u16,
}

/// What a fold mutation asks the caller to schedule.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskResizeArm {
    /// The generation the scheduled task must quote back to [`slopdesk_resize_fold_resolve`].
    pub generation: u64,
    /// Whether to arm the timer this mutation calls for — the contributor settle for a membership
    /// change, the short debounce for an offer.
    pub arm: bool,
}

/// One contributor as the workspace roster publishes it.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskResizeAttachment {
    /// Who.
    pub subscriber: u64,
    /// The offered columns, or zero for a member that holds the pane without having said how big.
    pub cols: u16,
    /// The offered rows.
    pub rows: u16,
    /// Whether the fold ACTUALLY credits this member right now — not the passivity flag alone.
    pub contributes: bool,
}

/// One pane's fold, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskResizeFold {
    /// The state the caller's lock guards.
    inner: ResizeFold,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_resize_fold_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskResizeFold) -> Option<&'a mut SlopDeskResizeFold> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// The wire shape of one grid.
const fn grid_out(grid: Grid) -> SlopDeskResizeGrid {
    SlopDeskResizeGrid {
        cols: grid.cols,
        rows: grid.rows,
        px: grid.px,
        py: grid.py,
    }
}

/// The fold's shape of one grid.
const fn grid_in(grid: SlopDeskResizeGrid) -> Grid {
    Grid {
        cols: grid.cols,
        rows: grid.rows,
        px: grid.px,
        py: grid.py,
    }
}

/// A fold for a session whose opening subscriber votes (or is size-passive).
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_resize_fold_new(opened_size_passive: bool) -> *mut SlopDeskResizeFold {
    Box::into_raw(Box::new(SlopDeskResizeFold {
        inner: ResizeFold::new(opened_size_passive),
    }))
}

/// Frees a fold. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_resize_fold_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_free(handle: *mut SlopDeskResizeFold) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Registers a member, or updates its passivity. An existing member keeps its standing offer.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_add(
    handle: *mut SlopDeskResizeFold,
    subscriber: SubscriberId,
    size_passive: bool,
) -> SlopDeskResizeArm {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskResizeArm::default();
    };
    let decision = state.inner.add_contributor(subscriber, size_passive);
    SlopDeskResizeArm {
        generation: decision.generation,
        arm: decision.arm_settle,
    }
}

/// Drops a member. A pane whose set empties keeps its last size.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_remove(
    handle: *mut SlopDeskResizeFold,
    subscriber: SubscriberId,
) -> SlopDeskResizeArm {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskResizeArm::default();
    };
    let decision = state.inner.remove_contributor(subscriber);
    SlopDeskResizeArm {
        generation: decision.generation,
        arm: decision.arm_settle,
    }
}

/// Records a subscriber's LATEST offer, registering it if it was not a member.
///
/// `arm` is false while a contributor settle is outstanding: the offer joins the fold that settle
/// will resolve.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_offer(
    handle: *mut SlopDeskResizeFold,
    subscriber: SubscriberId,
    offer: SlopDeskResizeGrid,
) -> SlopDeskResizeArm {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskResizeArm::default();
    };
    let decision = state.inner.note_offer(subscriber, grid_in(offer));
    SlopDeskResizeArm {
        generation: decision.generation,
        arm: decision.arm_debounce,
    }
}

/// Installs the ctl socket's override and answers the generation it applies under.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_resize_fold_override(
    handle: *mut SlopDeskResizeFold,
    grid: SlopDeskResizeGrid,
) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    match unsafe { held(handle) } {
        Some(state) => state.inner.set_ctl_override(grid_in(grid)),
        None => 0,
    }
}

/// Resolves the grid, answering whether anybody is holding this pane at a size.
///
/// `check_generation` is the timer paths' guard: a task already past its sleep passes the
/// generation it was scheduled under and resolves NOTHING if a newer one superseded it. The flush
/// paths pass `false` and resolve unconditionally, because they must never strand a size.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to one writable
/// [`SlopDeskResizeGrid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_resolve(
    handle: *mut SlopDeskResizeFold,
    check_generation: bool,
    generation: u64,
    out: *mut SlopDeskResizeGrid,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let guard = crate::optional_of(check_generation, generation);
    let Some(grid) = state.inner.resolve(guard) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: `out` is non-null and, by the caller's obligation, points to one writable grid.
    unsafe { out.write(grid_out(grid)) };
    true
}

/// The grid the fold last resolved, for the roster to publish.
///
/// False for a pane nothing has ever resolved — the caller falls back to the live winsize there,
/// because a ctl-spawned shell with no contributing subscriber is still a real terminal at a real
/// size.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to one writable
/// [`SlopDeskResizeGrid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_resize_fold_resolved(
    handle: *mut SlopDeskResizeFold,
    out: *mut SlopDeskResizeGrid,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(grid) = state.inner.resolved_grid() else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: `out` is non-null and, by the caller's obligation, points to one writable grid.
    unsafe { out.write(grid_out(grid)) };
    true
}

/// Releases the settle latch, guarded by the generation so a superseded task cannot unlatch a
/// settle a newer set change owns.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_resize_fold_clear_settle(
    handle: *mut SlopDeskResizeFold,
    generation: u64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.clear_settle(generation);
    }
}

/// Drops every member, for a pane being torn down. The generation is untouched, so a task still
/// past its sleep cannot match a rewound counter and apply a fold for a session that is gone.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_clear_members(handle: *mut SlopDeskResizeFold) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.clear_members();
    }
}

/// Whether a contributor-set change is still settling.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_is_settling(handle: *mut SlopDeskResizeFold) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_settling())
}

/// Every contributor in subscriber order, written into the caller's buffer if the whole list fits.
///
/// Answers the TOTAL count either way, so a caller that sees more than `capacity` retries with a
/// bigger buffer — [`crate::deliver`]'s convention, at a struct rather than at bytes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskResizeAttachment`]s for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_resize_fold_attachments(
    handle: *mut SlopDeskResizeFold,
    out: *mut SlopDeskResizeAttachment,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let attachments: Vec<SlopDeskResizeAttachment> = state
        .inner
        .attachments()
        .into_iter()
        .map(|attachment| {
            SlopDeskResizeAttachment {
                subscriber: attachment.subscriber,
                cols: attachment.cols,
                rows: attachment.rows,
                contributes: attachment.contributes,
            }
        })
        .collect();
    let count = attachments.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // elements by the caller's obligation, and the source is a Vec allocated inside this call, so
    // the two cannot overlap.
    unsafe { std::ptr::copy_nonoverlapping(attachments.as_ptr(), out, count) };
    count
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SlopDeskResizeAttachment, SlopDeskResizeGrid, slopdesk_resize_fold_add,
        slopdesk_resize_fold_attachments, slopdesk_resize_fold_clear_members,
        slopdesk_resize_fold_clear_settle, slopdesk_resize_fold_free, slopdesk_resize_fold_is_settling,
        slopdesk_resize_fold_new, slopdesk_resize_fold_offer, slopdesk_resize_fold_override,
        slopdesk_resize_fold_remove, slopdesk_resize_fold_resolve, slopdesk_resize_fold_resolved,
    };

    const fn grid(cols: u16, rows: u16) -> SlopDeskResizeGrid {
        SlopDeskResizeGrid {
            cols,
            rows,
            px: 0,
            py: 0,
        }
    }

    /// The arithmetic, the override and the readout across the boundary in one pane's lifetime.
    #[test]
    fn the_fold_answers_the_minimum_and_the_override_takes_precedence() {
        let handle = slopdesk_resize_fold_new(false);
        let mut resolved = SlopDeskResizeGrid::default();
        unsafe {
            slopdesk_resize_fold_add(handle, 0, false);
            slopdesk_resize_fold_add(handle, 7, false);
            slopdesk_resize_fold_offer(handle, 0, grid(120, 50));
            slopdesk_resize_fold_offer(handle, 7, grid(200, 30));
            assert!(slopdesk_resize_fold_resolve(handle, false, 0, &raw mut resolved));
            assert_eq!((resolved.cols, resolved.rows), (120, 30));

            slopdesk_resize_fold_override(handle, grid(132, 40));
            assert!(slopdesk_resize_fold_resolve(handle, false, 0, &raw mut resolved));
            assert_eq!((resolved.cols, resolved.rows), (132, 40));

            slopdesk_resize_fold_offer(handle, 0, grid(90, 20));
            assert!(slopdesk_resize_fold_resolve(handle, false, 0, &raw mut resolved));
            assert_eq!(
                (resolved.cols, resolved.rows),
                (90, 20),
                "the next offer retires it"
            );

            assert!(slopdesk_resize_fold_resolved(handle, &raw mut resolved));
            slopdesk_resize_fold_free(handle);
        }
    }

    /// A superseded generation resolves nothing, and an emptied set strands no size.
    #[test]
    fn the_generation_guard_and_the_empty_set_both_cross() {
        let handle = slopdesk_resize_fold_new(false);
        unsafe {
            slopdesk_resize_fold_add(handle, 0, false);
            let first = slopdesk_resize_fold_offer(handle, 0, grid(100, 40));
            let second = slopdesk_resize_fold_offer(handle, 0, grid(90, 30));
            assert!(!slopdesk_resize_fold_resolve(
                handle,
                true,
                first.generation,
                std::ptr::null_mut()
            ));
            assert!(slopdesk_resize_fold_resolve(
                handle,
                true,
                second.generation,
                std::ptr::null_mut()
            ));

            slopdesk_resize_fold_remove(handle, 0);
            assert!(!slopdesk_resize_fold_resolve(
                handle,
                false,
                0,
                std::ptr::null_mut()
            ));

            slopdesk_resize_fold_offer(handle, 4, grid(70, 20));
            slopdesk_resize_fold_clear_members(handle);
            assert_eq!(
                slopdesk_resize_fold_attachments(handle, std::ptr::null_mut(), 0),
                0
            );
            assert!(!slopdesk_resize_fold_resolve(
                handle,
                false,
                0,
                std::ptr::null_mut()
            ));
            slopdesk_resize_fold_free(handle);
        }
    }

    /// The settle latch and the roster readout, including the short-buffer retry convention.
    #[test]
    fn the_settle_latches_and_the_roster_reports_its_whole_length() {
        let handle = slopdesk_resize_fold_new(false);
        unsafe {
            slopdesk_resize_fold_add(handle, 0, false);
            let armed = slopdesk_resize_fold_add(handle, 7, false);
            assert!(armed.arm);
            assert!(slopdesk_resize_fold_is_settling(handle));
            assert!(
                !slopdesk_resize_fold_offer(handle, 7, grid(80, 24)).arm,
                "it joins the settle"
            );
            slopdesk_resize_fold_clear_settle(handle, armed.generation);
            assert!(!slopdesk_resize_fold_is_settling(handle));

            let needed = slopdesk_resize_fold_attachments(handle, std::ptr::null_mut(), 0);
            assert_eq!(needed, 2);
            let mut one = [SlopDeskResizeAttachment::default(); 1];
            assert_eq!(
                slopdesk_resize_fold_attachments(handle, one.as_mut_ptr(), one.len()),
                2,
                "a short buffer is told the whole length and written nothing"
            );
            assert_eq!(one.first().map(|a| a.subscriber), Some(0));
            let mut both = [SlopDeskResizeAttachment::default(); 2];
            assert_eq!(
                slopdesk_resize_fold_attachments(handle, both.as_mut_ptr(), both.len()),
                2
            );
            assert!(both.iter().all(|a| a.contributes));
            assert_eq!(both.get(1).map(|a| (a.cols, a.rows)), Some((80, 24)));
            slopdesk_resize_fold_free(handle);
        }
    }

    /// Null crosses as "nothing", at every entry point rather than at some of them.
    #[test]
    fn a_null_handle_is_inert_everywhere() {
        unsafe {
            assert!(!slopdesk_resize_fold_add(std::ptr::null_mut(), 0, false).arm);
            assert!(!slopdesk_resize_fold_remove(std::ptr::null_mut(), 0).arm);
            assert!(!slopdesk_resize_fold_offer(std::ptr::null_mut(), 0, grid(1, 1)).arm);
            assert_eq!(slopdesk_resize_fold_override(std::ptr::null_mut(), grid(1, 1)), 0);
            assert!(!slopdesk_resize_fold_resolve(
                std::ptr::null_mut(),
                false,
                0,
                std::ptr::null_mut()
            ));
            assert!(!slopdesk_resize_fold_resolved(
                std::ptr::null_mut(),
                std::ptr::null_mut()
            ));
            assert!(!slopdesk_resize_fold_is_settling(std::ptr::null_mut()));
            assert_eq!(
                slopdesk_resize_fold_attachments(std::ptr::null_mut(), std::ptr::null_mut(), 0),
                0
            );
            slopdesk_resize_fold_clear_settle(std::ptr::null_mut(), 0);
            slopdesk_resize_fold_clear_members(std::ptr::null_mut());
            slopdesk_resize_fold_free(std::ptr::null_mut());
        }
    }
}
