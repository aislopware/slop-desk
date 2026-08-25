//! What the Simulators surface SAYS and which of its situations a state picks, in C.
//!
//! The rules are `slopdesk_devicepanel::simulator`; what is here is the marshalling, and it is the
//! shape [`crate::android_presentation`]'s header argues for — kind bytes for the folds, one
//! delivery per table of words, `[u32 length][UTF-8 bytes]` big-endian throughout.
//!
//! The two panels get two modules here for the reason they get two modules in the wrapped crate:
//! they look alike and share not one byte of protocol, so a common door would be an abstraction
//! over a coincidence. What they genuinely share — the severity scale, the geometry, the key table
//! — already crosses through [`crate::device_log`], [`crate::device_geometry`] and
//! [`crate::panel_key`].

use core::ffi::c_uchar;

use slopdesk_devicelog::Severity;
use slopdesk_devicepanel::simulator::{self, DeviceVerb, Orientation, Plate, StageState, Turn};

use crate::{borrow, deliver, push_text};

/// Reads a lent `(ptr, len)` as UTF-8, treating invalid bytes as the empty string.
///
/// The same non-answer [`crate::android_presentation`]'s twin makes, for the same reason: the state
/// word that reaches [`simulator::row_subtitle`] must not silently compare equal to `Shutdown`
/// because a mangled byte folded that way.
///
/// # Safety
/// `ptr` must be null, or point to `len` live bytes for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
unsafe fn text<'a>(ptr: *const c_uchar, len: usize) -> &'a str {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    core::str::from_utf8(unsafe { borrow(ptr, len) }).unwrap_or_default()
}

/// The surface's fixed words, in ONE delivery.
///
/// No header: the fields are a fixed count in a fixed order. In order:
///
/// - `0` the device list's search placeholder
/// - `1` the empty list's sentence
/// - `2` the header's way back
/// - `3` the stage's retry button
/// - `4` the console's caps title
/// - `5` the console's filter placeholder
/// - `6` the console's level picker tooltip
/// - `7` the console's Copy Line verb
/// - `8` the console's Copy Console verb
/// - `9` the follow tooltip while following
/// - `10` the follow tooltip while not
/// - `11` the location popover's title, which is also the header fact's label
/// - `12` the location field's placeholder
/// - `13` the location popover's commit verb
/// - `14` the location popover's undo verb
/// - `15` what the popover says while nothing is pinned
/// - `16`..`18` the three [`StageState`] captions, in byte order — `16` is empty by construction
/// - `19`..`25` the seven [`DeviceVerb`] titles, in byte order — `23` is empty by construction
/// - `26`..`29` the four [`Orientation`] titles, in byte order
/// - `30`..`33` the four [`Orientation`] wire spellings, in byte order
///
/// Returns the bytes NEEDED; a return larger than `cap` means nothing was written, so the caller
/// asks again at that size.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::with_capacity(512);
    for word in [
        simulator::SEARCH_PLACEHOLDER,
        simulator::NO_DEVICES,
        simulator::BACK_HELP,
        simulator::RETRY_TITLE,
        simulator::CONSOLE_TITLE,
        simulator::CONSOLE_FILTER_PLACEHOLDER,
        simulator::CONSOLE_LEVEL_HELP,
        simulator::CONSOLE_COPY_LINE,
        simulator::CONSOLE_COPY_CONSOLE,
        simulator::console_follow_help(true),
        simulator::console_follow_help(false),
        simulator::LOCATION_TITLE,
        simulator::LOCATION_PLACEHOLDER,
        simulator::LOCATION_SET,
        simulator::LOCATION_CLEAR,
        simulator::LOCATION_LIVE,
    ] {
        push_text(&mut blob, word);
    }
    for state in [StageState::Live, StageState::Starting, StageState::Stalled] {
        push_text(&mut blob, state.caption());
    }
    for verb in [
        DeviceVerb::OpenScreen,
        DeviceVerb::CopyScreenshot,
        DeviceVerb::Shutdown,
        DeviceVerb::Boot,
        DeviceVerb::Separator,
        DeviceVerb::CopyUdid,
        DeviceVerb::CopyName,
    ] {
        push_text(&mut blob, verb.title());
    }
    for orientation in ORIENTATIONS {
        push_text(&mut blob, orientation.title());
    }
    for orientation in ORIENTATIONS {
        push_text(&mut blob, orientation.wire_value());
    }
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// The four orientations in byte order — the order every table above and below is written in.
const ORIENTATIONS: [Orientation; 4] = [
    Orientation::Portrait,
    Orientation::LandscapeLeft,
    Orientation::LandscapeRight,
    Orientation::PortraitUpsideDown,
];

/// Every plate the toolbar and the console strip draw, in ONE delivery.
///
/// `[u16 count]`, then per plate two length-prefixed strings: the SF Symbol's name and the tooltip.
/// In order — the five that do not latch, then each latching plate's pair, OFF then ON:
///
/// - `0` rotate left · `1` rotate right · `2` home · `3` app switcher · `4` screenshot
/// - `5`..`6` the demo status bar · `7`..`8` the simulated location · `9`..`10` the console drawer
/// - `11` the console's clear plate · `12` its dismiss plate · `13` its follow plate
///
/// The follow plate's two tooltips are in [`slopdesk_simulator_words`] rather than here, because
/// its GLYPH does not change across the latch and a pair would have carried the same name twice.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_plates(out: *mut c_uchar, cap: usize) -> usize {
    let plates = [
        simulator::ROTATE_LEFT,
        simulator::ROTATE_RIGHT,
        simulator::HOME,
        simulator::APP_SWITCHER,
        simulator::SCREENSHOT,
        simulator::status_bar_plate(false),
        simulator::status_bar_plate(true),
        simulator::location_plate(false),
        simulator::location_plate(true),
        simulator::console_plate(false),
        simulator::console_plate(true),
        Plate {
            symbol: simulator::CONSOLE_CLEAR_SYMBOL,
            help: simulator::CONSOLE_CLEAR_HELP,
        },
        Plate {
            symbol: simulator::CONSOLE_HIDE_SYMBOL,
            help: simulator::CONSOLE_HIDE_HELP,
        },
        Plate {
            symbol: simulator::CONSOLE_FOLLOW_SYMBOL,
            help: simulator::console_follow_help(false),
        },
    ];
    let mut blob = Vec::with_capacity(512);
    blob.extend_from_slice(&u16::try_from(plates.len()).unwrap_or(u16::MAX).to_be_bytes());
    for plate in &plates {
        push_text(&mut blob, plate.symbol);
        push_text(&mut blob, plate.help);
    }
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// How long the model may be loading before the veil admits it, in milliseconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_simulator_veil_delay_ms() -> u32 {
    simulator::VEIL_DELAY_MS
}

/// The floor between two-finger envelopes, in milliseconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_simulator_pinch_interval_ms() -> u32 {
    simulator::PINCH_INTERVAL_MS
}

/// What the stage is doing: `0` live · `1` starting · `2` stalled. The caption for each is index
/// `16 + answer` of [`slopdesk_simulator_words`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_simulator_stage(
    is_selected: bool,
    shows_loading: bool,
    is_awaiting_stream: bool,
    has_video: bool,
) -> u8 {
    simulator::stage(is_selected, shows_loading, is_awaiting_stream, has_video).as_byte()
}

/// A device's context menu, in order, as one [`DeviceVerb`] byte per row.
///
/// Returns the row count NEEDED; when it fits in `cap`, the first that many slots of `out` hold it.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_device_menu(
    is_booted: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let rows: Vec<u8> = simulator::device_menu(is_booted)
        .into_iter()
        .map(DeviceVerb::as_byte)
        .collect();
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&rows, out, cap) }
}

/// The trailing text on a shut-down device's row.
///
/// Returns the bytes NEEDED — `0` for a settled row whose heading already names its runtime, which
/// is a subtitle that is not drawn.
///
/// # Safety
/// `state` and `runtime` must be null or point to their stated lengths in live bytes, and `out`
/// must be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_row_subtitle(
    state: *const c_uchar,
    state_len: usize,
    is_booted: bool,
    runtime: *const c_uchar,
    runtime_len: usize,
    shows_runtime: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let state = unsafe { text(state, state_len) };
    // SAFETY: the caller's obligation, restated above.
    let runtime = unsafe { text(runtime, runtime_len) };
    let answer = simulator::row_subtitle(state, is_booted, runtime, shows_runtime);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The header's fact line, in ONE delivery.
///
/// `[u16 count]`, then per fact `[u8 ink][u8 is_measured][u8 shows_label]` and three
/// length-prefixed strings — the label, the drawn text, and what Copy hands over.
///
/// `has_resolution` is §4b's presence flag for a stream that has not named a size yet, and an empty
/// `pinned_readout` is a device using live values.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `udid` and `pinned_readout` must be null or point to their stated lengths in live bytes, and
/// `out` must be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_facts(
    udid: *const c_uchar,
    udid_len: usize,
    has_resolution: bool,
    width: f64,
    height: f64,
    orientation_byte: u8,
    pinned_readout: *const c_uchar,
    pinned_readout_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let udid = unsafe { text(udid, udid_len) };
    // SAFETY: the caller's obligation, restated above.
    let pinned = unsafe { text(pinned_readout, pinned_readout_len) };
    let facts = simulator::facts(
        udid,
        crate::optional_of(has_resolution, (width, height)),
        orientation_of(orientation_byte),
        pinned,
    );
    let mut blob = Vec::with_capacity(256);
    blob.extend_from_slice(&u16::try_from(facts.len()).unwrap_or(u16::MAX).to_be_bytes());
    for fact in &facts {
        blob.push(fact.ink.as_byte());
        blob.push(u8::from(fact.is_measured));
        blob.push(u8::from(fact.shows_label));
        push_text(&mut blob, fact.label);
        push_text(&mut blob, &fact.text);
        push_text(&mut blob, &fact.copies);
    }
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// An orientation byte no build wrote reads as upright.
///
/// The ORDINARY case, and deliberately so: every rule that branches on orientation treats portrait
/// as "nothing to say", so an unreadable byte prints no fact and turns no picture rather than
/// rotating the stage by a guess.
const fn orientation_of(byte: u8) -> Orientation {
    match Orientation::from_byte(byte) {
        Some(orientation) => orientation,
        None => Orientation::Portrait,
    }
}

/// A quarter turn, wrapping: the orientation byte AFTER the turn. `turn_right` is false for
/// anticlockwise.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_simulator_orientation_turned(orientation_byte: u8, turn_right: bool) -> u8 {
    orientation_of(orientation_byte)
        .turned(if turn_right { Turn::Right } else { Turn::Left })
        .as_byte()
}

/// Whether the device is on its side.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_simulator_orientation_is_landscape(orientation_byte: u8) -> bool {
    orientation_of(orientation_byte).is_landscape()
}

/// How far the PANEL must turn the picture to put the device upright, in degrees clockwise.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_simulator_orientation_view_angle(orientation_byte: u8) -> f64 {
    orientation_of(orientation_byte).view_angle()
}

/// `1206 × 2622` — a measured size as the header prints it.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_pixels(
    width: f64,
    height: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(simulator::pixels(width, height).as_bytes(), out, cap) }
}

/// The leading block of a UDID, cut on a character boundary.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `udid` must be null or point to `udid_len` live bytes, and `out` must be null or point to `cap`
/// writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_shortened_udid(
    udid: *const c_uchar,
    udid_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let udid = unsafe { text(udid, udid_len) };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(simulator::shortened_udid(udid).as_bytes(), out, cap) }
}

/// A bezel button's tooltip, spelled out from the server's wire token.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `id` must be null or point to `id_len` live bytes, and `out` must be null or point to `cap`
/// writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_button_label(
    id: *const c_uchar,
    id_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let id = unsafe { text(id, id_len) };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(simulator::button_label(id).as_bytes(), out, cap) }
}

/// The box a TURNED device has to fit into, as `[width, height]`.
///
/// The swap crosses as a pair rather than as the `turned` flag it was computed from, because the
/// caller's next act is to fit against it — and a renderer that swapped its own bounds would be the
/// second spelling of the one rule this answers.
///
/// # Safety
/// `out` must point to two writable, aligned `f64` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_simulator_footprint(
    width: f64,
    height: f64,
    turned: bool,
    out: *mut f64,
) {
    if out.is_null() {
        return;
    }
    let (fitted_width, fitted_height) = simulator::footprint(width, height, turned);
    // SAFETY: non-null, and writable for two `f64` by the caller's obligation.
    unsafe {
        out.write(fitted_width);
        out.add(1).write(fitted_height);
    }
}

/// Aspect-FIT, and never above 1. `0` for a degenerate content or bounds size, which is a bezel
/// that is not drawn rather than one drawn at an infinite scale.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_simulator_bezel_fit(
    content_width: f64,
    content_height: f64,
    width: f64,
    height: f64,
) -> f64 {
    simulator::bezel_fit(content_width, content_height, width, height)
}

/// What the console says when it is showing nothing.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `level_title` and `filter` must be null or point to their stated lengths in live bytes, and
/// `out` must be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_console_empty_message(
    has_lines: bool,
    is_started: bool,
    level_title: *const c_uchar,
    level_title_len: usize,
    filter: *const c_uchar,
    filter_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let level_title = unsafe { text(level_title, level_title_len) };
    // SAFETY: the caller's obligation, restated above.
    let filter = unsafe { text(filter, filter_len) };
    let answer = simulator::console_empty_message(has_lines, is_started, level_title, filter);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Which sentence [`slopdesk_simulator_phrase`] is being asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Phrase {
    /// The empty list's filtered sentence, over the query.
    NoMatches = 0,
    /// An idle row's one verb, over the device's name.
    BootHelp = 1,
    /// A running card's tooltip, over the device's name.
    OpenHelp = 2,
    /// A running card's stop plate, over the device's name.
    ShutdownHelp = 3,
    /// A section heading's stop-all control, over `count`.
    ShutdownAllHelp = 4,
    /// A fact's own Copy verb, over the fact's label.
    CopyTitle = 5,
    /// What the location popover says while a position is pinned, over its readout.
    LocationPinned = 6,
    /// What a failed read of a dropped file says, over the file's name.
    UnreadableDrop = 7,
}

impl Phrase {
    /// The phrase for `byte`, or `None` for a value no build of this crate wrote.
    const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::NoMatches),
            1 => Some(Self::BootHelp),
            2 => Some(Self::OpenHelp),
            3 => Some(Self::ShutdownHelp),
            4 => Some(Self::ShutdownAllHelp),
            5 => Some(Self::CopyTitle),
            6 => Some(Self::LocationPinned),
            7 => Some(Self::UnreadableDrop),
            _ => None,
        }
    }
}

/// One of the surface's sentences that carries a value, chosen by [`Phrase`].
///
/// `value` is the text the sentence names and `count` the number it names; each phrase reads
/// exactly one of them and ignores the other. A `phrase` byte no build wrote answers `0` — nothing
/// written — rather than a sentence the caller did not ask for.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `value` must be null or point to `value_len` live bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_phrase(
    phrase: u8,
    value: *const c_uchar,
    value_len: usize,
    count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(phrase) = Phrase::from_byte(phrase) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above.
    let value = unsafe { text(value, value_len) };
    let answer = match phrase {
        Phrase::NoMatches => simulator::no_matches(value),
        Phrase::BootHelp => simulator::boot_help(value),
        Phrase::OpenHelp => simulator::open_help(value),
        Phrase::ShutdownHelp => simulator::shutdown_help(value),
        Phrase::ShutdownAllHelp => simulator::shutdown_all_help(count),
        Phrase::CopyTitle => simulator::copy_title(value),
        Phrase::LocationPinned => simulator::location_pinned(value),
        Phrase::UnreadableDrop => simulator::unreadable_drop(value),
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The process name's ink for a severity: `0` primary · `1` secondary · `2` tertiary · `3` alarm.
///
/// A severity byte no build wrote reads as the console's bulk tier, for the reason its Android twin
/// gives — though here that tier is `secondary` rather than `tertiary`, which is the one place the
/// two consoles' answers genuinely differ.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_simulator_log_ink(severity_byte: u8) -> u8 {
    simulator::log_ink(match Severity::from_byte(severity_byte) {
        Some(severity) => severity,
        None => Severity::Plain,
    })
    .as_byte()
}

/// Every device family's silhouette and heading, in ONE delivery, in RANK order.
///
/// `[u16 count]`, then per family two length-prefixed strings: the SF Symbol's name and the
/// heading. The INDEX is the family's kind byte — the same byte
/// [`slopdesk_simulator_device_kind`] answers — so the face reads a classification straight into
/// this table without a second door and without a switch of its own.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_device_kinds(out: *mut c_uchar, cap: usize) -> usize {
    let kinds = simulator::DEVICE_KINDS;
    let mut blob = Vec::with_capacity(128);
    blob.extend_from_slice(&u16::try_from(kinds.len()).unwrap_or(u16::MAX).to_be_bytes());
    for kind in kinds {
        push_text(&mut blob, kind.symbol());
        push_text(&mut blob, kind.group_title());
    }
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// The family a model name names, as its kind byte — which is also its rank and its index into
/// [`slopdesk_simulator_device_kinds`].
///
/// A name this build does not recognise answers `0`, the phone: the row draws a plausible
/// silhouette beside the name rather than a question mark. See
/// [`slopdesk_devicepanel::simulator::device_kind`] for why the checks are in the order they are.
///
/// # Safety
/// `name` must be null, or point to `name_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_simulator_device_kind(name: *const c_uchar, name_len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    simulator::device_kind(unsafe { text(name, name_len) }).as_byte()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_devicepanel::simulator::{DeviceKind, DeviceVerb, Ink, Orientation, StageState};

    use super::{
        slopdesk_simulator_bezel_fit, slopdesk_simulator_button_label, slopdesk_simulator_device_kind,
        slopdesk_simulator_device_kinds, slopdesk_simulator_device_menu, slopdesk_simulator_facts,
        slopdesk_simulator_footprint, slopdesk_simulator_log_ink, slopdesk_simulator_orientation_turned,
        slopdesk_simulator_phrase, slopdesk_simulator_plates, slopdesk_simulator_row_subtitle,
        slopdesk_simulator_stage, slopdesk_simulator_words,
    };

    /// Cuts a run of `[u32 length][bytes]` fields, the way the Swift face does.
    fn fields(blob: &[u8], from: usize) -> Vec<String> {
        let mut cut = Vec::new();
        let mut at = from;
        while at + 4 <= blob.len() {
            let length = u32::from_be_bytes([
                *blob.get(at).unwrap_or(&0),
                *blob.get(at + 1).unwrap_or(&0),
                *blob.get(at + 2).unwrap_or(&0),
                *blob.get(at + 3).unwrap_or(&0),
            ]) as usize;
            at += 4;
            let Some(bytes) = blob.get(at..at + length) else {
                break;
            };
            cut.push(String::from_utf8_lossy(bytes).into_owned());
            at += length;
        }
        cut
    }

    /// Asks a door for its size, then for its bytes — the §4 retry the Swift face performs.
    fn delivered(door: impl Fn(*mut u8, usize) -> usize) -> Vec<u8> {
        let needed = door(core::ptr::null_mut(), 0);
        let mut room = vec![0_u8; needed];
        let written = door(room.as_mut_ptr(), room.len());
        assert_eq!(written, needed);
        room
    }

    #[test]
    fn the_words_cross_in_the_order_the_far_side_reads_them() {
        // SAFETY: the buffer is this test's, and lives across the call.
        let blob = delivered(|out, cap| unsafe { slopdesk_simulator_words(out, cap) });
        let words = fields(&blob, 0);
        assert_eq!(words.len(), 16 + 3 + 7 + 4 + 4);
        assert_eq!(words.first().map(String::as_str), Some("Search devices"));
        assert_eq!(words.get(4).map(String::as_str), Some("Console"));
        assert_eq!(words.get(11).map(String::as_str), Some("Simulated Location"));
        // The two captionless entries are empty BY CONSTRUCTION, and the far side leans on it.
        assert_eq!(
            words.get(16 + StageState::Live.as_byte() as usize),
            Some(&String::new())
        );
        assert_eq!(
            words.get(19 + DeviceVerb::Separator.as_byte() as usize),
            Some(&String::new())
        );
        // The two orientation tables are the same four, in the same order, spelled twice.
        assert_eq!(words.get(26).map(String::as_str), Some("Portrait"));
        assert_eq!(words.get(30).map(String::as_str), Some("portrait"));
        assert_eq!(words.get(27).map(String::as_str), Some("Landscape Left"));
        assert_eq!(words.get(31).map(String::as_str), Some("landscape-left"));
    }

    #[test]
    fn every_plate_crosses_as_a_glyph_and_a_sentence() {
        // SAFETY: the buffer is this test's, and lives across the call.
        let blob = delivered(|out, cap| unsafe { slopdesk_simulator_plates(out, cap) });
        let count = u16::from_be_bytes([*blob.first().unwrap_or(&0), *blob.get(1).unwrap_or(&0)]);
        assert_eq!(count, 14);
        let cut = fields(&blob, 2);
        assert_eq!(cut.len(), usize::from(count) * 2);
        assert!(cut.iter().all(|field| !field.is_empty()));
        assert_eq!(cut.first().map(String::as_str), Some("rotate.left"));
        assert_eq!(cut.get(1).map(String::as_str), Some("Rotate Left"));
        // The latching pairs differ in their SENTENCE and share their glyph.
        assert_eq!(cut.get(10), cut.get(12));
        assert_ne!(cut.get(11), cut.get(13));
    }

    #[test]
    fn the_stage_crosses_as_the_byte_whose_caption_the_words_door_carries() {
        assert_eq!(
            slopdesk_simulator_stage(true, true, false, false),
            StageState::Starting.as_byte()
        );
        assert_eq!(
            slopdesk_simulator_stage(true, false, false, false),
            StageState::Stalled.as_byte()
        );
        assert_eq!(
            slopdesk_simulator_stage(true, false, false, true),
            StageState::Live.as_byte()
        );
    }

    #[test]
    fn a_transition_crosses_verbatim_and_a_settled_row_may_cross_as_nothing() {
        let booting = b"Booting";
        let runtime = b"iOS 26.5";
        // SAFETY: the buffers are this test's, and live across the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_simulator_row_subtitle(
                booting.as_ptr(),
                booting.len(),
                false,
                runtime.as_ptr(),
                runtime.len(),
                false,
                out,
                cap,
            )
        });
        assert_eq!(String::from_utf8_lossy(&answer), "Booting");

        let shutdown = b"Shutdown";
        // SAFETY: the null buffer is the §4 size probe.
        let nothing = unsafe {
            slopdesk_simulator_row_subtitle(
                shutdown.as_ptr(),
                shutdown.len(),
                false,
                runtime.as_ptr(),
                runtime.len(),
                false,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(nothing, 0);
    }

    #[test]
    fn the_menu_crosses_as_kind_bytes() {
        // SAFETY: the buffers are this test's, and live across the call.
        let booted = delivered(|out, cap| unsafe { slopdesk_simulator_device_menu(true, out, cap) });
        assert_eq!(booted, vec![
            DeviceVerb::OpenScreen.as_byte(),
            DeviceVerb::CopyScreenshot.as_byte(),
            DeviceVerb::Shutdown.as_byte(),
            DeviceVerb::Separator.as_byte(),
            DeviceVerb::CopyUdid.as_byte(),
            DeviceVerb::CopyName.as_byte(),
        ]);
    }

    #[test]
    fn a_quiet_header_carries_one_fact_and_a_loud_one_carries_four() {
        let udid = b"A1B2C3D4-5E6F-4A8B-9C0D-1E2F3A4B5C6D";
        // SAFETY: the buffers are this test's, and live across the call.
        let quiet = delivered(|out, cap| unsafe {
            slopdesk_simulator_facts(
                udid.as_ptr(),
                udid.len(),
                false,
                0.0,
                0.0,
                Orientation::Portrait.as_byte(),
                core::ptr::null(),
                0,
                out,
                cap,
            )
        });
        let count = u16::from_be_bytes([*quiet.first().unwrap_or(&0), *quiet.get(1).unwrap_or(&0)]);
        assert_eq!(count, 1);
        let only = fields(&quiet, 5);
        assert_eq!(only.first().map(String::as_str), Some("UDID"));
        assert_eq!(only.get(1).map(String::as_str), Some("A1B2C3D4"));
        assert_eq!(
            only.get(2).map(String::as_str),
            Some("A1B2C3D4-5E6F-4A8B-9C0D-1E2F3A4B5C6D")
        );
        assert_eq!(quiet.get(2).copied(), Some(Ink::Tertiary.as_byte()));

        let pinned = b"37.334886, -122.008988";
        // SAFETY: the buffers are this test's, and live across the call.
        let loud = delivered(|out, cap| unsafe {
            slopdesk_simulator_facts(
                udid.as_ptr(),
                udid.len(),
                true,
                1206.0,
                2622.0,
                Orientation::LandscapeLeft.as_byte(),
                pinned.as_ptr(),
                pinned.len(),
                out,
                cap,
            )
        });
        let count = u16::from_be_bytes([*loud.first().unwrap_or(&0), *loud.get(1).unwrap_or(&0)]);
        assert_eq!(count, 4);
    }

    #[test]
    fn an_orientation_byte_no_build_wrote_stays_upright() {
        // Turning an unreadable byte right lands where turning PORTRAIT right lands.
        assert_eq!(
            slopdesk_simulator_orientation_turned(200, true),
            Orientation::LandscapeRight.as_byte()
        );
        assert_eq!(
            slopdesk_simulator_orientation_turned(Orientation::Portrait.as_byte(), false),
            Orientation::LandscapeLeft.as_byte()
        );
    }

    #[test]
    fn a_turned_device_crosses_back_as_its_swapped_pair() {
        let mut room = [0.0_f64; 2];
        // SAFETY: the array is this test's, and lives across the call.
        unsafe { slopdesk_simulator_footprint(400.0, 900.0, true, room.as_mut_ptr()) };
        assert!((room[0] - 900.0).abs() < f64::EPSILON);
        assert!((room[1] - 400.0).abs() < f64::EPSILON);
        // SAFETY: a null buffer is the one case the door refuses rather than writes.
        unsafe { slopdesk_simulator_footprint(400.0, 900.0, true, core::ptr::null_mut()) };
    }

    #[test]
    fn a_bezel_is_never_blown_past_its_artwork() {
        assert!((slopdesk_simulator_bezel_fit(100.0, 200.0, 400.0, 900.0) - 1.0).abs() < f64::EPSILON);
        assert!(slopdesk_simulator_bezel_fit(0.0, 200.0, 400.0, 900.0).abs() < f64::EPSILON);
    }

    #[test]
    fn an_unknown_button_id_is_still_labelled_with_something() {
        let id = b"camera-control";
        // SAFETY: the buffers are this test's, and live across the call.
        let answer =
            delivered(|out, cap| unsafe { slopdesk_simulator_button_label(id.as_ptr(), id.len(), out, cap) });
        assert_eq!(String::from_utf8_lossy(&answer), "Camera Control");
    }

    #[test]
    fn a_sentence_that_carries_a_value_gets_it_and_an_unknown_id_gets_nothing() {
        let name = b"iPhone 17 Pro";
        // SAFETY: the buffers are this test's, and live across the call.
        let boot = delivered(|out, cap| unsafe {
            slopdesk_simulator_phrase(1, name.as_ptr(), name.len(), 0, out, cap)
        });
        assert_eq!(String::from_utf8_lossy(&boot), "Boot iPhone 17 Pro");
        // SAFETY: the buffers are this test's, and live across the call.
        let all =
            delivered(|out, cap| unsafe { slopdesk_simulator_phrase(4, core::ptr::null(), 0, 2, out, cap) });
        assert_eq!(String::from_utf8_lossy(&all), "Shut down all 2 running devices");
        // SAFETY: the null buffer is the §4 size probe.
        let unknown =
            unsafe { slopdesk_simulator_phrase(200, name.as_ptr(), name.len(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(unknown, 0);
    }

    /// The table's INDEX is the kind byte, which is what lets the face hold no switch of its own.
    #[test]
    fn a_classification_indexes_straight_into_the_family_table() {
        // SAFETY: the buffers are this test's, and live across the call.
        let blob = delivered(|out, cap| unsafe { slopdesk_simulator_device_kinds(out, cap) });
        let count = usize::from(u16::from_be_bytes([
            *blob.first().unwrap_or(&0),
            *blob.get(1).unwrap_or(&0),
        ]));
        assert_eq!(count, 5);
        let table = fields(&blob, 2);
        assert_eq!(table.len(), count * 2);

        let name = "iPad Pro 13-inch (M4)";
        // SAFETY: the borrowed name lives across the call.
        let byte = unsafe { slopdesk_simulator_device_kind(name.as_ptr(), name.len()) };
        assert_eq!(byte, DeviceKind::Pad.as_byte());
        let row = usize::from(byte) * 2;
        assert_eq!(table.get(row).map(String::as_str), Some("ipad.landscape"));
        assert_eq!(table.get(row + 1).map(String::as_str), Some("iPad"));

        // A name this build does not know draws the phone rather than nothing.
        // SAFETY: the null pointer is the empty string this door documents.
        let unknown = unsafe { slopdesk_simulator_device_kind(core::ptr::null(), 0) };
        assert_eq!(unknown, DeviceKind::Phone.as_byte());
    }

    #[test]
    fn a_severity_byte_no_build_wrote_takes_this_consoles_bulk_tier() {
        // `secondary`, not the Android console's `tertiary` — the one place the two differ.
        assert_eq!(slopdesk_simulator_log_ink(200), Ink::Secondary.as_byte());
        assert_eq!(slopdesk_simulator_log_ink(5), Ink::Alarm.as_byte());
        assert_eq!(slopdesk_simulator_log_ink(1), Ink::Tertiary.as_byte());
    }
}
