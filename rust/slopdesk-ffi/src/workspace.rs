//! The workspace document's solvers: `rust/slopdesk-workspace` reached from the client's Swift.
//!
//! ## What crosses here, and what deliberately does not
//! `SlopDeskWorkspaceModel` is the app's DOCUMENT — 262 files import its value types, and a
//! `SplitNode` or a `Canvas` is what `SwiftUI` diffs to decide what to redraw. Those types stay in
//! Swift for the same reason `ClaudeStatus` did (docs/55 §6): a case list a `switch` reads is a
//! vocabulary, not an implementation. What crosses is the half that DECIDES — which neighbour
//! "move focus left" lands on, what order the sidebar's sections come in, which tab takes focus
//! after a close.
//!
//! ## Everything is flat, because everything here is geometry
//! No handles and no staging: a solver takes an array of `(id, rect)` and answers rects. The
//! caller's `withUnsafeBufferPointer` scope is the whole lifetime, and there is no state to own
//! between calls. Where a solver answers a VARIABLE number of elements it uses §4's convention over
//! its element type — return the count needed, write nothing when it does not fit.
//!
//! ## The closures flatten into parallel arrays
//! Some of these rules take a `Fn(TabId) -> Option<String>` in Rust and a `(TabID) -> String?` in
//! Swift. Rather than trampoline a Swift closure back per element, the caller evaluates it once per
//! id and hands over `(id, span)` pairs into one strings blob — the same encoding the agent module
//! uses, for the same reason: one pointer, one lifetime, one scope.
//!
//! ## Floats cross unrounded, and that is load-bearing
//! `CLAUDE.md` pins this repo's float results bit-exactly: no `mul_add`, and `Double.maximum`
//! rather than a `<` ternary, because the two disagree on signed zero and NaN. A solver whose
//! answer moved by one ULP would move a pane by a subpixel on every drag frame, so the tests on the
//! Swift side compare exactly rather than within a tolerance. Nothing here rounds, clamps or
//! normalises on the way through.

use core::ffi::c_uchar;
use std::collections::BTreeMap;

use slopdesk_workspace::canvas::{AlignEdge, CanvasBodyId};
use slopdesk_workspace::canvas_geometry::{BeaconEdge, PlacedPane};
use slopdesk_workspace::canvas_snap::{GuideOrientation, OwnEdge, Resolution};
use slopdesk_workspace::identity::{IdSource, SessionId};
use slopdesk_workspace::tree_ops::{self, TileLayout};
use slopdesk_workspace::{
    Body, BodyId, Camera, FocusDirection, Guide, GuideKind, NonOverlapConfig, PaneGroupId, PaneId, Point,
    Rect, ResizeAnchor, Size, SnapConfig, SolvedLayout, SplitAxis, SplitNode, SplitNodeId, SplitWeight,
    Stick, TabId, WeightedChild, canvas, canvas_arrange, canvas_geometry, canvas_non_overlap, canvas_snap,
    focus, geometry, listen, secrets, send_keys, shell_quoting, split_layout, state_codec, tab_ordering,
    templates,
};

use crate::{borrow, deliver};

// MARK: The flat shapes

/// A UUID, in its own byte order.
///
/// Both sides derive their ordering from these bytes, so anything sorted by an id sorts the same
/// way in Swift and in Rust — which matters more than it looks: `successor_after_close` walks an
/// order the caller built, and a disagreement there would send `⌘W` somewhere different per
/// process.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Uuid {
    /// The sixteen bytes, canonical UUID order.
    pub bytes: [u8; 16],
}

/// A rectangle in the plane's coordinates, laid out as Swift's `CGRect` reads it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRect {
    /// The minimum x.
    pub x: f64,
    /// The minimum y.
    pub y: f64,
    /// The width, which the sanitisers floor but this struct does not.
    pub width: f64,
    /// The height.
    pub height: f64,
}

impl CRect {
    const fn resolve(self) -> Rect {
        Rect::xywh(self.x, self.y, self.width, self.height)
    }

    const fn of(rect: Rect) -> Self {
        Self {
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
        }
    }
}

/// A point in the plane's coordinates.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CPoint {
    /// The x.
    pub x: f64,
    /// The y.
    pub y: f64,
}

/// One identified rectangle: a solved frame, a body on the plane.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Frame {
    /// Which pane this rectangle belongs to.
    pub id: Uuid,
    /// Where it is.
    pub rect: CRect,
}

/// A slice of the caller's strings blob: `present == false` is Swift's `nil`, and a present span of
/// length 0 is an empty string, which is not the same question.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Span {
    /// Where the text starts in the blob.
    pub offset: usize,
    /// How many bytes it runs for.
    pub len: usize,
    /// Whether there is any text at all.
    pub present: bool,
}

/// A tab and the project key the caller's closure answered for it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct KeyedTab {
    /// Which tab.
    pub id: Uuid,
    /// Its project key, into the blob passed alongside.
    pub key: Span,
}

/// Borrows a caller's array for one call.
///
/// # Safety
/// `items` must be null, or point to `count` initialised `T`s live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C array pointer becoming a slice"
)]
const unsafe fn borrow_array<'a, T>(items: *const T, count: usize) -> &'a [T] {
    if items.is_null() || count == 0 {
        return &[];
    }
    // SAFETY: non-null, and by the caller's obligation live and initialised for `count` elements.
    unsafe { core::slice::from_raw_parts(items, count) }
}

/// Resolves a span against the blob it indexes.
///
/// Out of range reads as `None` rather than panicking, and so does non-UTF-8: a span arrives from
/// another process's memory, and the only safe reading of a nonsensical one is "no key".
fn text_of(span: Span, blob: &[u8]) -> Option<&str> {
    if !span.present {
        return None;
    }
    let end = span.offset.checked_add(span.len)?;
    core::str::from_utf8(blob.get(span.offset..end)?).ok()
}

/// Reads an optional string argument: absent, or non-UTF-8, both read as `None`.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C pointer/length pair becoming a slice"
)]
unsafe fn optional_str<'a>(bytes: *const c_uchar, len: usize, present: bool) -> Option<&'a str> {
    if !present {
        return None;
    }
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    core::str::from_utf8(unsafe { borrow(bytes, len) }).ok()
}

/// Writes an id answer, tolerating a caller that only wanted the yes-or-no.
///
/// # Safety
/// `answer` must be null or writable for one [`Uuid`] for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
unsafe fn deliver_id(found: [u8; 16], answer: *mut Uuid) -> bool {
    if !answer.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `Uuid` for this call.
        unsafe { *answer = Uuid { bytes: found } };
    }
    true
}

/// A pane identity from its bytes.
const fn pane_id(id: Uuid) -> PaneId {
    PaneId::from_bytes(id.bytes)
}

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

/// Whether `raw` is a usable listen port. `0` is valid and means "OS-assigned".
///
/// The host's port field is a free-form persisted integer, so this is asked before every bind and
/// on every keystroke that redraws the Start button.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_listen_port_is_valid(raw: i64) -> bool {
    listen::is_valid_port(raw)
}

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

// MARK: Focus

/// A `FocusDirection` discriminant. Total, defaulting to `Next`, which is the direction that always
/// has an answer.
///
/// The MAP is `FocusDirection::ALL`'s order and is not restated here. It used to be, and a hand
/// map's fallback is not a refusal: a seventh direction added to both enums — which
/// `check-supervisor` counts and would have passed — would have arrived here as `Next` and cycled.
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

/// The natural (digit-aware) comparison of two labels: `-1`, `0` or `1`.
///
/// # Safety
/// Both `(bytes, len)` pairs must be null or point to that many initialised bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_natural_compare(
    left: *const c_uchar,
    left_len: usize,
    right: *const c_uchar,
    right_len: usize,
) -> i32 {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (lhs, rhs) = unsafe {
        (
            core::str::from_utf8(borrow(left, left_len)).unwrap_or_default(),
            core::str::from_utf8(borrow(right, right_len)).unwrap_or_default(),
        )
    };
    match tab_ordering::natural_compare(lhs, rhs) {
        core::cmp::Ordering::Less => -1,
        core::cmp::Ordering::Equal => 0,
        core::cmp::Ordering::Greater => 1,
    }
}

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

// MARK: The plane's coordinates

/// The sanitation every coordinate passes before it can reach a bounding-box union: NaN and the
/// infinities become finite, and an extent gets its floor.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_sanitize(frame: CRect) -> CRect {
    CRect::of(geometry::sanitize(frame.resolve()))
}

/// The same, but keeping a size the caller has already decided is right.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_sanitize_preserving_size(frame: CRect) -> CRect {
    CRect::of(geometry::sanitize_preserving_size(frame.resolve()))
}

/// A canvas rect in screen coordinates, under the pan-only camera.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_screen_rect(frame: CRect, camera: CPoint) -> CRect {
    CRect::of(geometry::screen_rect(frame.resolve(), camera_at(camera)))
}

/// A screen point back in canvas coordinates.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_canvas_point(point: CPoint, camera: CPoint) -> CPoint {
    let resolved = geometry::canvas_point(Point::new(point.x, point.y), camera_at(camera));
    CPoint {
        x: resolved.x,
        y: resolved.y,
    }
}

/// The camera at an origin. Pan-only, so its origin is the whole of it.
const fn camera_at(origin: CPoint) -> Camera {
    Camera {
        origin: Point::new(origin.x, origin.y),
    }
}

// MARK: Where a pane goes
//
// A PANE here is `(id, rect, is_video)` — the three facts the placement, culling and overview rules
// read. A `CanvasItem` carries far more (its spec, its group, its z), none of which any of these
// rules consults, so what crosses is the projection rather than the document.

/// One pane as the geometry rules see it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Placed {
    /// Which pane.
    pub id: Uuid,
    /// Where it is, in canvas coordinates.
    pub rect: CRect,
    /// Whether it costs a decode slot, which is the whole of why culling is asymmetric.
    pub is_video: bool,
}

impl Placed {
    const fn resolve(self) -> PlacedPane<[u8; 16]> {
        PlacedPane {
            id: self.id.bytes,
            frame: self.rect.resolve(),
            is_video: self.is_video,
        }
    }
}

/// The new frame while dragging `anchor` by `delta`.
///
/// The anchored edges move and the opposite ones stay pinned, with the extents floored — clamping
/// pushes the MOVED edge back, so the pinned edge never shifts.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_resizing(
    frame: CRect,
    anchor: u8,
    delta_width: f64,
    delta_height: f64,
    min_width: f64,
    min_height: f64,
) -> CRect {
    CRect::of(canvas_geometry::resizing(
        frame.resolve(),
        anchor_from(anchor),
        Size::new(delta_width, delta_height),
        Size::new(min_width, min_height),
    ))
}

/// A clean frame for a NEW pane.
///
/// Cascaded off `near` when there is one, else centred in the viewport, then stepped until it no
/// longer stacks on anything — with a bounded grid scan behind the step cap, so this terminates
/// rather than merely usually terminating.
///
/// # Safety
/// `existing` must be null or point to `count` live [`CRect`]s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_placement(
    near: CRect,
    has_near: bool,
    existing: *const CRect,
    count: usize,
    viewport: CRect,
    width: f64,
    height: f64,
    cascade: f64,
) -> CRect {
    // SAFETY: the caller's obligation, restated above; `borrow_array` states its own.
    let rects: Vec<Rect> = unsafe { borrow_array(existing, count) }
        .iter()
        .map(|rect| rect.resolve())
        .collect();
    CRect::of(canvas_geometry::placement(
        has_near.then(|| near.resolve()),
        &rects,
        viewport.resolve(),
        Size::new(width, height),
        cascade,
    ))
}

/// Whether a pane stays mounted.
///
/// A terminal always does — the compositor occludes it cheaply anyway — and a video pane only while
/// it is near the viewport, because culling one frees a decode slot. The focused pane is never
/// culled whatever its kind.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_pane_visible(
    pane: Placed,
    camera: CPoint,
    viewport_width: f64,
    viewport_height: f64,
    focused: Uuid,
    has_focused: bool,
    margin: f64,
) -> bool {
    canvas_geometry::is_visible(
        &pane.resolve(),
        camera_at(camera),
        Size::new(viewport_width, viewport_height),
        has_focused.then_some(&focused.bytes),
        margin,
    )
}

/// Whether a pane's frame touches the viewport at all — no margin, no kind filter.
///
/// Deliberately separate from [`slopdesk_ws_pane_visible`]: this is the video-cap "on screen"
/// signal, and terminals being held mounted must not pollute that membership set.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_in_viewport(
    rect: CRect,
    camera: CPoint,
    viewport_width: f64,
    viewport_height: f64,
) -> bool {
    let viewport = camera_at(camera).viewport_rect(Size::new(viewport_width, viewport_height));
    rect.resolve().intersects(viewport)
}

/// One pane's card in the fit-everything overview.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Card {
    /// Which pane.
    pub id: Uuid,
    /// Its SCREEN-space rect under the uniform scale.
    pub rect: CRect,
}

/// The overview: the uniform scale that fits every pane into the viewport — never magnified past 1×
/// — and each pane's card under it, with the scaled bounding box centred.
///
/// Returns the card count NEEDED. `scale` is written whenever the pointer is non-null, even when
/// the cards did not fit, so a caller can size its buffer from the first call without losing the
/// scale.
///
/// # Safety
/// `panes` must be null or point to `count` live [`Placed`]s; `scale` null or writable for one
/// `double`; `out` null or writable for `cap` [`Card`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_overview_layout(
    panes: *const Placed,
    count: usize,
    viewport_width: f64,
    viewport_height: f64,
    padding: f64,
    scale: *mut f64,
    out: *mut Card,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow_array` states its own.
    let placed: Vec<PlacedPane<[u8; 16]>> = unsafe { borrow_array(panes, count) }
        .iter()
        .map(|pane| pane.resolve())
        .collect();
    let layout =
        canvas_geometry::overview_layout(&placed, Size::new(viewport_width, viewport_height), padding);
    if !scale.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `f64` for this call.
        unsafe { *scale = layout.scale };
    }
    if layout.cards.len() > cap || out.is_null() {
        return layout.cards.len();
    }
    for (index, card) in layout.cards.iter().enumerate() {
        // SAFETY: `index < cards.len() <= cap`, and `out` is writable for `cap` by the obligation.
        unsafe {
            out.add(index).write(Card {
                id: Uuid { bytes: card.id },
                rect: CRect::of(card.rect),
            });
        }
    }
    layout.cards.len()
}

/// A pill on the viewport border saying "a pane is over there".
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Beacon {
    /// Which pane it points at.
    pub id: Uuid,
    /// Where to centre the pill, in viewport coordinates, already inset from every edge.
    pub screen_point: CPoint,
    /// 0 top · 1 bottom · 2 left · 3 right.
    pub edge: u8,
}

/// Every pane that does NOT touch the viewport, projected onto its border.
///
/// The DOMINANT overflow picks the edge, so a pane far up and slightly right reads as "above"
/// rather than flickering between the two. Returns the count NEEDED.
///
/// # Safety
/// `panes` must be null or point to `count` live [`Placed`]s; `out` null or writable for `cap`
/// [`Beacon`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_offscreen_beacons(
    panes: *const Placed,
    count: usize,
    camera: CPoint,
    viewport_width: f64,
    viewport_height: f64,
    inset: f64,
    out: *mut Beacon,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow_array` states its own.
    let placed: Vec<PlacedPane<[u8; 16]>> = unsafe { borrow_array(panes, count) }
        .iter()
        .map(|pane| pane.resolve())
        .collect();
    let beacons = canvas_geometry::offscreen_beacons(
        &placed,
        camera_at(camera),
        Size::new(viewport_width, viewport_height),
        inset,
    );
    if beacons.len() > cap || out.is_null() {
        return beacons.len();
    }
    for (index, beacon) in beacons.iter().enumerate() {
        // SAFETY: `index < beacons.len() <= cap`, and `out` is writable for `cap` by the obligation.
        unsafe {
            out.add(index).write(Beacon {
                id: Uuid { bytes: beacon.id },
                screen_point: CPoint {
                    x: beacon.screen_point.x,
                    y: beacon.screen_point.y,
                },
                edge: match beacon.edge {
                    BeaconEdge::Top => 0,
                    BeaconEdge::Bottom => 1,
                    BeaconEdge::Left => 2,
                    BeaconEdge::Right => 3,
                },
            });
        }
    }
    beacons.len()
}

// MARK: Non-overlap
//
// Three rules over one config. A BODY is a pane or a whole group moving as one, which is why its id
// carries a kind byte rather than being a bare pane id: a group and a pane may share sixteen bytes
// without being the same body.

/// The tuning the caller has decided on. `enabled == false` is the whole feature off, and every
/// rule below then answers its input unchanged.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct NonOverlap {
    /// The gap kept between two bodies.
    pub gutter: f64,
    /// How far a body may be pushed before the pass gives up on it.
    pub skin: f64,
    /// The sweep's iteration ceiling.
    pub max_slide_passes: u32,
    /// The relaxation's iteration ceiling.
    pub max_relax_iterations: u32,
    /// How much of an insert's target must be covered before it reads as an insert.
    pub insert_coverage: f64,
    /// Whether any of it runs.
    pub enabled: bool,
}

impl NonOverlap {
    const fn resolve(self) -> NonOverlapConfig {
        NonOverlapConfig {
            gutter: self.gutter,
            skin: self.skin,
            max_slide_passes: self.max_slide_passes,
            max_relax_iterations: self.max_relax_iterations,
            insert_coverage: self.insert_coverage,
            enabled: self.enabled,
        }
    }
}

/// A body's id: `kind == 1` is a group, anything else a pane.
///
/// Total on the kind byte rather than refusing an unknown one, because a pane is the conservative
/// reading: a body wrongly treated as a pane moves alone, where one wrongly treated as a group
/// would drag its neighbours with it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct BodyRef {
    /// 0 pane · 1 group.
    pub kind: u8,
    /// The sixteen bytes naming it within that namespace.
    pub id: Uuid,
}

impl BodyRef {
    const fn resolve(self) -> CanvasBodyId {
        if self.kind == 1 {
            BodyId::Group(PaneGroupId::from_bytes(self.id.bytes))
        } else {
            BodyId::Pane(PaneId::from_bytes(self.id.bytes))
        }
    }

    const fn of(id: CanvasBodyId) -> Self {
        match id {
            BodyId::Pane(pane) => {
                Self {
                    kind: 0,
                    id: Uuid { bytes: pane.bytes() },
                }
            },
            BodyId::Group(group) => {
                Self {
                    kind: 1,
                    id: Uuid { bytes: group.bytes() },
                }
            },
        }
    }
}

/// One body the solvers move around, and — on the way back — where it ended up.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CBody {
    /// Which body.
    pub id: BodyRef,
    /// Its rectangle.
    pub rect: CRect,
}

/// Borrows a caller's body array as the crate's own.
///
/// # Safety
/// `bodies` must be null, or point to `count` initialised [`CBody`]s live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C array pointer becoming a slice"
)]
unsafe fn borrow_bodies(bodies: *const CBody, count: usize) -> Vec<Body<CanvasBodyId>> {
    // SAFETY: the caller's obligation, restated above; `borrow_array` states its own.
    unsafe { borrow_array(bodies, count) }
        .iter()
        .map(|body| {
            Body {
                id: body.id.resolve(),
                rect: body.rect.resolve(),
            }
        })
        .collect()
}

/// Writes a committed arrangement under §4's convention.
///
/// The order is the map's — by kind, then by id bytes — so the array a caller reads on a retry is
/// the one the sizing call measured.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`CBody`]s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
unsafe fn deliver_commit(frames: &BTreeMap<CanvasBodyId, Rect>, out: *mut CBody, cap: usize) -> usize {
    if frames.len() > cap || out.is_null() {
        return frames.len();
    }
    for (index, (id, rect)) in frames.iter().enumerate() {
        // SAFETY: `index < frames.len() <= cap`, and `out` is writable for `cap` elements by the
        // caller's obligation.
        unsafe {
            out.add(index).write(CBody {
                id: BodyRef::of(*id),
                rect: CRect::of(*rect),
            });
        }
    }
    frames.len()
}

/// The tuning both languages start from.
///
/// Exported rather than transcribed: six numbers repeated in Swift would be six chances for the
/// gutter the snapper uses and the gutter the slide keeps to drift apart, and the whole reason they
/// share a value is that a gutter-snapped box must already be at the non-overlap boundary.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_non_overlap_default() -> NonOverlap {
    let config = NonOverlapConfig::default();
    NonOverlap {
        gutter: config.gutter,
        skin: config.skin,
        max_slide_passes: config.max_slide_passes,
        max_relax_iterations: config.max_relax_iterations,
        insert_coverage: config.insert_coverage,
        enabled: config.enabled,
    }
}

/// The swept slide that runs after the snapper: where a dragged rect ends up once it may not
/// overlap anyone.
///
/// `from` is the body's PERSISTED origin, so the whole sweep replays from there every frame and the
/// answer never depends on the path taken to get here.
///
/// # Safety
/// `bodies` must be null or point to `count` live [`CBody`]s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_slide(
    snapped: CRect,
    from: CPoint,
    bodies: *const CBody,
    count: usize,
    config: NonOverlap,
) -> CRect {
    // SAFETY: the caller's obligation, restated above; `borrow_bodies` states its own.
    let bodies = unsafe { borrow_bodies(bodies, count) };
    CRect::of(canvas_non_overlap::slide(
        snapped.resolve(),
        Point::new(from.x, from.y),
        &bodies,
        &config.resolve(),
    ))
}

/// The separation pass around a pinned body: everyone else moves, it does not. The answer INCLUDES
/// the pinned body at its target, so one write commits the whole arrangement.
///
/// # Safety
/// `bodies` must be null or point to `count` live [`CBody`]s; `out` must be null or writable for
/// `cap` [`CBody`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_separate(
    pinned: BodyRef,
    pinned_rect: CRect,
    bodies: *const CBody,
    count: usize,
    config: NonOverlap,
    out: *mut CBody,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let bodies = borrow_bodies(bodies, count);
        let frames = canvas_non_overlap::separate(
            &pinned.resolve(),
            pinned_rect.resolve(),
            &bodies,
            &config.resolve(),
        );
        deliver_commit(&frames, out, cap)
    }
}

/// The make-space relaxation that parts the neighbours on an insert.
///
/// [`usize::MAX`] means intent did NOT fire — the box is merely resting against a boundary — and
/// the caller then commits the slid frame with nothing else moved. That is a different answer from
/// a commit of zero bodies, which is why it is not 0.
///
/// # Safety
/// As [`slopdesk_ws_separate`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_make_space(
    target: CRect,
    dragged: BodyRef,
    bodies: *const CBody,
    count: usize,
    config: NonOverlap,
    out: *mut CBody,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let bodies = borrow_bodies(bodies, count);
        let Some(frames) =
            canvas_non_overlap::make_space(target.resolve(), &dragged.resolve(), &bodies, &config.resolve())
        else {
            return usize::MAX;
        };
        deliver_commit(&frames, out, cap)
    }
}

/// A resize clamped off its neighbours: only the edges the anchor MOVES are pushed back, so the
/// pinned edge never creeps.
///
/// # Safety
/// `bodies` must be null or point to `count` live [`CBody`]s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_clamp_resize(
    frame: CRect,
    anchor: u8,
    bodies: *const CBody,
    count: usize,
    min_width: f64,
    min_height: f64,
    config: NonOverlap,
) -> CRect {
    // SAFETY: the caller's obligation, restated above; `borrow_bodies` states its own.
    let bodies = unsafe { borrow_bodies(bodies, count) };
    CRect::of(canvas_non_overlap::clamp_resize(
        frame.resolve(),
        anchor_from(anchor),
        &bodies,
        Size::new(min_width, min_height),
        &config.resolve(),
    ))
}

/// The minimum push that would part two rects by a gutter, or false when they already are.
///
/// # Safety
/// `dx` and `dy` must each be null or writable for one `double` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_separation(
    a: CRect,
    b: CRect,
    gutter: f64,
    dx: *mut f64,
    dy: *mut f64,
) -> bool {
    let Some(separation) = canvas_non_overlap::separation(a.resolve(), b.resolve(), gutter) else {
        return false;
    };
    if !dx.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `f64` for this call.
        unsafe { *dx = separation.dx };
    }
    if !dy.is_null() {
        // SAFETY: as above.
        unsafe { *dy = separation.dy };
    }
    true
}

/// A `ResizeAnchor` discriminant. Total, defaulting to the bottom-right corner — the anchor a plain
/// drag-to-grow uses.
///
/// The map is `ResizeAnchor::ALL`'s order, stated once there rather than a second time here.
fn anchor_from(byte: u8) -> ResizeAnchor {
    ResizeAnchor::from_index(byte).unwrap_or(ResizeAnchor::BottomRight)
}

// MARK: Snapping

/// The snapper's tuning. Its two thresholds are asymmetric on purpose — a stick engages closer than
/// it releases — which is what keeps a drag from chattering at the boundary.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Snap {
    /// How near an edge must come to engage a stick.
    pub engage: f64,
    /// How far it must travel to release one.
    pub release: f64,
    /// The gap a pane-to-pane snap leaves.
    pub gutter: f64,
    /// The grid's pitch.
    pub grid_spacing: f64,
    /// The grid's engage threshold.
    pub grid_engage: f64,
    /// The grid's release threshold.
    pub grid_release: f64,
    /// Whether panes attract.
    pub snaps_to_panes: bool,
    /// Whether the grid does.
    pub snaps_to_grid: bool,
}

impl Snap {
    const fn resolve(self) -> SnapConfig {
        SnapConfig {
            engage: self.engage,
            release: self.release,
            gutter: self.gutter,
            grid_spacing: self.grid_spacing,
            grid_engage: self.grid_engage,
            grid_release: self.grid_release,
            snaps_to_panes: self.snaps_to_panes,
            snaps_to_grid: self.snaps_to_grid,
        }
    }
}

/// The snapper's tuning, from the crate rather than transcribed — see
/// [`slopdesk_ws_non_overlap_default`] for why.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_snap_default() -> Snap {
    let config = SnapConfig::default();
    Snap {
        engage: config.engage,
        release: config.release,
        gutter: config.gutter,
        grid_spacing: config.grid_spacing,
        grid_engage: config.grid_engage,
        grid_release: config.grid_release,
        snaps_to_panes: config.snaps_to_panes,
        snaps_to_grid: config.snaps_to_grid,
    }
}

/// A held stick, crossing in BOTH directions: the caller hands back what it got last frame, and
/// that is what makes the hold asymmetric rather than re-decided from scratch every frame.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CStick {
    /// Whether there is a stick at all.
    pub present: bool,
    /// 0 min · 1 mid · 2 max.
    pub own_edge: u8,
    /// The coordinate it is held to.
    pub target: f64,
    /// Whether it came from the grid rather than a neighbour, which uses the tighter release and
    /// draws no guide.
    pub is_grid: bool,
}

impl CStick {
    const fn resolve(self) -> Option<Stick> {
        if !self.present {
            return None;
        }
        Some(Stick {
            own_edge: match self.own_edge {
                1 => OwnEdge::Mid,
                2 => OwnEdge::Max,
                _ => OwnEdge::Min,
            },
            target: self.target,
            is_grid: self.is_grid,
        })
    }

    const fn of(stick: Option<Stick>) -> Self {
        match stick {
            None => {
                Self {
                    present: false,
                    own_edge: 0,
                    target: 0.0,
                    is_grid: false,
                }
            },
            Some(held) => {
                Self {
                    present: true,
                    own_edge: match held.own_edge {
                        OwnEdge::Min => 0,
                        OwnEdge::Mid => 1,
                        OwnEdge::Max => 2,
                    },
                    target: held.target,
                    is_grid: held.is_grid,
                }
            },
        }
    }
}

/// One alignment line the view draws while a pane-derived snap is active.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGuide {
    /// 0 vertical · 1 horizontal.
    pub orientation: u8,
    /// Its position on the snapped axis.
    pub position: f64,
    /// Where the drawn segment starts on the other axis.
    pub start: f64,
    /// Where it ends.
    pub end: f64,
    /// The strongest class that contributed to it: 0 gutter · 1 edge · 2 centre · 3 viewport.
    pub kind: u8,
}

impl CGuide {
    const fn of(guide: Guide) -> Self {
        Self {
            orientation: match guide.orientation {
                GuideOrientation::Vertical => 0,
                GuideOrientation::Horizontal => 1,
            },
            position: guide.position,
            start: guide.start,
            end: guide.end,
            kind: match guide.kind {
                GuideKind::Gutter => 0,
                GuideKind::Edge => 1,
                GuideKind::Center => 2,
                GuideKind::ViewportEdge => 3,
            },
        }
    }
}

/// The fixed-size half of a snap answer: where the rect goes, and what is held.
///
/// Separated from the guides because it is always written, even when the guide buffer was too
/// small. A caller that only draws the pane — a commit, rather than a live drag — never needs to
/// size a guide buffer at all.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SnapAnswer {
    /// Where the dragged rect goes.
    pub frame: CRect,
    /// The horizontal hold.
    pub stick_x: CStick,
    /// The vertical one.
    pub stick_y: CStick,
}

/// Writes a resolution's two halves, and reports how many guides it HAS.
///
/// # Safety
/// `answer` must be null or writable for one [`SnapAnswer`]; `guides` null or writable for
/// `guides_cap` [`CGuide`]s.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointers"
)]
unsafe fn deliver_resolution(
    resolution: &Resolution,
    answer: *mut SnapAnswer,
    guides: *mut CGuide,
    guides_cap: usize,
) -> usize {
    if !answer.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `SnapAnswer`.
        unsafe {
            *answer = SnapAnswer {
                frame: CRect::of(resolution.frame),
                stick_x: CStick::of(resolution.stick_x),
                stick_y: CStick::of(resolution.stick_y),
            };
        }
    }
    if resolution.guides.len() > guides_cap || guides.is_null() {
        return resolution.guides.len();
    }
    for (index, guide) in resolution.guides.iter().enumerate() {
        // SAFETY: `index < guides.len() <= guides_cap`, and `guides` is writable for that many by
        // the caller's obligation.
        unsafe { guides.add(index).write(CGuide::of(*guide)) };
    }
    resolution.guides.len()
}

/// The previous frame's holds, as the resolution the solver reads them out of. Only the sticks are
/// read, so the frame and the guides here are placeholders and never reach an answer.
const fn previous_holds(stick_x: CStick, stick_y: CStick) -> Resolution {
    Resolution {
        frame: Rect::xywh(0.0, 0.0, 0.0, 0.0),
        guides: Vec::new(),
        stick_x: stick_x.resolve(),
        stick_y: stick_y.resolve(),
    }
}

/// Snaps a MOVE drag. The size never changes; each axis resolves independently.
///
/// `proposed` must be the UNSNAPPED translation of the gesture's start, never a previously snapped
/// frame, or the snap drifts. Returns the guide count the answer HAS.
///
/// # Safety
/// `others` must be null or point to `count` live [`CRect`]s; `answer` and `guides` as
/// [`deliver_resolution`] requires. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_snap_move(
    proposed: CRect,
    others: *const CRect,
    count: usize,
    viewport: CRect,
    has_viewport: bool,
    config: Snap,
    previous_x: CStick,
    previous_y: CStick,
    answer: *mut SnapAnswer,
    guides: *mut CGuide,
    guides_cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let rects: Vec<Rect> = borrow_array(others, count)
            .iter()
            .map(|rect| rect.resolve())
            .collect();
        let previous = previous_holds(previous_x, previous_y);
        let resolved = canvas_snap::snap_move(
            proposed.resolve(),
            &rects,
            has_viewport.then(|| viewport.resolve()),
            &config.resolve(),
            Some(&previous),
        );
        deliver_resolution(&resolved, answer, guides, guides_cap)
    }
}

/// Snaps a RESIZE drag.
///
/// Only the edges the anchor MOVES are magnetic, and centres are skipped entirely: a resize aligns
/// edges, not centres. A candidate that would push the pane below its floor is DISCARDED rather
/// than clamped, so every guide the view draws is a true statement.
///
/// # Safety
/// As [`slopdesk_ws_snap_move`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_snap_resize(
    proposed: CRect,
    anchor: u8,
    others: *const CRect,
    count: usize,
    viewport: CRect,
    has_viewport: bool,
    min_width: f64,
    min_height: f64,
    config: Snap,
    previous_x: CStick,
    previous_y: CStick,
    answer: *mut SnapAnswer,
    guides: *mut CGuide,
    guides_cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let rects: Vec<Rect> = borrow_array(others, count)
            .iter()
            .map(|rect| rect.resolve())
            .collect();
        let previous = previous_holds(previous_x, previous_y);
        let resolved = canvas_snap::snap_resize(
            proposed.resolve(),
            anchor_from(anchor),
            &rects,
            has_viewport.then(|| viewport.resolve()),
            Size::new(min_width, min_height),
            &config.resolve(),
            Some(&previous),
        );
        deliver_resolution(&resolved, answer, guides, guides_cap)
    }
}

// MARK: The tiled tree
//
// ## Why the tree crosses FLAT and not as its own JSON
// Both languages already agree on a persisted encoding for a `SplitNode`, and reusing it here would
// have been two lines. It is the wrong instrument: `solve` runs on every layout pass, and a parse
// plus an allocation per frame is exactly the kind of regression `CLAUDE.md` says is the only veto
// on a port. So the tree crosses as its PRE-ORDER walk — one array, one pass, no parse — and the
// persisted codec stays what it is for, which is disk.
//
// ## The shape, and what makes it total
// Each node carries how many DIRECT children follow it. A well-formed array is consumed exactly; a
// hostile one — a `child_count` that overruns, a truncated tail — stops the walk and answers `None`
// rather than indexing past the end. That is the same obligation every entry point here carries,
// and it matters more for this one: a tree arrives from a peer over the workspace channel, not just
// from the client's own memory.

/// One node of the pre-order walk.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TreeNode {
    /// 0 leaf · 1 split. Total: anything else reads as a leaf, which is the shape that cannot
    /// recurse and so cannot be made to walk off the end.
    pub kind: u8,
    /// A leaf's pane id, or a split's divider-group id.
    pub id: Uuid,
    /// 0 horizontal (columns) · 1 vertical (rows). Splits only.
    pub axis: u8,
    /// Whether this node's own share is a FIXED extent in points rather than a flex share.
    pub weight_is_fixed: bool,
    /// How many direct children follow, in order. Leaves carry 0.
    pub child_count: u32,
    /// This node's share within its parent. The root's is ignored — it has no parent to share with.
    pub weight: f64,
}

impl TreeNode {
    const fn split_weight(self) -> SplitWeight {
        if self.weight_is_fixed {
            SplitWeight::Fixed(self.weight)
        } else {
            SplitWeight::Flex(self.weight)
        }
    }
}

/// Rebuilds one subtree from `nodes[*cursor..]`, advancing the cursor past everything it consumed.
///
/// `None` for a truncated or over-claiming array. Recursion is bounded by the array's length,
/// because every level consumes at least one node before descending.
fn decode_tree(nodes: &[TreeNode], cursor: &mut usize) -> Option<SplitNode> {
    let node = *nodes.get(*cursor)?;
    *cursor += 1;
    if node.kind != 1 {
        return Some(SplitNode::Leaf(PaneId::from_bytes(node.id.bytes)));
    }
    let count = usize::try_from(node.child_count).ok()?;
    let mut children = Vec::with_capacity(count.min(nodes.len()));
    for _ in 0..count {
        let child = *nodes.get(*cursor)?;
        let subtree = decode_tree(nodes, cursor)?;
        children.push(WeightedChild::new(child.split_weight(), subtree));
    }
    Some(SplitNode::Split {
        id: SplitNodeId::from_bytes(node.id.bytes),
        axis: if node.axis == 1 {
            SplitAxis::Vertical
        } else {
            SplitAxis::Horizontal
        },
        children,
    })
}

/// Borrows a caller's pre-order walk as a tree.
///
/// # Safety
/// `nodes` must be null, or point to `count` initialised [`TreeNode`]s live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C array pointer becoming a slice"
)]
unsafe fn borrow_tree(nodes: *const TreeNode, count: usize) -> Option<SplitNode> {
    // SAFETY: the caller's obligation, restated above; `borrow_array` states its own.
    let walk = unsafe { borrow_array(nodes, count) };
    let mut cursor = 0;
    decode_tree(walk, &mut cursor)
}

/// One child's share, for the partition that does not need the subtrees under it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Share {
    /// Fixed points rather than a flex share.
    pub is_fixed: bool,
    /// The magnitude.
    pub value: f64,
}

/// The default floor on a solved leaf, from the crate rather than transcribed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_min_leaf() -> CPoint {
    let size = geometry::MIN_ITEM_SIZE;
    CPoint {
        x: size.width,
        y: size.height,
    }
}

/// Tiles `nodes` inside `rect`, answering one frame per leaf.
///
/// Returns the leaf count NEEDED, or 0 for a tree the walk could not rebuild — which is the same
/// answer an empty tree gives, and the right one either way: nothing to draw.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`
/// [`Frame`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_solve_layout(
    nodes: *const TreeNode,
    count: usize,
    rect: CRect,
    min_width: f64,
    min_height: f64,
    out: *mut Frame,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return 0;
        };
        let solved = split_layout::solve(&root, rect.resolve(), Size::new(min_width, min_height));
        let frames: Vec<Frame> = solved
            .frames
            .iter()
            .map(|(pane, frame)| {
                Frame {
                    id: Uuid { bytes: pane.bytes() },
                    rect: CRect::of(*frame),
                }
            })
            .collect();
        deliver_frames(&frames, out, cap)
    }
}

/// Writes a frame array under §4's convention.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`Frame`]s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
const unsafe fn deliver_frames(frames: &[Frame], out: *mut Frame, cap: usize) -> usize {
    if frames.len() > cap || out.is_null() {
        return frames.len();
    }
    // SAFETY: `frames.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `frames` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(frames.as_ptr(), out, frames.len()) };
    frames.len()
}

/// The point-extent of each child along the split's axis within `total`.
///
/// Fixed children are reserved first against a RUNNING budget — so the fixed sum never exceeds the
/// bound and no two bands overlap — and the flex children divide what is left in proportion. An
/// all-zero-flex tree falls back to an equal split, so no pane ever vanishes.
///
/// Exported separately from the solve because the divider handles are placed on the same seams the
/// tiles land on, and a second copy of this partition would put the handle a pixel off the edge it
/// is supposed to drag.
///
/// # Safety
/// `shares` must be null or point to `count` live [`Share`]s; `out` null or writable for `cap`
/// `double`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_extents(
    shares: *const Share,
    count: usize,
    total: f64,
    out: *mut f64,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow_array` states its own.
    let children: Vec<WeightedChild> = unsafe { borrow_array(shares, count) }
        .iter()
        .map(|share| {
            let weight = if share.is_fixed {
                SplitWeight::Fixed(share.value)
            } else {
                SplitWeight::Flex(share.value)
            };
            // The subtree is never read by the partition — only the shares are — so a placeholder
            // leaf is the honest stand-in rather than a cost the caller pays to encode.
            WeightedChild::new(weight, SplitNode::Leaf(PaneId::from_bytes([0; 16])))
        })
        .collect();
    let extents = split_layout::extents(&children, total);
    if extents.len() > cap || out.is_null() {
        return extents.len();
    }
    // SAFETY: `extents.len() <= cap`, `out` is writable for `cap` by the caller's obligation, and
    // `extents` was allocated inside this call.
    unsafe { core::ptr::copy_nonoverlapping(extents.as_ptr(), out, extents.len()) };
    extents.len()
}

// MARK: The tree's own operations
//
// Every one of these ANSWERS a tree, so the walk crosses in both directions. The encoder below is
// the exact inverse of `decode_tree`, and the round trip is what the Swift tests already assert —
// they compare whole `SplitNode` values, so a lossy leg would fail loudly rather than subtly.
//
// Each op is its own entry point rather than one dispatcher with a wide argument list. A dispatcher
// would be less Swift, but `slopdesk_ws_tree_splitting(nodes, count, target, axis, new_leaf, …)`
// says which arguments it reads and a `(op, a, b, index, value)` tuple does not — and this is the
// boundary where a mis-assigned argument is a silently rearranged layout.

/// Appends `node` and its subtree to a pre-order walk, at the share it holds within its parent.
fn encode_tree(node: &SplitNode, weight: SplitWeight, walk: &mut Vec<TreeNode>) {
    let (is_fixed, magnitude) = match weight {
        SplitWeight::Flex(share) => (false, share),
        SplitWeight::Fixed(points) => (true, points),
    };
    match node {
        SplitNode::Leaf(pane) => {
            walk.push(TreeNode {
                kind: 0,
                id: Uuid { bytes: pane.bytes() },
                axis: 0,
                weight_is_fixed: is_fixed,
                child_count: 0,
                weight: magnitude,
            });
        },
        SplitNode::Split { id, axis, children } => {
            walk.push(TreeNode {
                kind: 1,
                id: Uuid { bytes: id.bytes() },
                axis: u8::from(*axis == SplitAxis::Vertical),
                weight_is_fixed: is_fixed,
                child_count: u32::try_from(children.len()).unwrap_or(u32::MAX),
                weight: magnitude,
            });
            for child in children {
                encode_tree(&child.node, child.weight, walk);
            }
        },
    }
}

/// Writes an answered tree under §4's convention, with [`usize::MAX`] for an op that did not apply.
///
/// The two are different answers and the caller must be able to tell them apart: "this pane is not
/// in this tree" has to leave the arrangement alone, where a zero-node tree would erase it.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`TreeNode`]s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
unsafe fn deliver_tree(answer: Option<SplitNode>, out: *mut TreeNode, cap: usize) -> usize {
    let Some(tree) = answer else {
        return usize::MAX;
    };
    let mut walk = Vec::new();
    encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
    if walk.len() > cap || out.is_null() {
        return walk.len();
    }
    // SAFETY: `walk.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `walk` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(walk.as_ptr(), out, walk.len()) };
    walk.len()
}

/// The axis a byte names. Total, defaulting to horizontal — columns, the arrangement a fresh split
/// makes when nobody said otherwise.
const fn axis_from(byte: u8) -> SplitAxis {
    if byte == 1 {
        SplitAxis::Vertical
    } else {
        SplitAxis::Horizontal
    }
}

/// Runs `op` over the tree in `nodes` and writes what it answered.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading and writing through the caller's pointers"
)]
unsafe fn tree_op(
    nodes: *const TreeNode,
    count: usize,
    out: *mut TreeNode,
    cap: usize,
    op: impl FnOnce(&SplitNode) -> Option<SplitNode>,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return usize::MAX;
        };
        deliver_tree(op(&root), out, cap)
    }
}

/// Splits `target` in two, the new leaf taking half of what it had.
///
/// [`usize::MAX`] when `target` is not in this tree — the arrangement is then left alone, which is
/// not the same as being replaced by an empty one.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_splitting(
    nodes: *const TreeNode,
    count: usize,
    target: Uuid,
    axis: u8,
    new_leaf: Uuid,
    before: bool,
    fresh_split: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            root.splitting(
                pane_id(target),
                axis_from(axis),
                pane_id(new_leaf),
                before,
                SplitNodeId::from_bytes(fresh_split.bytes),
            )
        })
    }
}

/// Inserts an EXISTING leaf beside `target`, which is the drag-to-dock gesture rather than a split.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_inserting_beside(
    nodes: *const TreeNode,
    count: usize,
    leaf: Uuid,
    target: Uuid,
    axis: u8,
    before: bool,
    fresh_split: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            root.inserting_beside(
                pane_id(leaf),
                pane_id(target),
                axis_from(axis),
                before,
                SplitNodeId::from_bytes(fresh_split.bytes),
            )
        })
    }
}

/// Docks a leaf against the whole container's edge. Always applies, so never [`usize::MAX`].
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_inserting_at_root(
    nodes: *const TreeNode,
    count: usize,
    leaf: Uuid,
    axis: u8,
    before: bool,
    fresh_split: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.inserting_at_root(
                pane_id(leaf),
                axis_from(axis),
                before,
                SplitNodeId::from_bytes(fresh_split.bytes),
            ))
        })
    }
}

/// Closes a pane, the survivors dividing what it had. [`usize::MAX`] when it was the last one — the
/// tab is then empty, which is the caller's decision to act on, not this function's.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_removing(
    nodes: *const TreeNode,
    count: usize,
    target: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe { tree_op(nodes, count, out, cap, |root| root.removing(pane_id(target))) }
}

/// Drags one divider by `delta`, its two neighbours trading the difference.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_resizing_divider(
    nodes: *const TreeNode,
    count: usize,
    split: Uuid,
    leading_index: usize,
    delta: f64,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.resizing_divider(SplitNodeId::from_bytes(split.bytes), leading_index, delta))
        })
    }
}

/// Evens ONE seam — both its children take their pair mean. Every other divider is untouched, which
/// is what makes this different from a rebalance.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_evening_divider(
    nodes: *const TreeNode,
    count: usize,
    split: Uuid,
    leading_index: usize,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.evening_divider(SplitNodeId::from_bytes(split.bytes), leading_index))
        })
    }
}

/// Sets a divider's ABSOLUTE leading weight, the trailing sibling taking the remainder — the
/// cursor-matched form used during a live drag.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_setting_divider_weight(
    nodes: *const TreeNode,
    count: usize,
    split: Uuid,
    leading_index: usize,
    leading_weight: f64,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.setting_divider_weight(
                SplitNodeId::from_bytes(split.bytes),
                leading_index,
                leading_weight,
            ))
        })
    }
}

/// Exchanges two panes' positions, every weight staying where it was.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_swapping(
    nodes: *const TreeNode,
    count: usize,
    a: Uuid,
    b: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.swapping(pane_id(a), pane_id(b)))
        })
    }
}

/// Resets every weight in the tree to an equal share.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_rebalanced(
    nodes: *const TreeNode,
    count: usize,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe { tree_op(nodes, count, out, cap, |root| Some(root.rebalanced())) }
}

/// Where a pane sits relative to the nearest enclosing split on an axis — which divider a resize
/// keystroke should move, and how many siblings share it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Enclosing {
    /// The split's identity.
    pub split: Uuid,
    /// The index of that split's DIRECT child subtree holding the pane.
    pub child_index: usize,
    /// How many children that split has.
    pub child_count: usize,
}

/// The nearest split enclosing `pane` on `axis`. False when there is none — the pane occupies that
/// axis alone, and there is no divider for a keystroke to move.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `answer` null or writable for one
/// [`Enclosing`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_enclosing_split(
    nodes: *const TreeNode,
    count: usize,
    pane: Uuid,
    axis: u8,
    answer: *mut Enclosing,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow_tree` states its own.
    let Some(root) = (unsafe { borrow_tree(nodes, count) }) else {
        return false;
    };
    let Some(found) = root.enclosing_split(pane_id(pane), axis_from(axis)) else {
        return false;
    };
    if !answer.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `Enclosing`.
        unsafe {
            *answer = Enclosing {
                split: Uuid {
                    bytes: found.split_id.bytes(),
                },
                child_index: found.child_index,
                child_count: found.child_count,
            };
        }
    }
    true
}

/// The first leaf in pre-order — where focus lands when a tab has no better answer. False for a
/// tree the walk could not rebuild.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `answer` null or writable for one
/// [`Uuid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_first_leaf(
    nodes: *const TreeNode,
    count: usize,
    answer: *mut Uuid,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return false;
        };
        let Some(first) = root.first_leaf_id() else {
            return false;
        };
        deliver_id(first.bytes(), answer)
    }
}

/// Whether two trees have the same SHAPE and the same panes in the same places, ignoring every
/// weight and every split identity.
///
/// The question a persistence round trip asks: a restore that repaired a divider position still
/// restored the same arrangement, and reporting that as a change would make every launch look
/// dirty.
///
/// # Safety
/// Both `(nodes, count)` pairs must be null or point to that many live [`TreeNode`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_structurally_equal(
    left: *const TreeNode,
    left_count: usize,
    right: *const TreeNode,
    right_count: usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow_tree` states its own.
    let (Some(lhs), Some(rhs)) = (unsafe { borrow_tree(left, left_count) }, unsafe {
        borrow_tree(right, right_count)
    }) else {
        return false;
    };
    lhs.is_structurally_equal(&rhs)
}

// MARK: The arrange commands
//
// Align, distribute and tidy read `(id, frame)` and write `(id, frame)`, so what crosses is the
// same `Frame` pair the layout solver already answers in. The plane itself never crosses: a
// `Canvas` carries specs, groups and z-order that none of these rules consults, and it is what
// SwiftUI diffs.

/// Reads the `(id, frame)` pairs an arrange command is given.
///
/// # Safety
/// `targets` must be null or point to `count` live [`Frame`]s.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading through a caller's pointer"
)]
unsafe fn borrow_targets(targets: *const Frame, count: usize) -> Vec<(PaneId, Rect)> {
    if targets.is_null() || count == 0 {
        return Vec::new();
    }
    // SAFETY: non-null and, by the caller's obligation, `count` live `Frame`s for the call.
    let slice = unsafe { core::slice::from_raw_parts(targets, count) };
    slice
        .iter()
        .map(|frame| (PaneId::from_bytes(frame.id.bytes), frame.rect.resolve()))
        .collect()
}

/// Writes the frames an arrange command moved, under §4's convention.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`Frame`]s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
unsafe fn deliver_moved(moved: &BTreeMap<PaneId, Rect>, out: *mut Frame, cap: usize) -> usize {
    let answers: Vec<Frame> = moved
        .iter()
        .map(|(id, rect)| {
            Frame {
                id: Uuid { bytes: id.bytes() },
                rect: CRect::of(*rect),
            }
        })
        .collect();
    // SAFETY: the caller's obligation, restated; `deliver` states its own.
    unsafe { deliver_frames(&answers, out, cap) }
}

/// The named panes flush to one edge or centre of THEIR bounding box.
///
/// Answers only the panes that MOVED, so a caller applies it by lookup and a pane nobody named is
/// untouched by construction rather than by a copy that happened to reproduce it.
///
/// # Safety
/// `targets` must be null or point to `count` live [`Frame`]s; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_align(
    targets: *const Frame,
    count: usize,
    edge: u8,
    out: *mut Frame,
    cap: usize,
) -> usize {
    // An unknown byte aligns LEFT rather than panicking — this is a boundary, and a caller that
    // sends a case this build has never heard of must not take the process down. The mapping itself
    // is `AlignEdge::ALL`'s order and is not restated here: a hand-written match ending in
    // `_ => Left` would silently swallow a seventh edge as a left-align.
    let edge = AlignEdge::from_index(edge).unwrap_or(AlignEdge::Left);
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let pairs = borrow_targets(targets, count);
        deliver_moved(&canvas_arrange::aligned(&pairs, edge), out, cap)
    }
}

/// The named panes spread so the gaps between adjacent ones are equal.
///
/// # Safety
/// As [`slopdesk_ws_align`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_distribute(
    targets: *const Frame,
    count: usize,
    horizontal: bool,
    out: *mut Frame,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let pairs = borrow_targets(targets, count);
        deliver_moved(&canvas_arrange::distributed(&pairs, horizontal), out, cap)
    }
}

/// A group's members affinely remapped from their own bounding box into `proposed`.
///
/// `targets` is the group's members and nothing else — the old box is derived from them here, so
/// there is no second box for a caller to compute and get wrong. The proposed box is floored at the
/// minimum pane size and every member is clamped back inside it, because the non-overlap solver
/// moves a group as one rigid body from that box and a member outside it corrupts the sweep.
///
/// # Safety
/// As [`slopdesk_ws_align`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_resize_group(
    targets: *const Frame,
    count: usize,
    proposed: CRect,
    out: *mut Frame,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let pairs = borrow_targets(targets, count);
        deliver_moved(
            &canvas_arrange::resized_group(&pairs, proposed.resolve()),
            out,
            cap,
        )
    }
}

/// Every pane packed into a square grid at the plane's origin, in the order given.
///
/// The camera is deliberately NOT this call's business — re-centring afterwards is a separate
/// decision, and one the caller may not want.
///
/// # Safety
/// As [`slopdesk_ws_align`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tidy(
    items: *const Frame,
    count: usize,
    gutter: f64,
    out: *mut Frame,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let pairs = borrow_targets(items, count);
        deliver_moved(&canvas_arrange::tidied(&pairs, gutter), out, cap)
    }
}

/// The tidy gutter and the default item size, exported rather than transcribed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_tidy_gutter() -> f64 {
    canvas::TIDY_GUTTER
}

/// The box containing every frame given. False for none — an empty plane has no box, which is a
/// different answer from a box at the origin.
///
/// # Safety
/// `frames` must be null or point to `count` live [`CRect`]s; `answer` null or writable for one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_bounding_box(
    frames: *const CRect,
    count: usize,
    answer: *mut CRect,
) -> bool {
    if frames.is_null() || count == 0 {
        return false;
    }
    // SAFETY: non-null and, by the caller's obligation, `count` live `CRect`s for the call.
    let rects: Vec<Rect> = unsafe { core::slice::from_raw_parts(frames, count) }
        .iter()
        .map(|rect| rect.resolve())
        .collect();
    let Some(box_rect) = canvas_arrange::bounding_box(&rects) else {
        return false;
    };
    if !answer.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `CRect`.
        unsafe { *answer = CRect::of(box_rect) };
    }
    true
}

// MARK: The re-tile layouts
//
// `tree_ops::rebuild` builds the tree; the workspace-level `apply_layout` around it does not cross,
// because it takes and answers a whole `TreeWorkspace` — sessions, tabs, titles, specs — and that
// document is what SwiftUI diffs. What crosses is the leaf ORDER in and the tree out, which is the
// only part of a re-tile that is a decision.

/// A caller's pool of pre-minted identities, handed out in order.
///
/// The crate mints nothing (`identity.rs`), and a re-tile needs one identity per split it creates.
/// Rather than trampolining into Swift per split, the caller passes a pool and this walks it. A
/// pool that runs dry repeats its last entry rather than panicking — see [`slopdesk_ws_retile`] for
/// why the documented pool size makes that unreachable.
struct Pool<'a> {
    splits: &'a [Uuid],
    next: usize,
}

impl IdSource for Pool<'_> {
    fn pane(&mut self) -> PaneId {
        // A re-tile preserves every leaf, so it never asks for one. Answering the first entry keeps
        // the trait total without inventing an identity the caller did not supply.
        PaneId::from_bytes(self.splits.first().map_or([0; 16], |id| id.bytes))
    }

    fn tab(&mut self) -> TabId {
        TabId::from_bytes(self.splits.first().map_or([0; 16], |id| id.bytes))
    }

    fn session(&mut self) -> SessionId {
        SessionId::from_bytes(self.splits.first().map_or([0; 16], |id| id.bytes))
    }

    fn split(&mut self) -> SplitNodeId {
        let picked = self.splits.get(self.next).or_else(|| self.splits.last());
        self.next += 1;
        SplitNodeId::from_bytes(picked.map_or([0; 16], |id| id.bytes))
    }
}

/// The tree a re-tile layout makes over `leaves`, in the caller's order.
///
/// `layout` is `LayoutPreset`'s case index: evenHorizontal, evenVertical, mainVertical,
/// mainHorizontal, tiled. The main-\* layouts take the FIRST leaf as the large one, so a caller
/// that wants the active pane there passes it first — putting that choice at the call site, where
/// the notion of "active" lives, rather than in the tiler.
///
/// `splits` is the identity pool. A tiled layout of `n` leaves creates at most `n` splits (one row
/// node per row, plus the outer), so `n + 1` entries is always enough and the pool cannot run dry.
///
/// Fewer than two leaves answers nothing: a one-child split would violate the tree's arity rule,
/// which is a no-op at the call site rather than a tree to install.
///
/// # Safety
/// `leaves` must be null or point to `count` live [`Uuid`]s, `splits` null or to `split_count` live
/// ones, and `out` null or writable for `cap` [`TreeNode`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_retile(
    leaves: *const Uuid,
    count: usize,
    layout: u8,
    splits: *const Uuid,
    split_count: usize,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    if leaves.is_null() || count < 2 {
        return usize::MAX;
    }
    // `TileLayout::ALL`'s order, not a second copy of it. An unknown byte re-tiles as one even row,
    // which is the layout a caller that named nothing meaningful should get.
    let layout = TileLayout::from_index(layout).unwrap_or(TileLayout::EvenHorizontal);
    // SAFETY: non-null and, by the caller's obligation, `count` live `Uuid`s for the call.
    let panes: Vec<PaneId> = unsafe { core::slice::from_raw_parts(leaves, count) }
        .iter()
        .map(|id| PaneId::from_bytes(id.bytes))
        .collect();
    let pool: &[Uuid] = if splits.is_null() || split_count == 0 {
        &[]
    } else {
        // SAFETY: non-null and, by the caller's obligation, `split_count` live `Uuid`s.
        unsafe { core::slice::from_raw_parts(splits, split_count) }
    };
    let mut ids = Pool {
        splits: pool,
        next: 0,
    };
    // SAFETY: the caller's obligation, restated above; `deliver_tree` states its own.
    unsafe { deliver_tree(Some(tree_ops::rebuild(layout, &panes, &mut ids)), out, cap) }
}

// MARK: The document's scalar field codec
//
// The leaves of the multiclient state protocol (docs/45). Every decoder is STRICT about width — a
// value of the wrong length answers "absent" rather than a lenient prefix read — because these
// bytes came off a socket and a mis-numbered field must FAIL rather than succeed into something
// plausible.
//
// The out-parameter shape rather than a return value, because every one of these has to be able to
// say "these bytes are not a value of this kind" without a sentinel that could also be data: a
// `lastExitCode` of -1 is a real exit code, and `0xFFFFFFFF` is its encoding.

/// Reads a caller's byte field.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading through a caller's pointer"
)]
const unsafe fn field(bytes: *const u8, len: usize) -> &'static [u8] {
    if bytes.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: non-null and, by the caller's obligation, `len` live bytes for the call. The lifetime
    // is erased to `'static` and immediately consumed by a total decoder, none of which retains it.
    unsafe { core::slice::from_raw_parts(bytes, len) }
}

/// A one-byte field's value. False when the bytes are not exactly one.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `u8`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u8(bytes: *const u8, len: usize, out: *mut u8) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_u8(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u8`.
        unsafe { *out = value };
    }
    true
}

/// A two-byte pair's values — `agentState` is `(state, kind)`, `progress` is `(state, percent)`.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; each out null or writable for one `u8`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u8_pair(
    bytes: *const u8,
    len: usize,
    first: *mut u8,
    second: *mut u8,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some((a, b)) = state_codec::decode_u8_pair(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !first.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u8`.
        unsafe { *first = a };
    }
    if !second.is_null() {
        // SAFETY: as above.
        unsafe { *second = b };
    }
    true
}

/// A `[u16 BE][u16 BE]` pair's values — `pane/grid` is `(cols, rows)`.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; each out null or writable for one `u16`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u16_pair(
    bytes: *const u8,
    len: usize,
    first: *mut u16,
    second: *mut u16,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some((a, b)) = state_codec::decode_u16_pair(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !first.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u16`.
        unsafe { *first = a };
    }
    if !second.is_null() {
        // SAFETY: as above.
        unsafe { *second = b };
    }
    true
}

/// A `[u32 BE]` field's value.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `u32`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u32(bytes: *const u8, len: usize, out: *mut u32) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_u32(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u32`.
        unsafe { *out = value };
    }
    true
}

/// A `[u32 BE]` field read as a SIGNED value — `pane/lastExitCode`, where a signal-killed child
/// reports a negative code and the bit pattern is what crosses.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `i32`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_i32(bytes: *const u8, len: usize, out: *mut i32) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_i32(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `i32`.
        unsafe { *out = value };
    }
    true
}

/// A `[u64 BE]` field read as a signed value — `pane/lastActivityMS`.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `i64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_i64(bytes: *const u8, len: usize, out: *mut i64) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_i64(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `i64`.
        unsafe { *out = value };
    }
    true
}

/// A `[u16 BE count][uuid…]` list's ids, under §4's convention. [`usize::MAX`] when the count and
/// the bytes disagree — which is a REFUSAL, not the empty list that a well-formed zero count is.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` [`Uuid`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_uuid_list(
    bytes: *const u8,
    len: usize,
    out: *mut Uuid,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(ids) = state_codec::decode_uuid_list(unsafe { field(bytes, len) }) else {
        return usize::MAX;
    };
    let answers: Vec<Uuid> = ids.into_iter().map(|bytes| Uuid { bytes }).collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// A `[u16 BE count][uuid…]` list's bytes, under §4's convention.
///
/// # Safety
/// `ids` must be null or point to `count` live [`Uuid`]s; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_uuid_list(
    ids: *const Uuid,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let raw: Vec<[u8; 16]> = if ids.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live `Uuid`s for the call.
        unsafe { core::slice::from_raw_parts(ids, count) }
            .iter()
            .map(|id| id.bytes)
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_uuid_list(&raw), out, cap) }
}

/// A string field's bytes: strict UTF-8, clamped at a CHARACTER boundary so a truncated value is
/// still valid UTF-8 rather than a half-written scalar the far end drops entirely.
///
/// `max_bytes` is the FIELD's limit, which is not always the protocol's — a rename is clamped
/// tighter than a title.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_string(
    bytes: *const u8,
    len: usize,
    max_bytes: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(text) = state_codec::decode_string(field(bytes, len)) else {
            return 0;
        };
        deliver(&state_codec::encode_string(text, max_bytes), out, cap)
    }
}

// MARK: The snapshot and the diff
//
// The highest-risk parsing in the document: a count and a length, both chosen by whoever is on the
// other end of the socket. Every bound is checked against the bytes ACTUALLY remaining before any
// capacity is reserved, so a hostile `0xFFFFFFFF` costs a comparison rather than four gigabytes.
//
// A decoded value is a SPAN into the caller's own input buffer rather than a copy. A snapshot is
// hundreds of entries and arrives on every attach; copying each value into a second blob would
// double the work for no property. The caller still holds the buffer, so the spans are live for
// exactly as long as they are useful.

/// The upper bound on entries in one snapshot or diff, exported rather than transcribed.
///
/// It is a REFUSAL threshold, so two copies of it would be two different ideas of what counts as an
/// absurd document — and the smaller one would reject states the other happily sends.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_entry_count() -> usize {
    state_codec::MAX_ENTRY_COUNT
}

/// One document entry on the way across: a key, and where its value sits in the input.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CEntry {
    /// Which kind of object the key names — root, session, tab, pane.
    pub kind: u8,
    /// Which field of it.
    pub field: u8,
    /// The object's identity.
    pub object: Uuid,
    /// Where the value sits in the buffer that was decoded. `present` is always true for a decode;
    /// it is the ENCODE direction that uses it, where a key with no value is a delete.
    pub value: Span,
}

/// Reads the entries a decode answered into the flat form.
fn flatten(entries: &[state_codec::Entry<'_>], base: *const u8) -> Vec<CEntry> {
    entries
        .iter()
        .map(|entry| {
            CEntry {
                kind: entry.kind,
                field: entry.field,
                object: Uuid { bytes: entry.object },
                value: Span {
                    // The value is a subslice of the input, so its offset is the pointer difference.
                    // Both pointers are into one allocation, which is what makes the arithmetic defined.
                    offset: (entry.value.as_ptr() as usize).saturating_sub(base as usize),
                    len: entry.value.len(),
                    present: true,
                },
            }
        })
        .collect()
}

/// The entries a snapshot carries, under §4's convention, with each value a span into `bytes`.
///
/// [`usize::MAX`] when the bytes are malformed — a REFUSAL, which is not the empty snapshot that a
/// well-formed zero count is. Trailing bytes are malformed on purpose: a snapshot that decoded to
/// fewer entries than it carries would have the client ack a state it does not hold.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` [`CEntry`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_snapshot(
    bytes: *const u8,
    len: usize,
    out: *mut CEntry,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let input = unsafe { field(bytes, len) };
    let Some(entries) = state_codec::decode_snapshot(input) else {
        return usize::MAX;
    };
    let answers = flatten(&entries, input.as_ptr());
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// The two halves a diff carries. Both counts are written even when a buffer was too small, so one
/// call sizes both and the retry needs no guessing.
///
/// False when the bytes are malformed. `sets_needed`/`deletes_needed` are then untouched, because
/// there is no partial answer to size for: a diff that half-decoded is not a diff.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; each `out` null or writable for its `cap`;
/// each `needed` null or writable for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_diff(
    bytes: *const u8,
    len: usize,
    sets_out: *mut CEntry,
    sets_cap: usize,
    deletes_out: *mut CEntry,
    deletes_cap: usize,
    sets_needed: *mut usize,
    deletes_needed: *mut usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let input = unsafe { field(bytes, len) };
    let Some((sets, deletes)) = state_codec::decode_diff(input) else {
        return false;
    };
    let set_entries = flatten(&sets, input.as_ptr());
    // A delete is a key with no value, which is what `present: false` says here.
    let delete_entries: Vec<CEntry> = deletes
        .iter()
        .map(|key| {
            CEntry {
                kind: key.kind,
                field: key.field,
                object: Uuid { bytes: key.object },
                value: Span {
                    offset: 0,
                    len: 0,
                    present: false,
                },
            }
        })
        .collect();
    // SAFETY: each pointer is null or writable for what its obligation says, and both source vectors
    // were allocated inside this call so neither can overlap a destination.
    unsafe {
        if !sets_needed.is_null() {
            *sets_needed = set_entries.len();
        }
        if !deletes_needed.is_null() {
            *deletes_needed = delete_entries.len();
        }
        if set_entries.len() <= sets_cap && !sets_out.is_null() {
            core::ptr::copy_nonoverlapping(set_entries.as_ptr(), sets_out, set_entries.len());
        }
        if delete_entries.len() <= deletes_cap && !deletes_out.is_null() {
            core::ptr::copy_nonoverlapping(delete_entries.as_ptr(), deletes_out, delete_entries.len());
        }
    }
    true
}

/// Reads the entries a caller is encoding, whose values are spans into `blob`.
///
/// A span the blob cannot back reads as an EMPTY value rather than trapping — the same bounds
/// discipline the decode side uses, applied to a caller who got their own arithmetic wrong.
fn gather<'a>(entries: &[CEntry], blob: &'a [u8]) -> Vec<state_codec::Entry<'a>> {
    entries
        .iter()
        .map(|entry| {
            state_codec::Entry {
                kind: entry.kind,
                object: entry.object.bytes,
                field: entry.field,
                value: entry
                    .value
                    .offset
                    .checked_add(entry.value.len)
                    .and_then(|end| blob.get(entry.value.offset..end))
                    .unwrap_or_default(),
            }
        })
        .collect()
}

/// A snapshot's bytes, under §4's convention.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s, `blob` null or to `blob_len` live
/// bytes, and `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_snapshot(
    entries: *const CEntry,
    count: usize,
    blob: *const u8,
    blob_len: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let flat = borrow_entries(entries, count);
        let bytes = field(blob, blob_len);
        deliver(&state_codec::encode_snapshot(&gather(&flat, bytes)), out, cap)
    }
}

/// A diff's bytes, under §4's convention. The DELETES carry only their keys; their spans are
/// ignored.
///
/// # Safety
/// As [`slopdesk_ws_encode_snapshot`], for both entry arrays.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_diff(
    sets: *const CEntry,
    set_count: usize,
    deletes: *const CEntry,
    delete_count: usize,
    blob: *const u8,
    blob_len: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let flat_sets = borrow_entries(sets, set_count);
        let flat_deletes = borrow_entries(deletes, delete_count);
        let bytes = field(blob, blob_len);
        let keys: Vec<state_codec::Key> = flat_deletes
            .iter()
            .map(|entry| {
                state_codec::Key {
                    kind: entry.kind,
                    object: entry.object.bytes,
                    field: entry.field,
                }
            })
            .collect();
        deliver(
            &state_codec::encode_diff(&gather(&flat_sets, bytes), &keys),
            out,
            cap,
        )
    }
}

/// Reads a caller's entry array.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading through a caller's pointer"
)]
unsafe fn borrow_entries(entries: *const CEntry, count: usize) -> Vec<CEntry> {
    if entries.is_null() || count == 0 {
        return Vec::new();
    }
    // SAFETY: non-null and, by the caller's obligation, `count` live `CEntry`s for the call.
    unsafe { core::slice::from_raw_parts(entries, count) }.to_vec()
}

// MARK: The layout structure and the split weights
//
// The layout decoder that crossed is ITERATIVE where the Swift one recursed. A depth cap checked
// before descending is correct, but it is one forgotten check away from a remote stack overflow;
// walking a flat array with an explicit frame stack makes the overflow structurally impossible, and
// the cap goes back to being a statement about documents rather than a safety mechanism.

/// One node of the layout structure, in a pre-order walk.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CLayoutNode {
    /// `0` leaf, `1` split.
    pub kind: u8,
    /// `0` horizontal, `1` vertical. Meaningless on a leaf.
    pub axis: u8,
    /// A split's child count. A `u8` by the FORMAT, so fan-out is bounded before any allocation.
    pub child_count: u8,
    /// The pane's or the split's identity.
    pub id: Uuid,
}

/// The walk a layout structure carries, under §4's convention.
///
/// [`usize::MAX`] when the bytes do not decode, with `depth_exceeded` saying WHICH refusal it was:
/// a well-formed tree nested past the cap sets it, an unknown tag or a truncated node does not. The
/// caller reports those differently, because one is a document this build declines to hold and the
/// other is a bug or an attack — so the distinction crosses as a flag rather than being flattened
/// into the one sentinel.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` nodes;
/// `depth_exceeded` null or writable for one `bool`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_layout(
    bytes: *const u8,
    len: usize,
    out: *mut CLayoutNode,
    cap: usize,
    depth_exceeded: *mut bool,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let decoded = state_codec::decode_layout(unsafe { field(bytes, len) });
    if !depth_exceeded.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `bool`.
        unsafe { *depth_exceeded = decoded == Err(state_codec::LayoutError::DepthExceeded) };
    }
    let Ok(walk) = decoded else {
        return usize::MAX;
    };
    let answers: Vec<CLayoutNode> = walk
        .into_iter()
        .map(|node| {
            CLayoutNode {
                kind: node.kind,
                axis: node.axis,
                child_count: node.child_count,
                id: Uuid { bytes: node.id },
            }
        })
        .collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// A layout structure's bytes, under §4's convention.
///
/// # Safety
/// `walk` must be null or point to `count` live nodes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_layout(
    walk: *const CLayoutNode,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let nodes: Vec<state_codec::LayoutNode> = if walk.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live nodes for the call.
        unsafe { core::slice::from_raw_parts(walk, count) }
            .iter()
            .map(|node| {
                state_codec::LayoutNode {
                    kind: node.kind,
                    id: node.id.bytes,
                    axis: node.axis,
                    child_count: node.child_count,
                }
            })
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_layout(&nodes), out, cap) }
}

/// One split's child weights, under §4's convention. [`usize::MAX`] when the count and the bytes
/// disagree — a refusal, not the empty list a well-formed zero count is.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` [`Share`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_weights(
    bytes: *const u8,
    len: usize,
    out: *mut Share,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(weights) = state_codec::decode_weights(unsafe { field(bytes, len) }) else {
        return usize::MAX;
    };
    let answers: Vec<Share> = weights
        .into_iter()
        .map(|(is_fixed, value)| Share { is_fixed, value })
        .collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// One split's child weights as bytes, under §4's convention.
///
/// # Safety
/// `shares` must be null or point to `count` live [`Share`]s; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_weights(
    shares: *const Share,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let weights: Vec<(bool, f64)> = if shares.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live `Share`s for the call.
        unsafe { core::slice::from_raw_parts(shares, count) }
            .iter()
            .map(|share| (share.is_fixed, share.value))
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_weights(&weights), out, cap) }
}

/// A `[16B]` field value. False when the bytes are not exactly sixteen.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one [`Uuid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_uuid(bytes: *const u8, len: usize, out: *mut Uuid) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_uuid(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `Uuid`.
        unsafe { *out = Uuid { bytes: value } };
    }
    true
}

/// A key's eighteen bytes, under §4's convention.
///
/// The addressing scheme is the document's, so it is written once in the crate rather than being a
/// small append loop on each side of the boundary.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_key(
    kind: u8,
    object: Uuid,
    field_tag: u8,
    out: *mut u8,
    cap: usize,
) -> usize {
    let key = state_codec::Key {
        kind,
        object: object.bytes,
        field: field_tag,
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_key(key), out, cap) }
}

/// A `[u32 BE]` field value's bytes, under §4's convention.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_u32(value: u32, out: *mut u8, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_u32(value), out, cap) }
}

/// A `[u16 BE][u16 BE]` field value's bytes, under §4's convention.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_u16_pair(
    first: u16,
    second: u16,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_u16_pair(first, second), out, cap) }
}

/// An `[i64 BE]` field value's bytes, under §4's convention.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_i64(value: i64, out: *mut u8, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_i64(value), out, cap) }
}

// MARK: - The two composite field values

/// A detached pane and the tab it came from, if that is still known.
///
/// `has_origin` is a FLAG, not a zero id: the wire's fixed-width pair spells absence as the
/// all-zero uuid, and the crate translates it here so no caller on this side has to know that
/// spelling.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CDetachedPane {
    /// The pane itself.
    pub pane: Uuid,
    /// The tab it was detached from. Meaningless when `has_origin` is false.
    pub origin: Uuid,
    /// Whether the origin is remembered at all.
    pub has_origin: bool,
}

/// A pane's video source, its two strings as SPANS into the caller's own input buffer.
///
/// Zero-copy the way a decoded entry is: the bytes are already in Swift's hands, so a span is an
/// offset into what it lent rather than a second allocation it then has to free.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CVideoTarget {
    /// The window's id on the host.
    pub window_id: u32,
    /// The display it sits on. Meaningless when `has_display` is false — `0` is the MAIN display,
    /// so it could never have carried the absence itself.
    pub display_id: u32,
    /// Whether the endpoint is display-shaped at all.
    pub has_display: bool,
    /// The window title, as an offset into the bytes the caller lent.
    pub title: Span,
    /// The owning application's name, likewise.
    pub app_name: Span,
}

/// The detached panes a value carries, under §4's convention. [`usize::MAX`] when the count and the
/// bytes disagree.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` panes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_detached_panes(
    bytes: *const u8,
    len: usize,
    out: *mut CDetachedPane,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(panes) = state_codec::decode_detached_panes(unsafe { field(bytes, len) }) else {
        return usize::MAX;
    };
    let answers: Vec<CDetachedPane> = panes
        .into_iter()
        .map(|entry| {
            CDetachedPane {
                pane: Uuid { bytes: entry.pane },
                origin: Uuid {
                    bytes: entry.origin.unwrap_or([0; 16]),
                },
                has_origin: entry.origin.is_some(),
            }
        })
        .collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// The detached panes as bytes, under §4's convention.
///
/// # Safety
/// `panes` must be null or point to `count` live [`CDetachedPane`]s; `out` null or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_detached_panes(
    panes: *const CDetachedPane,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let entries: Vec<state_codec::DetachedPane> = if panes.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live panes for the call.
        unsafe { core::slice::from_raw_parts(panes, count) }
            .iter()
            .map(|entry| {
                state_codec::DetachedPane {
                    pane: entry.pane.bytes,
                    origin: entry.has_origin.then_some(entry.origin.bytes),
                }
            })
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_detached_panes(&entries), out, cap) }
}

/// A pane's video target, its strings spanning the bytes the caller lent. False when a length
/// overruns, a string is not UTF-8, or bytes are left over.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one
/// [`CVideoTarget`]. The spans it writes are offsets into `bytes`, so they are meaningful only for
/// as long as the caller keeps that buffer alive.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_video_target(
    bytes: *const u8,
    len: usize,
    out: *mut CVideoTarget,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let input = unsafe { field(bytes, len) };
    let Some(target) = state_codec::decode_video_target(input) else {
        return false;
    };
    // The decoded strings BORROW `input`, so their offsets are found by pointer arithmetic within
    // it rather than by re-scanning the format — which is what makes this leg zero-copy.
    let span_of = |text: &str| {
        let offset = (text.as_ptr() as usize).saturating_sub(input.as_ptr() as usize);
        Span {
            offset,
            len: text.len(),
            present: true,
        }
    };
    if !out.is_null() {
        let answer = CVideoTarget {
            window_id: target.window_id,
            display_id: target.display_id.unwrap_or(0),
            has_display: target.display_id.is_some(),
            title: span_of(target.title),
            app_name: span_of(target.app_name),
        };
        // SAFETY: non-null and, by the caller's obligation, writable for one `CVideoTarget`.
        unsafe { *out = answer };
    }
    true
}

/// A pane's video target as bytes, under §4's convention. The two strings arrive as spans into one
/// `blob`, the same way every other multi-string call here takes them.
///
/// # Safety
/// `blob` must be null or point to `blob_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_video_target(
    window_id: u32,
    display_id: u32,
    has_display: bool,
    blob: *const u8,
    blob_len: usize,
    title: Span,
    app_name: Span,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let strings = unsafe { field(blob, blob_len) };
    // A span that does not fit the blob reads as the empty string: the caller got its arithmetic
    // wrong, and an empty title is a visible bug where a read past the end is not one at all.
    let text = |span: Span| {
        span.offset
            .checked_add(span.len)
            .and_then(|end| strings.get(span.offset..end))
            .and_then(|slice| core::str::from_utf8(slice).ok())
            .unwrap_or("")
    };
    let target = state_codec::VideoTarget {
        window_id,
        display_id: has_display.then_some(display_id),
        title: text(title),
        app_name: text(app_name),
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_video_target(&target), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::float_cmp,
    reason = "exact is the assertion: `CLAUDE.md` pins these results bit-exactly, so a tolerance here would \
              pass on the drift it exists to catch"
)]
mod tests {
    use slopdesk_workspace::{PaneId, SplitAxis, SplitNode, SplitNodeId, SplitWeight, WeightedChild};

    use super::{
        CPoint, CRect, CVideoTarget, Frame, KeyedTab, Share, Span, TreeNode, Uuid, decode_tree, encode_tree,
        slopdesk_ws_canvas_point, slopdesk_ws_decode_video_target, slopdesk_ws_encode_video_target,
        slopdesk_ws_extents, slopdesk_ws_focus_cycle, slopdesk_ws_focus_neighbor,
        slopdesk_ws_natural_compare, slopdesk_ws_project_key, slopdesk_ws_resize_group, slopdesk_ws_sanitize,
        slopdesk_ws_screen_rect, slopdesk_ws_section_header, slopdesk_ws_section_precedes,
        slopdesk_ws_send_keys, slopdesk_ws_solve_layout, slopdesk_ws_successor_after_close,
        slopdesk_ws_tree_removing, slopdesk_ws_tree_splitting,
    };

    const fn id(byte: u8) -> Uuid {
        Uuid { bytes: [byte; 16] }
    }

    const fn rect(x: f64, y: f64, width: f64, height: f64) -> CRect {
        CRect { x, y, width, height }
    }

    const fn leaf(byte: u8) -> TreeNode {
        TreeNode {
            kind: 0,
            id: id(byte),
            axis: 0,
            weight_is_fixed: false,
            child_count: 0,
            weight: 1.0,
        }
    }

    const fn span(offset: usize, len: usize) -> Span {
        Span {
            offset,
            len,
            present: true,
        }
    }

    const NO_KEY: Span = Span {
        offset: 0,
        len: 0,
        present: false,
    };

    fn transform(call: impl Fn(*const u8, usize, *mut u8, usize) -> usize, text: &str) -> String {
        let input = text.as_bytes();
        let mut out = vec![0_u8; 256];
        let needed = call(input.as_ptr(), input.len(), out.as_mut_ptr(), out.len());
        assert!(needed <= out.len(), "the test buffer is generous by design");
        String::from_utf8(out.get(..needed).unwrap_or_default().to_vec()).unwrap_or_default()
    }

    #[test]
    fn a_control_token_reaches_the_pty_as_its_bytes() {
        let encoded = transform(
            |bytes, len, out, cap| unsafe { slopdesk_ws_send_keys(bytes, len, out, cap) },
            "a<Esc>b",
        );
        assert_eq!(encoded.as_bytes(), b"a\x1Bb");
    }

    #[test]
    fn a_buffer_that_does_not_fit_is_left_untouched() {
        let input = b"hello world";
        let mut out = [0_u8; 4];
        let needed =
            unsafe { slopdesk_ws_send_keys(input.as_ptr(), input.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, input.len());
        assert_eq!(out, [0; 4], "nothing is written when the answer does not fit");
    }

    #[test]
    fn focus_moves_by_what_is_on_screen() {
        let frames = [
            Frame {
                id: id(1),
                rect: rect(0.0, 0.0, 100.0, 100.0),
            },
            Frame {
                id: id(2),
                rect: rect(100.0, 0.0, 100.0, 100.0),
            },
        ];
        let mut answer = id(0);
        // 1 is Right in the shared discriminant order.
        let moved =
            unsafe { slopdesk_ws_focus_neighbor(frames.as_ptr(), frames.len(), id(1), 1, &raw mut answer) };
        assert!(moved);
        assert_eq!(answer, id(2));
        // 0 is Left, and there is nothing to the left of the leftmost pane.
        assert!(!unsafe {
            slopdesk_ws_focus_neighbor(frames.as_ptr(), frames.len(), id(1), 0, &raw mut answer)
        });
    }

    #[test]
    fn cycling_wraps_and_refuses_a_pane_it_does_not_hold() {
        let panes = [id(1), id(2), id(3)];
        let mut answer = id(0);
        assert!(unsafe {
            slopdesk_ws_focus_cycle(panes.as_ptr(), panes.len(), id(3), true, &raw mut answer)
        });
        assert_eq!(answer, id(1), "forward from the last wraps to the first");
        assert!(!unsafe {
            slopdesk_ws_focus_cycle(panes.as_ptr(), panes.len(), id(9), true, &raw mut answer)
        });
    }

    #[test]
    fn a_blank_project_key_is_absent_rather_than_empty() {
        // The trailing slash folds, which is what keeps a pane's directory and its git toplevel from
        // becoming two identically-titled sections.
        let key = transform(
            |bytes, len, out, cap| unsafe { slopdesk_ws_project_key(bytes, len, true, out, cap) },
            "  /Users/me/slop-desk/  ",
        );
        assert_eq!(key, "/Users/me/slop-desk");
        let blank = transform(
            |bytes, len, out, cap| unsafe { slopdesk_ws_project_key(bytes, len, true, out, cap) },
            "   ",
        );
        assert!(blank.is_empty(), "a blank key folds to absent, which is 0 bytes");
        assert_eq!(
            unsafe { slopdesk_ws_project_key(core::ptr::null(), 0, false, core::ptr::null_mut(), 0) },
            0
        );
    }

    #[test]
    fn the_keyless_section_sorts_last_however_it_is_spelled() {
        assert_eq!(
            transform(
                |bytes, len, out, cap| unsafe { slopdesk_ws_section_header(bytes, len, false, out, cap) },
                "",
            ),
            "Other"
        );
        let alpha = b"alpha";
        assert!(unsafe {
            slopdesk_ws_section_precedes(alpha.as_ptr(), alpha.len(), true, core::ptr::null(), 0, false)
        });
        assert!(!unsafe {
            slopdesk_ws_section_precedes(core::ptr::null(), 0, false, alpha.as_ptr(), alpha.len(), true)
        });
    }

    #[test]
    fn ten_sorts_after_nine_rather_than_after_one() {
        let compare = |lhs: &str, rhs: &str| unsafe {
            slopdesk_ws_natural_compare(lhs.as_ptr(), lhs.len(), rhs.as_ptr(), rhs.len())
        };
        assert_eq!(compare("tab 9", "tab 10"), -1);
        assert_eq!(compare("tab 10", "tab 9"), 1);
        assert_eq!(compare("tab", "tab"), 0);
    }

    #[test]
    fn closing_a_tab_returns_focus_to_the_one_it_was_opened_from() {
        let blob = b"alpha";
        let tabs = [
            KeyedTab {
                id: id(1),
                key: span(0, 5),
            },
            KeyedTab {
                id: id(2),
                key: span(0, 5),
            },
            KeyedTab {
                id: id(3),
                key: NO_KEY,
            },
        ];
        let history = [id(2), id(1)];
        let mut answer = id(0);
        let found = unsafe {
            slopdesk_ws_successor_after_close(
                id(2),
                tabs.as_ptr(),
                tabs.len(),
                blob.as_ptr(),
                blob.len(),
                history.as_ptr(),
                history.len(),
                &raw mut answer,
            )
        };
        assert!(found);
        assert_eq!(answer, id(1), "the most recent SURVIVOR, not the closing tab");
    }

    #[test]
    fn with_no_history_focus_stays_inside_the_project_section() {
        let blob = b"alpha";
        let tabs = [
            KeyedTab {
                id: id(1),
                key: span(0, 5),
            },
            KeyedTab {
                id: id(2),
                key: NO_KEY,
            },
            KeyedTab {
                id: id(3),
                key: span(0, 5),
            },
        ];
        let mut answer = id(0);
        assert!(unsafe {
            slopdesk_ws_successor_after_close(
                id(1),
                tabs.as_ptr(),
                tabs.len(),
                blob.as_ptr(),
                blob.len(),
                core::ptr::null(),
                0,
                &raw mut answer,
            )
        });
        assert_eq!(
            answer,
            id(3),
            "the sibling in the same section, skipping the keyless tab"
        );
    }

    #[test]
    fn a_span_pointing_off_the_end_reads_as_no_key_rather_than_trapping() {
        let blob = b"alpha";
        let tabs = [
            KeyedTab {
                id: id(1),
                key: span(4, usize::MAX),
            },
            KeyedTab {
                id: id(2),
                key: span(900, 5),
            },
        ];
        let mut answer = id(0);
        assert!(unsafe {
            slopdesk_ws_successor_after_close(
                id(1),
                tabs.as_ptr(),
                tabs.len(),
                blob.as_ptr(),
                blob.len(),
                core::ptr::null(),
                0,
                &raw mut answer,
            )
        });
        assert_eq!(answer, id(2));
    }

    #[test]
    fn a_pre_order_walk_tiles_the_bound_it_was_given() {
        // A horizontal split of two equal leaves: [split(2), leaf, leaf].
        let nodes = [
            TreeNode {
                kind: 1,
                id: id(9),
                axis: 0,
                weight_is_fixed: false,
                child_count: 2,
                weight: 1.0,
            },
            leaf(1),
            leaf(2),
        ];
        let mut out = [Frame {
            id: id(0),
            rect: rect(0.0, 0.0, 0.0, 0.0),
        }; 4];
        let count = unsafe {
            slopdesk_ws_solve_layout(
                nodes.as_ptr(),
                nodes.len(),
                rect(0.0, 0.0, 400.0, 200.0),
                10.0,
                10.0,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(count, 2);
        let widths: Vec<f64> = out.iter().take(2).map(|frame| frame.rect.width).collect();
        assert_eq!(widths, vec![200.0, 200.0], "columns halve the width exactly");
        assert!(out.iter().take(2).all(|frame| frame.rect.height == 200.0));
    }

    /// The group-handle resize, across the boundary the way `Canvas+Ops.resizingGroup` calls it.
    ///
    /// The box the members currently occupy is derived on the far side rather than passed in, so
    /// what this proves is that a `CRect` handed BY VALUE arrives intact: every other arrange door
    /// takes only pointers, and a struct-by-value argument that the header and the crate disagreed
    /// about would misread the box rather than fail to link.
    #[test]
    fn a_group_resize_scales_its_members_and_keeps_them_inside_the_new_box() {
        let members = [
            Frame {
                id: id(1),
                rect: rect(0.0, 0.0, 400.0, 400.0),
            },
            Frame {
                id: id(2),
                rect: rect(400.0, 0.0, 400.0, 400.0),
            },
        ];
        let mut out = [Frame {
            id: id(0),
            rect: rect(0.0, 0.0, 0.0, 0.0),
        }; 4];
        let count = unsafe {
            slopdesk_ws_resize_group(
                members.as_ptr(),
                members.len(),
                rect(0.0, 0.0, 1600.0, 400.0),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(count, 2);
        let widths: Vec<f64> = out.iter().take(2).map(|frame| frame.rect.width).collect();
        assert_eq!(
            widths,
            vec![800.0, 800.0],
            "a doubled box doubles each member exactly"
        );
        let xs: Vec<f64> = out.iter().take(2).map(|frame| frame.rect.x).collect();
        assert_eq!(xs, vec![0.0, 800.0], "the internal layout survives the remap");
    }

    #[test]
    fn a_walk_that_claims_more_children_than_it_carries_is_refused() {
        for hostile in [
            // A split promising three children with none behind it.
            vec![TreeNode {
                kind: 1,
                id: id(9),
                axis: 0,
                weight_is_fixed: false,
                child_count: 3,
                weight: 1.0,
            }],
            // …and one promising more than the array could ever hold.
            vec![
                TreeNode {
                    kind: 1,
                    id: id(9),
                    axis: 1,
                    weight_is_fixed: false,
                    child_count: u32::MAX,
                    weight: 1.0,
                },
                leaf(1),
            ],
            Vec::new(),
        ] {
            let count = unsafe {
                slopdesk_ws_solve_layout(
                    hostile.as_ptr(),
                    hostile.len(),
                    rect(0.0, 0.0, 400.0, 200.0),
                    10.0,
                    10.0,
                    core::ptr::null_mut(),
                    0,
                )
            };
            assert_eq!(count, 0, "a tree that cannot be rebuilt draws nothing");
        }
    }

    #[test]
    fn fixed_children_are_reserved_before_the_flex_ones_divide_the_rest() {
        let shares = [
            Share {
                is_fixed: true,
                value: 100.0,
            },
            Share {
                is_fixed: false,
                value: 1.0,
            },
            Share {
                is_fixed: false,
                value: 1.0,
            },
        ];
        let mut out = [0.0_f64; 3];
        let count =
            unsafe { slopdesk_ws_extents(shares.as_ptr(), shares.len(), 500.0, out.as_mut_ptr(), out.len()) };
        assert_eq!(count, 3);
        assert_eq!(out, [100.0, 200.0, 200.0]);
    }

    #[test]
    fn a_nan_coordinate_becomes_a_number_before_it_can_poison_a_union() {
        let sanitized = slopdesk_ws_sanitize(rect(f64::NAN, f64::INFINITY, -5.0, f64::NAN));
        assert!(sanitized.x.is_finite() && sanitized.y.is_finite());
        assert!(sanitized.width > 0.0 && sanitized.height > 0.0);
    }

    #[test]
    fn the_camera_round_trips_a_point_through_the_screen() {
        let camera = CPoint { x: 30.0, y: -12.0 };
        let screen = slopdesk_ws_screen_rect(rect(100.0, 50.0, 10.0, 10.0), camera);
        let back = slopdesk_ws_canvas_point(
            CPoint {
                x: screen.x,
                y: screen.y,
            },
            camera,
        );
        assert!(
            (back.x - 100.0).abs() < f64::EPSILON && (back.y - 50.0).abs() < f64::EPSILON,
            "the camera is a translation, so it inverts exactly"
        );
    }

    /// The round trip is the whole safety of the tree ops: every one of them reads a walk and
    /// writes one, so a leg that lost a weight or reordered a child would corrupt an arrangement
    /// silently.
    #[test]
    fn a_tree_survives_the_walk_out_and_back() {
        let tree = SplitNode::Split {
            id: SplitNodeId::from_bytes([9; 16]),
            axis: SplitAxis::Vertical,
            children: vec![
                WeightedChild::new(
                    SplitWeight::Fixed(120.0),
                    SplitNode::Leaf(PaneId::from_bytes([1; 16])),
                ),
                WeightedChild::new(
                    SplitWeight::Flex(3.0),
                    SplitNode::Leaf(PaneId::from_bytes([2; 16])),
                ),
            ],
        };
        let mut walk = Vec::new();
        encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
        let mut cursor = 0;
        let rebuilt = decode_tree(&walk, &mut cursor);
        assert_eq!(cursor, walk.len(), "the walk is consumed exactly");
        assert_eq!(rebuilt, Some(tree), "out and back is the identity");
    }

    /// "This pane is not here" and "this was the last pane" are DIFFERENT answers: the first has to
    /// leave the arrangement alone, where treating it as the second would close the tab.
    #[test]
    fn a_stranger_is_not_the_last_pane() {
        let tree = SplitNode::Leaf(PaneId::from_bytes([1; 16]));
        let mut walk = Vec::new();
        encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
        let mut out = [leaf(0); 8];
        // SAFETY: both pointers are to live arrays of the lengths given.
        let stranger = unsafe {
            slopdesk_ws_tree_removing(walk.as_ptr(), walk.len(), id(7), out.as_mut_ptr(), out.len())
        };
        assert_eq!(
            stranger, 1,
            "a pane that is not here removes nothing — the tree stands"
        );
        // SAFETY: as above.
        let last = unsafe {
            slopdesk_ws_tree_removing(walk.as_ptr(), walk.len(), id(1), out.as_mut_ptr(), out.len())
        };
        assert_eq!(
            last,
            usize::MAX,
            "removing the last leaf leaves no tree, which is not an empty one"
        );
    }

    /// A split mints nothing of its own — the identity it is given is the identity it wears, which
    /// is what lets a replay reproduce a layout byte for byte.
    #[test]
    fn a_split_wears_the_identity_it_was_handed() {
        let tree = SplitNode::Leaf(PaneId::from_bytes([1; 16]));
        let mut walk = Vec::new();
        encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
        let mut out = [leaf(0); 8];
        // SAFETY: both pointers are to live arrays of the lengths given.
        let count = unsafe {
            slopdesk_ws_tree_splitting(
                walk.as_ptr(),
                walk.len(),
                Uuid { bytes: [1; 16] },
                1,
                Uuid { bytes: [2; 16] },
                false,
                Uuid { bytes: [42; 16] },
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(count, 3, "a root leaf split in two is a split over two leaves");
        let walked: Vec<(u8, [u8; 16])> = out
            .iter()
            .take(count)
            .map(|node| (node.kind, node.id.bytes))
            .collect();
        assert_eq!(
            walked,
            vec![(1, [42; 16]), (0, [1; 16]), (0, [2; 16])],
            "the split wears the id it was handed, and the target keeps the leading side"
        );
    }

    /// The span leg is pointer arithmetic, so it is worth proving the offsets land on the strings
    /// they name rather than merely being in range — an off-by-one here would read a plausible
    /// window title out of the neighbouring field.
    #[test]
    fn a_video_target_s_spans_point_at_its_own_strings() {
        let blob = b"GhosttyTerminal";
        let title = Span {
            offset: 7,
            len: 8,
            present: true,
        };
        let app = Span {
            offset: 0,
            len: 7,
            present: true,
        };
        let mut bytes = [0_u8; 64];
        // SAFETY: both buffers are live locals, and the spans sit inside `blob`.
        let written = unsafe {
            slopdesk_ws_encode_video_target(
                42,
                0,
                true,
                blob.as_ptr(),
                blob.len(),
                title,
                app,
                bytes.as_mut_ptr(),
                bytes.len(),
            )
        };
        let mut answer = CVideoTarget {
            window_id: 0,
            display_id: 9,
            has_display: false,
            title: Span {
                offset: 0,
                len: 0,
                present: false,
            },
            app_name: Span {
                offset: 0,
                len: 0,
                present: false,
            },
        };
        // SAFETY: `bytes` is live for the call and `answer` is a live local.
        let ok = unsafe { slopdesk_ws_decode_video_target(bytes.as_ptr(), written, &raw mut answer) };
        assert!(ok, "the value this call just encoded must decode");
        assert_eq!(answer.window_id, 42);
        assert!(answer.has_display, "display 0 is a display");
        assert_eq!(answer.display_id, 0);
        let text = |span: Span| {
            String::from_utf8_lossy(bytes.get(span.offset..span.offset + span.len).unwrap_or(&[]))
                .into_owned()
        };
        assert_eq!(text(answer.title), "Terminal");
        assert_eq!(text(answer.app_name), "Ghostty");
    }
}
