//! What the Android panel SAYS and which situation a state picks, in C.
//!
//! The rules are `slopdesk_devicepanel::android`; what is here is the marshalling.
//!
//! ## Words cross here, unlike [`crate::device_panel`]
//!
//! That module's header states the panel boundary's ordinary rule — every answer is a KIND byte,
//! because the caller already holds the string the answer is about. It still holds for every fold
//! below whose answer is a CHOICE: the stage, the menu, the ink, the device's own flags.
//!
//! It does not hold for the panel's COPY, and [`crate::settings_options`] is where that was
//! settled: a table of `&'static str` read once into a Swift `static let` is not an identity the
//! caller already has, it is the single spelling two renderers must share. So the words come across
//! — in ONE delivery per table, never a door per string, for exactly the reason that module gives
//! about `1 + 4n` crossings.
//!
//! ## The layout
//!
//! Every table is a run of length-prefixed fields — `[u32 length][UTF-8 bytes]`, big-endian, via
//! `crate::push_text` — so one splitter on the far side cuts all of them. What varies is the
//! header, and each door's own doc states it.
//!
//! A field's ORDER is the contract. The near side reads them positionally, which is why every
//! `_words` door documents its order as a numbered list and its Swift face pads a short delivery
//! rather than shifting: a delivery that came up short is a layout disagreement between the two
//! sides, and padding is what stops it becoming a silent off-by-one where every word after the gap
//! wears its neighbour's.

use core::ffi::c_uchar;

use slopdesk_devicelog::Severity;
use slopdesk_devicepanel::android::{
    self, ACTION_TRAY, CONSOLE_VERB, DeviceMenuEntry, NAVIGATION_TRAY, StageReading, StageVerb,
};

use crate::{borrow, deliver, push_text};

/// Reads a lent `(ptr, len)` as UTF-8, treating invalid bytes as the empty string.
///
/// Every string this module takes is one the panel itself decoded out of the bridge's JSON, so
/// invalid UTF-8 cannot arrive from the host. Lossy would still be wrong: an `adb` state word that
/// came across mangled must not silently match one of [`android::explain_state`]'s cases, and the
/// empty string is the same non-answer a missing key already makes.
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

/// The panel's fixed words, in ONE delivery.
///
/// No header: the fields are a fixed count in a fixed order, and a build of this crate that grew
/// one would be a build whose Swift face grew the same slot. In order:
///
/// - `0` the device list's search placeholder
/// - `1` the empty list's sentence
/// - `2` the header's way back
/// - `3` the stage's retry button
/// - `4` what the paste verb says when the clipboard is empty
/// - `5` the console's caps title
/// - `6` the console's filter placeholder
/// - `7` the console's priority picker tooltip
/// - `8` the console's clear tooltip
/// - `9` the console's dismiss tooltip
/// - `10` the console's follow glyph
/// - `11` the console's clear glyph
/// - `12` the console's dismiss glyph
/// - `13` the follow tooltip while following
/// - `14` the follow tooltip while not
/// - `15`..`18` the four [`StageReading`] captions, in byte order — `15` is empty by construction
/// - `19`..`25` the seven [`DeviceMenuEntry`] titles, in byte order — `19` is empty by construction
/// - `26` a log row's own Copy verb
/// - `27` the whole console's Copy verb
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
pub unsafe extern "C" fn slopdesk_android_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::with_capacity(512);
    for word in [
        android::SEARCH_PLACEHOLDER,
        android::NO_DEVICES,
        android::BACK_HELP,
        android::RETRY_TITLE,
        android::EMPTY_CLIPBOARD_REPORT,
        android::CONSOLE_TITLE,
        android::CONSOLE_FILTER_PLACEHOLDER,
        android::CONSOLE_LEVEL_HELP,
        android::CONSOLE_CLEAR_HELP,
        android::CONSOLE_HIDE_HELP,
        android::CONSOLE_FOLLOW_SYMBOL,
        android::CONSOLE_CLEAR_SYMBOL,
        android::CONSOLE_HIDE_SYMBOL,
        android::console_follow_help(true),
        android::console_follow_help(false),
    ] {
        push_text(&mut blob, word);
    }
    for reading in [
        StageReading::Streaming,
        StageReading::StartingDevice,
        StageReading::StartingMirror,
        StageReading::Stalled,
    ] {
        push_text(&mut blob, reading.caption());
    }
    for entry in [
        DeviceMenuEntry::Separator,
        DeviceMenuEntry::OpenScreen,
        DeviceMenuEntry::CopyScreenshot,
        DeviceMenuEntry::ShutDown,
        DeviceMenuEntry::Start,
        DeviceMenuEntry::CopySerial,
        DeviceMenuEntry::CopyName,
    ] {
        push_text(&mut blob, entry.title());
    }
    // The third log verb's title NAMES its tag, so it is a phrase rather than a word — see
    // [`Phrase::FilterByTag`].
    push_text(&mut blob, android::LOG_COPY_LINE);
    push_text(&mut blob, android::LOG_COPY_CONSOLE);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// A log row's menu, in order, as one [`android::LogVerb`] byte per row: `0` copy this row · `1`
/// copy the console · `2` filter by the row's tag.
///
/// Returns the row count NEEDED; when it fits in `cap`, the first that many slots of `out` hold it.
/// The tag item appears only where there IS a tag, which is why the flag crosses rather than the
/// row: a caller that decided for itself would be the second speller of a one-branch rule.
///
/// # Safety
/// `out` must be null, or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_log_menu(has_name: bool, out: *mut c_uchar, cap: usize) -> usize {
    let verbs = android::log_menu(has_name);
    if verbs.len() <= cap && !out.is_null() {
        for (slot, verb) in verbs.iter().enumerate() {
            // SAFETY: `slot` is below `verbs.len()`, which is at most `cap` writable bytes here.
            unsafe { out.add(slot).write(verb.as_byte()) };
        }
    }
    verbs.len()
}

/// Which tray a stage plate belongs to.
const TRAY_NAVIGATION: u8 = 0;
/// Which tray a stage plate belongs to.
const TRAY_ACTION: u8 = 1;
/// The console plate sits on NEITHER tray — see `slopdesk_devicepanel::android::CONSOLE_VERB`.
const TRAY_CONSOLE: u8 = 2;

/// Appends one toolbar plate: `[u8 tray][u8 action]` then its four length-prefixed strings — the
/// glyph and sentence at rest, then the pair while latched.
fn push_verb(blob: &mut Vec<u8>, tray: u8, verb: &StageVerb) {
    blob.push(tray);
    blob.push(verb.action.as_byte());
    push_text(blob, verb.symbol);
    push_text(blob, verb.help);
    push_text(blob, verb.latched_symbol);
    push_text(blob, verb.latched_help);
}

/// Every plate the stage's toolbar draws, in ONE delivery.
///
/// `[u16 count]`, then `count` plates in the layout [`push_verb`] documents: the navigation tray in
/// its platform order, then the action tray, then the console plate. The TRAY byte is what lets the
/// far side rebuild three groups from one list without knowing the counts — which is the part that
/// would drift, since a plate moving between trays is a design decision and not a rendering one.
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
pub unsafe extern "C" fn slopdesk_android_stage_verbs(out: *mut c_uchar, cap: usize) -> usize {
    let count = NAVIGATION_TRAY.len() + ACTION_TRAY.len() + 1;
    let mut blob = Vec::with_capacity(512);
    blob.extend_from_slice(&u16::try_from(count).unwrap_or(u16::MAX).to_be_bytes());
    for verb in &NAVIGATION_TRAY {
        push_verb(&mut blob, TRAY_NAVIGATION, verb);
    }
    for verb in &ACTION_TRAY {
        push_verb(&mut blob, TRAY_ACTION, verb);
    }
    push_verb(&mut blob, TRAY_CONSOLE, &CONSOLE_VERB);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// How long the model may be loading before the veil admits it, in milliseconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_veil_delay_ms() -> u32 {
    android::VEIL_DELAY_MS
}

/// The proportions of a device that has not reported a screen.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_fallback_aspect() -> f64 {
    android::FALLBACK_ASPECT
}

/// The device is running AND reachable.
pub const DEVICE_IS_RUNNING: u8 = 1 << 0;
/// Attached, but it will refuse every shell until somebody accepts a dialog on its own screen.
pub const DEVICE_IS_ATTACHED_BUT_UNUSABLE: u8 = 1 << 1;
/// A tap on it opens the mirror.
pub const DEVICE_CAN_ENTER: u8 = 1 << 2;
/// A section heading's stop-all control may act on it.
pub const DEVICE_IS_STOPPABLE: u8 = 1 << 3;

/// The four things the panel asks about one device's state, as a bitfield.
///
/// One door rather than four because they are four reads of the SAME two fields, and a caller that
/// asked them separately would cross `adb`'s state word four times per row per redraw. The bits are
/// [`DEVICE_IS_RUNNING`], [`DEVICE_IS_ATTACHED_BUT_UNUSABLE`], [`DEVICE_CAN_ENTER`] and
/// [`DEVICE_IS_STOPPABLE`].
///
/// The RAW fields cross, never a caller-computed `is_running`: the rule is `has_serial && state ==
/// "device"`, and half of it spelled at the call site is the drift the whole port exists to end.
///
/// # Safety
/// `state` must be null, or point to `state_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_device_flags(
    has_serial: bool,
    state: *const c_uchar,
    state_len: usize,
    is_emulator: bool,
) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let state = unsafe { text(state, state_len) };
    let mut flags = 0;
    if android::is_running(has_serial, state) {
        flags |= DEVICE_IS_RUNNING;
    }
    if android::is_attached_but_unusable(has_serial, state) {
        flags |= DEVICE_IS_ATTACHED_BUT_UNUSABLE;
    }
    if android::can_enter(has_serial, state, is_emulator) {
        flags |= DEVICE_CAN_ENTER;
    }
    if android::is_stoppable(has_serial, state, is_emulator) {
        flags |= DEVICE_IS_STOPPABLE;
    }
    flags
}

/// What stands over the picture: `0` streaming · `1` the device is starting · `2` the mirror is ·
/// `3` stalled. The caption for each is index `15 + answer` of [`slopdesk_android_words`].
///
/// `device_is_running` is a tri-state, §4b's shape for an absent optional: `has_device` false is
/// "no selected device to ask", and then the wait is the mirror's by definition.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_stage(
    shows_loading: bool,
    has_selection: bool,
    is_awaiting_stream: bool,
    has_video: bool,
    has_device: bool,
    device_is_running: bool,
) -> u8 {
    android::stage(
        shows_loading,
        has_selection,
        is_awaiting_stream,
        has_video,
        crate::optional_of(has_device, device_is_running),
    )
    .as_byte()
}

/// A device's context menu, in order, as one [`DeviceMenuEntry`] byte per row.
///
/// KIND bytes, and the words come from [`slopdesk_android_words`]: the serial and the name the two
/// copy verbs act on are the caller's own row.
///
/// Returns the row count NEEDED; when it fits in `cap`, the first that many slots of `out` hold it.
///
/// # Safety
/// `state` must be null or point to `state_len` live bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_device_menu(
    has_serial: bool,
    state: *const c_uchar,
    state_len: usize,
    is_emulator: bool,
    has_avd_name: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let state = unsafe { text(state, state_len) };
    let rows: Vec<u8> = android::device_menu(has_serial, state, is_emulator, has_avd_name)
        .into_iter()
        .map(DeviceMenuEntry::as_byte)
        .collect();
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&rows, out, cap) }
}

/// The header's fact line, in ONE delivery.
///
/// `[u16 count]`, then per fact `[u8 ink][u8 is_measured][u8 shows_label]` and three
/// length-prefixed strings — the label, the drawn text, and what Copy hands over.
///
/// A dimension or density of `0` or less is "the host did not report it", which is the same
/// non-answer the JSON decode makes of a missing key; an empty `abi` or `serial` likewise.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `abi` and `serial` must be null or point to their stated lengths in live bytes, and `out` must
/// be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_facts(
    width: i64,
    height: i64,
    density: i64,
    abi: *const c_uchar,
    abi_len: usize,
    serial: *const c_uchar,
    serial_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let abi = unsafe { text(abi, abi_len) };
    // SAFETY: the caller's obligation, restated above.
    let serial = unsafe { text(serial, serial_len) };
    let facts = android::facts(width, height, density, abi, serial);
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

/// The device's state as a sentence.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `state` must be null or point to `state_len` live bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_explain(
    state: *const c_uchar,
    state_len: usize,
    is_emulator: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let state = unsafe { text(state, state_len) };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(android::explain(state, is_emulator).as_bytes(), out, cap) }
}

/// The card's tooltip: a verb for a device that can be opened, and its STATE for one that cannot.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `name` and `state` must be null or point to their stated lengths in live bytes, and `out` must
/// be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_card_help(
    name: *const c_uchar,
    name_len: usize,
    has_serial: bool,
    state: *const c_uchar,
    state_len: usize,
    is_emulator: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let name = unsafe { text(name, name_len) };
    // SAFETY: the caller's obligation, restated above.
    let state = unsafe { text(state, state_len) };
    let answer = android::card_help(name, has_serial, state, is_emulator);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The one-line fact under the headline.
///
/// Returns the bytes NEEDED. A return larger than `cap` means nothing was written.
///
/// # Safety
/// `release`, `manufacturer` and `model` must be null or point to their stated lengths in live
/// bytes, and `out` must be null or point to `cap` writable bytes, all for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_summary(
    release: *const c_uchar,
    release_len: usize,
    api_level: i64,
    width: i64,
    height: i64,
    is_emulator: bool,
    manufacturer: *const c_uchar,
    manufacturer_len: usize,
    model: *const c_uchar,
    model_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let release = unsafe { text(release, release_len) };
    // SAFETY: the caller's obligation, restated above.
    let manufacturer = unsafe { text(manufacturer, manufacturer_len) };
    // SAFETY: the caller's obligation, restated above.
    let model = unsafe { text(model, model_len) };
    let answer = android::summary(
        release,
        api_level,
        width,
        height,
        is_emulator,
        manufacturer,
        model,
    );
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The trailing text on a row that is not running.
///
/// Returns the bytes NEEDED — `0` for a row with neither a version to print nor a screen to fall
/// back on, which is a subtitle that is not drawn.
///
/// # Safety
/// `version_label` must be null or point to `version_label_len` live bytes, and `out` must be null
/// or point to `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_subtitle(
    version_label: *const c_uchar,
    version_label_len: usize,
    shows_version: bool,
    width: i64,
    height: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let version_label = unsafe { text(version_label, version_label_len) };
    let answer = android::subtitle(version_label, shows_version, width, height);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
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
pub unsafe extern "C" fn slopdesk_android_console_empty_message(
    has_lines: bool,
    is_log_started: bool,
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
    let answer = android::console_empty_message(has_lines, is_log_started, level_title, filter);
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Which sentence [`slopdesk_android_phrase`] is being asked for.
///
/// One door rather than five, because five doors that each `format!` one value into one template
/// would be five sites restating the same marshalling. The id is the argument that varies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Phrase {
    /// The empty list's filtered sentence, over the query.
    NoMatches = 0,
    /// An idle row's one verb, over the device's name.
    StartHelp = 1,
    /// A running card's stop plate, over the device's name.
    ShutDownHelp = 2,
    /// A section heading's stop-all control, over `count`.
    ShutDownAllHelp = 3,
    /// A fact's own Copy verb, over the fact's label.
    CopyTitle = 4,
    /// A log row's tag filter, over the tag. The one log verb whose title is not a constant, which
    /// is the whole reason the item is worth a menu slot.
    FilterByTag = 5,
}

impl Phrase {
    /// The phrase for `byte`, or `None` for a value no build of this crate wrote.
    const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::NoMatches),
            1 => Some(Self::StartHelp),
            2 => Some(Self::ShutDownHelp),
            3 => Some(Self::ShutDownAllHelp),
            4 => Some(Self::CopyTitle),
            5 => Some(Self::FilterByTag),
            _ => None,
        }
    }
}

/// One of the panel's sentences that carries a value, chosen by [`Phrase`].
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
pub unsafe extern "C" fn slopdesk_android_phrase(
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
        Phrase::NoMatches => android::no_matches(value),
        Phrase::StartHelp => android::start_help(value),
        Phrase::ShutDownHelp => android::shut_down_help(value),
        Phrase::ShutDownAllHelp => android::shut_down_all_help(count),
        Phrase::CopyTitle => android::copy_title(value),
        Phrase::FilterByTag => android::filter_by_tag(value),
    };
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The tag's ink for a severity: `0` primary · `1` secondary · `2` tertiary · `3` icon · `4` error.
///
/// A severity byte no build wrote reads as the console's bulk tier, which is the one that recedes —
/// the safe answer, because the alternative is spending the panel's one alarm colour on a line
/// nothing is known about.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_android_log_ink(severity_byte: u8) -> u8 {
    android::log_ink(match Severity::from_byte(severity_byte) {
        Some(severity) => severity,
        None => Severity::Plain,
    })
    .as_byte()
}

/// The device's screen proportions, or `0` for a device that has not reported them.
///
/// `0` rather than §4b's presence flag because a ratio of zero is not a shape either: the one
/// caller feeds this straight into [`slopdesk_android_art_width`], whose fallback is what an absent
/// ratio means there.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_android_aspect_ratio(width: i64, height: i64) -> f64 {
    android::aspect_ratio(width, height).unwrap_or(0.0)
}

/// The card's screen box at a fixed art HEIGHT.
///
/// `ratio` of `0` or less is a device that has not reported a screen, and takes the fallback. The
/// three lengths are the caller's design tokens; what is here is the fallback, the multiply, and
/// the order of the clamp.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_android_art_width(ratio: f64, art: f64, floor: f64, cap: f64) -> f64 {
    android::art_width((ratio > 0.0).then_some(ratio), art, floor, cap)
}

/// Every device family's silhouette and heading, in ONE delivery, in RANK order.
///
/// `[u16 count]`, then per family two length-prefixed strings: the SF Symbol's name and the
/// heading. The INDEX is the family's kind byte — the same byte [`slopdesk_android_device_kind`]
/// answers — so the face reads a classification straight into this table.
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
pub unsafe extern "C" fn slopdesk_android_device_kinds(out: *mut c_uchar, cap: usize) -> usize {
    let kinds = android::DEVICE_KINDS;
    let mut blob = Vec::with_capacity(128);
    blob.extend_from_slice(&u16::try_from(kinds.len()).unwrap_or(u16::MAX).to_be_bytes());
    for kind in kinds {
        push_text(&mut blob, kind.symbol());
        push_text(&mut blob, kind.group_title());
    }
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(&blob, out, cap) }
}

/// The family a device belongs to, as its kind byte — which is also its rank and its index into
/// [`slopdesk_android_device_kinds`].
///
/// `hint` is the platform's own word for itself — `ro.build.characteristics` on a running device,
/// `tag.id` on an AVD on disk — and is read as TOKENS, never as a substring: `emulator,nosdcard` is
/// the commonest value there is and `nosdcard` contains `car`. See
/// [`slopdesk_devicepanel::android::device_kind`].
///
/// The three geometry arguments are the device's reported pixels and DPI bucket, and `0` on any of
/// them means it reported no screen — which answers the phone rather than dividing by it. They are
/// `i64` because the caller's are platform `Int`s and a negative from a hand-edited `config.ini`
/// must reach the rule as a negative rather than wrap.
///
/// # Safety
/// `hint` and `name` must each be null, or point to their stated length in live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_device_kind(
    hint: *const c_uchar,
    hint_len: usize,
    name: *const c_uchar,
    name_len: usize,
    width: i64,
    height: i64,
    density: i64,
) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let hint = unsafe { text(hint, hint_len) };
    // SAFETY: ditto.
    let name = unsafe { text(name, name_len) };
    android::device_kind(hint, name, width, height, density).as_byte()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_devicepanel::android::{DeviceKind, DeviceMenuEntry, Ink, StageReading};

    use super::{
        DEVICE_CAN_ENTER, DEVICE_IS_ATTACHED_BUT_UNUSABLE, DEVICE_IS_RUNNING, DEVICE_IS_STOPPABLE,
        slopdesk_android_art_width, slopdesk_android_aspect_ratio, slopdesk_android_device_flags,
        slopdesk_android_device_kind, slopdesk_android_device_kinds, slopdesk_android_device_menu,
        slopdesk_android_explain, slopdesk_android_facts, slopdesk_android_log_ink, slopdesk_android_phrase,
        slopdesk_android_stage, slopdesk_android_stage_verbs, slopdesk_android_words,
    };

    /// Cuts a run of `[u32 length][bytes]` fields, the way the Swift face does.
    fn fields(blob: &[u8], from: usize) -> Vec<String> {
        let mut cut = Vec::new();
        let mut at = from;
        while at + 4 <= blob.len() {
            let Some(prefix) = blob.get(at..at + 4) else {
                break;
            };
            let length = u32::from_be_bytes([
                *prefix.first().unwrap_or(&0),
                *prefix.get(1).unwrap_or(&0),
                *prefix.get(2).unwrap_or(&0),
                *prefix.get(3).unwrap_or(&0),
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
        let blob = delivered(|out, cap| unsafe { slopdesk_android_words(out, cap) });
        let words = fields(&blob, 0);
        assert_eq!(words.len(), 15 + 4 + 7 + 2);
        assert_eq!(words.first().map(String::as_str), Some("Search devices"));
        assert_eq!(words.get(3).map(String::as_str), Some("Try Again"));
        assert_eq!(words.get(5).map(String::as_str), Some("Logcat"));
        // The two captionless entries are empty BY CONSTRUCTION, and the far side leans on it.
        assert_eq!(
            words.get(15 + StageReading::Streaming.as_byte() as usize),
            Some(&String::new())
        );
        assert_eq!(
            words.get(19 + DeviceMenuEntry::Separator.as_byte() as usize),
            Some(&String::new())
        );
        assert_eq!(
            words.get(19 + DeviceMenuEntry::CopySerial.as_byte() as usize),
            Some(&"Copy Serial".to_owned())
        );
        assert_eq!(words.get(26).map(String::as_str), Some("Copy Line"));
        assert_eq!(words.get(27).map(String::as_str), Some("Copy Console"));
    }

    #[test]
    fn every_plate_crosses_with_its_tray_and_its_four_strings() {
        // SAFETY: the buffer is this test's, and lives across the call.
        let blob = delivered(|out, cap| unsafe { slopdesk_android_stage_verbs(out, cap) });
        let count = u16::from_be_bytes([*blob.first().unwrap_or(&0), *blob.get(1).unwrap_or(&0)]);
        assert_eq!(count, 8);
        // Three navigation plates, four action plates, one console plate — read off the tray bytes
        // rather than assumed, since the tray is the part that would move.
        let mut at = 2;
        let mut trays = Vec::new();
        for _ in 0..count {
            trays.push(*blob.get(at).unwrap_or(&255));
            at += 2;
            for _ in 0..4 {
                let length = u32::from_be_bytes([
                    *blob.get(at).unwrap_or(&0),
                    *blob.get(at + 1).unwrap_or(&0),
                    *blob.get(at + 2).unwrap_or(&0),
                    *blob.get(at + 3).unwrap_or(&0),
                ]) as usize;
                assert!(length > 0);
                at += 4 + length;
            }
        }
        assert_eq!(trays, vec![0, 0, 0, 1, 1, 1, 1, 2]);
        assert_eq!(at, blob.len());
    }

    #[test]
    fn one_crossing_answers_all_four_questions_about_a_device() {
        let ready = b"device";
        // SAFETY: the literal outlives the call.
        let flags = unsafe { slopdesk_android_device_flags(true, ready.as_ptr(), ready.len(), true) };
        assert_eq!(flags, DEVICE_IS_RUNNING | DEVICE_CAN_ENTER | DEVICE_IS_STOPPABLE);
        let waiting = b"unauthorized";
        // SAFETY: the literal outlives the call.
        let flags = unsafe { slopdesk_android_device_flags(true, waiting.as_ptr(), waiting.len(), false) };
        assert_eq!(flags, DEVICE_IS_ATTACHED_BUT_UNUSABLE);
    }

    #[test]
    fn a_state_word_that_did_not_survive_the_crossing_matches_nothing() {
        // Invalid UTF-8 reads as the empty string, which is no state at all — never one of
        // `explain_state`'s cases by accident.
        let mangled = [0xFF_u8, 0xFE];
        // SAFETY: the array outlives the call.
        let flags = unsafe { slopdesk_android_device_flags(true, mangled.as_ptr(), mangled.len(), false) };
        assert_eq!(flags, DEVICE_IS_ATTACHED_BUT_UNUSABLE);
    }

    #[test]
    fn the_stage_crosses_as_the_byte_whose_caption_the_words_door_carries() {
        assert_eq!(
            slopdesk_android_stage(true, true, true, false, true, false),
            StageReading::StartingDevice.as_byte()
        );
        // No device to ask: the wait is the mirror's.
        assert_eq!(
            slopdesk_android_stage(true, true, true, false, false, false),
            StageReading::StartingMirror.as_byte()
        );
        assert_eq!(
            slopdesk_android_stage(false, true, false, false, true, true),
            StageReading::Stalled.as_byte()
        );
    }

    #[test]
    fn the_menu_crosses_as_kind_bytes_and_the_words_come_from_the_table() {
        let state = b"device";
        // SAFETY: the buffers are this test's, and live across the call.
        let rows = delivered(|out, cap| unsafe {
            slopdesk_android_device_menu(true, state.as_ptr(), state.len(), true, true, out, cap)
        });
        assert_eq!(rows, vec![
            DeviceMenuEntry::OpenScreen.as_byte(),
            DeviceMenuEntry::CopyScreenshot.as_byte(),
            DeviceMenuEntry::ShutDown.as_byte(),
            DeviceMenuEntry::Separator.as_byte(),
            DeviceMenuEntry::CopySerial.as_byte(),
            DeviceMenuEntry::CopyName.as_byte(),
        ]);
    }

    #[test]
    fn a_fact_carries_its_three_flags_ahead_of_its_three_strings() {
        let abi = b"arm64-v8a";
        let serial = b"emulator-5554";
        // SAFETY: the buffers are this test's, and live across the call.
        let blob = delivered(|out, cap| unsafe {
            slopdesk_android_facts(
                1080,
                2400,
                420,
                abi.as_ptr(),
                abi.len(),
                serial.as_ptr(),
                serial.len(),
                out,
                cap,
            )
        });
        let count = u16::from_be_bytes([*blob.first().unwrap_or(&0), *blob.get(1).unwrap_or(&0)]);
        assert_eq!(count, 4);
        assert_eq!(blob.get(2).copied(), Some(Ink::Secondary.as_byte()));
        assert_eq!(blob.get(3).copied(), Some(1));
        assert_eq!(blob.get(4).copied(), Some(1));
        let first = fields(&blob, 5);
        assert_eq!(first.first().map(String::as_str), Some("Screen"));
        assert_eq!(first.get(1).map(String::as_str), Some("1080 × 2400"));
    }

    #[test]
    fn a_device_with_nothing_to_report_delivers_its_header_and_no_facts() {
        // SAFETY: the buffers are this test's, and live across the call.
        let blob = delivered(|out, cap| unsafe {
            slopdesk_android_facts(0, 0, 0, core::ptr::null(), 0, core::ptr::null(), 0, out, cap)
        });
        assert_eq!(blob, vec![0, 0]);
    }

    #[test]
    fn a_sentence_that_carries_a_value_gets_it_and_an_unknown_id_gets_nothing() {
        let name = b"Pixel 9";
        // SAFETY: the buffers are this test's, and live across the call.
        let started = delivered(|out, cap| unsafe {
            slopdesk_android_phrase(1, name.as_ptr(), name.len(), 0, out, cap)
        });
        assert_eq!(String::from_utf8_lossy(&started), "Start Pixel 9");
        // SAFETY: the buffers are this test's, and live across the call.
        let all =
            delivered(|out, cap| unsafe { slopdesk_android_phrase(3, core::ptr::null(), 0, 3, out, cap) });
        assert_eq!(String::from_utf8_lossy(&all), "Shut down all 3 running emulators");
        // SAFETY: the null buffer is the §4 size probe.
        let unknown =
            unsafe { slopdesk_android_phrase(200, name.as_ptr(), name.len(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(unknown, 0);
    }

    #[test]
    fn an_offline_emulator_explains_itself_as_a_boot() {
        let state = b"offline";
        // SAFETY: the buffers are this test's, and live across the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_android_explain(state.as_ptr(), state.len(), true, out, cap)
        });
        assert_eq!(String::from_utf8_lossy(&answer), "Starting up…");
    }

    #[test]
    fn a_severity_byte_no_build_wrote_recedes_rather_than_alarms() {
        assert_eq!(slopdesk_android_log_ink(200), Ink::Tertiary.as_byte());
        assert_eq!(slopdesk_android_log_ink(5), Ink::Err.as_byte());
    }

    #[test]
    fn an_unreported_screen_crosses_as_zero_and_takes_the_fallback() {
        assert!(slopdesk_android_aspect_ratio(0, 2400).abs() < f64::EPSILON);
        let fallback = slopdesk_android_art_width(0.0, 100.0, 0.0, 1000.0);
        let named = slopdesk_android_art_width(slopdesk_android_aspect_ratio(1080, 2340), 100.0, 0.0, 1000.0);
        assert!((fallback - 100.0 * (9.0 / 19.5)).abs() < 1e-9);
        assert!((named - 100.0 * (1080.0 / 2340.0)).abs() < 1e-9);
    }

    /// The table's INDEX is the kind byte, and the trap the rule turns on survives the crossing:
    /// `emulator,nosdcard` is a phone, and `nosdcard` containing `car` changes nothing.
    #[test]
    fn a_classification_indexes_straight_into_the_family_table() {
        // SAFETY: the buffers are this test's, and live across the call.
        let blob = delivered(|out, cap| unsafe { slopdesk_android_device_kinds(out, cap) });
        let count = usize::from(u16::from_be_bytes([
            *blob.first().unwrap_or(&0),
            *blob.get(1).unwrap_or(&0),
        ]));
        assert_eq!(count, 5);
        let table = fields(&blob, 2);
        assert_eq!(table.len(), count * 2);

        let hint = b"emulator,nosdcard";
        let name = b"Pixel_8";
        // SAFETY: both borrows live across the call.
        let byte = unsafe {
            slopdesk_android_device_kind(
                hint.as_ptr(),
                hint.len(),
                name.as_ptr(),
                name.len(),
                1080,
                2400,
                420,
            )
        };
        assert_eq!(byte, DeviceKind::Phone.as_byte());
        let row = usize::from(byte) * 2;
        assert_eq!(table.get(row).map(String::as_str), Some("iphone"));
        assert_eq!(table.get(row + 1).map(String::as_str), Some("Phone"));

        // A device with nothing to say and no screen to measure is still a phone, not a trap.
        // SAFETY: the null pointers are the empty strings this door documents.
        let bare =
            unsafe { slopdesk_android_device_kind(core::ptr::null(), 0, core::ptr::null(), 0, 0, 0, 0) };
        assert_eq!(bare, DeviceKind::Phone.as_byte());
    }
}
