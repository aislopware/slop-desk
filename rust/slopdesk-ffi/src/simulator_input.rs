//! The simulator dialect's upstream envelopes, in C.
//!
//! The rules are `slopdesk_devicepanel::sim_input`'s. One door per VERB rather than one door with
//! every field optional, for the reason the crate header gives: the envelope's key set changes per
//! type, and a single entry point covering all of them makes the wrong combination representable.
//! Each answers JSON text through `docs/55` §4's convention — a pure function of its arguments, so
//! the retry a short buffer asks for cannot see a different answer.

use core::ffi::c_uchar;

use slopdesk_devicepanel::sim_input::{
    self, DEFAULT_SWIPE_DURATION, DEFAULT_TAP_DURATION, Modifiers, Surface, TouchPhase,
};

use crate::{borrow, deliver};

/// The contact lands.
pub const SLOPDESK_SIM_TOUCH_DOWN: u8 = 0;
/// The contact moves while still down.
pub const SLOPDESK_SIM_TOUCH_MOVE: u8 = 1;
/// The contact lifts.
pub const SLOPDESK_SIM_TOUCH_UP: u8 = 2;

/// The shift bit of a key chord.
pub const SLOPDESK_SIM_MODIFIER_SHIFT: u8 = 1 << 0;
/// The control bit.
pub const SLOPDESK_SIM_MODIFIER_CONTROL: u8 = 1 << 1;
/// The option bit.
pub const SLOPDESK_SIM_MODIFIER_OPTION: u8 = 1 << 2;
/// The command bit.
pub const SLOPDESK_SIM_MODIFIER_COMMAND: u8 = 1 << 3;

/// Send the text as synthesized keystrokes. US-ASCII only.
pub const SLOPDESK_SIM_TEXT_TYPE: u8 = 0;
/// Send the text through the device's pasteboard — the only path that carries emoji or CJK.
pub const SLOPDESK_SIM_TEXT_PASTE: u8 = 1;

/// The seconds of contact a tap reports when the caller has no reason to ask for another.
///
/// A door rather than a constant in the header because it is the SERVER's default: a number written
/// down on this side would be a second copy of a value the server owns.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_sim_default_tap_duration() -> f64 {
    DEFAULT_TAP_DURATION
}

/// The seconds a one-finger drag is interpolated over by default. See above.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_sim_default_swipe_duration() -> f64 {
    DEFAULT_SWIPE_DURATION
}

/// The surface a positional envelope's coordinates were measured in.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskSimSurface {
    /// The measured surface's width, in the caller's own units.
    pub width: f64,
    /// The measured surface's height, in the same units.
    pub height: f64,
}

impl SlopDeskSimSurface {
    const fn of(self) -> Surface {
        Surface {
            width: self.width,
            height: self.height,
        }
    }
}

const fn phase(byte: u8) -> TouchPhase {
    match byte {
        SLOPDESK_SIM_TOUCH_DOWN => TouchPhase::Down,
        SLOPDESK_SIM_TOUCH_MOVE => TouchPhase::Move,
        // An unknown byte reads as the LIFT, which is the only phase whose worst case is a contact
        // that ends early: an unknown byte taken as a `down` would strand one on the device.
        _ => TouchPhase::Up,
    }
}

/// A tap, or a long-press when `duration` is raised.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_tap(
    x: f64,
    y: f64,
    duration: f64,
    surface: SlopDeskSimSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = sim_input::tap(x, y, duration, surface.of());
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A one-finger drag from start to end, interpolated host-side.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_swipe(
    from_x: f64,
    from_y: f64,
    to_x: f64,
    to_y: f64,
    duration: f64,
    surface: SlopDeskSimSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = sim_input::swipe((from_x, from_y), (to_x, to_y), duration, surface.of());
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A single continuous contact, with the system-edge hint when the gesture began off-screen.
///
/// # Safety
/// `edge` must be readable for `edge_len` bytes when `has_edge`, and `out` writable for `cap`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_touch(
    phase_byte: u8,
    x: f64,
    y: f64,
    edge: *const c_uchar,
    edge_len: usize,
    has_edge: bool,
    surface: SlopDeskSimSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above; borrowed only while `answer` is built.
    let edge = has_edge.then(|| unsafe { borrow(edge, edge_len) });
    let edge = edge.map(String::from_utf8_lossy);
    let answer = sim_input::touch(phase(phase_byte), x, y, edge.as_deref(), surface.of());
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Two simultaneous contacts — pinch, spread, two-finger pan.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_touch2(
    phase_byte: u8,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    surface: SlopDeskSimSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = sim_input::touch2(phase(phase_byte), (x1, y1), (x2, y2), surface.of());
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A hardware button by its server-side name. `hold` above zero is a press-and-hold.
///
/// # Safety
/// `name` must be readable for `name_len` bytes, and `out` writable for `cap`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_button(
    name: *const c_uchar,
    name_len: usize,
    hold: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above; borrowed only while `answer` is built.
    let name = String::from_utf8_lossy(unsafe { borrow(name, name_len) });
    let answer = sim_input::button(&name, hold);
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// One key by its `KeyboardEvent.code` name, with the chord as this module's bits.
///
/// # Safety
/// `code` must be readable for `code_len` bytes, and `out` writable for `cap`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_key(
    code: *const c_uchar,
    code_len: usize,
    modifiers: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above; borrowed only while `answer` is built.
    let code = String::from_utf8_lossy(unsafe { borrow(code, code_len) });
    let answer = sim_input::key(&code, Modifiers::from_bits(modifiers));
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// A run of text, by either route: keystrokes or the device's pasteboard.
///
/// # Safety
/// `text` must be readable for `text_len` bytes, and `out` writable for `cap`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_text(
    route: u8,
    text: *const c_uchar,
    text_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above; borrowed only while `answer` is built.
    let text = String::from_utf8_lossy(unsafe { borrow(text, text_len) });
    let answer = if route == SLOPDESK_SIM_TEXT_PASTE {
        sim_input::paste(&text)
    } else {
        sim_input::type_text(&text)
    };
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Pull the device's current selection onto the host's clipboard.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_input_copy(out: *mut c_uchar, cap: usize) -> usize {
    let answer = sim_input::copy();
    // SAFETY: `answer` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        SLOPDESK_SIM_MODIFIER_COMMAND, SLOPDESK_SIM_MODIFIER_SHIFT, SLOPDESK_SIM_TEXT_PASTE,
        SLOPDESK_SIM_TOUCH_DOWN, SLOPDESK_SIM_TOUCH_UP, SlopDeskSimSurface,
        slopdesk_sim_default_tap_duration, slopdesk_sim_input_copy, slopdesk_sim_input_key,
        slopdesk_sim_input_tap, slopdesk_sim_input_text, slopdesk_sim_input_touch,
    };

    const SURFACE: SlopDeskSimSurface = SlopDeskSimSurface {
        width: 200.0,
        height: 400.0,
    };

    fn text_of(written: usize, buffer: &[u8]) -> String {
        String::from_utf8_lossy(&buffer[..written]).into_owned()
    }

    /// The whole envelope crosses as text, sorted, exactly as the crate spells it — the door adds
    /// nothing and reorders nothing.
    #[test]
    fn a_tap_crosses_whole() {
        let mut out = [0_u8; 128];
        // SAFETY: `out` is a live local for the call.
        let written = unsafe {
            slopdesk_sim_input_tap(
                10.0,
                20.0,
                slopdesk_sim_default_tap_duration(),
                SURFACE,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(
            text_of(written, &out),
            r#"{"duration":0.05,"height":400.0,"type":"tap","width":200.0,"x":10.0,"y":20.0}"#
        );
    }

    /// The edge hint crosses as an OPTIONAL pair, and its absence is a different message — not an
    /// empty string the server would read as an edge named "".
    #[test]
    fn the_edge_hint_crosses_as_its_own_flag() {
        let mut out = [0_u8; 128];
        let mut touch = |edge: Option<&str>| {
            let bytes = edge.unwrap_or_default().as_bytes();
            // SAFETY: both buffers are live locals for the call.
            let written = unsafe {
                slopdesk_sim_input_touch(
                    SLOPDESK_SIM_TOUCH_DOWN,
                    1.0,
                    2.0,
                    bytes.as_ptr(),
                    bytes.len(),
                    edge.is_some(),
                    SURFACE,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            text_of(written, &out)
        };

        assert!(!touch(None).contains("edge"));
        assert!(touch(Some("bottom")).contains(r#""edge":"bottom""#));
    }

    /// A phase byte this build does not know reads as the LIFT: the only phase whose worst case is
    /// a contact that ends early, where a `down` would strand one on the device.
    #[test]
    fn an_unknown_phase_byte_lifts_rather_than_plants() {
        let mut out = [0_u8; 128];
        let mut verb = |byte: u8| {
            // SAFETY: `out` is a live local for the call.
            let written = unsafe {
                slopdesk_sim_input_touch(
                    byte,
                    1.0,
                    2.0,
                    core::ptr::null(),
                    0,
                    false,
                    SURFACE,
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            text_of(written, &out)
        };

        assert!(verb(SLOPDESK_SIM_TOUCH_UP).contains("touch1-up"));
        assert!(verb(0xFF).contains("touch1-up"));
    }

    /// The chord crosses as BITS and comes back as names in one fixed order, so two callers that
    /// held the same keys cannot send two different messages.
    #[test]
    fn the_chord_crosses_as_bits() {
        let code = b"KeyA";
        let mut out = [0_u8; 128];
        // SAFETY: both buffers are live locals for the call.
        let written = unsafe {
            slopdesk_sim_input_key(
                code.as_ptr(),
                code.len(),
                SLOPDESK_SIM_MODIFIER_COMMAND | SLOPDESK_SIM_MODIFIER_SHIFT,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(
            text_of(written, &out),
            r#"{"code":"KeyA","modifiers":["shift","command"],"type":"key"}"#
        );
    }

    /// The two text routes stay distinct across the door: one is keystrokes, the other the
    /// pasteboard, and only the second carries anything outside ASCII.
    #[test]
    fn the_text_route_picks_the_verb() {
        let text = "🙂".as_bytes();
        let mut out = [0_u8; 128];
        let mut send = |route: u8| {
            // SAFETY: both buffers are live locals for the call.
            let written = unsafe {
                slopdesk_sim_input_text(route, text.as_ptr(), text.len(), out.as_mut_ptr(), out.len())
            };
            text_of(written, &out)
        };

        assert!(send(SLOPDESK_SIM_TEXT_PASTE).contains(r#""type":"paste""#));
        assert!(send(0).contains(r#""type":"type""#));
    }

    /// The §4 retry: no room answers the size and writes nothing, and asking again answers the same
    /// bytes — every door here is a pure function of its arguments.
    #[test]
    fn a_short_buffer_answers_the_size_and_writes_nothing() {
        // SAFETY: the delivery pointer is null with a matching capacity of zero.
        let needed = unsafe { slopdesk_sim_input_copy(core::ptr::null_mut(), 0) };
        assert_eq!(needed, r#"{"type":"copy"}"#.len());

        let mut out = [0_u8; 64];
        // SAFETY: `out` is a live local for the call.
        let written = unsafe { slopdesk_sim_input_copy(out.as_mut_ptr(), out.len()) };
        assert_eq!(text_of(written, &out), r#"{"type":"copy"}"#);
    }
}
