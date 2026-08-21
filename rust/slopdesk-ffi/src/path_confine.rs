//! Path confinement, in C — `Sources/SlopDeskHost/MetadataResponseBuilder.swift` and
//! `Sources/SlopDeskHost/CodeBridgeServer.swift`.
//!
//! The rule is [`slopdesk_probe::path_confine`], and that module's own documentation is where the
//! argument for every refusal lives. What is here is the marshalling — and the reason this door
//! exists at all rather than the rule being restated in Swift, which is worth a paragraph because
//! the restatement had already happened twice.
//!
//! hostd asks "is this path confined to this root" in two places and the forked `slopdesk-probe`
//! asks it in a third. All three were written separately and all three answered differently: the
//! request decoder refused a `..` component outright, the editor bridge did no `..` handling at all
//! and answered TRUE for `contains(root: "/a", path: "/a/../../etc/passwd")`, and the probe
//! resolved `..` lexically and re-checked. None of that is visible from any one of the three files,
//! which is precisely the shape a security rule must not have: the second layer was documented as
//! defence in depth behind the first, and it was in fact answering a different question, so
//! tightening either of them tightened nothing.
//!
//! The wrapped crate is `slopdesk-probe` because that crate IS the metadata RPC's Rust half — the
//! confinement question was already being asked inside it. The `path = "../slopdesk-probe"` edge in
//! this crate's manifest is also what puts the rule inside `build-ffi.sh`'s content stamp
//! (`docs/55` §3), so a Swift caller cannot end up linked against last week's confinement.
//!
//! ## Why one door answers three questions
//!
//! The three call sites want three different things out of one evaluation: a bare yes/no (the
//! editor bridge's routing), the confined ABSOLUTE path (`listDirectory`, `listAgentSessions`) and
//! the confined path BELOW the root (`gitDiff`'s repo-relative pathspec). Splitting that into three
//! doors would have meant three evaluations of one rule and three chances to call the wrong one.
//! So the answer is the absolute path under `docs/55` §4's `(out, cap) -> needed` protocol, plus a
//! `size_t *` carrying where the relative half starts inside it — the second-size shape
//! `slopdesk_ws_search_rank` already uses. A caller that only wants the yes/no passes `(NULL, 0)`,
//! which §4 documents as the way to ask for a length, and reads the return as a bool.
//!
//! `0` is the refusal and it cannot collide with an answer: a confined path always begins with `/`
//! and always names at least one component, so its length is never zero.

use core::ffi::c_uchar;

use slopdesk_probe::path_confine::{self, Shape};

use crate::{borrow, deliver};

/// The candidate may be absolute, or relative and joined to the root.
pub const SLOPDESK_PATH_SHAPE_EITHER: u32 = 0;
/// The candidate must be relative; an absolute one is refused rather than confined.
pub const SLOPDESK_PATH_SHAPE_RELATIVE: u32 = 1;
/// The candidate must be absolute; a relative one is refused rather than joined.
pub const SLOPDESK_PATH_SHAPE_ABSOLUTE: u32 = 2;

/// The shape a caller named, or `None` for a value nobody defined.
///
/// An unrecognised shape REFUSES rather than falling back to the permissive one. Every other
/// unknown-tag default in this crate is chosen for its call site; here the call site is a
/// confinement decision, so the only admissible default is the one that grants nothing.
const fn shape_of(raw: u32) -> Option<Shape> {
    match raw {
        SLOPDESK_PATH_SHAPE_EITHER => Some(Shape::Either),
        SLOPDESK_PATH_SHAPE_RELATIVE => Some(Shape::RelativeOnly),
        SLOPDESK_PATH_SHAPE_ABSOLUTE => Some(Shape::AbsoluteOnly),
        _ => None,
    }
}

/// The normalised absolute path `candidate` names when it is confined to `root`, or `0` when it is
/// not confined, not the named shape, or not a path this rule will act on at all.
///
/// `relative_offset` takes the byte offset within the answer at which the part BELOW the root
/// begins — equal to the answer's length exactly when the candidate names the root itself. It is
/// written whenever there IS an answer, including when the buffer was too small for it, so a caller
/// retrying at the reported size does not have to evaluate the rule a third time.
///
/// Bytes that are not UTF-8 refuse. A path this side cannot even decode is not one it should be
/// judging the containment of, and both callers hand over `String.utf8`.
///
/// # Safety
/// `root` must be null or point to `root_len` initialised bytes, `candidate` likewise for
/// `candidate_len`; `out` must be null or writable for `cap` bytes; `relative_offset` must be null
/// or one writable `usize`. All live for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and three of the four buffers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_path_confine(
    root: *const c_uchar,
    root_len: usize,
    candidate: *const c_uchar,
    candidate_len: usize,
    shape: u32,
    relative_offset: *mut usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(shape) = shape_of(shape) else {
        return 0;
    };
    // SAFETY: the caller's contract, one pair at a time.
    let (root_bytes, candidate_bytes) = unsafe { (borrow(root, root_len), borrow(candidate, candidate_len)) };
    let (Ok(root_text), Ok(candidate_text)) = (
        core::str::from_utf8(root_bytes),
        core::str::from_utf8(candidate_bytes),
    ) else {
        return 0;
    };
    let Some(confined) = path_confine::confine(root_text, candidate_text, shape) else {
        return 0;
    };
    if !relative_offset.is_null() {
        // SAFETY: the caller's contract — non-null means one writable `usize` live for the call.
        unsafe { relative_offset.write(confined.relative_offset()) };
    }
    // SAFETY: the caller's contract.
    unsafe { deliver(confined.absolute().as_bytes(), out, cap) }
}

/// Whether `candidate` is a path the rule could ever confine — absolute, naming at least one
/// component, free of `..` and of an interior NUL.
///
/// The question a caller asks when it has no root to confine against. The metadata request decoder
/// is that caller: an agent session id is confined against roots under the host's `$HOME`, which
/// belong to the forked probe and not to a pure reducer, so what the decoder can still do — and
/// must, so a hostile id never reaches a fork — is refuse an argument that is not a well-formed
/// absolute path.
///
/// A second door over one implementation, not a second implementation: the parser behind it is the
/// one [`slopdesk_path_confine`] runs. Bytes that are not UTF-8 answer `false`, for the reason
/// given there.
///
/// # Safety
/// `candidate` must be null or point to `candidate_len` initialised bytes, live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pair is the caller's"
)]
pub unsafe extern "C" fn slopdesk_path_is_confinable_absolute(
    candidate: *const c_uchar,
    candidate_len: usize,
) -> bool {
    // SAFETY: the caller's contract.
    let bytes = unsafe { borrow(candidate, candidate_len) };
    core::str::from_utf8(bytes).is_ok_and(path_confine::is_confinable_absolute)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{
        SLOPDESK_PATH_SHAPE_ABSOLUTE, SLOPDESK_PATH_SHAPE_EITHER, SLOPDESK_PATH_SHAPE_RELATIVE,
        slopdesk_path_confine, slopdesk_path_is_confinable_absolute,
    };

    /// The door as the Swift face reads it: the absolute answer and the relative half of it.
    fn confine(root: &str, candidate: &str, shape: u32) -> Option<(String, String)> {
        let mut buffer = [0_u8; 256];
        let mut offset = usize::MAX;
        // SAFETY: every pair is a live local.
        let needed = unsafe {
            slopdesk_path_confine(
                root.as_ptr(),
                root.len(),
                candidate.as_ptr(),
                candidate.len(),
                shape,
                &raw mut offset,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        if needed == 0 {
            return None;
        }
        let absolute = String::from_utf8_lossy(buffer.get(..needed)?).into_owned();
        let relative = String::from_utf8_lossy(buffer.get(offset..needed)?).into_owned();
        Some((absolute, relative))
    }

    /// The sizing-only call the editor bridge makes — no buffer, no offset, the return read as a
    /// bool.
    fn within(root: &str, candidate: &str) -> bool {
        // SAFETY: both pairs are live locals; a null out buffer with a zero cap is §4's length ask.
        unsafe {
            slopdesk_path_confine(
                root.as_ptr(),
                root.len(),
                candidate.as_ptr(),
                candidate.len(),
                SLOPDESK_PATH_SHAPE_ABSOLUTE,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            ) > 0
        }
    }

    fn confinable(candidate: &str) -> bool {
        // SAFETY: the pair is a live local.
        unsafe { slopdesk_path_is_confinable_absolute(candidate.as_ptr(), candidate.len()) }
    }

    #[test]
    fn the_answer_carries_both_halves_of_one_evaluation() {
        assert_eq!(
            confine("/repo", "src/main.rs", SLOPDESK_PATH_SHAPE_EITHER),
            Some(("/repo/src/main.rs".to_owned(), "src/main.rs".to_owned())),
        );
        assert_eq!(
            confine("/repo", "/repo", SLOPDESK_PATH_SHAPE_ABSOLUTE),
            Some(("/repo".to_owned(), String::new())),
            "the root itself is inside, and its relative half is empty",
        );
    }

    #[test]
    fn a_refusal_is_zero_and_leaves_the_caller_holding_nothing() {
        assert_eq!(confine("/repo", "../escape", SLOPDESK_PATH_SHAPE_EITHER), None);
        assert_eq!(confine("/repo", "/etc/passwd", SLOPDESK_PATH_SHAPE_EITHER), None);
        assert_eq!(confine("/repo", "/repo/a/../b", SLOPDESK_PATH_SHAPE_EITHER), None);
        assert!(!within("/a", "/a/../../etc/passwd"));
        assert!(!within("/a/repo", "/a/repo-evil/x"));
        assert!(within("/a/repo", "/a/repo/x"));
    }

    #[test]
    fn an_undersized_buffer_reports_the_size_and_writes_nothing() {
        let root = "/repo";
        let candidate = "/repo/a/long/enough/path";
        let mut tiny = [0xAA_u8; 4];
        let mut offset = usize::MAX;
        // SAFETY: every pair is a live local.
        let needed = unsafe {
            slopdesk_path_confine(
                root.as_ptr(),
                root.len(),
                candidate.as_ptr(),
                candidate.len(),
                SLOPDESK_PATH_SHAPE_EITHER,
                &raw mut offset,
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(needed, candidate.len());
        assert_eq!(tiny, [0xAA; 4], "an overflow leaves the caller's buffer alone");
        assert_eq!(
            offset,
            "/repo".len() + 1,
            "…and still reports where the relative half starts"
        );
    }

    #[test]
    fn a_shape_nobody_defined_refuses_rather_than_falling_back_to_the_loose_one() {
        assert_eq!(confine("/repo", "src", 7), None);
        assert_eq!(confine("/repo", "/repo/src", 7), None);
        // …while the three that exist each refuse the spelling they do not accept.
        assert_eq!(confine("/repo", "/repo/src", SLOPDESK_PATH_SHAPE_RELATIVE), None);
        assert_eq!(confine("/repo", "src", SLOPDESK_PATH_SHAPE_ABSOLUTE), None);
    }

    #[test]
    fn a_null_or_empty_pair_refuses_rather_than_confining_nothing_to_nothing() {
        // SAFETY: null pairs with zero lengths are what `borrow` documents as empty.
        let needed = unsafe {
            slopdesk_path_confine(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                SLOPDESK_PATH_SHAPE_EITHER,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0);
        assert!(!confinable(""));
    }

    #[test]
    fn the_rootless_door_answers_the_shape_question_alone() {
        assert!(confinable("/home/me/.claude/projects/-p/s.jsonl"));
        assert!(!confinable("/"));
        assert!(!confinable("relative.jsonl"));
        assert!(!confinable("/a/../../secrets"));
    }

    #[test]
    fn bytes_that_are_not_utf8_refuse_on_either_side() {
        let root = b"/repo";
        let bad = [0x2F_u8, 0x72, 0x65, 0x70, 0x6F, 0x2F, 0xFF];
        // SAFETY: both pairs are live locals.
        let needed = unsafe {
            slopdesk_path_confine(
                root.as_ptr(),
                root.len(),
                bad.as_ptr(),
                bad.len(),
                SLOPDESK_PATH_SHAPE_EITHER,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0);
        // SAFETY: the pair is a live local.
        assert!(!unsafe { slopdesk_path_is_confinable_absolute(bad.as_ptr(), bad.len()) });
    }
}
