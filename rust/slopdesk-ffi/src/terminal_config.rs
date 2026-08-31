//! The terminal's FACTORY defaults, and the text a settings number is written with.
//!
//! ## What was here
//!
//! A door that spelled a whole libghostty config TEXT from two dozen interned runs, for the deleted
//! fork's `ghostty_config_load_string`. The renderer that replaced the fork takes typed doors — the
//! `slopdesk_term_surface_set_*` family in [`crate::terminal_surface`] — so the text had no parser
//! on the other end and every run in that record was a value already crossing somewhere else. It
//! went with [`slopdesk_terminal::config`]'s emitter; `docs/68` argues the boundary.
//!
//! What is left is the two answers that never had anything to do with the text: what a fresh
//! install carries, and how a number is spelled.

use core::ffi::c_uchar;

use slopdesk_terminal::config::{ENV_INTEGRAL_LIMIT, number_text};

use crate::deliver;

/// A FACTORY default that is a string, by index: 0 the font family, 1 the background, 2 the
/// foreground. Any other index answers empty.
///
/// The defaults cross as data rather than being retyped at the caller: they used to sit in a Swift
/// `init`'s default arguments AND in this crate's test fixture, with nothing connecting the two
/// lists.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_terminal_factory_text(
    field: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let text = match field {
        0 => slopdesk_terminal::config::FACTORY_FONT_FAMILY,
        1 => slopdesk_terminal::config::FACTORY_BACKGROUND,
        2 => slopdesk_terminal::config::FACTORY_FOREGROUND,
        _ => "",
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// A FACTORY default that is a number, by index: 0 the point size, 1 the cursor opacity, 2 the
/// scrollback depth in lines. Any other index answers zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_terminal_factory_number(field: u8) -> f64 {
    match field {
        0 => slopdesk_terminal::config::FACTORY_FONT_SIZE,
        1 => slopdesk_terminal::config::FACTORY_CURSOR_OPACITY,
        #[expect(
            clippy::cast_precision_loss,
            reason = "a line count this small is exact in f64"
        )]
        2 => slopdesk_terminal::config::FACTORY_SCROLLBACK_LINES as f64,
        _ => 0.0,
    }
}

/// Writes the text a `SLOPDESK_*` environment value is written with into the lent buffer.
///
/// One spelling, two limits — see [`number_text`]. The env overlay asks at the limit a millisecond
/// count reaches; the settings file asks at its own, on the Rust side, and neither spells the rule.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_settings_env_number_text(
    value: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let text = number_text(value, ENV_INTEGRAL_LIMIT);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(text.as_bytes(), out, cap) }
}
