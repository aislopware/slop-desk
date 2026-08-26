//! Both device panels' SECTIONED reading of their device list — two doors over
//! `slopdesk_devicepanel::sections`.
//!
//! ## Why one module, when the two panels get two everywhere else
//!
//! [`crate::android_presentation`] and [`crate::simulator_presentation`] are two modules because
//! the panels share not one byte of protocol — a common door over `adb` and `simctl` would be an
//! abstraction over a coincidence. The grouping is the opposite case: it is ONE rule in the wrapped
//! crate, deliberately, and a delivery framed twice is the drift the port was for. So the two doors
//! sit beside each other over one framing, and what differs between them is only what each panel
//! knows about a device.
//!
//! ## Indices out, not devices
//!
//! The answer names the caller's OWN rows by index, the way [`crate::jump_to`] does. What comes
//! back in words is the part the caller does not hold: the heading, the fact the group lifted, and
//! the row identity that joins the two. A device's name, state and serial never make the trip.
//!
//! ## The framing
//!
//! `[u16 section count]`, then per section:
//!
//! 1. `[u8]` — 1 when this is the running group, which is not cut by family.
//! 2. `[u32 length][UTF-8]` — the heading.
//! 3. `[u8]` — 1 when the group lifted a fact.
//! 4. `[u32 length][UTF-8]` — that fact, empty when it lifted none.
//! 5. `[u16]` — how many rows are under it, then per row: a. `[u16]` — the row's index in the
//!    caller's array. b. `[u8]` — 1 when the row still prints its own value. c. `[u32
//!    length][UTF-8]` — the row identity.
//!
//! ## Every array is positional, so a disagreement answers NOTHING
//!
//! The per-device arrays are read by position — a device's family, its running flag, its key and
//! the fact it might contribute are four arrays deep. One of them a row short would file every
//! later device under its neighbour's family and animate it on its neighbour's identity, so a
//! length disagreement loses the WHOLE reading instead. `jump_to`'s header states the same rule for
//! the same reason.

use core::ffi::c_uchar;

use slopdesk_devicepanel::sections::{Row, Section, sections};
use slopdesk_devicepanel::{android, simulator};

use crate::workspace::{Span, borrow_array, text_of};
use crate::{borrow, deliver, push_text};

/// Frames a sectioned reading into the layout this module's header states.
fn push_sections(blob: &mut Vec<u8>, answer: &[Section]) {
    blob.extend_from_slice(&count(answer.len()).to_be_bytes());
    for section in answer {
        blob.push(u8::from(section.is_running));
        push_text(blob, &section.title);
        blob.push(u8::from(section.shared.is_some()));
        push_text(blob, section.shared.as_deref().unwrap_or_default());
        blob.extend_from_slice(&count(section.members.len()).to_be_bytes());
        for member in &section.members {
            blob.extend_from_slice(&count(member.index).to_be_bytes());
            blob.push(u8::from(member.shows_value));
            push_text(blob, &member.row_identity);
        }
    }
}

/// A count as the `u16` the framing carries, saturating rather than wrapping.
///
/// A device list long enough to reach this is one no panel can render anyway, and the saturating
/// answer is a short list; a wrapping one would be a row index naming a different device.
fn count(value: usize) -> u16 {
    u16::try_from(value).unwrap_or(u16::MAX)
}

/// The Android panel's sectioned device list.
///
/// `kinds` are `SLOPDESK_ANDROID_KIND_*` bytes, one per device; `attached` is 1 for a device `adb`
/// has handed a transport id; `api_levels` is `ro.build.version.sdk` with anything at or below `0`
/// meaning the device reported none; `keys` and `releases` name each device's stable key and its
/// `ro.build.version.release` in `blob`. The answer is this module's framing.
///
/// The heading's lifted fact is [`slopdesk_devicepanel::android::version_label`] — the SAME
/// spelling a row prints — so a heading can never state a version the grouping did not compare.
///
/// # Safety
/// `(blob, blob_len)` must be null, or name `blob_len` initialised bytes live for the call;
/// `(kinds, kind_count)`, `(attached, attached_count)`, `(api_levels, api_count)`,
/// `(keys, key_count)` and `(releases, release_count)` likewise for their own element counts;
/// `(out, cap)` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_android_sections(
    kinds: *const c_uchar,
    kind_count: usize,
    attached: *const c_uchar,
    attached_count: usize,
    api_levels: *const i64,
    api_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    keys: *const Span,
    key_count: usize,
    releases: *const Span,
    release_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if attached_count != kind_count
        || api_count != kind_count
        || key_count != kind_count
        || release_count != kind_count
    {
        return 0;
    }
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(blob, blob_len) };
    // SAFETY: ditto, for the five arrays.
    let (kinds, attached, api_levels, keys, releases) = unsafe {
        (
            borrow_array(kinds, kind_count),
            borrow_array(attached, attached_count),
            borrow_array(api_levels, api_count),
            borrow_array(keys, key_count),
            borrow_array(releases, release_count),
        )
    };

    let labels: Vec<Option<String>> = releases
        .iter()
        .zip(api_levels)
        .map(|(release, level)| {
            android::version_label(text_of(*release, bytes), (*level > 0).then_some(*level))
        })
        .collect();
    let rows: Vec<Row<'_>> = kinds
        .iter()
        .zip(attached)
        .zip(keys)
        .zip(&labels)
        .map(|(((rank, attached), key), label)| {
            Row {
                rank: *rank,
                is_running: *attached != 0,
                value: label.as_deref(),
                key: text_of(*key, bytes).unwrap_or_default(),
            }
        })
        .collect();

    let titles: Vec<&str> = android::DEVICE_KINDS
        .iter()
        .map(|kind| kind.group_title())
        .collect();
    let mut framed = Vec::with_capacity(256);
    push_sections(&mut framed, &sections(&rows, android::ATTACHED_TITLE, &titles));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&framed, out, cap) }
}

/// The simulator panel's sectioned device list.
///
/// `kinds` are `SLOPDESK_SIMULATOR_KIND_*` bytes, one per device; `booted` is 1 for a running
/// simulator; `keys` and `runtimes` name each device's udid and its runtime in `blob`. The answer
/// is this module's framing.
///
/// A runtime that arrives EMPTY — `/simulators.json` can carry one — is a value the row still has
/// and the heading still cannot lift. The wrapped fold states why the two answers differ.
///
/// # Safety
/// `(blob, blob_len)` must be null, or name `blob_len` initialised bytes live for the call;
/// `(kinds, kind_count)`, `(booted, booted_count)`, `(keys, key_count)` and
/// `(runtimes, runtime_count)` likewise for their own element counts; `(out, cap)` must be null or
/// writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_simulator_sections(
    kinds: *const c_uchar,
    kind_count: usize,
    booted: *const c_uchar,
    booted_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    keys: *const Span,
    key_count: usize,
    runtimes: *const Span,
    runtime_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if booted_count != kind_count || key_count != kind_count || runtime_count != kind_count {
        return 0;
    }
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(blob, blob_len) };
    // SAFETY: ditto, for the four arrays.
    let (kinds, booted, keys, runtimes) = unsafe {
        (
            borrow_array(kinds, kind_count),
            borrow_array(booted, booted_count),
            borrow_array(keys, key_count),
            borrow_array(runtimes, runtime_count),
        )
    };

    let rows: Vec<Row<'_>> = kinds
        .iter()
        .zip(booted)
        .zip(keys)
        .zip(runtimes)
        .map(|(((rank, booted), key), runtime)| {
            Row {
                rank: *rank,
                is_running: *booted != 0,
                // A runtime is a field every decoded device has, so an unreadable span is the empty
                // string it decoded from — never `None`, which is the answer for a fact the device
                // never stated and is what the Android panel's version is.
                value: Some(text_of(*runtime, bytes).unwrap_or_default()),
                key: text_of(*key, bytes).unwrap_or_default(),
            }
        })
        .collect();

    let titles: Vec<&str> = simulator::DEVICE_KINDS
        .iter()
        .map(|kind| kind.group_title())
        .collect();
    let mut framed = Vec::with_capacity(256);
    push_sections(&mut framed, &sections(&rows, simulator::RUNNING_TITLE, &titles));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&framed, out, cap) }
}

/// What an Android device calls its platform version, or NO BYTES when it has said nothing about
/// one.
///
/// `has_release` and `has_api` are the caller's optionals: a release that is absent and one that is
/// blank both fall through to the API level, and a device with neither answers nothing. An empty
/// answer cannot be a real label — every label this rule builds has a word in front of a number —
/// so the two non-answers do not need telling apart on the near side.
///
/// # Safety
/// `(release, release_len)` must be null, or name `release_len` live bytes for the call;
/// `(out, cap)` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_android_version_label(
    release: *const c_uchar,
    release_len: usize,
    has_release: bool,
    api_level: i64,
    has_api: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let release = unsafe { borrow(release, release_len) };
    let release = has_release.then(|| core::str::from_utf8(release).ok()).flatten();
    let label = android::version_label(release, has_api.then_some(api_level)).unwrap_or_default();
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(label.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        Span, slopdesk_android_sections, slopdesk_android_version_label, slopdesk_simulator_sections,
    };
    use crate::testing::delivered;

    /// One device's contribution to the lent arrays.
    struct Lent {
        rank: u8,
        running: bool,
        api: i64,
        key: Span,
        value: Span,
    }

    /// A blob builder with `WsStrings`' own layout — append and name what was appended.
    #[derive(Default)]
    struct Arena {
        bytes: Vec<u8>,
    }

    impl Arena {
        fn span(&mut self, text: Option<&str>) -> Span {
            let Some(text) = text else {
                return Span {
                    offset: 0,
                    len: 0,
                    present: false,
                };
            };
            let offset = self.bytes.len();
            self.bytes.extend_from_slice(text.as_bytes());
            Span {
                offset,
                len: text.len(),
                present: true,
            }
        }
    }

    /// The near side's reader, in the shape `DevicePanelBlob` walks it.
    #[derive(Debug, PartialEq, Eq)]
    struct ReadSection {
        title: String,
        is_running: bool,
        shared: Option<String>,
        members: Vec<(usize, bool, String)>,
    }

    struct Cursor<'a> {
        bytes: &'a [u8],
        at: usize,
    }

    impl Cursor<'_> {
        fn byte(&mut self) -> u8 {
            let byte = self.bytes.get(self.at).copied().unwrap_or_default();
            self.at += 1;
            byte
        }

        fn count(&mut self) -> usize {
            usize::from(self.byte()) << 8 | usize::from(self.byte())
        }

        fn text(&mut self) -> String {
            let mut length = 0usize;
            for _ in 0..4 {
                length = length << 8 | usize::from(self.byte());
            }
            let end = self.at + length;
            let text = self
                .bytes
                .get(self.at..end)
                .map(|slice| String::from_utf8_lossy(slice).into_owned())
                .unwrap_or_default();
            self.at = end.min(self.bytes.len());
            text
        }
    }

    fn read(bytes: &[u8]) -> Vec<ReadSection> {
        let mut cursor = Cursor { bytes, at: 0 };
        let count = cursor.count();
        (0..count)
            .map(|_| {
                let is_running = cursor.byte() == 1;
                let title = cursor.text();
                let present = cursor.byte() == 1;
                let shared = cursor.text();
                let members = (0..cursor.count())
                    .map(|_| (cursor.count(), cursor.byte() == 1, cursor.text()))
                    .collect();
                ReadSection {
                    title,
                    is_running,
                    shared: present.then_some(shared),
                    members,
                }
            })
            .collect()
    }

    /// The lifted fact per section, and the per-row answers, without indexing a delivery a
    /// disagreement could have emptied.
    fn lifted(sections: &[ReadSection]) -> Vec<Option<&str>> {
        sections.iter().map(|section| section.shared.as_deref()).collect()
    }

    fn rows(sections: &[ReadSection]) -> Vec<Vec<(usize, bool, &str)>> {
        sections
            .iter()
            .map(|section| {
                section
                    .members
                    .iter()
                    .map(|(index, shows, identity)| (*index, *shows, identity.as_str()))
                    .collect()
            })
            .collect()
    }

    fn android(devices: &[(u8, bool, Option<&str>, i64, &str)]) -> Vec<ReadSection> {
        let mut arena = Arena::default();
        let lent: Vec<Lent> = devices
            .iter()
            .map(|(rank, running, release, api, key)| {
                Lent {
                    rank: *rank,
                    running: *running,
                    api: *api,
                    key: arena.span(Some(key)),
                    value: arena.span(*release),
                }
            })
            .collect();
        let kinds: Vec<u8> = lent.iter().map(|row| row.rank).collect();
        let attached: Vec<u8> = lent.iter().map(|row| u8::from(row.running)).collect();
        let apis: Vec<i64> = lent.iter().map(|row| row.api).collect();
        let keys: Vec<Span> = lent.iter().map(|row| row.key).collect();
        let releases: Vec<Span> = lent.iter().map(|row| row.value).collect();
        let bytes = delivered(|out, cap| unsafe {
            slopdesk_android_sections(
                kinds.as_ptr(),
                kinds.len(),
                attached.as_ptr(),
                attached.len(),
                apis.as_ptr(),
                apis.len(),
                arena.bytes.as_ptr(),
                arena.bytes.len(),
                keys.as_ptr(),
                keys.len(),
                releases.as_ptr(),
                releases.len(),
                out,
                cap,
            )
        });
        read(&bytes)
    }

    fn simulator(devices: &[(u8, bool, &str, &str)]) -> Vec<ReadSection> {
        let mut arena = Arena::default();
        let lent: Vec<Lent> = devices
            .iter()
            .map(|(rank, booted, runtime, udid)| {
                Lent {
                    rank: *rank,
                    running: *booted,
                    api: 0,
                    key: arena.span(Some(udid)),
                    value: arena.span(Some(runtime)),
                }
            })
            .collect();
        let kinds: Vec<u8> = lent.iter().map(|row| row.rank).collect();
        let booted: Vec<u8> = lent.iter().map(|row| u8::from(row.running)).collect();
        let keys: Vec<Span> = lent.iter().map(|row| row.key).collect();
        let runtimes: Vec<Span> = lent.iter().map(|row| row.value).collect();
        let bytes = delivered(|out, cap| unsafe {
            slopdesk_simulator_sections(
                kinds.as_ptr(),
                kinds.len(),
                booted.as_ptr(),
                booted.len(),
                arena.bytes.as_ptr(),
                arena.bytes.len(),
                keys.as_ptr(),
                keys.len(),
                runtimes.as_ptr(),
                runtimes.len(),
                out,
                cap,
            )
        });
        read(&bytes)
    }

    #[test]
    fn the_android_panel_leads_with_what_adb_can_reach() {
        let answer = android(&[
            (0, false, Some("15"), 35, "Pixel_9"),
            (0, true, Some("15"), 35, "emulator-5554"),
        ]);
        assert_eq!(
            answer
                .iter()
                .map(|section| (section.title.as_str(), section.is_running))
                .collect::<Vec<_>>(),
            vec![("Attached", true), ("Phone", false)]
        );
        assert_eq!(
            rows(&answer)
                .first()
                .map(|group| group.iter().map(|(index, ..)| *index).collect::<Vec<_>>()),
            Some(vec![1]),
            "the indices are the caller's"
        );
    }

    #[test]
    fn an_android_group_on_one_release_says_it_once() {
        let answer = android(&[(0, false, Some("15"), 35, "a"), (0, false, Some("15"), 35, "b")]);
        assert_eq!(lifted(&answer), vec![Some("Android 15")]);
        assert_eq!(rows(&answer), vec![vec![
            (0, false, "Phone/a"),
            (1, false, "Phone/b")
        ]]);
    }

    #[test]
    fn an_android_device_with_only_an_api_level_still_has_a_version() {
        let answer = android(&[(0, false, None, 34, "a")]);
        assert_eq!(lifted(&answer), vec![Some("API 34")]);
        // Zero is not an API level, it is the absence of one — and a group cannot lift a non-fact.
        assert_eq!(lifted(&android(&[(0, false, None, 0, "a")])), vec![None]);
    }

    #[test]
    fn an_android_row_identity_names_the_group_it_is_in() {
        assert_eq!(rows(&android(&[(1, false, None, 0, "Pixel_Tablet")])), vec![
            vec![(0, false, "Tablet/Pixel_Tablet")]
        ]);
    }

    #[test]
    fn the_simulator_panel_leads_with_what_is_booted_and_groups_the_rest() {
        let answer = simulator(&[
            (0, false, "iOS 26.5", "u1"),
            (1, false, "iOS 26.5", "u2"),
            (0, true, "iOS 18.5", "u3"),
        ]);
        assert_eq!(
            answer
                .iter()
                .map(|section| section.title.as_str())
                .collect::<Vec<_>>(),
            vec!["Running", "iPhone", "iPad"]
        );
        assert_eq!(lifted(&answer), vec![
            Some("iOS 18.5"),
            Some("iOS 26.5"),
            Some("iOS 26.5")
        ]);
    }

    #[test]
    fn an_empty_runtime_is_not_lifted_but_the_row_still_owns_it() {
        let answer = simulator(&[(0, false, "", "u1"), (0, false, "", "u2")]);
        assert_eq!(lifted(&answer), vec![None]);
        assert_eq!(
            rows(&answer),
            vec![vec![(0, true, "iPhone/u1"), (1, true, "iPhone/u2")]],
            "a row whose group lifted nothing prints what it has, even when that is nothing"
        );
    }

    #[test]
    fn a_length_disagreement_answers_nothing_rather_than_shifting_a_family() {
        let kinds = [0u8, 1];
        let booted = [0u8];
        let keys = [Span {
            offset: 0,
            len: 0,
            present: true,
        }];
        let needed = unsafe {
            slopdesk_simulator_sections(
                kinds.as_ptr(),
                kinds.len(),
                booted.as_ptr(),
                booted.len(),
                core::ptr::null(),
                0,
                keys.as_ptr(),
                keys.len(),
                keys.as_ptr(),
                keys.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0);
    }

    #[test]
    fn an_empty_list_has_no_sections() {
        assert!(android(&[]).is_empty());
        assert!(simulator(&[]).is_empty());
    }

    #[test]
    fn the_label_door_and_the_grouping_speak_the_same_words() {
        let label = |release: Option<&str>, api: Option<i64>| {
            let bytes = delivered(|out, cap| unsafe {
                let text = release.unwrap_or_default();
                slopdesk_android_version_label(
                    text.as_ptr(),
                    text.len(),
                    release.is_some(),
                    api.unwrap_or_default(),
                    api.is_some(),
                    out,
                    cap,
                )
            });
            String::from_utf8(bytes).unwrap_or_default()
        };
        assert_eq!(label(Some("15"), Some(35)), "Android 15");
        assert_eq!(label(Some(""), Some(34)), "API 34");
        assert_eq!(label(None, None), "");
        // The linchpin: the heading prints what the label door would have printed for the same
        // device, because both spell `android::version_label`.
        assert_eq!(lifted(&android(&[(0, false, Some("15"), 35, "a")])), vec![Some(
            label(Some("15"), Some(35)).as_str()
        )]);
    }
}
