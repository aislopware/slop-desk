//! What the sidebar READS: which pane focus lands on, what order the sections come in, and the
//! text a row is drawn with.
//!
//! These are the rules `super`'s header calls "the half that DECIDES". None of them touches a
//! document — each takes the flat `(id, span)` arrays and answers an index, an order or a string.

use core::ffi::c_uchar;

use slopdesk_ids::{PaneId, TabId};
use slopdesk_tree::{FocusDirection, PaneKind, SolvedLayout, focus, tab_ordering};
use slopdesk_workspace::rail_title;

use super::{Frame, KeyedTab, Span, Uuid, borrow_array, deliver_id, optional_str, pane_id, text_of};
use crate::{borrow, deliver};

// MARK: Focus

/// A `FocusDirection` discriminant. Total, defaulting to `Next`, which is the direction that always
/// has an answer.
///
/// The MAP is `FocusDirection::ALL`'s order and is not restated here. It used to be, and a hand
/// map's fallback is not a refusal: a seventh direction added to both enums — which
/// `slopdesk-invariants` counts and would have passed — would have arrived here as `Next` and
/// cycled.
fn direction_from(byte: u8) -> FocusDirection {
    FocusDirection::from_index(byte).unwrap_or(FocusDirection::Next)
}

/// The solved layout a focus query runs against, rebuilt from the caller's flat frames.
fn solved_from(frames: &[Frame]) -> SolvedLayout {
    let mut solved = SolvedLayout::empty();
    for frame in frames {
        solved.frames.insert(pane_id(frame.id), frame.rect.resolve());
    }
    solved
}

/// The pane adjacent to `pane` in `direction`, resolved against the rects the user actually sees.
/// False when there is none — an edge, or a pane the layout does not hold.
///
/// # Safety
/// `frames` must be null or point to `count` live [`Frame`]s; `answer` must be null or writable for
/// one [`Uuid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_focus_neighbor(
    frames: *const Frame,
    count: usize,
    pane: Uuid,
    direction: u8,
    answer: *mut Uuid,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let solved = solved_from(borrow_array(frames, count));
        let Some(found) = focus::neighbor(pane_id(pane), direction_from(direction), &solved) else {
            return false;
        };
        deliver_id(found.bytes(), answer)
    }
}

/// Cycles through `panes` from `from`, wrapping at the ends. False when `from` is not among them.
///
/// # Safety
/// `panes` must be null or point to `count` live [`Uuid`]s; `answer` must be null or writable for
/// one [`Uuid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_focus_cycle(
    panes: *const Uuid,
    count: usize,
    from: Uuid,
    forward: bool,
    answer: *mut Uuid,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let ids: Vec<PaneId> = borrow_array(panes, count).iter().copied().map(pane_id).collect();
        let Some(found) = focus::cycle(&ids, pane_id(from), forward) else {
            return false;
        };
        deliver_id(found.bytes(), answer)
    }
}

// MARK: Tab ordering
//
// The generic bucketing stays in Swift — `bucketedByProject<Element>` shuffles a `[Element]` and
// cannot cross — but the ORDER it shuffles by is a rule, and that is here. Splitting it this way is
// what keeps the sidebar's sections identical to the tree walker's without either side owning a
// second comparator.

/// The trimmed, case-folded project key, or 0 bytes when the key is absent or blank.
///
/// A present key is never empty — that is what "blank folds to absent" means — so a 0 return is
/// unambiguously `nil` rather than `""`.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes; `out` must be null or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_project_key(
    bytes: *const c_uchar,
    len: usize,
    present: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(key) = tab_ordering::normalized_project_key(optional_str(bytes, len, present)) else {
            return 0;
        };
        deliver(key.as_bytes(), out, cap)
    }
}

/// The section header a project key sorts under — the literal `Other` when there is none.
///
/// # Safety
/// As [`slopdesk_ws_project_key`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_section_header(
    bytes: *const c_uchar,
    len: usize,
    present: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let header = tab_ordering::project_section_header(optional_str(bytes, len, present));
        deliver(header.as_bytes(), out, cap)
    }
}

/// Whether the left section sorts before the right one. An absent key is the `Other` bucket, which
/// sorts last however it is spelled.
///
/// # Safety
/// Both `(bytes, len)` pairs must be null or point to that many initialised bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_section_precedes(
    left: *const c_uchar,
    left_len: usize,
    left_present: bool,
    right: *const c_uchar,
    right_len: usize,
    right_present: bool,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `optional_str` states its own.
    unsafe {
        tab_ordering::section_precedes(
            optional_str(left, left_len, left_present),
            optional_str(right, right_len, right_present),
        )
    }
}

// The digit-aware comparison has no door of its own, and never had a Swift caller when it did.
//
// What Swift asks is which SECTION comes first, and `slopdesk_ws_section_precedes` above answers
// exactly that — comparing headers, then keys, so the tie-break that makes the order total cannot
// be left out by a caller who only borrowed the comparison. `tab_ordering::natural_compare` keeps
// its own tests in the crate; a second door onto it would only let a caller rebuild that order
// badly.

/// The tab to focus once `closing` is closed.
///
/// `tabs` is the DISPLAY order and still contains `closing`; each entry carries the project key the
/// caller's closure answered, spanning into `strings`. False when `closing` is absent from that
/// order, or is the only tab.
///
/// # Safety
/// `tabs` must be null or point to `tab_count` live [`KeyedTab`]s; `strings` to `strings_len`
/// bytes; `history` to `history_count` [`Uuid`]s; `answer` must be null or writable for one
/// [`Uuid`]. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_successor_after_close(
    closing: Uuid,
    tabs: *const KeyedTab,
    tab_count: usize,
    strings: *const c_uchar,
    strings_len: usize,
    history: *const Uuid,
    history_count: usize,
    answer: *mut Uuid,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let keyed = borrow_array(tabs, tab_count);
        let blob = borrow(strings, strings_len);
        let order: Vec<TabId> = keyed.iter().map(|tab| TabId::from_bytes(tab.id.bytes)).collect();
        let focus_history: Vec<TabId> = borrow_array(history, history_count)
            .iter()
            .map(|id| TabId::from_bytes(id.bytes))
            .collect();
        // Linear rather than a map: the display order runs to the tens, and a keyed lookup would
        // have to own a `String` per probe to answer the same question.
        let key_of = |tab: TabId| {
            keyed
                .iter()
                .find(|entry| entry.id.bytes == tab.bytes())
                .and_then(|entry| text_of(entry.key, blob))
                .map(str::to_owned)
        };
        let Some(found) = tab_ordering::successor_after_close(
            TabId::from_bytes(closing.bytes),
            &order,
            key_of,
            &focus_history,
        ) else {
            return false;
        };
        deliver_id(found.bytes(), answer)
    }
}

// MARK: What a pane is called
//
// Every surface that names a pane — the rail row, the tab strip, the pane switcher, the window
// title — reads the SAME precedence, and the reason it is one rule rather than four is that two
// surfaces disagreeing about a pane's name read as two panes. The rules are
// `slopdesk_workspace::rail_title`; what is here is the marshalling, and the two composite inputs
// arrive as spans into one blob for the reason the module docs give: one pointer, one lifetime, one
// scope, where a `(ptr, len)` per string would mean seven nested borrows per row per frame.

/// The structural title's inputs, each string spanning the blob passed alongside.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRowTitle {
    /// A `PaneKind` byte: 0 terminal, 1 desktop.
    pub kind: u8,
    /// The title on the pane's spec; absent when there is no spec at all.
    pub spec_title: Span,
    /// Whether that title was typed by the user.
    pub user_renamed: bool,
    /// The pane's working directory.
    pub cwd: Span,
    /// The title the running program last asserted.
    pub live_title: Span,
    /// The host-reported foreground process.
    pub process_label: Span,
    /// The project section the pane is drawn under.
    pub project_key: Span,
}

/// Line two's inputs, each string spanning the blob passed alongside.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CSubtitle {
    /// A `PaneKind` byte: 0 terminal, 1 desktop.
    pub kind: u8,
    /// The title on the pane's spec; absent when there is no spec at all, which is what decides
    /// whether the pane has a second line to write.
    pub spec_title: Span,
    /// Whether the two video fields below mean anything.
    pub video_present: bool,
    /// The owning application of the streamed host window.
    pub video_app_name: Span,
    /// That window's own title.
    pub video_title: Span,
    /// The pane's working directory.
    pub cwd: Span,
    /// The title the running program last asserted.
    pub live_title: Span,
    /// The project section the pane is drawn under; absent on a surface with no section headers.
    pub project_key: Span,
}

/// The live title's inputs, each string spanning the blob passed alongside.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CLiveRowTitle {
    /// What the structural rule answered.
    pub structural_title: Span,
    /// Whether that answer is a rename the user typed.
    pub user_renamed: bool,
    /// Whether the pane is an agent session.
    pub is_agent: bool,
    /// The agent's latched session intent.
    pub intent: Span,
    /// The command line running right now.
    pub running_command: Span,
    /// The normalised title the running program asserted.
    pub program_title: Span,
    /// The foreground-process title, so a structural rung can be recognised as one.
    pub process_title: Span,
    /// A `PaneKind` byte: 0 terminal, 1 desktop.
    pub kind: u8,
    /// The pane's folder name.
    pub cwd_title: Span,
    /// The kind-generic name.
    pub fallback: Span,
}

/// One command block, in the two fields a title reads.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CCommandTitleBlock {
    /// What was typed, spanning the blob passed alongside.
    pub text: Span,
    /// Whether `duration_ms` means anything — false is a block still running, which is a different
    /// fact from one that finished instantly.
    pub has_duration: bool,
    /// Host-measured wall clock; read only when `has_duration`.
    pub duration_ms: u32,
}

/// Reads the blocks a title rule scans, each text spanning `blob`.
fn command_blocks<'a>(
    blocks: &'a [CCommandTitleBlock],
    blob: &'a [u8],
) -> Vec<rail_title::CommandTitleBlock<'a>> {
    blocks
        .iter()
        .map(|block| {
            rail_title::CommandTitleBlock {
                command_text: text_of(block.text, blob).unwrap_or_default(),
                duration_ms: block.has_duration.then_some(block.duration_ms),
            }
        })
        .collect()
}

/// The foreground process as the metadata slot shows it. `0` is "nothing to show", which a real
/// name never is.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_slot_process_name(
    bytes: *const c_uchar,
    len: usize,
    present: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(name) = rail_title::slot_process_name(optional_str(bytes, len, present)) else {
            return 0;
        };
        deliver(name.as_bytes(), out, cap)
    }
}

/// The foreground process as a pane TITLE — the same cleanup with a bare shell suppressed. `0` is
/// "skip this rung".
///
/// # Safety
/// As [`slopdesk_ws_slot_process_name`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_process_display_name(
    bytes: *const c_uchar,
    len: usize,
    present: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(name) = rail_title::process_display_name(optional_str(bytes, len, present)) else {
            return 0;
        };
        deliver(name.as_bytes(), out, cap)
    }
}

/// Whether a slot label names a command rather than the shell the pane is idling in.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_slot_label_is_command(
    bytes: *const c_uchar,
    len: usize,
    present: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `optional_str` states its own.
    unsafe { rail_title::slot_label_is_command(optional_str(bytes, len, present)) }
}

/// Whether a pane is an agent session: any status verdict, or a known agent CLI in the foreground.
///
/// # Safety
/// As [`slopdesk_ws_slot_label_is_command`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_is_agent_session(
    has_agent_status: bool,
    bytes: *const c_uchar,
    len: usize,
    present: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `optional_str` states its own.
    unsafe { rail_title::is_agent_session(has_agent_status, optional_str(bytes, len, present)) }
}

/// The canonical agent mark, asked for rather than transcribed: a copy pinned to a different
/// presentation would draw a different glyph beside the same rows.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_agent_title_mark(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(rail_title::AGENT_TITLE_MARK.as_bytes(), out, cap) }
}

/// How long a finished command must have run to title the pane it ran in.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_command_title_min_duration_ms() -> u32 {
    rail_title::COMMAND_TITLE_MIN_DURATION_MS
}

/// `title` led with the agent mark, unless it already leads with one.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_agent_marked_title(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let title = core::str::from_utf8(borrow(bytes, len)).unwrap_or_default();
        deliver(rail_title::agent_marked_title(title).as_bytes(), out, cap)
    }
}

/// A program-set title with any activity-spinner frame folded onto the one static mark. `0` is
/// "nothing left to show", so the caller's chain falls through.
///
/// # Safety
/// As [`slopdesk_ws_slot_process_name`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_normalized_program_title(
    bytes: *const c_uchar,
    len: usize,
    present: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(title) = rail_title::normalized_program_title(optional_str(bytes, len, present)) else {
            return 0;
        };
        deliver(title.as_bytes(), out, cap)
    }
}

/// The pane's STRUCTURAL title — the identity it keeps between events.
///
/// `0` is the EMPTY title here rather than "no answer": the at-root idle shell yields deliberately,
/// so the live chain below can speak for it.
///
/// # Safety
/// `strings` must be null or point to `strings_len` initialised bytes; `out` null or writable for
/// `cap` bytes. Both live for the call, and every span in `inputs` is bounds-checked against
/// `strings` rather than trusted.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_row_title(
    inputs: CRowTitle,
    strings: *const c_uchar,
    strings_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = borrow(strings, strings_len);
        let title = rail_title::row_title(rail_title::RowTitle {
            kind: PaneKind::from_byte(inputs.kind),
            spec_title: text_of(inputs.spec_title, blob),
            user_renamed: inputs.user_renamed,
            cwd: text_of(inputs.cwd, blob),
            live_title: text_of(inputs.live_title, blob),
            process_label: text_of(inputs.process_label, blob),
            project_key: text_of(inputs.project_key, blob),
        });
        deliver(title.as_bytes(), out, cap)
    }
}

/// What LINE TWO says. `0` is "no second line", which is a single-line row.
///
/// # Safety
/// `strings` must be null or point to `strings_len` initialised bytes; `out` null or writable for
/// `cap` bytes. Both live for the call, and every span in `inputs` is bounds-checked against
/// `strings` rather than trusted.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_subtitle(
    inputs: CSubtitle,
    strings: *const c_uchar,
    strings_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = borrow(strings, strings_len);
        let Some(line) = rail_title::pane_subtitle(rail_title::Subtitle {
            kind: PaneKind::from_byte(inputs.kind),
            spec_title: text_of(inputs.spec_title, blob),
            video: inputs.video_present.then(|| {
                rail_title::SubtitleVideo {
                    app_name: text_of(inputs.video_app_name, blob),
                    title: text_of(inputs.video_title, blob),
                }
            }),
            cwd: text_of(inputs.cwd, blob),
            live_title: text_of(inputs.live_title, blob),
            project_key: text_of(inputs.project_key, blob),
        }) else {
            return 0;
        };
        deliver(line.as_bytes(), out, cap)
    }
}

/// The idle shell's last-command title. `0` is "no block qualified", so the caller keeps its own
/// rung.
///
/// # Safety
/// `blocks` must be null or point to `count` live [`CCommandTitleBlock`]s; `strings` to
/// `strings_len` bytes; `out` null or writable for `cap`. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_last_command_title(
    blocks: *const CCommandTitleBlock,
    count: usize,
    strings: *const c_uchar,
    strings_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = borrow(strings, strings_len);
        let held = command_blocks(borrow_array(blocks, count), blob);
        let Some(title) = rail_title::last_command_title(&held) else {
            return 0;
        };
        deliver(title.as_bytes(), out, cap)
    }
}

/// What a surface actually SHOWS for this pane right now.
///
/// `0` is the empty title, for the reason [`slopdesk_ws_row_title`] gives.
///
/// # Safety
/// As [`slopdesk_ws_last_command_title`], plus: every span in `inputs` indexes the same `strings`
/// blob and is bounds-checked against it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_live_row_title(
    inputs: CLiveRowTitle,
    blocks: *const CCommandTitleBlock,
    count: usize,
    strings: *const c_uchar,
    strings_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = borrow(strings, strings_len);
        let held = command_blocks(borrow_array(blocks, count), blob);
        let title = rail_title::live_row_title(
            rail_title::LiveRowTitle {
                structural_title: text_of(inputs.structural_title, blob).unwrap_or_default(),
                user_renamed: inputs.user_renamed,
                is_agent: inputs.is_agent,
                intent: text_of(inputs.intent, blob),
                running_command: text_of(inputs.running_command, blob),
                program_title: text_of(inputs.program_title, blob),
                process_title: text_of(inputs.process_title, blob),
                kind: PaneKind::from_byte(inputs.kind),
                cwd_title: text_of(inputs.cwd_title, blob),
                fallback: text_of(inputs.fallback, blob).unwrap_or_default(),
            },
            &held,
        );
        deliver(title.as_bytes(), out, cap)
    }
}
