//! What Settings offers, in C.
//!
//! The rules are `slopdesk_workspace::settings_catalog`; what is here is the marshalling. Every
//! door is a COUNT plus indexed accessors, which is this boundary's idiom for a list — the near
//! side asks how many rows a group has, then asks each row for its three strings. A settings page
//! renders once per open, so the call count is not the thing to optimise; being able to add an
//! option without touching a struct layout is.
//!
//! ## An empty string and a missing one say different things
//!
//! A caption is genuinely optional — most choices have none — and
//! [`slopdesk_settings_option_caption`] answers `0` for both "this row has no caption" and "this
//! index has no row". That is deliberate and safe: a caller that asked for row `i` already learned
//! from the count that row `i` exists, and a caption of zero length and no caption at all render
//! identically. Nothing downstream branches on the difference.
//!
//! ## The token is the contract, not the index
//!
//! Each option crosses as the value the store PERSISTS. The near side rebuilds its own Swift enum
//! from it with the `RawRepresentable` init it already has, so inserting a case in either language
//! cannot silently re-point a row at a different value the way a case index would.

use core::ffi::c_uchar;

use slopdesk_workspace::settings_catalog::{self, ApplyTiming, Group, Ladder, Section, Stepper};

use crate::deliver;

/// A ladder's range and granularity, flat.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskSettingsLadder {
    /// The lowest settable value.
    pub min: f64,
    /// The highest.
    pub max: f64,
    /// The slider's granularity.
    pub step: f64,
    /// Whether `ladder` named a ladder at all. `false` leaves the three above at zero.
    pub known: bool,
}

/// A stepper range's ends and granularity, flat.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskSettingsStepper {
    /// The lowest settable value.
    pub min: i64,
    /// The highest.
    pub max: i64,
    /// How far one click moves it.
    pub step: i64,
    /// Whether `stepper` named a range at all. `false` leaves the three above at zero.
    pub known: bool,
}

/// How many choices a group offers. `0` for a group index no group has.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_option_count(group: u8) -> usize {
    Group::from_index(group).map_or(0, |id| settings_catalog::group(id).len())
}

/// The value a choice PERSISTS — the Swift enum's `rawValue`.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_option_token(
    group: u8,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { option_field(group, index, out, cap, |row| row.token) }
}

/// What a choice is called.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_option_label(
    group: u8,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { option_field(group, index, out, cap, |row| row.label) }
}

/// A choice's caveat, or `0` for one that has none.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_option_caption(
    group: u8,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { option_field(group, index, out, cap, |row| row.caption) }
}

/// One field of one option row, delivered.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "the delivery is the marshalling; every door above restates the same obligation"
)]
unsafe fn option_field(
    group: u8,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
    field: impl Fn(&settings_catalog::OptionRow) -> &'static str,
) -> usize {
    let Some(row) = Group::from_index(group).and_then(|id| settings_catalog::option(id, index)) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(field(row).as_bytes(), out, cap) }
}

/// The one-line form a `.menu` picker shows: the label with the caveat folded in after an en dash.
///
/// A menu item has no second line to hang a caption on, so the fold is what keeps the honesty a
/// caption carries from vanishing when a group renders as a dropdown instead of as cards. It
/// crosses as its own door rather than being re-concatenated on the near side — the en dash and the
/// no-caption case are a rule, and a rule spelled in two languages is two rules.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_option_menu_label(
    group: u8,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(row) = Group::from_index(group).and_then(|id| settings_catalog::option(id, index)) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(row.menu_label().as_bytes(), out, cap) }
}

/// A `density` token by NAME rather than by position.
///
/// The density group is the one group whose value the store persists as a bare string rather than
/// through an enum, so the near side has no `RawRepresentable` to round-trip it through and would
/// otherwise spell `"compact"` itself — in the two `?? "comfortable"` fallbacks as well as in the
/// card art's is-this-the-compact-one test. One door keeps all four spellings the same one.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_settings_density_token(
    compact: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let token = if compact {
        settings_catalog::DENSITY_COMPACT
    } else {
        settings_catalog::DENSITY_COMFORTABLE
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(token.as_bytes(), out, cap) }
}

/// How many sections the taxonomy has.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_settings_section_count() -> usize {
    Section::ALL.len()
}

/// A section's routed identifier.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_section_id(index: usize, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { section_field(index, out, cap, Section::id) }
}

/// A section's row label.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_section_title(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { section_field(index, out, cap, Section::title) }
}

/// A section's SF Symbol name.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_section_symbol(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above.
    unsafe { section_field(index, out, cap, Section::symbol) }
}

/// One field of one section, delivered.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "the delivery is the marshalling; every door above restates the same obligation"
)]
unsafe fn section_field(
    index: usize,
    out: *mut c_uchar,
    cap: usize,
    field: impl Fn(Section) -> &'static str,
) -> usize {
    let Some(section) = Section::from_index(index) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(field(section).as_bytes(), out, cap) }
}

/// The apply-timing chip's text.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_settings_timing_label(
    timing: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(timing) = ApplyTiming::from_index(timing) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(timing.label().as_bytes(), out, cap) }
}

/// The apply-timing chip's glyph.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_settings_timing_symbol(
    timing: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(timing) = ApplyTiming::from_index(timing) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(timing.symbol().as_bytes(), out, cap) }
}

/// A ladder's range and granularity.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_ladder(ladder: u8) -> SlopDeskSettingsLadder {
    let Some(bounds) = Ladder::from_index(ladder).map(Ladder::bounds) else {
        return SlopDeskSettingsLadder {
            min: 0.0,
            max: 0.0,
            step: 0.0,
            known: false,
        };
    };
    SlopDeskSettingsLadder {
        min: bounds.min,
        max: bounds.max,
        step: bounds.step,
        known: true,
    }
}

/// How many magnitude stops a ladder has.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_ladder_preset_count(ladder: u8) -> usize {
    Ladder::from_index(ladder).map_or(0, |id| id.presets().len())
}

/// What a stop sets. `NaN` for a stop that does not exist, which no caller reaches after asking the
/// count — a sentinel rather than a silent zero, because zero is a legitimate stop.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_ladder_preset_value(ladder: u8, index: usize) -> f64 {
    Ladder::from_index(ladder)
        .and_then(|id| id.presets().get(index))
        .map_or(f64::NAN, |preset| preset.value)
}

/// What a stop is called.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_ladder_preset_label(
    ladder: u8,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(preset) = Ladder::from_index(ladder).and_then(|id| id.presets().get(index)) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(preset.label.as_bytes(), out, cap) }
}

/// What the slider's current value reads as.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_ladder_readout(
    ladder: u8,
    value: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(text) = Ladder::from_index(ladder).map(|id| id.readout(value)) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// A stepper range's ends and granularity.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_settings_stepper(stepper: u8) -> SlopDeskSettingsStepper {
    let Some(bounds) = Stepper::from_index(stepper).map(Stepper::bounds) else {
        return SlopDeskSettingsStepper {
            min: 0,
            max: 0,
            step: 0,
            known: false,
        };
    };
    SlopDeskSettingsStepper {
        min: bounds.min,
        max: bounds.max,
        step: bounds.step,
        known: true,
    }
}

/// What a stepper's value reads as after the row's label — `80`, `1000 px`, `13.5`.
///
/// The UNIT used to cross instead, on the argument that the near side does not always hold an
/// integer — font size is a `Double` — so each side would compose from the value it actually has.
/// Both then did, and the two compositions stopped agreeing: only one of them dropped the fraction
/// off a whole value. The value is a `double` here for that reason, and the composition is one.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_settings_stepper_readout(
    stepper: u8,
    value: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(text) = Stepper::from_index(stepper).map(|stepper| stepper.readout(value)) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::*;

    /// Reads a delivered string back, exercising the retry protocol on anything that overflows.
    fn read(mut door: impl FnMut(*mut c_uchar, usize) -> usize) -> Option<String> {
        let mut out = [0_u8; 64];
        let written = door(out.as_mut_ptr(), out.len());
        if written == 0 {
            return None;
        }
        assert!(
            written <= out.len(),
            "no catalog string is longer than the probe buffer"
        );
        out.get(..written)
            .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
    }

    #[test]
    fn a_group_crosses_row_by_row() {
        let group = Group::CursorStyle.index();
        assert_eq!(slopdesk_settings_option_count(group), 4);
        // SAFETY: the buffer inside `read` is a live local.
        let token = read(|out, cap| unsafe { slopdesk_settings_option_token(group, 0, out, cap) });
        assert_eq!(token.as_deref(), Some("block"));
        // SAFETY: as above.
        let label = read(|out, cap| unsafe { slopdesk_settings_option_label(group, 0, out, cap) });
        assert_eq!(label.as_deref(), Some("Block"));
        // SAFETY: as above.
        let caption = read(|out, cap| unsafe { slopdesk_settings_option_caption(group, 0, out, cap) });
        assert_eq!(caption, None, "a cursor style needs no caveat");
    }

    #[test]
    fn a_caveat_crosses_when_there_is_one() {
        let group = Group::NewTabPosition.index();
        // SAFETY: the buffer inside `read` is a live local.
        let caption = read(|out, cap| unsafe { slopdesk_settings_option_caption(group, 0, out, cap) });
        assert_eq!(caption.as_deref(), Some("Appends, like End"));
    }

    #[test]
    fn an_unknown_group_or_index_is_an_answer_rather_than_a_crash() {
        assert_eq!(slopdesk_settings_option_count(200), 0);
        // SAFETY: the buffer inside `read` is a live local.
        assert_eq!(
            read(|out, cap| unsafe { slopdesk_settings_option_token(200, 0, out, cap) }),
            None
        );
        // SAFETY: as above.
        assert_eq!(
            read(|out, cap| unsafe { slopdesk_settings_option_token(Group::Density.index(), 99, out, cap) }),
            None,
        );
        // SAFETY: a null buffer with a zero capacity is what `deliver` is written against.
        assert_eq!(
            unsafe { slopdesk_settings_option_token(Group::Density.index(), 0, core::ptr::null_mut(), 0) },
            "comfortable".len(),
            "an overflow reports the size it needs and writes nothing",
        );
    }

    #[test]
    fn a_menu_label_crosses_folded() {
        let group = Group::NewTabPosition.index();
        // SAFETY: the buffer inside `read` is a live local.
        let folded = read(|out, cap| unsafe { slopdesk_settings_option_menu_label(group, 0, out, cap) });
        assert_eq!(folded.as_deref(), Some("Automatic — Appends, like End"));
        // SAFETY: as above.
        let plain = read(|out, cap| unsafe { slopdesk_settings_option_menu_label(group, 1, out, cap) });
        assert_eq!(plain.as_deref(), Some("End"), "no caveat, no dangling dash");
    }

    #[test]
    fn the_density_tokens_cross_by_name() {
        // SAFETY: the buffer inside `read` is a live local.
        let compact = read(|out, cap| unsafe { slopdesk_settings_density_token(true, out, cap) });
        assert_eq!(compact.as_deref(), Some("compact"));
        // SAFETY: as above.
        let comfortable = read(|out, cap| unsafe { slopdesk_settings_density_token(false, out, cap) });
        assert_eq!(comfortable.as_deref(), Some("comfortable"));
        let tokens: Vec<&str> = settings_catalog::group(Group::Density)
            .iter()
            .map(|row| row.token)
            .collect();
        assert_eq!(
            tokens,
            vec![
                comfortable.as_deref().unwrap_or_default(),
                compact.as_deref().unwrap_or_default()
            ],
            "the named tokens ARE the group's, in its order",
        );
    }

    /// Every section crosses, in one order, for BOTH halves — there is no longer a per-section
    /// platform flag to cross beside them, because no section is one half's alone (docs/56
    /// increment 30).
    #[test]
    fn the_taxonomy_crosses_in_order_for_both_halves() {
        assert_eq!(slopdesk_settings_section_count(), 8);
        let ids: Vec<Option<String>> = (0..slopdesk_settings_section_count())
            // SAFETY: the buffer inside `read` is a live local.
            .map(|index| read(|out, cap| unsafe { slopdesk_settings_section_id(index, out, cap) }))
            .collect();
        assert_eq!(ids.first().and_then(Clone::clone).as_deref(), Some("general"));
        assert_eq!(ids.last().and_then(Clone::clone).as_deref(), Some("advanced"));
        assert!(ids.iter().all(Option::is_some), "no section crosses nameless");
    }

    #[test]
    fn a_ladder_crosses_with_its_stops_and_its_readout() {
        let ladder = Ladder::Scrollback.index();
        let bounds = slopdesk_settings_ladder(ladder);
        assert!(bounds.known);
        assert!((bounds.min - 1000.0).abs() < 1e-9);
        assert!((bounds.max - 100_000.0).abs() < 1e-9);
        assert_eq!(slopdesk_settings_ladder_preset_count(ladder), 5);
        assert!((slopdesk_settings_ladder_preset_value(ladder, 0) - 1000.0).abs() < 1e-9);
        assert!(slopdesk_settings_ladder_preset_value(ladder, 99).is_nan());
        // SAFETY: the buffer inside `read` is a live local.
        let label = read(|out, cap| unsafe { slopdesk_settings_ladder_preset_label(ladder, 4, out, cap) });
        assert_eq!(label.as_deref(), Some("100k"));
        // SAFETY: as above.
        let readout = read(|out, cap| unsafe { slopdesk_settings_ladder_readout(ladder, 50000.0, out, cap) });
        assert_eq!(readout.as_deref(), Some("50\u{202F}000 lines"));

        let unknown = slopdesk_settings_ladder(200);
        assert!(!unknown.known);
        assert_eq!(slopdesk_settings_ladder_preset_count(200), 0);
    }

    #[test]
    fn a_stepper_readout_crosses_composed() {
        let pixels = Stepper::WindowPixels.index();
        // SAFETY: the buffer inside `read` is a live local.
        let whole = read(|out, cap| unsafe { slopdesk_settings_stepper_readout(pixels, 1000.0, out, cap) });
        assert_eq!(whole.as_deref(), Some("1000 px"));
        // SAFETY: as above.
        let fractional =
            read(|out, cap| unsafe { slopdesk_settings_stepper_readout(Stepper::FontPoints.index(), 13.5, out, cap) });
        assert_eq!(fractional.as_deref(), Some("13.5"));
        // SAFETY: as above.
        assert_eq!(
            read(|out, cap| unsafe { slopdesk_settings_stepper_readout(200, 1.0, out, cap) }),
            None,
            "an unknown stepper is an answer rather than a crash",
        );
    }

    #[test]
    fn the_timing_chip_crosses_both_ways() {
        // SAFETY: the buffer inside `read` is a live local.
        let live = read(|out, cap| unsafe { slopdesk_settings_timing_label(0, out, cap) });
        assert_eq!(live.as_deref(), Some("Applies now"));
        // SAFETY: as above.
        let symbol = read(|out, cap| unsafe { slopdesk_settings_timing_symbol(1, out, cap) });
        assert_eq!(symbol.as_deref(), Some("arrow.triangle.2.circlepath"));
        // SAFETY: as above.
        assert_eq!(
            read(|out, cap| unsafe { slopdesk_settings_timing_label(9, out, cap) }),
            None
        );
    }
}
