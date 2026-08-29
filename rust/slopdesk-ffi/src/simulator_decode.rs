//! What the simulator's own server ANSWERS, in C.
//!
//! The three foreign decodes `slopdesk_devicepanel` performs on the way IN — the device body
//! `definition.json` describes, the device set `/simulators.json` lists, and the one coordinate the
//! location route takes — plus the shortlist of places worth one tap. [`crate::simulator_routes`]
//! is the same wire read the other way: it builds the URLs these answers come back from.
//!
//! ## Framing
//!
//! `docs/55` §4's plain shape, with two additions this module's deliveries need and states here
//! rather than at each door:
//!
//! - A NUMBER is eight bytes, big-endian, of an `f64`'s bit pattern. Not text: the near side
//!   compares the decoded geometry with `==` against literals the server wrote, and only a bit
//!   round trip makes that hold. Big-endian for [`crate::push_text`]'s own reason — a width that
//!   followed the target would be a bug waiting for a different build.
//! - A COUNT is two bytes, big-endian, and rides INSIDE the blob. Zero devices is a real answer
//!   from a host with no simulators installed, so it cannot be the `0` return that means "no
//!   answer" — and every blob here has a fixed header before its count, so `0` back is never
//!   ambiguous.
//!
//! Nothing here decides anything. Each door is one call into the wrapped crate and one walk over
//! what it answered; the drop rules, the range checks and the rounding are all
//! `slopdesk_devicepanel`'s, under `forbid(unsafe_code)`.

use core::ffi::c_uchar;

use slopdesk_devicepanel::{sim_chrome, sim_devices, sim_log, sim_place};

use crate::{borrow, deliver, lent, push_text, saturating_u32};

/// The console's `log_started` message: the child is up, output follows.
pub const SLOPDESK_SIM_LOG_STARTED: u8 = 0;

/// One batch of console lines. The count rides inside the blob — an EMPTY batch is a real message,
/// which the server sends between bursts.
pub const SLOPDESK_SIM_LOG_LINES: u8 = 1;

/// Appends one `f64` as eight big-endian bytes of its bit pattern.
fn push_number(blob: &mut Vec<u8>, value: f64) {
    blob.extend_from_slice(&value.to_bits().to_be_bytes());
}

/// Appends a row count as two big-endian bytes, saturating rather than wrapping.
///
/// A wrapped count would make the near side read a truncated table as a complete one. Nothing the
/// server answers approaches 65 535 buttons or devices; saturating is what makes that unreachable
/// case loud rather than silently short.
fn push_count(blob: &mut Vec<u8>, count: usize) {
    let count = u16::try_from(count).unwrap_or(u16::MAX);
    blob.extend_from_slice(&count.to_be_bytes());
}

/// Decode one `/simulators/<udid>/definition.json` into the panel's device body.
///
/// The blob, in order: the model, the BLEED rect's four numbers, the viewport's width and height,
/// the live rect's `x`, `y`, width and height, the corner radius, the bare and rest artwork
/// references, then a `[u16]` button count and per button its id, its four percentages, its two
/// artwork references and its envelope name.
///
/// That order is the near side's DECLARATION order, field for field, so each value is read straight
/// into the initialiser argument it belongs to. A layout that needed a scratch local per field is
/// one where a swapped pair type-checks.
///
/// The bleed rides along rather than being recomputed on the near side: it is the union of every
/// button frame with the viewport, which is the same percent-of-viewport formula the buttons
/// themselves are placed by, and a second speller of it is how a side button ends up clipped at one
/// renderer's edge and not the other's.
///
/// Zero back is a REFUSAL — a degenerate viewport or screen rect, or a root that is not a device
/// body. There is nothing to draw, and every consumer divides by those numbers.
///
/// # Safety
/// `json` must be readable for `json_len` bytes for the duration of the call, and `out` writable
/// for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading caller-owned buffers is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_chrome(
    json: *const c_uchar,
    json_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the span is readable for its stated length by the caller's obligation, and it is
    // borrowed only for the duration of this call.
    let bytes = unsafe { borrow(json, json_len) };
    let Some(chrome) = sim_chrome::Chrome::decode(bytes) else {
        return 0;
    };
    let bleed = chrome.bleed();
    let mut blob = Vec::new();
    push_text(&mut blob, &chrome.model);
    push_number(&mut blob, bleed.origin.x);
    push_number(&mut blob, bleed.origin.y);
    push_number(&mut blob, bleed.size.width);
    push_number(&mut blob, bleed.size.height);
    push_number(&mut blob, chrome.screen.viewport.width);
    push_number(&mut blob, chrome.screen.viewport.height);
    push_number(&mut blob, chrome.screen.rect.origin.x);
    push_number(&mut blob, chrome.screen.rect.origin.y);
    push_number(&mut blob, chrome.screen.rect.size.width);
    push_number(&mut blob, chrome.screen.rect.size.height);
    push_number(&mut blob, chrome.screen.clip_radius);
    push_text(&mut blob, &chrome.screen.bare_path);
    push_text(&mut blob, &chrome.screen.rest_path);
    push_count(&mut blob, chrome.buttons.len());
    for button in &chrome.buttons {
        push_text(&mut blob, &button.id);
        push_number(&mut blob, button.left_percent);
        push_number(&mut blob, button.top_percent);
        push_number(&mut blob, button.width_percent);
        push_number(&mut blob, button.height_percent);
        push_text(&mut blob, &button.rest_path);
        push_text(&mut blob, &button.pressed_path);
        push_text(&mut blob, &button.envelope_button);
    }
    // SAFETY: `blob` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(&blob, out, cap) }
}

/// Decode one `/simulators.json` into the panel's device list, running group first.
///
/// The blob is a `[u16]` device count, then per device one boot byte — `1` for booted — followed by
/// its udid, name, runtime and the server's raw state string.
///
/// Zero back is a REFUSAL, and it means exactly one thing: a top level that is not an object. A
/// host with no simulators installed answers a count of zero, which is why the count rides inside
/// the blob rather than being the return value.
///
/// # Safety
/// `json` must be readable for `json_len` bytes for the duration of the call, and `out` writable
/// for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading caller-owned buffers is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_device_list(
    json: *const c_uchar,
    json_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as at `slopdesk_sim_chrome` — readable for its stated length, borrowed for the call.
    let bytes = unsafe { borrow(json, json_len) };
    let Some(devices) = sim_devices::decode_list(bytes) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_count(&mut blob, devices.len());
    for device in &devices {
        blob.push(u8::from(device.is_booted));
        push_text(&mut blob, &device.udid);
        push_text(&mut blob, &device.name);
        push_text(&mut blob, &device.runtime);
        push_text(&mut blob, &device.state);
    }
    // SAFETY: `blob` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(&blob, out, cap) }
}

/// Decode one text frame off the console socket.
///
/// The blob is a `[u8]` kind — [`SLOPDESK_SIM_LOG_STARTED`] or [`SLOPDESK_SIM_LOG_LINES`] — and,
/// for a batch, a `[u32 BE]` line count followed by that many runs.
///
/// Zero back is IGNORE THIS MESSAGE, not a failure: a `type` this build has no case for, or a
/// payload that is not the envelope. A newer server that adds a message must cost the console that
/// message and not the socket, so the near side reads `0` as "nothing to do" rather than as an
/// error to report. It cannot collide with a real answer, because every known message carries at
/// least its kind byte.
///
/// The LINES cross rather than the text frame's offsets, unlike the video envelope beside them:
/// the near side is going to make one `String` per row either way, and a batch is fifty rows every
/// fifty milliseconds rather than three megabytes sixty times a second.
///
/// # Safety
/// `text` must be readable for `text_len` bytes for the duration of the call, and `out` writable
/// for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading caller-owned buffers is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_log_message(
    text: *const c_uchar,
    text_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: readable for its stated length by the caller's obligation, borrowed for the call.
    // Non-UTF-8 reads as empty, which decodes to `Unknown` — the refusal this door already has.
    let payload = unsafe { lent(text, text_len) };
    let mut blob = Vec::new();
    match sim_log::decode(payload) {
        sim_log::Message::Unknown => return 0,
        sim_log::Message::Started => blob.push(SLOPDESK_SIM_LOG_STARTED),
        sim_log::Message::Lines(lines) => {
            blob.push(SLOPDESK_SIM_LOG_LINES);
            blob.extend_from_slice(&saturating_u32(lines.len()).to_be_bytes());
            for line in &lines {
                push_text(&mut blob, line);
            }
        },
    }
    // SAFETY: `blob` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(&blob, out, cap) }
}

/// Read a typed coordinate. Answers sixteen bytes — latitude then longitude — or `0`.
///
/// Zero is the refusal, and a refusal is the whole point of the door: a coordinate parsed WRONG
/// pins the device somewhere plausible, the panel reports success, and the only evidence is an app
/// that thinks it is in the wrong hemisphere. A valid answer is always sixteen bytes, so `0` is
/// never a coordinate.
///
/// # Safety
/// `text` must be readable for `text_len` bytes for the duration of the call, and `out` writable
/// for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading caller-owned buffers is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_coordinate_parse(
    text: *const c_uchar,
    text_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: readable for its stated length by the caller's obligation, borrowed for the call.
    // Non-UTF-8 reads as empty, which parses to nothing — the refusal this door already has.
    let typed = unsafe { lent(text, text_len) };
    let Some(coordinate) = sim_place::Coordinate::parse(typed) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_number(&mut blob, coordinate.latitude);
    push_number(&mut blob, coordinate.longitude);
    // SAFETY: `blob` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(&blob, out, cap) }
}

/// The fixed-width readout for a pinned position, `"37.334886, -122.008988"`.
///
/// Six decimals always, padded rather than trimmed: a header figure that changes width as the value
/// changes makes the whole facts line jump. Never empty, so the return is never `0`.
///
/// # Safety
/// `out` must be writable for `cap` bytes for the duration of the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_coordinate_readout(
    latitude: f64,
    longitude: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let readout = sim_place::Coordinate::new(latitude, longitude).readout();
    // SAFETY: `readout` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(readout.as_bytes(), out, cap) }
}

/// The shortlist of places worth one tap.
///
/// A `[u16]` count, then per place its name followed by its latitude and longitude. It is a table
/// of constants, so it crosses once when the popover is built rather than a door per field.
///
/// # Safety
/// `out` must be writable for `cap` bytes for the duration of the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point writing a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_places(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    push_count(&mut blob, sim_place::ALL.len());
    for place in sim_place::ALL {
        push_text(&mut blob, place.name);
        push_number(&mut blob, place.coordinate.latitude);
        push_number(&mut blob, place.coordinate.longitude);
    }
    // SAFETY: `blob` is a live local that cannot overlap `out`, which the caller keeps writable.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
#[expect(
    clippy::float_cmp,
    reason = "a number crosses as its BIT PATTERN, so an exact compare is the assertion — a               \
              tolerance here would pass on the drift the framing exists to prevent"
)]
mod tests {
    use slopdesk_devicepanel::sim_place;

    use super::{
        SLOPDESK_SIM_LOG_LINES, SLOPDESK_SIM_LOG_STARTED, slopdesk_sim_chrome, slopdesk_sim_coordinate_parse,
        slopdesk_sim_coordinate_readout, slopdesk_sim_device_list, slopdesk_sim_log_message,
        slopdesk_sim_places,
    };
    use crate::testing::delivered;

    /// The near side's cursor, written here so a layout disagreement fails in Rust first.
    struct Cursor<'a> {
        blob: &'a [u8],
        at: usize,
    }

    impl<'a> Cursor<'a> {
        const fn new(blob: &'a [u8]) -> Self {
            Self { blob, at: 0 }
        }

        fn byte(&mut self) -> u8 {
            let byte = self.blob.get(self.at).copied().unwrap_or_default();
            self.at += 1;
            byte
        }

        fn count(&mut self) -> usize {
            usize::from(self.byte()) << 8 | usize::from(self.byte())
        }

        fn number(&mut self) -> f64 {
            let mut bits = 0_u64;
            for _ in 0..8 {
                bits = bits << 8 | u64::from(self.byte());
            }
            f64::from_bits(bits)
        }

        /// The WIDER count, for the one delivery here whose rows are a device's own output rather
        /// than a table's: a busy console batch is not bounded by anything two bytes can name.
        fn count32(&mut self) -> usize {
            let mut count = 0_usize;
            for _ in 0..4 {
                count = count << 8 | usize::from(self.byte());
            }
            count
        }

        fn text(&mut self) -> String {
            let mut length = 0_usize;
            for _ in 0..4 {
                length = length << 8 | usize::from(self.byte());
            }
            let text = self
                .blob
                .get(self.at..self.at + length)
                .map(|span| String::from_utf8_lossy(span).into_owned())
                .unwrap_or_default();
            self.at += length;
            text
        }
    }

    const SCREEN: &str = r#"{
      "bezelImage": { "bare": "/simulators/U/bezel.png?buttons=false",
                      "rest": "/simulators/U/bezel.png" },
      "clipRadius": 62,
      "rect": { "x": 18, "y": 18, "width": 400, "height": 872 },
      "viewport": { "width": 436, "height": 908 }
    }"#;

    const POWER: &str = r#"{ "id": "power",
      "box": { "leftPct": 97.0, "topPct": 28.8, "widthPct": 3.6, "heightPct": 11.1 },
      "images": { "rest": "/simulators/U/chrome-button/power.png",
                  "pressed": "/simulators/U/chrome-button/power-down.png" },
      "envelope": { "button": "side-button", "type": "button" } }"#;

    fn chrome(json: &str) -> Vec<u8> {
        delivered(|out, cap| {
            // SAFETY: both the fixture and the buffer are live for the duration of the call.
            unsafe { slopdesk_sim_chrome(json.as_ptr(), json.len(), out, cap) }
        })
    }

    /// The body crosses whole: the geometry as bit patterns, the artwork references, the bleed the
    /// panel lays out to, and one button with the SERVER's envelope name.
    #[test]
    fn the_device_body_crosses_whole() {
        let json = format!(
            r#"{{ "identity": {{ "model": "iPhone 17 Pro" }}, "screen": {SCREEN}, "buttons": [{POWER}] }}"#
        );
        let blob = chrome(&json);
        let mut cursor = Cursor::new(&blob);
        assert_eq!(cursor.text(), "iPhone 17 Pro");
        // The bleed: x stays at the body's own edge, and the width runs past the viewport because
        // the power button protrudes.
        assert_eq!(cursor.number(), 0.0);
        assert_eq!(cursor.number(), 0.0);
        assert!(cursor.number() > 436.0);
        assert_eq!(cursor.number(), 908.0);
        assert_eq!(cursor.number(), 436.0);
        assert_eq!(cursor.number(), 908.0);
        assert_eq!(cursor.number(), 18.0);
        assert_eq!(cursor.number(), 18.0);
        assert_eq!(cursor.number(), 400.0);
        assert_eq!(cursor.number(), 872.0);
        assert_eq!(cursor.number(), 62.0);
        assert_eq!(cursor.text(), "/simulators/U/bezel.png?buttons=false");
        assert_eq!(cursor.text(), "/simulators/U/bezel.png");
        assert_eq!(cursor.count(), 1);
        assert_eq!(cursor.text(), "power");
        assert_eq!(cursor.number(), 97.0);
        assert_eq!(cursor.number(), 28.8);
        assert_eq!(cursor.number(), 3.6);
        assert_eq!(cursor.number(), 11.1);
        assert_eq!(cursor.text(), "/simulators/U/chrome-button/power.png");
        assert_eq!(cursor.text(), "/simulators/U/chrome-button/power-down.png");
        assert_eq!(cursor.text(), "side-button");
        assert_eq!(cursor.at, blob.len(), "the layout must consume the delivery");
    }

    /// Zero back is the refusal, and it reaches every way the wrapped crate refuses. A null span is
    /// an empty document, which is one of them.
    #[test]
    fn a_body_with_nothing_to_draw_answers_zero() {
        assert!(chrome("{}").is_empty());
        assert!(chrome("[]").is_empty());
        assert!(chrome("not json").is_empty());
        // SAFETY: a null input span with a zero length is the documented "no bytes" pair.
        let written = unsafe { slopdesk_sim_chrome(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(written, 0);
    }

    fn devices(json: &str) -> Vec<u8> {
        delivered(|out, cap| {
            // SAFETY: both the fixture and the buffer are live for the duration of the call.
            unsafe { slopdesk_sim_device_list(json.as_ptr(), json.len(), out, cap) }
        })
    }

    /// The two groups fold into one list with running first, and the boot byte rides ahead of each
    /// row's words.
    #[test]
    fn the_device_list_crosses_running_first() {
        let blob = devices(
            r#"{"running":[{"name":"iPhone 17 Pro","runtime":"iOS 26.5","state":"Booted","udid":"U-1"}],
                "available":[{"name":"iPhone Air","runtime":"iOS 26.5","state":"Shutdown","udid":"U-2"}]}"#,
        );
        let mut cursor = Cursor::new(&blob);
        assert_eq!(cursor.count(), 2);
        assert_eq!(cursor.byte(), 1);
        assert_eq!(cursor.text(), "U-1");
        assert_eq!(cursor.text(), "iPhone 17 Pro");
        assert_eq!(cursor.text(), "iOS 26.5");
        assert_eq!(cursor.text(), "Booted");
        assert_eq!(cursor.byte(), 0);
        assert_eq!(cursor.text(), "U-2");
        assert_eq!(cursor.text(), "iPhone Air");
        assert_eq!(cursor.text(), "iOS 26.5");
        assert_eq!(cursor.text(), "Shutdown");
        assert_eq!(cursor.at, blob.len(), "the layout must consume the delivery");
    }

    /// A host with no simulators answers a COUNT of zero inside a two-byte blob; only a top level
    /// that is not an object answers the ABI's own zero.
    #[test]
    fn an_empty_device_set_is_not_a_refusal() {
        let blob = devices("{}");
        assert_eq!(blob.len(), 2);
        assert_eq!(Cursor::new(&blob).count(), 0);
        assert!(devices("[]").is_empty());
        assert!(devices("not json").is_empty());
    }

    fn log(text: &str) -> Vec<u8> {
        delivered(|out, cap| {
            // SAFETY: both the fixture and the buffer are live for the duration of the call.
            unsafe { slopdesk_sim_log_message(text.as_ptr(), text.len(), out, cap) }
        })
    }

    /// The two envelopes the server sends cross as a kind and, for a batch, its rows.
    #[test]
    fn the_console_envelopes_cross_as_a_kind_and_its_rows() {
        assert_eq!(log(r#"{"type":"log_started"}"#), vec![SLOPDESK_SIM_LOG_STARTED]);

        let blob = log(r#"{"type":"log","lines":["one","two"]}"#);
        let mut cursor = Cursor::new(&blob);
        assert_eq!(cursor.byte(), SLOPDESK_SIM_LOG_LINES);
        assert_eq!(cursor.count32(), 2);
        assert_eq!(cursor.text(), "one");
        assert_eq!(cursor.text(), "two");
        assert_eq!(cursor.at, blob.len(), "the layout must consume the delivery");
    }

    /// An EMPTY batch is a real message — the server sends one between bursts — so it crosses as a
    /// kind with a count of zero rather than as the ABI's own zero.
    #[test]
    fn an_empty_batch_is_not_the_refusal() {
        let blob = log(r#"{"type":"log","lines":[]}"#);
        assert_eq!(blob, vec![SLOPDESK_SIM_LOG_LINES, 0, 0, 0, 0]);
    }

    /// Zero is IGNORE THIS MESSAGE. A `type` a newer server added must cost the console that
    /// message and not the socket it arrived on.
    #[test]
    fn a_message_this_build_has_no_case_for_answers_zero() {
        assert!(log(r#"{"type":"log_ended"}"#).is_empty());
        assert!(log(r#"{"lines":["one"]}"#).is_empty());
        assert!(log("[]").is_empty());
        assert!(log("not json").is_empty());
        // SAFETY: a null input span with a zero length is the documented "no bytes" pair.
        let written = unsafe { slopdesk_sim_log_message(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(written, 0);
    }

    fn parse(text: &str) -> Option<(f64, f64)> {
        let blob = delivered(|out, cap| {
            // SAFETY: both the fixture and the buffer are live for the duration of the call.
            unsafe { slopdesk_sim_coordinate_parse(text.as_ptr(), text.len(), out, cap) }
        });
        if blob.is_empty() {
            return None;
        }
        assert_eq!(blob.len(), 16, "a coordinate is two numbers and nothing else");
        let mut cursor = Cursor::new(&blob);
        Some((cursor.number(), cursor.number()))
    }

    /// The paste every map app produces crosses as two bit patterns, and everything that is not a
    /// coordinate answers zero rather than a plausible position.
    #[test]
    fn a_coordinate_crosses_only_when_it_is_one() {
        assert_eq!(parse("37.334886, -122.008988"), Some((37.334_886, -122.008_988)));
        assert_eq!(parse("0, 0"), Some((0.0, 0.0)));
        assert_eq!(parse("90, 180"), Some((90.0, 180.0)));
        assert_eq!(parse("91, 0"), None);
        assert_eq!(parse("Apple Park"), None);
        assert_eq!(parse(""), None);
        // SAFETY: a null input span with a zero length is the documented "no bytes" pair.
        let written =
            unsafe { slopdesk_sim_coordinate_parse(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(written, 0);
    }

    /// The readout is the wrapped crate's, reached through the ABI.
    #[test]
    fn the_readout_is_the_crates() {
        let readout = delivered(|out, cap| {
            // SAFETY: the buffer is a live local for the duration of the call.
            unsafe { slopdesk_sim_coordinate_readout(37.334_886_123_4, -122.008_988_123_4, out, cap) }
        });
        assert_eq!(String::from_utf8_lossy(&readout), "37.334886, -122.008988");
    }

    /// The shortlist crosses whole, and every row of it parses back through the parse door — the
    /// round trip the popover's Copy relies on.
    #[test]
    fn the_shortlist_crosses_whole_and_round_trips() {
        let blob = delivered(|out, cap| {
            // SAFETY: the buffer is a live local for the duration of the call.
            unsafe { slopdesk_sim_places(out, cap) }
        });
        let mut cursor = Cursor::new(&blob);
        assert_eq!(cursor.count(), sim_place::ALL.len());
        for place in sim_place::ALL {
            assert_eq!(cursor.text(), place.name);
            let latitude = cursor.number();
            let longitude = cursor.number();
            assert_eq!(latitude, place.coordinate.latitude);
            assert_eq!(longitude, place.coordinate.longitude);
            let readout = delivered(|out, cap| {
                // SAFETY: the buffer is a live local for the duration of the call.
                unsafe { slopdesk_sim_coordinate_readout(latitude, longitude, out, cap) }
            });
            let readout = String::from_utf8_lossy(&readout).into_owned();
            assert_eq!(parse(&readout), Some((latitude, longitude)));
        }
        assert_eq!(cursor.at, blob.len(), "the layout must consume the delivery");
    }

    /// An undersized buffer writes NOTHING and reports what it needed — `docs/55` §4's retry, which
    /// the near side's reader performs and which every one of these doors must honour.
    #[test]
    fn an_undersized_buffer_is_a_size_report() {
        let mut probe = [0_u8; 4];
        // SAFETY: the buffer is a live local, and four bytes is smaller than any shortlist.
        let needed = unsafe { slopdesk_sim_places(probe.as_mut_ptr(), probe.len()) };
        assert!(needed > probe.len());
        assert_eq!(probe, [0, 0, 0, 0]);
    }
}
