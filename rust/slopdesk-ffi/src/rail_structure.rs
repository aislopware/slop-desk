//! The rail's structural FINGERPRINT, for the whole pane list in one crossing.
//!
//! The sidebar memoizes its row model against a fingerprint of the workspace's structure, and the
//! fingerprint is evaluated on EVERY render pass and every keystroke — hit or miss, because
//! comparing it is what decides which. So the walk that builds it is the walk the memo pays for
//! itself, and per pane it was asking two questions that are each several rules deep: the
//! By-Project key's transient-plugin guard, and whether the title chain would come off the pane's
//! foreground process.
//!
//! ## Why the whole list, when the crossings were nanoseconds
//!
//! The crossings were never the cost. Measured on this boundary, a bare door is about a nanosecond
//! and a door with two `Array(String.utf8)` allocations behind it is about a hundred — the
//! MARSHALLING is what a per-member door buys. Asking per pane meant a heap allocation per string
//! per question: the cwd lent twice to two different doors, the answer of each copied out through a
//! scratch buffer and then into a `String` nobody keeps. The list door lends every string once, out
//! of one blob the caller appends into, and answers all of it in one buffer.
//!
//! ## What the answer carries, and why a length is not enough
//!
//! Per pane, in the caller's order: the titles-by-process flag, then the resolved project key as a
//! PRESENCE byte and a four-byte big-endian length. The presence byte is `docs/55` §4b's rule and
//! it is load-bearing here — a pane whose cwd is the empty string resolves to a project key that is
//! present and blank, which buckets differently from a pane with no key at all.

use core::ffi::c_uchar;

use slopdesk_workspace::rail_list::{self, StructurePane};
use slopdesk_workspace::rail_title::{TitleShape, titles_by_process};
use slopdesk_workspace::session::PaneKind;

use crate::deliver;
use crate::workspace::{Span, borrow_array, text_of};

/// The fields that pick a pane's title RUNG, with the project key already resolved.
///
/// Deliberately not [`CRailStructurePane`] though the layout matches: that one carries the key the
/// HOST pushed, before the precedence runs, and this one carries the key the pane was FILED under.
/// A surface with no section headers passes none at all and gets the folder name, which is the same
/// rule with nothing to subtract — and a struct that let the two be passed for each other would
/// make an at-root pane out of every pane on that surface, with nothing but a comment to catch it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRailTitleShape {
    /// A `PaneKind` byte: 0 terminal, 1 desktop.
    pub kind: c_uchar,
    /// The title on the pane's spec; absent is a pane with no spec at all.
    pub spec_title: Span,
    /// Whether that title was typed by the user.
    pub user_renamed: bool,
    /// Where the shell is.
    pub cwd: Span,
    /// The project section this pane is drawn under, absent on a surface with no headers.
    pub project_key: Span,
}

/// Whether this pane's structural title would come off its foreground PROCESS.
///
/// The near side reads its volatile process dictionary only where this is true, so the answer
/// decides an Observation dependency and not just a string. Kept beside the list door for the three
/// callers that genuinely want ONE answer — the window title and the two Open-Quickly pickers,
/// which ask about the pane under the cursor.
///
/// # Safety
/// `strings` must be null or point to `strings_len` initialised bytes, live for the call. Every
/// span in `shape` is bounds-checked against it rather than trusted.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_rail_titles_by_process(
    shape: CRailTitleShape,
    strings: *const c_uchar,
    strings_len: usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = crate::borrow(strings, strings_len);
        titles_by_process(TitleShape {
            kind: PaneKind::from_byte(shape.kind),
            spec_title: text_of(shape.spec_title, blob),
            user_renamed: shape.user_renamed,
            cwd: text_of(shape.cwd, blob),
            project_key: text_of(shape.project_key, blob),
        })
    }
}

/// One pane as the fingerprint reads it. Every string is a span into the ONE blob passed alongside.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRailStructurePane {
    /// A `PaneKind` byte: 0 terminal, 1 desktop.
    pub kind: c_uchar,
    /// The title on the pane's spec; absent is a pane with no spec at all, which is a different
    /// fact from a spec whose title is blank.
    pub spec_title: Span,
    /// Whether that title was typed by the user.
    pub user_renamed: bool,
    /// Where the shell is.
    pub cwd: Span,
    /// The HOST-pushed project key, before the precedence runs.
    pub host_project_key: Span,
}

/// Both fingerprint answers for every pane, in one delivery.
///
/// `count` entries in the caller's order, each `[u8 titles_by_process][u8 key_present]
/// [u32 big-endian key_len][key_len UTF-8 bytes]`. A return larger than `cap` means nothing was
/// written; ask again at that size.
///
/// # Safety
/// `panes` must be null or point to `count` live [`CRailStructurePane`]s; `strings` null or
/// `strings_len` initialised bytes; `out` null or writable for `cap` bytes. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_rail_structure_keys(
    panes: *const CRailStructurePane,
    count: usize,
    strings: *const c_uchar,
    strings_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = crate::borrow(strings, strings_len);
        let held: Vec<StructurePane<'_>> = borrow_array(panes, count)
            .iter()
            .map(|pane| {
                StructurePane {
                    kind: PaneKind::from_byte(pane.kind),
                    spec_title: text_of(pane.spec_title, blob),
                    user_renamed: pane.user_renamed,
                    cwd: text_of(pane.cwd, blob),
                    host_project_key: text_of(pane.host_project_key, blob),
                }
            })
            .collect();
        let mut answer = Vec::with_capacity(count * 8);
        for key in rail_list::structure_keys(&held) {
            answer.push(u8::from(key.titles_by_process));
            answer.push(u8::from(key.project_key.is_some()));
            let text = key.project_key.unwrap_or_default();
            let len = u32::try_from(text.len()).unwrap_or(u32::MAX);
            answer.extend_from_slice(&len.to_be_bytes());
            answer.extend_from_slice(text.as_bytes());
        }
        deliver(&answer, out, cap)
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]
    #![expect(
        clippy::expect_used,
        reason = "a panic while walking a record this test just asked the door for IS the failure report — \
                  softening it to a default would let a short delivery read as an absent key and pass"
    )]

    use slopdesk_workspace::session::PaneKind;
    use slopdesk_workspace::tab_ordering::project_key_of;

    use super::{
        CRailStructurePane, CRailTitleShape, slopdesk_ws_rail_structure_keys,
        slopdesk_ws_rail_titles_by_process,
    };
    use crate::workspace::Span;

    /// A blob builder: the near side's `WsStrings`, in the words the tests need.
    #[derive(Default)]
    struct Blob {
        bytes: Vec<u8>,
    }

    impl Blob {
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

    /// The delivery, walked back into `(titles_by_process, project_key)` per pane.
    fn walked(panes: &[CRailStructurePane], blob: &[u8]) -> Vec<(bool, Option<String>)> {
        let mut out = vec![0_u8; 1024];
        // SAFETY: three live local buffers, borrowed for the duration of the call.
        let written = unsafe {
            slopdesk_ws_rail_structure_keys(
                panes.as_ptr(),
                panes.len(),
                blob.as_ptr(),
                blob.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        let mut rest: &[u8] = out.get(..written).expect("the answer fits the buffer");
        let mut answers = Vec::with_capacity(panes.len());
        for _ in 0..panes.len() {
            let (header, tail) = rest.split_at(6);
            let len = u32::from_be_bytes(
                header
                    .get(2..6)
                    .expect("four bytes")
                    .try_into()
                    .expect("four bytes"),
            ) as usize;
            let (body, tail) = tail.split_at(len);
            answers.push((
                header.first() == Some(&1),
                (header.get(1) == Some(&1))
                    .then(|| String::from_utf8(body.to_vec()).expect("the key is the crate's own string")),
            ));
            rest = tail;
        }
        assert!(rest.is_empty(), "the delivery is exactly as long as the list");
        answers
    }

    /// One pane's inputs, in the words the rules use.
    #[derive(Clone, Copy)]
    struct Case<'a> {
        kind: PaneKind,
        spec_title: Option<&'a str>,
        user_renamed: bool,
        cwd: Option<&'a str>,
        host_project_key: Option<&'a str>,
    }

    const fn case<'a>(
        kind: PaneKind,
        spec_title: Option<&'a str>,
        user_renamed: bool,
        cwd: Option<&'a str>,
        host_project_key: Option<&'a str>,
    ) -> Case<'a> {
        Case {
            kind,
            spec_title,
            user_renamed,
            cwd,
            host_project_key,
        }
    }

    /// Every member of the list answer, against the SINGLE-member door on the same inputs — the
    /// agreement `docs/55` asks of a whole-list door, walked pane by pane rather than restated.
    ///
    /// The project key is checked against the precedence it composes, because the list door
    /// resolves one where the single door is handed one; the rung is checked against the door
    /// itself, so the day somebody changes the title chain either both move or this fails.
    #[test]
    fn every_member_agrees_with_the_single_member_door() {
        let mut blob = Blob::default();
        let cases = [
            // At its project root: the folder name would restate the section header.
            case(
                PaneKind::Terminal,
                Some("slopdesk"),
                false,
                Some("/w/slopdesk"),
                Some("/w/slopdesk"),
            ),
            // Strayed into the subtree: the folder name titles it.
            case(
                PaneKind::Terminal,
                Some("api"),
                false,
                Some("/w/slopdesk/api"),
                Some("/w/slopdesk"),
            ),
            // No directory known yet.
            case(PaneKind::Terminal, Some("Terminal"), false, None, None),
            // A name the user typed outranks everything.
            case(
                PaneKind::Terminal,
                Some("build"),
                true,
                Some("/w/slopdesk"),
                Some("/w/slopdesk"),
            ),
            // A transient plugin cache is never a project key, so the cwd is not one either.
            case(
                PaneKind::Terminal,
                Some("x"),
                false,
                Some("/c/zsh-users---zsh-autosuggestions"),
                None,
            ),
            // A video pane is filed under nothing and titles by no process.
            case(PaneKind::Desktop, Some("Safari"), false, None, None),
            // A cwd that is present and BLANK: a key that is present and blank, not an absent one.
            case(PaneKind::Terminal, Some("blank"), false, Some(""), None),
        ];
        let panes: Vec<CRailStructurePane> = cases
            .iter()
            .map(|pane| {
                CRailStructurePane {
                    kind: pane.kind.as_byte(),
                    spec_title: blob.span(pane.spec_title),
                    user_renamed: pane.user_renamed,
                    cwd: blob.span(pane.cwd),
                    host_project_key: blob.span(pane.host_project_key),
                }
            })
            .collect();

        let mut blanks = 0_usize;
        for (index, (answered, pane)) in walked(&panes, &blob.bytes).into_iter().zip(cases).enumerate() {
            let expected_key = (pane.kind == PaneKind::Terminal)
                .then(|| project_key_of(pane.host_project_key, pane.cwd))
                .flatten();
            blanks += usize::from(expected_key.as_deref() == Some(""));
            assert_eq!(answered.1, expected_key, "pane {index}: the project key");

            let mut one = Blob::default();
            let shape = CRailTitleShape {
                kind: pane.kind.as_byte(),
                spec_title: one.span(pane.spec_title),
                user_renamed: pane.user_renamed,
                cwd: one.span(pane.cwd),
                project_key: one.span(expected_key.as_deref()),
            };
            // SAFETY: one live local buffer, borrowed for the duration of the call.
            let alone =
                unsafe { slopdesk_ws_rail_titles_by_process(shape, one.bytes.as_ptr(), one.bytes.len()) };
            assert_eq!(answered.0, alone, "pane {index}: the title's process rung");
        }
        // A key that is PRESENT and blank is not an absent key, and a length alone could not say
        // which — asserted here so the corpus cannot lose the case that makes the flag load-bearing.
        assert_eq!(blanks, 1, "the corpus still carries a present-and-blank key");
    }

    /// What the rung MEANS, asserted on the single door in words — so the agreement above cannot be
    /// two halves of one mistake.
    #[test]
    fn a_pane_titles_by_its_process_at_its_root_and_nowhere_it_has_a_folder_name() {
        let rung = |pane: Case<'_>| {
            let mut blob = Blob::default();
            let shape = CRailTitleShape {
                kind: pane.kind.as_byte(),
                spec_title: blob.span(pane.spec_title),
                user_renamed: pane.user_renamed,
                cwd: blob.span(pane.cwd),
                project_key: blob.span(pane.host_project_key),
            };
            // SAFETY: one live local buffer, borrowed for the duration of the call.
            unsafe { slopdesk_ws_rail_titles_by_process(shape, blob.bytes.as_ptr(), blob.bytes.len()) }
        };
        let root = Some("/w/slopdesk");
        assert!(
            rung(case(PaneKind::Terminal, Some("slopdesk"), false, root, root)),
            "at its root the header names the folder, so line one names the program"
        );
        assert!(
            !rung(case(
                PaneKind::Terminal,
                Some("api"),
                false,
                Some("/w/slopdesk/api"),
                root
            )),
            "strayed into the subtree, the folder name is the title"
        );
        assert!(
            !rung(case(PaneKind::Terminal, Some("slopdesk"), false, root, None)),
            "no key at all is a surface with no headers — the folder name stays"
        );
        assert!(
            rung(case(PaneKind::Terminal, Some("Terminal"), false, None, None)),
            "no directory known yet"
        );
        assert!(
            !rung(case(PaneKind::Terminal, Some("build"), true, root, root)),
            "a name the user typed outranks every rung below it"
        );
        assert!(
            !rung(case(PaneKind::Terminal, None, false, None, None)),
            "a pane with no spec has no structural title to resolve"
        );
        assert!(
            !rung(case(PaneKind::Desktop, Some("Safari"), false, None, None)),
            "a video pane never titled by a process"
        );
    }

    /// An overflow reports its size and leaves the caller's buffer alone — §4's retry, on the list.
    #[test]
    fn a_fingerprint_that_does_not_fit_names_its_size_and_writes_nothing() {
        let mut blob = Blob::default();
        let panes = [CRailStructurePane {
            kind: PaneKind::Terminal.as_byte(),
            spec_title: blob.span(Some("api")),
            user_renamed: false,
            cwd: blob.span(Some("/w/slopdesk/api")),
            host_project_key: blob.span(Some("/w/slopdesk")),
        }];
        let mut tiny = [0xAA_u8; 4];
        // SAFETY: two live local buffers, borrowed for the duration of the call.
        let needed = unsafe {
            slopdesk_ws_rail_structure_keys(
                panes.as_ptr(),
                panes.len(),
                blob.bytes.as_ptr(),
                blob.bytes.len(),
                tiny.as_mut_ptr(),
                tiny.len(),
            )
        };
        assert_eq!(needed, 6 + "/w/slopdesk".len(), "two flags, a length and the key");
        assert_eq!(tiny, [0xAA; 4], "an overflow leaves the caller's buffer alone");
    }

    /// No panes is no answer, and `docs/55` §4 spells that `0` — the near side keeps an empty key.
    #[test]
    fn an_empty_rail_answers_nothing() {
        let mut out = [0_u8; 8];
        // SAFETY: a null list with a zero count, and a live local buffer.
        let written = unsafe {
            slopdesk_ws_rail_structure_keys(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 0);
    }
}
