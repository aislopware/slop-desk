//! What a pane is HANDED: the keys typed into it, the secrets kept out of what is shown, and
//! the port its listener binds.
//!
//! One concern joins these: every door here is about the bytes on the way IN. The redaction pair is
//! the odd one at a glance — it answers what a UI may DISPLAY — but it reads the same buffer the
//! send-keys door writes, and splitting them would put one bound in two files.

use core::ffi::c_uchar;

use slopdesk_ids::shell_quoting;
use slopdesk_tree::PaneSpec;
use slopdesk_workspace::{listen, secrets, send_keys, templates};

use crate::{borrow, deliver};

// MARK: Send keys

/// `<Token>`-marked text as the bytes a PTY receives.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_send_keys(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(bytes, len)) else {
            return 0;
        };
        deliver(&send_keys::encode(text), out, cap)
    }
}

/// One key NAME as the bytes a PTY receives, and whether the name is a key at all.
///
/// The `<Token>` grammar's other spelling — a bare name, which is what a comma-separated `--key`
/// list is made of. No key encodes to nothing, so an unknown name could have crossed as a zero
/// length; it does not, because a caller that has to recognise a length as "no such key" is one
/// refusal away from writing the table again.
///
/// # Safety
/// `name` must be null or point to `len` initialised bytes live for the call; `out` must be null or
/// writable for `cap` bytes; `needed` must be null or point to one writable `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_key_token(
    name: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
    needed: *mut usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(name, len)) else {
            return false;
        };
        let Some(bytes) = send_keys::key_token(text) else {
            return false;
        };
        let written = deliver(&bytes, out, cap);
        if !needed.is_null() {
            needed.write(written);
        }
        true
    }
}

/// Any text as ONE shell word. `bare_if_safe` leaves a word a shell would not act on unquoted
/// (`shlex.quote`); without it the quotes are always written.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_shell_quote(
    bytes: *const c_uchar,
    len: usize,
    bare_if_safe: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(bytes, len)) else {
            return 0;
        };
        let quoted = if bare_if_safe {
            shell_quoting::shlex_quoted(text)
        } else {
            shell_quoting::single_quoted(text)
        };
        deliver(quoted.as_bytes(), out, cap)
    }
}

// MARK: Secrets

/// A title or notification body with every recognised credential masked.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_redact_secrets(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(bytes, len)) else {
            return 0;
        };
        deliver(secrets::redact(text).as_bytes(), out, cap)
    }
}

/// The placeholder a masked credential collapses to. §4-shaped.
///
/// Asked for rather than transcribed because it is what a caller ASSERTS against — a test that
/// spells its own copy passes on a mask the redactor stopped producing, which is the one failure a
/// redaction test exists to catch.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_secret_mask(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(secrets::MASK.as_bytes(), out, cap) }
}

/// Whether `bytes` looks like a credential — a shape the redactor knows, or a single high-entropy
/// token. The preview a clipboard ring renders asks this before it shows anything at all.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_looks_secret(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(bytes, len) };
    core::str::from_utf8(raw).is_ok_and(secrets::looks_secret)
}

/// Whether `path` is almost certainly a plugin manager's TRANSIENT cache directory rather than
/// somewhere a person navigated to.
///
/// The pane directory a split or a relaunch inherits. Without an OSC-7 hook it comes from asking
/// the kernel what the shell's working directory is, which observes every internal `chdir` — so a
/// plugin manager stepping into a cache directory to source it can be caught mid-step, and the
/// pane then spawns its next shell THERE. Invalid UTF-8 is not a plugin path, so it is `false`.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_transient_plugin_cwd(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(bytes, len) };
    core::str::from_utf8(raw).is_ok_and(PaneSpec::looks_like_transient_plugin_cwd)
}

/// A directory's LEAF, as a sidebar row or a tab title shows it, under §4's convention.
///
/// `0` means there is no name to show — an absent, blank or all-slashes path — which is a real
/// answer here rather than an empty buffer: a name that exists is never empty, so the two cannot
/// be confused. Root answers `/`, because its leaf is itself.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_cwd_display_name(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    let raw = unsafe { borrow(bytes, len) };
    let name = core::str::from_utf8(raw)
        .ok()
        .and_then(|text| PaneSpec::cwd_display_name(Some(text)))
        .unwrap_or_default();
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(name.as_bytes(), out, cap) }
}

/// The same directory as a BADGE prints it — home collapsed to `~`, a trailing `/` marking it a
/// directory — for the command palette's WORKING DIRECTORY pill.
///
/// `0` means the path was empty, and an empty badge is the honest answer to an empty path: unlike
/// the leaf above, this one prints the WHOLE path, so there is no such thing as a path with nothing
/// to show.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_cwd_badge_path(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    let raw = unsafe { borrow(bytes, len) };
    let badge = core::str::from_utf8(raw)
        .map(PaneSpec::cwd_badge_path)
        .unwrap_or_default();
    // SAFETY: the caller's obligation, restated above.
    unsafe { deliver(badge.as_bytes(), out, cap) }
}

/// The risk of typing `bytes` into a field, as a `PasteRisk` discriminant.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_paste_risk(
    bytes: *const c_uchar,
    len: usize,
    target_is_secure: bool,
    max_length: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(bytes, len) };
    // Text that is not UTF-8 cannot be typed as keystrokes either, so it reads as the empty paste.
    let text = core::str::from_utf8(raw).unwrap_or("");
    risk_byte(secrets::assess(text, target_is_secure, max_length))
}

/// A `PasteRisk` discriminant, matching the Swift enum's case order.
#[expect(
    clippy::cast_possible_truncation,
    reason = "four variants: the index cannot leave u8"
)]
fn risk_byte(risk: secrets::PasteRisk) -> u8 {
    secrets::PasteRisk::ALL
        .iter()
        .position(|candidate| *candidate == risk)
        .unwrap_or(0) as u8
}

// MARK: What a preset or a template types into the pane it just opened

/// The bytes a freshly spawned pane receives: a `cd` line when a directory is set, then the
/// command.
///
/// The two callers that had this — a launch preset and a session template — send the same bytes on
/// purpose, so a template pane behaves exactly like a preset one. Both cross here.
///
/// The security property is that the `cd` line is built from LITERAL bytes and never reaches the
/// token parser: a working directory is a filesystem path, and a `<Enter>` inside one would end the
/// quoted line early and run the rest as its own command. Quoting does not help — it escapes
/// quotes, not tokens. Only `command`, which is shell input by intent, is parsed.
///
/// An empty command with no directory writes nothing, which is what lets a preset open a plain
/// shell. A null or empty `cwd` is "no directory"; the two are the same answer here.
///
/// # Safety
/// `command` and `cwd` must each be null or point to their stated length in initialised bytes live
/// for the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_launch_keystrokes(
    command: *const c_uchar,
    command_len: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` and `deliver` state their own.
    unsafe {
        // Text that is not UTF-8 cannot be typed as keystrokes either, so it reads as empty — the
        // same answer the caller would get for a pane with nothing to run.
        let command = core::str::from_utf8(borrow(command, command_len)).unwrap_or("");
        let directory = core::str::from_utf8(borrow(cwd, cwd_len)).ok();
        deliver(&templates::keystrokes(command, directory), out, cap)
    }
}

// MARK: The listen port, and the bind conflict hiding inside a retryable state

// `slopdesk_ws_listen_port_is_valid` was here. Its ONE caller was
// `Sources/SlopDeskTransport/PortValidation.swift:16`, which `docs/63` G.3 deleted along with the
// rest of the Swift client mux — the port is validated at the dial in `rust/slopdesk-clientnet`
// now, by the code that binds it rather than by a field that asks about it. `listen::is_valid_port`
// stays: `listen::port` composes it, and that is the door the host still opens.

/// Whether a listener-failure detail string says the bind failed because the address is in use.
///
/// Non-UTF-8 reads as "not a bind conflict": the caller renders the same detail as text, so bytes
/// it cannot render cannot be the phrase this looks for either.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_listen_detail_is_address_in_use(
    bytes: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(bytes, len) };
    core::str::from_utf8(raw).is_ok_and(listen::detail_indicates_address_in_use)
}

/// Whether a listener parked in the framework's retryable "no usable network path yet" state is
/// really stuck on a bind conflict that will never auto-recover.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_listen_waiting_errno_is_fatal(posix_errno: i32) -> bool {
    listen::waiting_errno_is_fatal_bind_conflict(posix_errno)
}
