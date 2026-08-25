//! What a new pane inherits from the one it was split off, and which readings are kept, in C.
//!
//! `slopdesk_workspace::store_seed` owns the decisions. What is here is the marshalling.
//!
//! ## Blank is absent on the way IN to a seed, and a real value on the way in to a gate
//!
//! The two halves of this module read a blank string differently, and the difference is the rules'
//! rather than the boundary's. A seed asks what there is to hand down, and there is nothing to hand
//! down from a blank directory, so the seed doors treat it as absent — the same reading a null
//! `(ptr, len)` gets. A write gate asks whether a value the caller is holding is worth storing, and
//! the caller genuinely holds it, so the gate doors pass it through and let the rule judge it.
//!
//! That is why the gates carry an explicit `has_current` beside their second pair: a pane whose
//! directory has never been recorded and one recorded as blank are different facts to a dirty
//! guard, and `(ptr, len)` alone cannot tell them apart.

use core::ffi::c_uchar;

use slopdesk_workspace::store_seed;

use crate::borrow;

/// A caller-lent `(ptr, len)` as text, blank preserved. `None` only for bytes that are not UTF-8 —
/// a path this side cannot read is a path it cannot make a claim about.
///
/// # Safety
/// `(ptr, len)` must satisfy [`borrow`]'s obligation.
#[expect(
    unsafe_code,
    reason = "lending the caller's bytes for the call is half this module's pointer work"
)]
unsafe fn word<'a>(ptr: *const c_uchar, len: usize) -> Option<&'a str> {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    let lent = unsafe { borrow(ptr, len) };
    core::str::from_utf8(lent).ok()
}

/// Writes `answer` into `(out, cap)`, answering the bytes it NEEDED. `0` is no answer, `n <= cap`
/// is written, `n > cap` wrote nothing.
///
/// # Safety
/// `(out, cap)` must be null or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the counted convention"
)]
unsafe fn spill(answer: Option<&str>, out: *mut c_uchar, cap: usize) -> usize {
    let Some(bytes) = answer.map(str::as_bytes) else {
        return 0;
    };
    let needed = bytes.len();
    if needed == 0 || needed > cap || out.is_null() {
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` bytes by
    // the caller's obligation, and the source is the caller's own input, which the caller lent for
    // reading only — the two buffers are the argument and the answer, never the same allocation.
    unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr(), out, needed) };
    needed
}

/// A pane's directory sanitized as an INHERIT SOURCE — `0` when there is nothing worth inheriting,
/// which is what a plugin manager's cache directory reads as.
///
/// # Safety
/// `(cwd, len)` must be readable, and `(out, cap)` writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_seed_inheritable_cwd(
    cwd: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `word` and `spill`.
    unsafe {
        let source = word(cwd, len).filter(|path| !path.is_empty());
        spill(store_seed::inheritable_cwd(source), out, cap)
    }
}

/// The parent's project key seeded onto a child spawning in `cwd` — `0` to seed nothing, which is
/// what a keyless parent and a key that does not cover the child's directory both read as.
///
/// # Safety
/// `(key, key_len)` and `(cwd, cwd_len)` must be readable, and `(out, cap)` writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_seed_inheritable_project_key(
    key: *const c_uchar,
    key_len: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `word` and `spill`.
    unsafe {
        let parent = word(key, key_len).filter(|key| !key.is_empty());
        let inherited = word(cwd, cwd_len).filter(|path| !path.is_empty());
        spill(store_seed::inheritable_project_key(parent, inherited), out, cap)
    }
}

/// Whether a freshly-observed directory is worth writing: not a plugin-cache reading, and not the
/// value already stored.
///
/// `has_current` distinguishes a pane whose directory has never been recorded from one recorded as
/// blank — a difference `(current, current_len)` alone cannot carry.
///
/// # Safety
/// `(candidate, candidate_len)` and `(current, current_len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_seed_accepts_cwd(
    candidate: *const c_uchar,
    candidate_len: usize,
    current: *const c_uchar,
    current_len: usize,
    has_current: bool,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `word`.
    unsafe {
        let Some(candidate) = word(candidate, candidate_len) else {
            return false;
        };
        let stored = if has_current {
            word(current, current_len)
        } else {
            None
        };
        store_seed::accepts_cwd(candidate, stored)
    }
}

/// Whether a host-pushed project key is worth writing: not blank, not a plugin-cache reading, and
/// not the value already stored.
///
/// # Safety
/// `(candidate, candidate_len)` and `(current, current_len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_seed_accepts_project_key(
    candidate: *const c_uchar,
    candidate_len: usize,
    current: *const c_uchar,
    current_len: usize,
    has_current: bool,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `word`.
    unsafe {
        let Some(candidate) = word(candidate, candidate_len) else {
            return false;
        };
        let stored = if has_current {
            word(current, current_len)
        } else {
            None
        };
        store_seed::accepts_project_key(candidate, stored)
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        slopdesk_ws_seed_accepts_cwd, slopdesk_ws_seed_accepts_project_key, slopdesk_ws_seed_inheritable_cwd,
        slopdesk_ws_seed_inheritable_project_key,
    };

    /// Reads the one-input seed door back as a String through the size-then-read protocol.
    fn inherited_cwd(cwd: &str) -> Option<String> {
        // SAFETY: `cwd` is a live local and `out` is null, the documented size call.
        let needed =
            unsafe { slopdesk_ws_seed_inheritable_cwd(cwd.as_ptr(), cwd.len(), core::ptr::null_mut(), 0) };
        if needed == 0 {
            return None;
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: `cwd` is a live local and `out` holds exactly `needed` bytes.
        let written =
            unsafe { slopdesk_ws_seed_inheritable_cwd(cwd.as_ptr(), cwd.len(), out.as_mut_ptr(), out.len()) };
        if written != needed {
            return None;
        }
        String::from_utf8(out).ok()
    }

    /// Reads the two-input seed door back the same way.
    fn inherited_key(key: &str, cwd: &str) -> Option<String> {
        let mut out = [0_u8; 128];
        // SAFETY: both inputs are live locals and `out` is a live 128-byte buffer.
        let needed = unsafe {
            slopdesk_ws_seed_inheritable_project_key(
                key.as_ptr(),
                key.len(),
                cwd.as_ptr(),
                cwd.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        if needed == 0 || needed > out.len() {
            return None;
        }
        out.get(..needed)
            .and_then(|bytes| core::str::from_utf8(bytes).ok())
            .map(str::to_owned)
    }

    /// Calls the cwd gate with the caller's two readings.
    fn accepts_cwd(candidate: &str, current: Option<&str>) -> bool {
        let stored = current.unwrap_or_default();
        // SAFETY: both strings are live locals for the call.
        unsafe {
            slopdesk_ws_seed_accepts_cwd(
                candidate.as_ptr(),
                candidate.len(),
                stored.as_ptr(),
                stored.len(),
                current.is_some(),
            )
        }
    }

    /// Calls the project-key gate with the caller's two readings.
    fn accepts_key(candidate: &str, current: Option<&str>) -> bool {
        let stored = current.unwrap_or_default();
        // SAFETY: both strings are live locals for the call.
        unsafe {
            slopdesk_ws_seed_accepts_project_key(
                candidate.as_ptr(),
                candidate.len(),
                stored.as_ptr(),
                stored.len(),
                current.is_some(),
            )
        }
    }

    /// A plugin-cache directory crosses back as nothing to inherit.
    #[test]
    fn the_inherit_source_is_sanitized_across_the_door() {
        assert_eq!(inherited_cwd("/work/alpha"), Some("/work/alpha".to_owned()));
        assert_eq!(inherited_cwd("/cache/zsh-users---zsh-autosuggestions"), None);
        assert_eq!(inherited_cwd(""), None);
    }

    /// The key rides along only over its own subtree.
    #[test]
    fn the_seeded_key_crosses_only_over_its_subtree() {
        assert_eq!(
            inherited_key("/work/alpha", "/work/alpha/src"),
            Some("/work/alpha".to_owned()),
        );
        assert_eq!(inherited_key("/work/alpha", "/work/beta"), None);
        assert_eq!(inherited_key("", "/work/alpha"), None);
        assert_eq!(inherited_key("/work/alpha", ""), None);
    }

    /// The dirty guard tells "never recorded" from "recorded blank".
    #[test]
    fn the_gates_tell_absent_from_blank() {
        assert!(
            accepts_cwd("", None),
            "nothing is stored, so a blank reading is a change"
        );
        assert!(!accepts_cwd("", Some("")), "the stored value is already blank");
        assert!(accepts_cwd("/work/alpha", Some("/work/beta")));
        assert!(!accepts_cwd("/work/alpha", Some("/work/alpha")));
        assert!(!accepts_cwd("/cache/owner---repo", None));
    }

    /// The key gate refuses a blank key outright, which is where the two gates differ.
    #[test]
    fn the_key_gate_refuses_a_blank_key() {
        assert!(!accepts_key("", None));
        assert!(accepts_key("/work/alpha", None));
        assert!(!accepts_key("/work/alpha", Some("/work/alpha")));
        assert!(!accepts_key("/cache/owner---repo", None));
    }

    /// Bytes that are not UTF-8 are refused rather than stored — a path this side cannot read is
    /// one it cannot make a claim about.
    #[test]
    fn invalid_utf8_is_refused() {
        let raw = [0x2F_u8, 0xFF, 0xFE];
        // SAFETY: `raw` is a live local for the call, and the second pair is the empty case.
        let accepted =
            unsafe { slopdesk_ws_seed_accepts_cwd(raw.as_ptr(), raw.len(), core::ptr::null(), 0, false) };
        assert!(!accepted);
    }

    /// A null pair at every input is the documented empty case.
    #[test]
    fn null_inputs_are_the_empty_case() {
        // SAFETY: null pointers with zero lengths are the documented empty pairs.
        unsafe {
            assert_eq!(
                slopdesk_ws_seed_inheritable_cwd(core::ptr::null(), 0, core::ptr::null_mut(), 0),
                0,
            );
            assert_eq!(
                slopdesk_ws_seed_inheritable_project_key(
                    core::ptr::null(),
                    0,
                    core::ptr::null(),
                    0,
                    core::ptr::null_mut(),
                    0,
                ),
                0,
            );
            assert!(!slopdesk_ws_seed_accepts_project_key(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                false,
            ));
        }
    }
}
