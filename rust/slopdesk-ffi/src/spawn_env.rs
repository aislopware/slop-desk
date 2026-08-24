//! What a pane's login shell is spawned with, in C — `Sources/SlopDeskHost/HostServer.swift`.
//!
//! The rules are [`slopdesk_muxsession::spawn_env`]; what is here is the marshalling.
//!
//! ## Why the parent environment crosses as a BLOB and not as reads on the near side
//!
//! [`crate::tool_path`] argues the opposite for its three lookups, and both are right, because the
//! question is how many keys the rule NAMES. A locator reads three variables the caller already
//! knows about, so pushing dictionary access across the boundary would buy nothing. The curated
//! environment names TWELVE — nine mirrored, three shell-integration opt-outs — and the whole point
//! of the module is that the list is closed and lives in one place. Passing twelve `(ptr, len)`
//! pairs would put the list back on the Swift side in the argument order, which is the drift this
//! port exists to end.
//!
//! So the parent crosses whole, as `[u32 big-endian length][UTF-8]` runs in KEY, VALUE order — the
//! same framing [`crate::push_text`] writes going the other way, read here by [`take_text`]. An odd
//! number of runs, a length that overruns the blob, or a non-UTF-8 run ends the read: a truncated
//! parent yields a curated environment built from what was intact, which is exactly what the
//! allowlist would have produced had the missing keys been absent.
//!
//! ## Why the version is a parameter
//! `TERM_PROGRAM_VERSION` is a release-owned site. `make release` rewrites every place the
//! marketing version is typed, and a copy minted inside a crate the release tool does not scan
//! would be a version that silently stopped being bumped. The caller passes what it already holds.

use core::ffi::c_uchar;

use slopdesk_muxsession::spawn_env::{self, Exports};

use crate::{borrow, deliver, push_text};

/// Reads one `[u32 big-endian length][UTF-8]` run at `cursor`, advancing it past the run.
///
/// `None` on a truncated prefix, a length that overruns the blob, or bytes that are not UTF-8 —
/// each of which means the delivery and this reader disagree about the layout, and continuing past
/// one would dress every later run in its neighbour's text.
fn take_text(blob: &[u8], cursor: &mut usize) -> Option<String> {
    let prefix = blob.get(*cursor..cursor.checked_add(4)?)?;
    let length = usize::try_from(u32::from_be_bytes(prefix.try_into().ok()?)).ok()?;
    let start = cursor.checked_add(4)?;
    let end = start.checked_add(length)?;
    let text = core::str::from_utf8(blob.get(start..end)?).ok()?;
    *cursor = end;
    Some(text.to_owned())
}

/// The parent environment as a map, read from the KEY, VALUE run pairs of `blob`.
fn parse_parent(blob: &[u8]) -> std::collections::BTreeMap<String, String> {
    let mut parent = std::collections::BTreeMap::new();
    let mut cursor = 0_usize;
    while cursor < blob.len() {
        let Some(key) = take_text(blob, &mut cursor) else {
            break;
        };
        let Some(value) = take_text(blob, &mut cursor) else {
            break;
        };
        parent.insert(key, value);
    }
    parent
}

/// A `(ptr, len)` pair as an optional string: empty or null is ABSENT, which is how the three
/// exports say "the host has none" without a separate flag.
///
/// # Safety
/// `ptr` must be null or point to `len` live bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "reading the caller's bytes is what this helper exists to do once"
)]
unsafe fn optional_text<'a>(ptr: *const c_uchar, len: usize) -> Option<&'a str> {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let bytes = unsafe { borrow(ptr, len) };
    if bytes.is_empty() {
        return None;
    }
    core::str::from_utf8(bytes).ok()
}

/// The curated child environment, delivered as KEY, VALUE runs in the same framing the parent
/// arrived in, with `pair_count` receiving how many PAIRS were written.
///
/// The order is the map's, which is lexicographic by key and therefore stable: two spawns of the
/// same pane produce byte-identical deliveries.
///
/// # Safety
/// Every `(ptr, len)` pair must be null or point to that many live bytes for the whole call; `out`
/// must be null or writable for `cap` bytes; `pair_count` must be null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_spawn_env(
    parent: *const c_uchar,
    parent_len: usize,
    term: *const c_uchar,
    term_len: usize,
    version: *const c_uchar,
    version_len: usize,
    agent_socket: *const c_uchar,
    agent_socket_len: usize,
    pane_id: *const c_uchar,
    pane_id_len: usize,
    control_socket: *const c_uchar,
    control_socket_len: usize,
    out: *mut c_uchar,
    cap: usize,
    pair_count: *mut usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let parent = parse_parent(unsafe { borrow(parent, parent_len) });
    // SAFETY: the caller's obligation above is `borrow`'s.
    let term = unsafe { optional_text(term, term_len) }.unwrap_or_default();
    // SAFETY: the caller's obligation above is `borrow`'s.
    let version = unsafe { optional_text(version, version_len) }.unwrap_or_default();
    let exports = Exports {
        // SAFETY: the caller's obligation above is `borrow`'s, three times.
        agent_socket_path: unsafe { optional_text(agent_socket, agent_socket_len) },
        // SAFETY: as above.
        pane_id: unsafe { optional_text(pane_id, pane_id_len) },
        // SAFETY: as above.
        control_socket_path: unsafe { optional_text(control_socket, control_socket_len) },
    };
    let env = spawn_env::curated(&parent, term, version, exports);
    let mut blob: Vec<u8> = Vec::new();
    for (key, value) in &env {
        push_text(&mut blob, key);
        push_text(&mut blob, value);
    }
    if !pair_count.is_null() {
        // SAFETY: non-null and writable by the caller's obligation above.
        unsafe { *pair_count = env.len() };
    }
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(&blob, out, cap) }
}

/// The login shell for a `$SHELL` value: the value itself when ABSOLUTE, else `/bin/zsh`.
///
/// The VALUE, not the environment — the one dictionary read stays with the caller, the way
/// [`crate::tool_path`] leaves its three there.
///
/// # Safety
/// `shell` must be null or point to `shell_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_login_shell(
    shell: *const c_uchar,
    shell_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut parent = std::collections::BTreeMap::new();
    // SAFETY: the caller's obligation above is `borrow`'s.
    if let Some(value) = unsafe { optional_text(shell, shell_len) } {
        parent.insert("SHELL".to_owned(), value.to_owned());
    }
    let answer = spawn_env::login_shell(&parent).to_owned();
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The login shell's `argv[0]`: the basename with a leading `-`.
///
/// # Safety
/// `shell` must be null or point to `shell_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_login_argv0(
    shell: *const c_uchar,
    shell_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let shell = unsafe { optional_text(shell, shell_len) }.unwrap_or_default();
    let answer = spawn_env::login_argv0(shell);
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the door is the point"
)]
mod tests {
    use std::collections::BTreeMap;

    use super::{slopdesk_login_argv0, slopdesk_login_shell, slopdesk_spawn_env, take_text};
    use crate::push_text;
    use crate::testing::delivered;

    fn blob_of(pairs: &[(&str, &str)]) -> Vec<u8> {
        let mut blob = Vec::new();
        for (key, value) in pairs {
            push_text(&mut blob, key);
            push_text(&mut blob, value);
        }
        blob
    }

    fn curated(parent: &[(&str, &str)]) -> BTreeMap<String, String> {
        let parent = blob_of(parent);
        let mut pairs = 0_usize;
        let delivery = delivered(|out, cap| {
            // SAFETY: every slice is live for the call and `pairs` is a live cell.
            unsafe {
                slopdesk_spawn_env(
                    parent.as_ptr(),
                    parent.len(),
                    c"xterm-ghostty".to_bytes().as_ptr(),
                    13,
                    c"9.9.9".to_bytes().as_ptr(),
                    5,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    out,
                    cap,
                    &raw mut pairs,
                )
            }
        });
        let mut cursor = 0_usize;
        let mut env = BTreeMap::new();
        for _ in 0..pairs {
            let key = take_text(&delivery, &mut cursor).expect("a key run");
            let value = take_text(&delivery, &mut cursor).expect("a value run");
            env.insert(key, value);
        }
        assert_eq!(cursor, delivery.len(), "the delivery is exactly its runs");
        env
    }

    #[test]
    fn the_parent_crosses_and_the_defaults_land_on_top() {
        let env = curated(&[
            ("HOME", "/Users/x"),
            ("TERM_PROGRAM", "Apple_Terminal"),
            ("SSH_AUTH_SOCK", "/tmp/agent"),
            ("SLOPDESK_OSC133", "0"),
        ]);
        assert_eq!(env.get("HOME").map(String::as_str), Some("/Users/x"));
        assert_eq!(env.get("TERM").map(String::as_str), Some("xterm-ghostty"));
        assert_eq!(env.get("TERM_PROGRAM").map(String::as_str), Some("slopdesk"));
        assert_eq!(env.get("TERM_PROGRAM_VERSION").map(String::as_str), Some("9.9.9"));
        assert_eq!(env.get("SLOPDESK_OSC133").map(String::as_str), Some("0"));
        assert!(!env.contains_key("SSH_AUTH_SOCK"), "the allowlist held");
    }

    #[test]
    fn an_empty_parent_is_still_a_usable_environment() {
        let env = curated(&[]);
        assert_eq!(env.get("LANG").map(String::as_str), Some("en_US.UTF-8"));
        assert!(env.get("PATH").is_some_and(|path| path.contains("/usr/bin")));
    }

    #[test]
    fn the_three_exports_appear_only_when_named() {
        let parent = blob_of(&[]);
        let mut pairs = 0_usize;
        let delivery = delivered(|out, cap| {
            // SAFETY: every slice is live for the call and `pairs` is a live cell.
            unsafe {
                slopdesk_spawn_env(
                    parent.as_ptr(),
                    parent.len(),
                    c"t".to_bytes().as_ptr(),
                    1,
                    c"v".to_bytes().as_ptr(),
                    1,
                    c"/tmp/hook.sock".to_bytes().as_ptr(),
                    14,
                    std::ptr::null(),
                    0,
                    c"/tmp/ctl.sock".to_bytes().as_ptr(),
                    13,
                    out,
                    cap,
                    &raw mut pairs,
                )
            }
        });
        let mut cursor = 0_usize;
        let mut env = BTreeMap::new();
        for _ in 0..pairs {
            let key = take_text(&delivery, &mut cursor).expect("a key run");
            let value = take_text(&delivery, &mut cursor).expect("a value run");
            env.insert(key, value);
        }
        assert_eq!(
            env.get("SLOPDESK_SOCKET_PATH").map(String::as_str),
            Some("/tmp/hook.sock")
        );
        assert_eq!(
            env.get("SLOPDESK_CONTROL_SOCKET").map(String::as_str),
            Some("/tmp/ctl.sock")
        );
        assert!(!env.contains_key("SLOPDESK_PANE_ID"), "an empty export is absent");
    }

    #[test]
    fn a_truncated_parent_yields_what_was_intact() {
        let mut parent = blob_of(&[("HOME", "/Users/x"), ("LC_ALL", "C")]);
        parent.truncate(parent.len() - 1);
        let mut pairs = 0_usize;
        let delivery = delivered(|out, cap| {
            // SAFETY: the slice is live for the call and `pairs` is a live cell.
            unsafe {
                slopdesk_spawn_env(
                    parent.as_ptr(),
                    parent.len(),
                    c"t".to_bytes().as_ptr(),
                    1,
                    c"v".to_bytes().as_ptr(),
                    1,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    out,
                    cap,
                    &raw mut pairs,
                )
            }
        });
        assert!(pairs > 0, "the intact prefix still produced an environment");
        assert!(!delivery.is_empty());
    }

    #[test]
    fn a_null_parent_is_inert() {
        // SAFETY: every pointer is null, which the door's own contract admits.
        let needed = unsafe {
            slopdesk_spawn_env(
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
            )
        };
        assert!(needed > 0, "the defaults are an environment even with no parent");
    }

    fn shell(value: &str) -> String {
        // SAFETY: `value` is a live slice for the call.
        String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_login_shell(value.as_ptr(), value.len(), out, cap)
        }))
        .expect("a path crosses as its own bytes")
    }

    fn argv0(value: &str) -> String {
        // SAFETY: `value` is a live slice for the call.
        String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_login_argv0(value.as_ptr(), value.len(), out, cap)
        }))
        .expect("a basename crosses as its own bytes")
    }

    #[test]
    fn only_an_absolute_shell_crosses_as_itself() {
        assert_eq!(shell("/bin/fish"), "/bin/fish");
        assert_eq!(shell("fish"), "/bin/zsh");
        assert_eq!(shell(""), "/bin/zsh");
    }

    #[test]
    fn argv0_wears_the_login_dash() {
        assert_eq!(argv0("/bin/zsh"), "-zsh");
        assert_eq!(argv0("/opt/homebrew/bin/fish"), "-fish");
        assert_eq!(argv0(""), "-");
    }
}
