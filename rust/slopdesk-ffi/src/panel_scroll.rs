//! A device panel's virtual finger, in C.
//!
//! The machine is `slopdesk_devicepanel::scroll`'s. A HANDLE rather than a fold over scalars
//! (`docs/55` §4b) because a scroll gesture is exactly the thing a tick is not: where the contact
//! is, and whether there is one at all, must survive between events, and a caller that carried that
//! across the boundary would be holding the half of the machine that decides where the next plant
//! lands.
//!
//! The contacts come back in the FITTED rect's own space. What each becomes on the wire is the
//! panel's — the simulator sends those coordinates with the surface size beside them, the Android
//! lane converts to the video's pixel grid — and neither conversion belongs to a state machine that
//! is the same on both.

use slopdesk_devicepanel::scroll::{Action, ScrollGesture, ScrollPhase};

use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

/// The gesture began, or the first change of one that began off-view.
pub const SLOPDESK_PANEL_SCROLL_BEGAN: u8 = 0;
/// The gesture continues.
pub const SLOPDESK_PANEL_SCROLL_CHANGED: u8 = 1;
/// The fingers left the trackpad — ended or cancelled.
pub const SLOPDESK_PANEL_SCROLL_ENDED: u8 = 2;
/// A classic wheel notch, which carries no phase of its own.
pub const SLOPDESK_PANEL_SCROLL_WHEEL: u8 = 3;

/// Plant the contact.
pub const SLOPDESK_PANEL_CONTACT_DOWN: u8 = 0;
/// Move the contact that is already down.
pub const SLOPDESK_PANEL_CONTACT_MOVE: u8 = 1;
/// Lift the contact.
pub const SLOPDESK_PANEL_CONTACT_UP: u8 = 2;

/// The most contacts one event can produce: the re-grip, which moves to the boundary, lifts, and
/// plants again. A caller may size its buffer by this and never retry.
pub const SLOPDESK_PANEL_CONTACT_MAX: usize = 4;

/// One thing to send, in the order it must be sent.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskPanelContact {
    /// Where the finger does it, in the fitted rect's own space.
    pub point: SlopDeskVideoPoint,
    /// What the finger does — one of the `SLOPDESK_PANEL_CONTACT_*` codes.
    pub action: u8,
}

/// One panel's virtual finger, opaque to the caller.
///
/// `Copy` deliberately absent: the handle is the OWNER of a boxed gesture, and a type that copied
/// would let a caller hold two states that agree only until the first event.
#[derive(Debug)]
#[expect(
    missing_copy_implementations,
    reason = "a copied gesture is two contacts on one device"
)]
pub struct SlopDeskPanelScroll {
    gesture: ScrollGesture,
}

/// Creates a scroll gesture. Exactly one [`slopdesk_panel_scroll_free`] per call; see `docs/55`
/// §4b.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_panel_scroll_new() -> *mut SlopDeskPanelScroll {
    Box::into_raw(Box::new(SlopDeskPanelScroll {
        gesture: ScrollGesture::new(),
    }))
}

/// Frees a scroll gesture. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_panel_scroll_new`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_scroll_free(handle: *mut SlopDeskPanelScroll) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from `Box::into_raw` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Feed one scroll event. Answers how many contacts it produced, writing up to `cap` of them.
///
/// `angle` un-rotates the delta for a panel whose frame is DRAWN turned while its framebuffer is
/// not. Zero for a panel that rotates on the device instead.
///
/// A null handle answers zero and changes nothing, which is the conservative reading of a call that
/// could not be made.
///
/// # Safety
/// `handle` must be null, or a live gesture with no other call on it in flight; `out` must be
/// writable for `cap` contacts.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_scroll_accept(
    handle: *mut SlopDeskPanelScroll,
    delta: SlopDeskVideoSize,
    is_precise: bool,
    phase_byte: u8,
    pointer: SlopDeskVideoPoint,
    fitted: SlopDeskVideoRect,
    angle: f64,
    out: *mut SlopDeskPanelContact,
    cap: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: non-null by the check above, and a live gesture with no other call in flight by the
    // caller's obligation.
    let state = unsafe { &mut *handle };
    let contacts = state.gesture.accept(
        delta.of(),
        is_precise,
        phase(phase_byte),
        pointer.of(),
        fitted.of(),
        angle,
    );
    // SAFETY: `out` is writable for `cap` contacts by the caller's obligation.
    unsafe { write_contacts(&contacts, out, cap) }
}

/// Close a gesture the caller's idle timer has decided is over. Zero with no contact down.
///
/// # Safety
/// As [`slopdesk_panel_scroll_accept`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_scroll_lift(
    handle: *mut SlopDeskPanelScroll,
    out: *mut SlopDeskPanelContact,
    cap: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: non-null by the check above, and live by the caller's obligation.
    let state = unsafe { &mut *handle };
    let contacts = state.gesture.lift();
    // SAFETY: `out` is writable for `cap` contacts by the caller's obligation.
    unsafe { write_contacts(&contacts, out, cap) }
}

/// Forget the contact without producing anything — the socket went away, so a lift has nowhere to
/// go and the device's touch state is moot.
///
/// # Safety
/// `handle` must be null, or a live gesture with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_scroll_abandon(handle: *mut SlopDeskPanelScroll) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null by the check above, and live by the caller's obligation.
    unsafe { &mut *handle }.gesture.abandon();
}

/// Whether a contact is down, and where. `false` — and `out` untouched — when there is none.
///
/// # Safety
/// `handle` must be null, or a live gesture; `out` must be writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_panel_scroll_finger(
    handle: *const SlopDeskPanelScroll,
    out: *mut SlopDeskVideoPoint,
) -> bool {
    if handle.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: non-null by the check above, and live by the caller's obligation.
    let Some(point) = unsafe { &*handle }.gesture.finger() else {
        return false;
    };
    // SAFETY: `out` was just checked non-null and is writable by the caller's obligation.
    unsafe { out.write(SlopDeskVideoPoint::from(point)) };
    true
}

const fn phase(byte: u8) -> ScrollPhase {
    match byte {
        SLOPDESK_PANEL_SCROLL_BEGAN => ScrollPhase::Began,
        SLOPDESK_PANEL_SCROLL_CHANGED => ScrollPhase::Changed,
        SLOPDESK_PANEL_SCROLL_WHEEL => ScrollPhase::Wheel,
        // An unknown byte reads as the END, which is the only phase whose worst case is a gesture
        // that stops early: taken as a `began` it would strand a contact on the device.
        _ => ScrollPhase::Ended,
    }
}

const fn action(action: Action) -> u8 {
    match action {
        Action::Down => SLOPDESK_PANEL_CONTACT_DOWN,
        Action::Move => SLOPDESK_PANEL_CONTACT_MOVE,
        Action::Up => SLOPDESK_PANEL_CONTACT_UP,
    }
}

/// Writes as many contacts as fit and answers how many there WERE — the count convention `docs/55`
/// §4 gives for an array, so a caller that under-sized its buffer knows to ask again.
///
/// # Safety
/// `out` must be writable for `cap` contacts.
#[expect(
    unsafe_code,
    reason = "writing a caller-owned array is the whole of this helper"
)]
unsafe fn write_contacts(
    contacts: &[slopdesk_devicepanel::scroll::Contact],
    out: *mut SlopDeskPanelContact,
    cap: usize,
) -> usize {
    let needed = contacts.len();
    if needed == 0 || needed > cap || out.is_null() {
        return needed;
    }
    for (index, contact) in contacts.iter().enumerate() {
        let record = SlopDeskPanelContact {
            point: SlopDeskVideoPoint::from(contact.point),
            action: action(contact.action),
        };
        // SAFETY: `index < needed <= cap`, and `out` is writable for `cap` contacts by the caller's
        // obligation, so every offset written stays inside the array it was given.
        unsafe { out.add(index).write(record) };
    }
    needed
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::float_cmp,
    reason = "calling the boundary IS what these tests are for, and a coordinate that must land on a whole \
              point is pinned exactly or not at all"
)]
mod tests {
    use super::{
        SLOPDESK_PANEL_CONTACT_DOWN, SLOPDESK_PANEL_CONTACT_MAX, SLOPDESK_PANEL_CONTACT_MOVE,
        SLOPDESK_PANEL_CONTACT_UP, SLOPDESK_PANEL_SCROLL_BEGAN, SLOPDESK_PANEL_SCROLL_CHANGED,
        SLOPDESK_PANEL_SCROLL_ENDED, SlopDeskPanelContact, SlopDeskPanelScroll,
        slopdesk_panel_scroll_abandon, slopdesk_panel_scroll_accept, slopdesk_panel_scroll_finger,
        slopdesk_panel_scroll_free, slopdesk_panel_scroll_lift, slopdesk_panel_scroll_new,
    };
    use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

    const FITTED: SlopDeskVideoRect = SlopDeskVideoRect {
        x: 0.0,
        y: 0.0,
        width: 200.0,
        height: 400.0,
    };

    fn accept(
        handle: *mut SlopDeskPanelScroll,
        dy: f64,
        phase: u8,
        pointer_y: f64,
    ) -> Vec<SlopDeskPanelContact> {
        let mut out = [SlopDeskPanelContact::default(); SLOPDESK_PANEL_CONTACT_MAX];
        // SAFETY: `handle` is live for the test and `out` is a live local for the call.
        let count = unsafe {
            slopdesk_panel_scroll_accept(
                handle,
                SlopDeskVideoSize {
                    width: 0.0,
                    height: dy,
                },
                true,
                phase,
                SlopDeskVideoPoint {
                    x: 100.0,
                    y: pointer_y,
                },
                FITTED,
                0.0,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        out[..count].to_vec()
    }

    fn actions(contacts: &[SlopDeskPanelContact]) -> Vec<u8> {
        contacts.iter().map(|contact| contact.action).collect()
    }

    /// The handle is what carries the contact between events: the second call MOVES rather than
    /// planting again, which is the whole reason this is not a fold over scalars.
    #[test]
    fn the_handle_remembers_the_contact_between_events() {
        let handle = slopdesk_panel_scroll_new();

        assert_eq!(
            actions(&accept(handle, -1.0, SLOPDESK_PANEL_SCROLL_BEGAN, 200.0)),
            [SLOPDESK_PANEL_CONTACT_DOWN, SLOPDESK_PANEL_CONTACT_MOVE]
        );
        assert_eq!(
            actions(&accept(handle, -1.0, SLOPDESK_PANEL_SCROLL_CHANGED, 200.0)),
            [SLOPDESK_PANEL_CONTACT_MOVE]
        );

        let mut finger = SlopDeskVideoPoint::default();
        // SAFETY: both are live for the call.
        assert!(unsafe { slopdesk_panel_scroll_finger(handle, &raw mut finger) });
        assert_eq!(finger.y, 198.0);

        // SAFETY: created above by `new` and not yet freed.
        unsafe { slopdesk_panel_scroll_free(handle) };
    }

    /// The re-grip is the longest event, and its length is what `SLOPDESK_PANEL_CONTACT_MAX` names:
    /// a caller sizing by it never has to ask twice.
    #[test]
    fn the_longest_event_fits_the_advertised_maximum() {
        let handle = slopdesk_panel_scroll_new();
        accept(handle, -1.0, SLOPDESK_PANEL_SCROLL_BEGAN, 30.0);
        let contacts = accept(handle, -100.0, SLOPDESK_PANEL_SCROLL_CHANGED, 30.0);

        assert_eq!(actions(&contacts), [
            SLOPDESK_PANEL_CONTACT_MOVE,
            SLOPDESK_PANEL_CONTACT_UP,
            SLOPDESK_PANEL_CONTACT_DOWN
        ]);
        assert!(contacts.len() <= SLOPDESK_PANEL_CONTACT_MAX);

        // SAFETY: created above by `new` and not yet freed.
        unsafe { slopdesk_panel_scroll_free(handle) };
    }

    /// An under-sized buffer answers the COUNT and writes nothing, which is the array retry.
    #[test]
    fn a_short_buffer_answers_the_count_and_writes_nothing() {
        let handle = slopdesk_panel_scroll_new();
        let mut out = [SlopDeskPanelContact::default(); 1];
        // SAFETY: `handle` and `out` are live for the call.
        let count = unsafe {
            slopdesk_panel_scroll_accept(
                handle,
                SlopDeskVideoSize {
                    width: 0.0,
                    height: -1.0,
                },
                true,
                SLOPDESK_PANEL_SCROLL_BEGAN,
                SlopDeskVideoPoint { x: 100.0, y: 200.0 },
                FITTED,
                0.0,
                out.as_mut_ptr(),
                out.len(),
            )
        };

        assert_eq!(count, 2);
        assert_eq!(out[0], SlopDeskPanelContact::default());

        // SAFETY: created above by `new` and not yet freed.
        unsafe { slopdesk_panel_scroll_free(handle) };
    }

    /// Abandoning produces nothing and still forgets the contact, and lifting after it is silent —
    /// an extra `up` is a tap the user did not make.
    #[test]
    fn abandoning_is_silent_and_still_forgets() {
        let handle = slopdesk_panel_scroll_new();
        accept(handle, -1.0, SLOPDESK_PANEL_SCROLL_BEGAN, 200.0);

        // SAFETY: `handle` is live for the test.
        unsafe { slopdesk_panel_scroll_abandon(handle) };

        let mut finger = SlopDeskVideoPoint::default();
        // SAFETY: both are live for the call.
        assert!(!unsafe { slopdesk_panel_scroll_finger(handle, &raw mut finger) });

        let mut out = [SlopDeskPanelContact::default(); SLOPDESK_PANEL_CONTACT_MAX];
        // SAFETY: both are live for the call.
        let count = unsafe { slopdesk_panel_scroll_lift(handle, out.as_mut_ptr(), out.len()) };
        assert_eq!(count, 0);

        // SAFETY: created above by `new` and not yet freed.
        unsafe { slopdesk_panel_scroll_free(handle) };
    }

    /// A phase byte this build does not know ENDS the gesture: taken as a `began` it would strand a
    /// contact on the device, which no later event can clear.
    #[test]
    fn an_unknown_phase_byte_ends_rather_than_plants() {
        let handle = slopdesk_panel_scroll_new();
        accept(handle, -1.0, SLOPDESK_PANEL_SCROLL_BEGAN, 200.0);

        assert_eq!(actions(&accept(handle, 0.0, 0xFF, 200.0)), [
            SLOPDESK_PANEL_CONTACT_UP
        ]);
        assert!(accept(handle, 0.0, SLOPDESK_PANEL_SCROLL_ENDED, 200.0).is_empty());

        // SAFETY: created above by `new` and not yet freed.
        unsafe { slopdesk_panel_scroll_free(handle) };
    }

    /// A null handle answers nothing and does nothing, and a null free is a no-op — the two calls a
    /// caller makes when its own construction failed.
    #[test]
    fn a_null_handle_is_inert() {
        let mut out = [SlopDeskPanelContact::default(); SLOPDESK_PANEL_CONTACT_MAX];
        // SAFETY: a null handle is explicitly allowed by each door's contract.
        unsafe {
            assert_eq!(
                slopdesk_panel_scroll_lift(core::ptr::null_mut(), out.as_mut_ptr(), out.len()),
                0
            );
            slopdesk_panel_scroll_abandon(core::ptr::null_mut());
            slopdesk_panel_scroll_free(core::ptr::null_mut());
            assert!(!slopdesk_panel_scroll_finger(
                core::ptr::null(),
                core::ptr::null_mut()
            ));
        }
    }
}
