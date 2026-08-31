//! What one gesture moved and what one launch asks for, in C.
//!
//! The rules are `slopdesk_workspace::store_shape`; what is here is the marshalling.
//!
//! ## No identity crosses
//!
//! A split, a pane, a tab and a session are `UUID`s the near side owns. Every door here takes a
//! caller-minted `u32` TOKEN in their place — one table spanning both snapshots of a comparison, so
//! that "the same split" stays decidable — and answers a POSITION or an index into the list it was
//! handed. Carrying a `UUID` across would buy nothing but a second place for an identity to be
//! wrong, which is `pane_facts`'s reasoning applied to a correlation.
//!
//! ## Where the flattening happens, and why that is still a port
//!
//! The near side walks its own tree to build the slot list, because the tree is what it holds. What
//! moved is the DECIDING: which child of which split changed, which pane traded places, which of
//! two autoconnects wins, whether a zoom collapses. `docs/55` §4c's git-line entry is the precedent
//! — transcription stays near, the choice crosses.

use core::ffi::c_uchar;

use slopdesk_terminal::surface_action::{SelectionEdge, SurfaceAction};
use slopdesk_workspace::store_shape::{
    self, BootstrapKind, FocusLanding, FocusTab, ScrollAction, WeightSlot,
};

use crate::{borrow, deliver};

// ---------------------------------------------------------------------------------------------- //
// Divider weights
// ---------------------------------------------------------------------------------------------- //

/// One CHILD slot of one split, flattened out of a tab's tree in pre-order.
///
/// `weight` means nothing unless `is_flex`. The two are carried apart rather than as a sentinel
/// weight because a fixed child and a zero-weight flex child are different answers to "did this
/// move", and no `f64` is outside a weight's range by construction.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsWeightSlot {
    /// The child's flex share of its parent's axis.
    pub weight: f64,
    /// The caller's token for the enclosing split's identity.
    pub split: u32,
    /// Whether the child is flex at all.
    pub is_flex: bool,
}

/// The one `splitNode/weight` a structural resize moved.
///
/// `found` is the guard: every other field is meaningless when it is `false`, which is the `Option`
/// the rule answers, flattened for a caller that has no such type. A nothing-moved verdict leaves
/// the rest zeroed rather than undefined.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWsWeightChange {
    /// Its new flex share.
    pub weight: f64,
    /// Which of that split's children moved.
    pub index: usize,
    /// The caller's token for the split that holds it.
    pub split: u32,
    /// Whether anything moved at all. `false` ⇒ ignore every field above.
    pub found: bool,
}

/// Lends the caller's slots as the rule's own record.
///
/// # Safety
/// `(rows, len)` must be readable for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: the caller's array becoming a slice"
)]
unsafe fn lend_slots(rows: *const SlopDeskWsWeightSlot, len: usize) -> Vec<WeightSlot> {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    unsafe { borrow(rows, len) }
        .iter()
        .map(|slot| {
            WeightSlot {
                weight: slot.weight,
                split: slot.split,
                is_flex: slot.is_flex,
            }
        })
        .collect()
}

/// The FLEX share of `split`'s child at `index`, written to `out`. `false` when that seam is absent
/// or fixed, and `out` is then untouched.
///
/// # Safety
/// `(rows, len)` must be readable for the call, and `out` either null or writable for one `f64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_leading_weight(
    rows: *const SlopDeskWsWeightSlot,
    len: usize,
    split: u32,
    index: usize,
    out: *mut f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let lent = unsafe { lend_slots(rows, len) };
    let Some(weight) = store_shape::leading_weight(&lent, split, index) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: `out` is non-null and writable for one `f64` by the caller's obligation.
    unsafe { out.write(weight) };
    true
}

/// The one weight that differs between two flattenings of the same trees.
///
/// # Safety
/// Both `(ptr, len)` pairs must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_changed_divider_weight(
    before: *const SlopDeskWsWeightSlot,
    before_len: usize,
    after: *const SlopDeskWsWeightSlot,
    after_len: usize,
) -> SlopDeskWsWeightChange {
    // SAFETY: the caller's obligation, restated above.
    let (was, now) = unsafe { (lend_slots(before, before_len), lend_slots(after, after_len)) };
    store_shape::changed_divider_weight(&was, &now).map_or_else(SlopDeskWsWeightChange::default, |change| {
        SlopDeskWsWeightChange {
            weight: change.weight,
            index: change.index,
            split: change.split,
            found: true,
        }
    })
}

// ---------------------------------------------------------------------------------------------- //
// The swap partner
// ---------------------------------------------------------------------------------------------- //

/// Which pane traded places with `active`, as a POSITION into `after`, or `-1`.
///
/// A signed sentinel rather than a presence flag because a position is never negative by
/// construction — the same convention the `slopdesk_vi_*` doors keep.
///
/// # Safety
/// Both `(ptr, len)` pairs must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_swap_partner(
    before: *const u32,
    before_len: usize,
    after: *const u32,
    after_len: usize,
    active: u32,
) -> isize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let (was, now) = unsafe { (borrow(before, before_len), borrow(after, after_len)) };
    store_shape::swap_partner(was, now, active)
        .and_then(|position| isize::try_from(position).ok())
        .unwrap_or(-1)
}

// ---------------------------------------------------------------------------------------------- //
// The launch bootstrap
// ---------------------------------------------------------------------------------------------- //

/// Where the `=` falls in a launch argument that overrides an environment variable, or `-1`.
///
/// The offset is in BYTES and always lands on a `=`, so both halves either side of it are whole
/// UTF-8. An argument that is not valid UTF-8 is not an override — there is no offset that could be
/// honestly reported into it.
///
/// # Safety
/// `(argument, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_automation_override(argument: *const c_uchar, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(argument, len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return -1;
    };
    store_shape::automation_override(text)
        .and_then(|offset| isize::try_from(offset).ok())
        .unwrap_or(-1)
}

/// Whether the terminal autoconnect variables describe a target, writing its port to `out`.
///
/// `false` leaves `out` untouched: an unset autoconnect is not a request to dial port 0.
///
/// # Safety
/// Both `(ptr, len)` pairs must be readable for the call, and `out` either null or writable for one
/// `u16`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_terminal_target_port(
    host: *const c_uchar,
    host_len: usize,
    port: *const c_uchar,
    port_len: usize,
    out: *mut u16,
) -> bool {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let (host_bytes, port_bytes) = unsafe { (borrow(host, host_len), borrow(port, port_len)) };
    let (Ok(host_text), Ok(port_text)) = (core::str::from_utf8(host_bytes), core::str::from_utf8(port_bytes))
    else {
        return false;
    };
    let Some(resolved) = store_shape::terminal_target(host_text, port_text) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: `out` is non-null and writable for one `u16` by the caller's obligation.
    unsafe { out.write(resolved) };
    true
}

/// Which shape a launch asks the store to mount: `0` the default workspace, `1` the terminal
/// autoconnect, `2` the video autoconnect.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_bootstrap_kind(has_video: bool, has_terminal: bool) -> c_uchar {
    BootstrapKind::resolve(has_video, has_terminal).code()
}

// ---------------------------------------------------------------------------------------------- //
// The inspector's port
// ---------------------------------------------------------------------------------------------- //

/// The inspector port beside a terminal port, or `-1` when there is no room above it.
///
/// Signed, because a `u16` answer is never negative — the sentinel is outside the answer's range by
/// construction, which is what `docs/55` §4b asks of one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_inspector_port(terminal: u16) -> i32 {
    store_shape::inspector_port(terminal).map_or(-1, i32::from)
}

// ---------------------------------------------------------------------------------------------- //
// The binding-action grammar
// ---------------------------------------------------------------------------------------------- //

/// The binding action one named scroll fires: §4's byte count, or `0` for a code this build does
/// not know.
///
/// # Safety
/// `out` must either be null or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the buffer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_scroll_action(code: c_uchar, out: *mut c_uchar, cap: usize) -> usize {
    let Some(action) = ScrollAction::from_code(code) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(action.wire().as_bytes(), out, cap) }
}

/// One binding action WITH an argument, spelled by the grammar's only speller.
///
/// ⚠️ **This door exists so that no `String` naming an action is ever built in Swift.** The
/// executor at the other end (`slopdesk_term_surface_binding_action`) answers a spelling it does
/// not recognise by doing NOTHING and returning `false` — a typo does not raise, it makes a
/// keystroke quietly stop working. So the client knows the verbs as NUMBERS, which a compiler
/// checks, and asks here for the one string it then carries.
///
/// | `code` | action | `argument` |
/// | --- | --- | --- |
/// | 1 | `scroll_page_lines` | signed rows |
/// | 2 | `scroll_page_fractional` | signed THOUSANDTHS of a page (`-900` is `-0.9`) |
/// | 3 | `jump_to_prompt` | signed prompts |
/// | 4 | `adjust_selection` | `0` up, `1` down, `2` left, `3` right |
/// | 5 | `scroll_to_top` | ignored |
/// | 6 | `scroll_to_bottom` | ignored |
/// | 7 | `scroll_to_row` | the screen row |
///
/// Thousandths rather than an `f64` for code 2 because the fraction is one of two design constants
/// (`0.5` for `⌃d`, `0.9` for `⌃f`) and an integer cannot arrive as a NaN — the one input the
/// grammar refuses. §4's byte count; `0` for a code this build does not know, and for an argument
/// outside its verb's range.
///
/// # Safety
/// `out` must either be null or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the buffer is the caller's"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_ws_binding_action(
    code: c_uchar,
    argument: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(spelling) = spell(code, argument) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(spelling.as_bytes(), out, cap) }
}

/// The code table above, as a function.
///
/// Split out of the door so the whole table is testable without a pointer, and so an argument that
/// does not fit its verb answers `None` HERE rather than being silently clamped into a different
/// action than the caller asked for.
fn spell(code: c_uchar, argument: i64) -> Option<String> {
    let action = match code {
        1 => SurfaceAction::ScrollLines(i32::try_from(argument).ok()?),
        2 => {
            // Exact for every value the client sends, and now provably so rather than by argument:
            // the `i32` narrowing is checked, and every `i32` converts to `f64` infallibly. The
            // `cast_precision_loss` exemption this used to carry described an `as` cast that is
            // gone — a `From` conversion cannot lose precision, so there is nothing left to exempt.
            let fraction = f64::from(i32::try_from(argument).ok()?) / 1000.0;
            SurfaceAction::ScrollFraction(fraction)
        },
        3 => SurfaceAction::JumpToPrompt(i16::try_from(argument).ok()?),
        4 => {
            SurfaceAction::AdjustSelection(match argument {
                0 => SelectionEdge::Up,
                1 => SelectionEdge::Down,
                2 => SelectionEdge::Left,
                3 => SelectionEdge::Right,
                _ => return None,
            })
        },
        5 => SurfaceAction::ScrollToTop,
        6 => SurfaceAction::ScrollToBottom,
        7 => SurfaceAction::ScrollToRow(u32::try_from(argument).ok()?),
        _ => return None,
    };
    Some(action.spell())
}

// ---------------------------------------------------------------------------------------------- //
// The device-focus overlay
// ---------------------------------------------------------------------------------------------- //

/// One tab of the projection, as the device-focus overlay needs to see it.
///
/// The tabs arrive in session order, so one session's tabs are a maximal RUN of equal `session`
/// tokens — which is the shape the near side's own nested walk produces.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsFocusTab {
    /// The caller's token for the session this tab belongs to.
    pub session: u32,
    /// Whether the focused pane is a leaf of this tab.
    pub holds_pane: bool,
    /// Whether this is the tab the overlay names.
    pub is_focus_tab: bool,
    /// Whether this tab's zoom is showing the focused pane itself.
    pub zoom_is_target: bool,
}

/// Where a device-focus overlay lands.
///
/// `resolved` is the guard, and the same flattened `Option` the commit door answers: a focus whose
/// tab and pane have both gone leaves the rest zeroed, and the near side shows host truth.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsFocusLanding {
    /// Which tab of the list handed in, as a position.
    pub tab: usize,
    /// Whether the overlay resolved at all. `false` ⇒ ignore every field.
    pub resolved: bool,
    /// Whether the overlay also names the tab's active pane.
    pub focuses_pane: bool,
    /// Whether the landing tab's zoom collapses.
    pub clears_zoom: bool,
}

/// Where a device's own focus overlay lands on the projection.
///
/// # Safety
/// `(tabs, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_device_focus_landing(
    tabs: *const SlopDeskWsFocusTab,
    len: usize,
    has_pane: bool,
) -> SlopDeskWsFocusLanding {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let rows: Vec<FocusTab> = unsafe { borrow(tabs, len) }
        .iter()
        .map(|row| {
            FocusTab {
                session: row.session,
                holds_pane: row.holds_pane,
                is_focus_tab: row.is_focus_tab,
                zoom_is_target: row.zoom_is_target,
            }
        })
        .collect();
    store_shape::device_focus_landing(&rows, has_pane).map_or_else(
        SlopDeskWsFocusLanding::default,
        |landing: FocusLanding| {
            SlopDeskWsFocusLanding {
                tab: landing.tab,
                resolved: true,
                focuses_pane: landing.focuses_pane,
                clears_zoom: landing.clears_zoom,
            }
        },
    )
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::store_shape::{self, ScrollAction};

    use super::{
        SlopDeskWsFocusLanding, SlopDeskWsFocusTab, SlopDeskWsWeightChange, SlopDeskWsWeightSlot,
        slopdesk_ws_automation_override, slopdesk_ws_binding_action, slopdesk_ws_bootstrap_kind,
        slopdesk_ws_changed_divider_weight, slopdesk_ws_device_focus_landing, slopdesk_ws_inspector_port,
        slopdesk_ws_leading_weight, slopdesk_ws_scroll_action, slopdesk_ws_swap_partner,
        slopdesk_ws_terminal_target_port, spell,
    };

    /// A flex slot, as the caller writes one.
    const fn flex(split: u32, weight: f64) -> SlopDeskWsWeightSlot {
        SlopDeskWsWeightSlot {
            weight,
            split,
            is_flex: true,
        }
    }

    /// A fixed slot, which has no share to move.
    const fn fixed(split: u32) -> SlopDeskWsWeightSlot {
        SlopDeskWsWeightSlot {
            weight: 0.0,
            split,
            is_flex: false,
        }
    }

    /// Every slot list the rule can be asked about crosses to the same answer the rule gives
    /// directly — the differential the boundary exists to keep true.
    #[test]
    fn every_leading_weight_crosses_verbatim() {
        let rows = [flex(1, 0.25), fixed(1), flex(1, 0.75), flex(2, 1.0)];
        let native: Vec<store_shape::WeightSlot> = rows
            .iter()
            .map(|slot| {
                store_shape::WeightSlot {
                    weight: slot.weight,
                    split: slot.split,
                    is_flex: slot.is_flex,
                }
            })
            .collect();
        for split in 0_u32..4 {
            for index in 0_usize..5 {
                let mut weight = f64::NAN;
                // SAFETY: both are live locals for the call.
                let found = unsafe {
                    slopdesk_ws_leading_weight(rows.as_ptr(), rows.len(), split, index, &raw mut weight)
                };
                let expected = store_shape::leading_weight(&native, split, index);
                assert_eq!(found, expected.is_some(), "split {split} index {index}");
                if let Some(expected) = expected {
                    assert!((weight - expected).abs() < f64::EPSILON);
                }
            }
        }
    }

    /// A refusal leaves the caller's slot alone rather than writing a sentinel into it.
    #[test]
    fn a_refused_leading_weight_writes_nothing() {
        let rows = [flex(1, 0.5)];
        let mut weight = -1.0;
        // SAFETY: both are live locals for the call.
        let found = unsafe { slopdesk_ws_leading_weight(rows.as_ptr(), rows.len(), 9, 0, &raw mut weight) };
        assert!(!found);
        assert!((weight - -1.0).abs() < f64::EPSILON);
    }

    /// A null buffer is answered rather than dereferenced, on both halves of the pair.
    #[test]
    fn a_null_buffer_is_inert_on_both_sides() {
        let rows = [flex(1, 0.5)];
        // SAFETY: `rows` is a live local, and a null `out` is the documented case.
        let found =
            unsafe { slopdesk_ws_leading_weight(rows.as_ptr(), rows.len(), 1, 0, core::ptr::null_mut()) };
        assert!(found);
        // SAFETY: a zero-length read of a dangling-but-aligned pointer.
        let empty = unsafe {
            slopdesk_ws_leading_weight(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                1,
                0,
                core::ptr::null_mut(),
            )
        };
        assert!(!empty);
    }

    #[test]
    fn the_moved_weight_crosses_with_its_guard() {
        let before = [flex(4, 0.5), flex(4, 0.5)];
        let after = [flex(4, 0.3), flex(4, 0.7)];
        // SAFETY: both arrays are live locals for the call.
        let change = unsafe {
            slopdesk_ws_changed_divider_weight(before.as_ptr(), before.len(), after.as_ptr(), after.len())
        };
        assert!(change.found);
        assert_eq!(change.split, 4);
        assert_eq!(change.index, 0);
        assert!((change.weight - 0.3).abs() < f64::EPSILON);
    }

    /// A nothing-moved verdict is zeroed, not arbitrary.
    #[test]
    fn an_unmoved_tree_crosses_as_a_zeroed_record() {
        let rows = [flex(4, 0.5), flex(4, 0.5)];
        // SAFETY: the array is a live local for the call.
        let change = unsafe {
            slopdesk_ws_changed_divider_weight(rows.as_ptr(), rows.len(), rows.as_ptr(), rows.len())
        };
        assert_eq!(change, SlopDeskWsWeightChange::default());
        // SAFETY: two zero-length reads of a dangling-but-aligned pointer.
        let empty = unsafe {
            slopdesk_ws_changed_divider_weight(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                core::ptr::NonNull::dangling().as_ptr(),
                0,
            )
        };
        assert!(!empty.found);
    }

    #[test]
    fn the_swap_partner_crosses_as_a_position_or_minus_one() {
        let before = [10_u32, 20, 30];
        let after = [20_u32, 10, 30];
        // SAFETY: both arrays are live locals for the call.
        let found = unsafe {
            slopdesk_ws_swap_partner(before.as_ptr(), before.len(), after.as_ptr(), after.len(), 10)
        };
        assert_eq!(found, 0);
        // SAFETY: both arrays are live locals for the call.
        let refused = unsafe {
            slopdesk_ws_swap_partner(before.as_ptr(), before.len(), before.as_ptr(), before.len(), 10)
        };
        assert_eq!(refused, -1, "a pane that did not move has no partner");
    }

    #[test]
    fn an_empty_pair_of_orders_has_no_partner() {
        // SAFETY: two zero-length reads of a dangling-but-aligned pointer.
        let refused = unsafe {
            slopdesk_ws_swap_partner(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                0,
            )
        };
        assert_eq!(refused, -1);
    }

    #[test]
    fn an_override_argument_crosses_as_a_byte_offset() {
        let argument = b"SLOPDESK_AUTOCONNECT_PORT=7420";
        // SAFETY: the literal is `'static`.
        let at = unsafe { slopdesk_ws_automation_override(argument.as_ptr(), argument.len()) };
        assert_eq!(at, 25);
        let plain = b"PATH=/usr/bin";
        // SAFETY: the literal is `'static`.
        let refused = unsafe { slopdesk_ws_automation_override(plain.as_ptr(), plain.len()) };
        assert_eq!(refused, -1);
    }

    /// Bytes that are not UTF-8 name no offset, because no offset into them would be honest.
    #[test]
    fn a_non_utf8_argument_is_not_an_override() {
        let raw = [b'S', b'L', b'O', b'P', b'D', b'E', b'S', b'K', b'_', 0xFF, b'='];
        // SAFETY: the array is a live local for the call.
        let refused = unsafe { slopdesk_ws_automation_override(raw.as_ptr(), raw.len()) };
        assert_eq!(refused, -1);
        // SAFETY: a zero-length read of a dangling-but-aligned pointer.
        let empty = unsafe { slopdesk_ws_automation_override(core::ptr::NonNull::dangling().as_ptr(), 0) };
        assert_eq!(empty, -1);
    }

    #[test]
    fn a_terminal_target_crosses_as_a_flag_and_a_port() {
        let host = b"10.0.0.2";
        let port = b"7420";
        let mut resolved = 0_u16;
        // SAFETY: every argument is a live local or a `'static` literal.
        let found = unsafe {
            slopdesk_ws_terminal_target_port(
                host.as_ptr(),
                host.len(),
                port.as_ptr(),
                port.len(),
                &raw mut resolved,
            )
        };
        assert!(found);
        assert_eq!(resolved, 7420);
    }

    /// An unset autoconnect leaves the caller's slot alone — it is not a request to dial port 0.
    #[test]
    fn a_refused_terminal_target_writes_nothing() {
        let port = b"7420";
        let mut resolved = 9_u16;
        // SAFETY: a zero-length host read, and the rest are live locals.
        let found = unsafe {
            slopdesk_ws_terminal_target_port(
                core::ptr::NonNull::dangling().as_ptr(),
                0,
                port.as_ptr(),
                port.len(),
                &raw mut resolved,
            )
        };
        assert!(!found);
        assert_eq!(resolved, 9);
        let host = b"10.0.0.2";
        let bad = b"65536";
        // SAFETY: both literals are `'static`.
        let out_of_range = unsafe {
            slopdesk_ws_terminal_target_port(
                host.as_ptr(),
                host.len(),
                bad.as_ptr(),
                bad.len(),
                core::ptr::null_mut(),
            )
        };
        assert!(!out_of_range);
    }

    #[test]
    fn the_bootstrap_precedence_crosses_as_its_three_codes() {
        assert_eq!(slopdesk_ws_bootstrap_kind(true, true), 2);
        assert_eq!(slopdesk_ws_bootstrap_kind(true, false), 2);
        assert_eq!(slopdesk_ws_bootstrap_kind(false, true), 1);
        assert_eq!(slopdesk_ws_bootstrap_kind(false, false), 0);
    }

    #[test]
    fn the_inspector_port_crosses_signed_and_refuses_the_top_port() {
        assert_eq!(slopdesk_ws_inspector_port(7420), 7421);
        assert_eq!(slopdesk_ws_inspector_port(0), 1);
        assert_eq!(slopdesk_ws_inspector_port(u16::MAX), -1);
    }

    /// Every action's string crosses verbatim, and a short buffer is told the length.
    #[test]
    fn every_scroll_action_crosses_verbatim() {
        for action in ScrollAction::ALL {
            let expected = action.wire();
            let mut out = [0_u8; 64];
            // SAFETY: the buffer is a live local for the call.
            let written = unsafe { slopdesk_ws_scroll_action(action.code(), out.as_mut_ptr(), out.len()) };
            assert_eq!(written, expected.len());
            assert_eq!(
                core::str::from_utf8(out.get(..written).unwrap_or_default()).unwrap_or_default(),
                expected
            );

            let mut short = [0_u8; 1];
            // SAFETY: the buffer is a live local for the call.
            let needed = unsafe { slopdesk_ws_scroll_action(action.code(), short.as_mut_ptr(), 1) };
            assert_eq!(needed, expected.len(), "a short buffer is told the length");
            assert_eq!(short, [0], "and written nothing");
        }
    }

    /// A code this build does not know answers 0, which is the same answer as an empty run — and
    /// for a caller that has no action to fire, those are the same thing.
    #[test]
    fn an_unnamed_scroll_code_answers_nothing() {
        let mut out = [0_u8; 64];
        // SAFETY: the buffer is a live local for the call.
        let written = unsafe { slopdesk_ws_scroll_action(9, out.as_mut_ptr(), out.len()) };
        assert_eq!(written, 0);
        // SAFETY: a null `out` is the documented probe.
        let probed = unsafe { slopdesk_ws_scroll_action(0, core::ptr::null_mut(), 0) };
        assert_eq!(probed, ScrollAction::PageUp.wire().len());
    }

    /// The whole code table, pinned as literals. ⚠️ These strings are a CONTRACT with the executor,
    /// which answers an unrecognised one by silently doing nothing — so they are asserted here
    /// rather than derived, and a change that renames a verb must fail here first.
    #[test]
    fn every_argument_carrying_code_spells_its_action() {
        for (code, argument, expected) in [
            (1_u8, -3_i64, "scroll_page_lines:-3"),
            (1, 12, "scroll_page_lines:12"),
            (2, -900, "scroll_page_fractional:-0.9"),
            (2, 500, "scroll_page_fractional:0.5"),
            (3, -1, "jump_to_prompt:-1"),
            (4, 0, "adjust_selection:up"),
            (4, 1, "adjust_selection:down"),
            (4, 2, "adjust_selection:left"),
            (4, 3, "adjust_selection:right"),
            (5, 0, "scroll_to_top"),
            (6, 0, "scroll_to_bottom"),
            (7, 42, "scroll_to_row:42"),
        ] {
            assert_eq!(spell(code, argument).as_deref(), Some(expected));
        }
    }

    /// An argument outside its verb's range must produce NO action rather than a different one: a
    /// clamped row is a jump somewhere the caller did not ask for, which is worse than a dead key.
    #[test]
    fn an_argument_that_does_not_fit_its_verb_spells_nothing() {
        assert!(spell(1, i64::from(i32::MAX) + 1).is_none());
        assert!(spell(3, 40_000).is_none());
        assert!(spell(4, 4).is_none());
        assert!(spell(7, -1).is_none());
        assert!(spell(0, 0).is_none());
        assert!(spell(8, 0).is_none());
    }

    #[test]
    fn an_argument_carrying_action_crosses_verbatim() {
        let expected = spell(1, -3).unwrap_or_default();
        let mut out = [0_u8; 64];
        // SAFETY: the buffer is a live local for the call.
        let written = unsafe { slopdesk_ws_binding_action(1, -3, out.as_mut_ptr(), out.len()) };
        assert_eq!(written, expected.len());
        assert_eq!(
            core::str::from_utf8(out.get(..written).unwrap_or_default()).unwrap_or_default(),
            expected
        );
        // SAFETY: a null `out` is the documented probe.
        let unknown = unsafe { slopdesk_ws_binding_action(9, 0, core::ptr::null_mut(), 0) };
        assert_eq!(unknown, 0);
    }

    /// A tab, as the caller writes one.
    const fn tab(
        session: u32,
        holds_pane: bool,
        is_focus_tab: bool,
        zoom_is_target: bool,
    ) -> SlopDeskWsFocusTab {
        SlopDeskWsFocusTab {
            session,
            holds_pane,
            is_focus_tab,
            zoom_is_target,
        }
    }

    #[test]
    fn a_pane_focus_crosses_with_its_zoom_verdict() {
        let tabs = [tab(0, false, true, false), tab(1, true, false, false)];
        // SAFETY: the array is a live local for the call.
        let landing = unsafe { slopdesk_ws_device_focus_landing(tabs.as_ptr(), tabs.len(), true) };
        assert!(landing.resolved && landing.focuses_pane && landing.clears_zoom);
        assert_eq!(landing.tab, 1);

        let held = [tab(0, true, false, true)];
        // SAFETY: the array is a live local for the call.
        let kept = unsafe { slopdesk_ws_device_focus_landing(held.as_ptr(), held.len(), true) };
        assert!(kept.resolved && kept.focuses_pane && !kept.clears_zoom);
    }

    #[test]
    fn a_tab_focus_crosses_without_naming_a_pane() {
        let tabs = [tab(0, true, false, false), tab(0, false, true, false)];
        // SAFETY: the array is a live local for the call.
        let landing = unsafe { slopdesk_ws_device_focus_landing(tabs.as_ptr(), tabs.len(), false) };
        assert!(landing.resolved && !landing.focuses_pane && !landing.clears_zoom);
        assert_eq!(landing.tab, 1);
    }

    /// A focus that resolves to nothing is zeroed, and an empty list is the same answer.
    #[test]
    fn an_unresolved_focus_crosses_as_a_zeroed_record() {
        let tabs = [tab(0, false, false, false)];
        // SAFETY: the array is a live local for the call.
        let landing = unsafe { slopdesk_ws_device_focus_landing(tabs.as_ptr(), tabs.len(), true) };
        assert_eq!(landing, SlopDeskWsFocusLanding::default());
        // SAFETY: a zero-length read of a dangling-but-aligned pointer.
        let empty =
            unsafe { slopdesk_ws_device_focus_landing(core::ptr::NonNull::dangling().as_ptr(), 0, true) };
        assert!(!empty.resolved);
    }
}
