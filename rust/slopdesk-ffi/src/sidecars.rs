//! Is the sidecar that is RUNNING the sidecar that is INSTALLED — the door.
//!
//! `rust/slopdesk-sidecars` owns the answer: the policy table, the verdict, the banner parse and
//! the manifest diff. This is the marshalling, and it is a door rather than a socket for the reason
//! `docs/55` gives — the question is a function of its arguments, asked by a process that already
//! has both, so a daemon to ask it of would be a lifetime nothing here needs.
//!
//! ## Why the answers cross as JSON text
//! Each is a small record with an optional field or two, and BOTH near-side callers already decode
//! JSON on the same line of code: hostd shows the report in a UI as well as logging it, and
//! `slopdesk sidecars` reads a `MANIFEST.json` to ask the question in the first place. A flat C
//! struct per answer would mean a presence flag per optional and a fixed char array per version —
//! two schemas to keep in step instead of one, for a call that happens five times at start.
//!
//! ## An absent version is an EMPTY pair, not a sentinel
//! `borrow` already folds null and zero-length together, and an empty version string is not a
//! version under any reading, so "the daemon did not answer" and "the daemon answered nothing" are
//! the same fact and cross the same way. That is the one place this file makes a decision, and it
//! is a decision about the ABI rather than about sidecars — which is the line the crate draws.

use std::ffi::c_uchar;

use slopdesk_sidecars::manifest::{self, plan_json};
use slopdesk_sidecars::{Report, parse_version_banner};

use crate::{borrow, deliver};

/// A `(ptr, len)` pair as an optional version: `None` for null, empty, or non-UTF-8.
///
/// Lossy decoding would turn a truncated read into a version string full of replacement characters,
/// which compares unequal to everything and reads as `stale` forever. Absent is the honest answer,
/// and absent is [`slopdesk_sidecars::Verdict::Unknown`], which is a log line rather than a
/// restart.
fn optional_text(bytes: &[u8]) -> Option<&str> {
    let text = core::str::from_utf8(bytes).ok()?.trim();
    if text.is_empty() { None } else { Some(text) }
}

/// One sidecar's audit, as the JSON object `SidecarVersionAudit` decodes.
///
/// `running` is what the live daemon reported over its own channel — superd's `hello`, screend's
/// banner, the announce line for the three of superd's children. `on_disk` is what the binary that
/// would be spawned answers to `--version`. Either may be an empty pair, which is "it did not say".
///
/// # Safety
/// Each input must be null or point to its stated number of live bytes; `out` null or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_sidecar_audit(
    tool: *const c_uchar,
    tool_len: usize,
    running: *const c_uchar,
    running_len: usize,
    on_disk: *const c_uchar,
    on_disk_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (tool_bytes, running_bytes, on_disk_bytes) = unsafe {
        (
            borrow(tool, tool_len),
            borrow(running, running_len),
            borrow(on_disk, on_disk_len),
        )
    };
    let Some(tool_name) = optional_text(tool_bytes) else {
        return 0;
    };
    let answer = Report::new(
        tool_name,
        optional_text(running_bytes),
        optional_text(on_disk_bytes),
    )
    .to_json();
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The version out of a `--version` banner: the second field of the first line.
///
/// Exported rather than reimplemented on the near side because the SAME parse decides what
/// `package-release.sh` pins, what the manifest carries and what this audit compares. Three readers
/// of one contract is two chances to drift.
///
/// # Safety
/// `banner` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_sidecar_version_banner(
    banner: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(banner, len) };
    let Some(text) = core::str::from_utf8(bytes).ok() else {
        return 0;
    };
    let Some(version) = parse_version_banner(text) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(version.as_bytes(), out, cap) }
}

/// What an upgrade changed, from the `MANIFEST.json` that just landed and the one recorded before.
///
/// `previous` may be an empty pair — a first install — in which case every tool reads `added`.
/// Returns 0 when `current` is not a readable manifest, which is the caller's cue to say so rather
/// than to act on a plan it does not have.
///
/// # Safety
/// Each input must be null or point to its stated number of live bytes; `out` null or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_sidecar_upgrade_plan(
    previous: *const c_uchar,
    previous_len: usize,
    current: *const c_uchar,
    current_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (previous_bytes, current_bytes) =
        unsafe { (borrow(previous, previous_len), borrow(current, current_len)) };
    let Ok(current_text) = core::str::from_utf8(current_bytes) else {
        return 0;
    };
    let Ok(current_manifest) = manifest::parse(current_text) else {
        return 0;
    };
    // A previous manifest that is missing is a first install; one that is CORRUPT is treated the
    // same way, deliberately. The alternative is refusing to plan at all because a file written by
    // an install two versions ago cannot be read — which would strand exactly the user who most
    // needs to be told what changed.
    let previous_manifest = core::str::from_utf8(previous_bytes)
        .ok()
        .and_then(|text| manifest::parse(text).ok());
    let answer = plan_json(previous_manifest.as_ref(), &current_manifest);
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}
