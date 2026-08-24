//! What the code panel's three surfaces show, in C.
//!
//! The rules are `slopdesk_codepanel::surface`; what is here is the marshalling.
//!
//! The workbench and the two device surfaces answer the SAME layout, because they are the same
//! four-state question asked about three subjects:
//!
//! ```text
//! [u8 kind][u8 detail_is_command]
//! 3 × [u32 length][UTF-8 bytes]   // the waiting label OR the empty title, the system image, the detail
//! ```
//!
//! `kind` is `0` gate, `1` mount-or-devices, `2` waiting, `3` empty. The gate and the mount carry
//! no words; the waiting state carries only the first run; the empty state carries all three. A
//! caller reads exactly as many as `kind` says it has, and the runs that do not apply are empty
//! rather than absent — a fixed three keeps the reader a straight line.
//!
//! The two ANIMATION keys are separate doors and stay strings, because that is what they are for:
//! a caller feeds them to its own transition identity, and the whole point is that `phase_key`
//! deliberately DROPS the ready payload while `ready_key` keeps it. Folding them together would
//! hand a caller one key where the difference between the two is the rule.

use core::ffi::c_uchar;

use slopdesk_codepanel::surface::{self, DeviceSurface, EmptyState, Phase, Workbench};

use crate::{borrow, deliver, push_text};

/// The shared layout, from the pieces every state has some of.
fn packed(kind: u8, label: &str, empty: Option<EmptyState>) -> Vec<u8> {
    let (image, detail, is_command) = empty.map_or(("", "", false), |empty| {
        (empty.system_image, empty.detail, empty.detail_is_command)
    });
    let mut blob = vec![kind, u8::from(is_command)];
    push_text(&mut blob, label);
    push_text(&mut blob, image);
    push_text(&mut blob, detail);
    blob
}

/// The workbench state, packed.
fn packed_workbench(workbench: Workbench) -> Vec<u8> {
    match workbench {
        Workbench::Gate => packed(0, "", None),
        Workbench::Mount => packed(1, "", None),
        Workbench::Waiting(label) => packed(2, label, None),
        Workbench::Empty(empty) => packed(3, empty.title, Some(empty)),
    }
}

/// A device surface's state, packed. `1` is the device list, the twin of the workbench's mount.
fn packed_devices(surface: DeviceSurface) -> Vec<u8> {
    match surface {
        DeviceSurface::Devices => packed(1, "", None),
        DeviceSurface::Waiting(label) => packed(2, label, None),
        DeviceSurface::Empty(empty) => packed(3, empty.title, Some(empty)),
    }
}

/// What the workbench surface shows, in one delivery.
///
/// The four gates are separate arguments in the order the rule asks them, and that order is the
/// rule: the project gate first (a project the user never opened must cost nothing at all), then
/// the root, then the brief wait while the host's project-key push is in flight, and only then the
/// no-project placeholder. A caller that re-asks any of them elsewhere is asking the same decision
/// twice, which is how a panel boots an editor it was gated out of.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_code_workbench(
    phase: u8,
    has_root: bool,
    root_is_opened: bool,
    ready_is_this_root: bool,
    awaiting_project_key: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let workbench = surface::workbench(
        Phase::from_byte(phase),
        has_root,
        root_is_opened,
        ready_is_this_root,
        awaiting_project_key,
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&packed_workbench(workbench), out, cap) }
}

/// What a device surface shows, in one delivery — `android` picks which of the two.
///
/// One door rather than two, because the two differ in three strings and in nothing else; a second
/// door would be a second place for the shared fold to drift.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_code_device_surface(
    phase: u8,
    android: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let phase = Phase::from_byte(phase);
    let state = if android {
        surface::android(phase)
    } else {
        surface::simulators(phase)
    };
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&packed_devices(state), out, cap) }
}

/// The announced-but-empty fourth surface, in the same layout as the other three.
///
/// It has no phase — the tab is real, selecting it parks the workbench and cancels the ensure poll,
/// and only the content is a placeholder — so it takes no argument and always answers `3`, the
/// empty state. It rides the shared layout anyway, because a caller that read it a second way would
/// be a second reader of the one shape this module exists to have.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_code_desktop_surface(out: *mut c_uchar, cap: usize) -> usize {
    let blob = packed(3, surface::DESKTOP.title, Some(surface::DESKTOP));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The panel's fixed words, in one delivery.
///
/// ```text
/// 7 × [u32 length][UTF-8 bytes]
/// ```
///
/// In order: the provision command, the gate's system image, the gate's title, the two device toast
/// ids, and the two device fallback subjects. Seven constants that would otherwise be seven doors,
/// or worse, seven string literals spelled a second time in another language.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_code_panel_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in [
        surface::PROVISION_COMMAND,
        surface::GATE_SYSTEM_IMAGE,
        surface::GATE_OPEN_TITLE,
        surface::SIMULATOR_TOAST_ID,
        surface::ANDROID_TOAST_ID,
        surface::SIMULATOR_FALLBACK_SUBJECT,
        surface::ANDROID_FALLBACK_SUBJECT,
    ] {
        push_text(&mut blob, word);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The transition identity for `phase`, with the ready payload deliberately DROPPED.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// A ready service that respawns on a new port is the same surface and must not blink.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_code_phase_key(phase: u8, out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    push_text(&mut blob, surface::phase_key(Phase::from_byte(phase)));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The identity that DOES carry the ready payload — the key a mounted webview is rebuilt against.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// The twin of [`slopdesk_code_phase_key`], and the difference between them is the rule: this one
/// changes when the endpoint moves, which is exactly when the mount must be torn down.
///
/// # Safety
/// `host` must be null or `host_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_code_ready_key(
    phase: u8,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let host = String::from_utf8_lossy(unsafe { borrow(host, host_len) });
    let mut blob = Vec::new();
    push_text(
        &mut blob,
        &surface::ready_key(Phase::from_byte(phase), &host, port),
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The gate button's subject — the project root's last component, or the whole path when it has no
/// components to take.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `root` must be null or `root_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_code_gate_title(
    root: *const c_uchar,
    root_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let root = String::from_utf8_lossy(unsafe { borrow(root, root_len) });
    let mut blob = Vec::new();
    push_text(&mut blob, surface::gate_title(&root));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The clipped title bar's height, in points.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_code_clipped_title_bar_height() -> f64 {
    surface::CLIPPED_TITLE_BAR_HEIGHT
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_codepanel::surface::{self, DeviceSurface, Phase, Workbench};

    use super::{
        slopdesk_code_clipped_title_bar_height, slopdesk_code_desktop_surface, slopdesk_code_device_surface,
        slopdesk_code_gate_title, slopdesk_code_panel_words, slopdesk_code_phase_key,
        slopdesk_code_ready_key, slopdesk_code_workbench,
    };
    use crate::testing::{delivered, runs};

    /// What the near side would read back out of one delivery.
    #[derive(PartialEq, Eq, Debug)]
    struct Read {
        kind: u8,
        is_command: bool,
        label: String,
        image: String,
        detail: String,
    }

    fn read(blob: &[u8]) -> Option<Read> {
        let header = blob.get(..2)?;
        let words = runs(blob.get(2..)?, 3);
        Some(Read {
            kind: *header.first()?,
            is_command: header.get(1) == Some(&1),
            label: words.first()?.clone(),
            image: words.get(1)?.clone(),
            detail: words.get(2)?.clone(),
        })
    }

    /// What the crate's own answer packs to, spelled independently of `packed`.
    fn expected_workbench(workbench: Workbench) -> Read {
        match workbench {
            Workbench::Gate | Workbench::Mount => {
                Read {
                    kind: u8::from(matches!(workbench, Workbench::Mount)),
                    is_command: false,
                    label: String::new(),
                    image: String::new(),
                    detail: String::new(),
                }
            },
            Workbench::Waiting(label) => {
                Read {
                    kind: 2,
                    is_command: false,
                    label: label.to_owned(),
                    image: String::new(),
                    detail: String::new(),
                }
            },
            Workbench::Empty(empty) => {
                Read {
                    kind: 3,
                    is_command: empty.detail_is_command,
                    label: empty.title.to_owned(),
                    image: empty.system_image.to_owned(),
                    detail: empty.detail.to_owned(),
                }
            },
        }
    }

    /// EVERY phase against EVERY combination of the four gates — 64 sweeps, not a probe.
    #[test]
    fn every_workbench_state_crosses_unchanged() {
        for phase_byte in 0..5_u8 {
            for gates in 0..16_u8 {
                let (root, opened, ready, awaiting) =
                    (gates & 1 == 1, gates & 2 == 2, gates & 4 == 4, gates & 8 == 8);
                let blob = delivered(|out, cap| {
                    // SAFETY: `out` is a live local for the call.
                    unsafe { slopdesk_code_workbench(phase_byte, root, opened, ready, awaiting, out, cap) }
                });
                let expected =
                    surface::workbench(Phase::from_byte(phase_byte), root, opened, ready, awaiting);
                assert_eq!(
                    read(&blob),
                    Some(expected_workbench(expected)),
                    "phase {phase_byte}, gates {gates:#06b}",
                );
            }
        }
    }

    #[test]
    fn both_device_surfaces_cross_unchanged() {
        for phase_byte in 0..5_u8 {
            for android in [false, true] {
                let blob = delivered(|out, cap| {
                    // SAFETY: `out` is a live local for the call.
                    unsafe { slopdesk_code_device_surface(phase_byte, android, out, cap) }
                });
                let phase = Phase::from_byte(phase_byte);
                let expected = if android {
                    surface::android(phase)
                } else {
                    surface::simulators(phase)
                };
                let expected = match expected {
                    DeviceSurface::Devices => expected_workbench(Workbench::Mount),
                    DeviceSurface::Waiting(label) => expected_workbench(Workbench::Waiting(label)),
                    DeviceSurface::Empty(empty) => expected_workbench(Workbench::Empty(empty)),
                };
                assert_eq!(
                    read(&blob),
                    Some(expected),
                    "phase {phase_byte}, android {android}"
                );
            }
        }
    }

    #[test]
    fn the_seven_fixed_words_cross_in_their_documented_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_code_panel_words(out, cap) }
        });
        let words = runs(&blob, 7);
        let expected = [
            surface::PROVISION_COMMAND,
            surface::GATE_SYSTEM_IMAGE,
            surface::GATE_OPEN_TITLE,
            surface::SIMULATOR_TOAST_ID,
            surface::ANDROID_TOAST_ID,
            surface::SIMULATOR_FALLBACK_SUBJECT,
            surface::ANDROID_FALLBACK_SUBJECT,
        ];
        for (index, word) in expected.into_iter().enumerate() {
            assert_eq!(words.get(index).map(String::as_str), Some(word));
        }
    }

    /// The two keys differ in exactly the way the rule says: the port moves one and not the other.
    #[test]
    fn the_two_animation_keys_cross_unchanged_and_stay_different() {
        let host = b"127.0.0.1".to_vec();
        let ready = |port: u16| {
            let blob = delivered(|out, cap| {
                // SAFETY: `host` and `out` are live locals for the call.
                unsafe { slopdesk_code_ready_key(3, host.as_ptr(), host.len(), port, out, cap) }
            });
            runs(&blob, 1).first().cloned().unwrap_or_default()
        };
        for phase_byte in 0..5_u8 {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_code_phase_key(phase_byte, out, cap) }
            });
            assert_eq!(
                runs(&blob, 1).first().map(String::as_str),
                Some(surface::phase_key(Phase::from_byte(phase_byte))),
            );
        }
        assert_eq!(
            ready(8080),
            surface::ready_key(Phase::from_byte(3), "127.0.0.1", 8080)
        );
        assert_ne!(ready(8080), ready(8081), "a respawn on a new port IS a new key");
    }

    #[test]
    fn the_gate_title_and_the_bar_height_cross_unchanged() {
        for root in ["", "/", "/Users/me/proj", "proj"] {
            let bytes = root.as_bytes().to_vec();
            let blob = delivered(|out, cap| {
                // SAFETY: `bytes` and `out` are live locals for the call.
                unsafe { slopdesk_code_gate_title(bytes.as_ptr(), bytes.len(), out, cap) }
            });
            assert_eq!(
                runs(&blob, 1).first().map(String::as_str),
                Some(surface::gate_title(root)),
                "{root:?}",
            );
        }
        assert!(
            (slopdesk_code_clipped_title_bar_height() - surface::CLIPPED_TITLE_BAR_HEIGHT).abs()
                < f64::EPSILON
        );
    }

    /// The announced surface crosses as an EMPTY state carrying all three runs — the same shape the
    /// other two answer, so the near side has one reader rather than a special case.
    #[test]
    fn the_announced_surface_rides_the_shared_layout() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_code_desktop_surface(out, cap) }
        });
        assert_eq!(
            read(&blob),
            Some(Read {
                kind: 3,
                is_command: surface::DESKTOP.detail_is_command,
                label: String::from(surface::DESKTOP.title),
                image: String::from(surface::DESKTOP.system_image),
                detail: String::from(surface::DESKTOP.detail),
            }),
        );
    }
}
