//! The workspace document's solvers: `rust/slopdesk-workspace` reached from the client's Swift.
//!
//! ## What crosses here, and what deliberately does not
//! `SlopDeskWorkspaceModel` is the app's DOCUMENT — 262 files import its value types. Those types
//! stay in Swift for two reasons, and the first one alone would not hold. It is the one
//! `ClaudeStatus` used (docs/55 §6): a case list a `switch` reads is a vocabulary, not an
//! implementation. The second is the only kind of veto `CLAUDE.md` recognises — a MEASURED one.
//! `WorkspaceMarshalBenchTests` ran the port this header would otherwise invite, over the shipped
//! encoder and decoder rather than a fixture, and moving the whole document per gesture costs
//! ~2.8 ms on a realistic workspace and ~12.6 ms on a hoarder's: a third of a 120 Hz frame, then a
//! missed one, for a divider drag that is otherwise a few hundred microseconds.
//!
//! So what crosses is the half that DECIDES — which neighbour "move focus left" lands on, what
//! order the sidebar's sections come in, which tab takes focus after a close. A RULE is bounded by
//! one tab; the document is not, and that is the whole of why the line is here.
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

use slopdesk_ids::identity::{IdSource, SessionId};
use slopdesk_ids::{PaneId, SplitNodeId, TabId, shell_quoting};
use slopdesk_tree::tree_ops::{self, TileLayout};
use slopdesk_tree::workspace::{self, TreeWorkspace};
use slopdesk_tree::{
    FocusDirection, PaneKind, PaneSpec, Rect, Size, SolvedLayout, SplitAxis, SplitNode, SplitWeight,
    WeightedChild, focus, geometry, split_layout, split_tree, tab_ordering,
};
use slopdesk_wire::document::codec as wire_codec;
use slopdesk_wire::document::state::HostWorkspaceState;
use slopdesk_wire::document::topology::WorkspaceTopology;
use slopdesk_workspace::{listen, persist, rail_title, secrets, send_keys, state_codec, templates};

use crate::workspace_state_file::{write_status, write_version};
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
    pub(crate) const fn resolve(self) -> Rect {
        Rect::xywh(self.x, self.y, self.width, self.height)
    }

    pub(crate) const fn of(rect: Rect) -> Self {
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

/// A pane and the project key the caller's closure answered for it.
///
/// The same two fields as [`KeyedTab`] and deliberately not the same type: a close rule reads a
/// TAB's key and the intent applier reads a PANE's, the two ids name different objects, and a
/// struct whose name says "tab" would let one be passed where the other belongs with nothing but a
/// comment to catch it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct KeyedPane {
    /// Which pane.
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
pub(crate) const unsafe fn borrow_array<'a, T>(items: *const T, count: usize) -> &'a [T] {
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
pub(crate) fn text_of(span: Span, blob: &[u8]) -> Option<&str> {
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

// MARK: The split tree's two shared metrics

/// The minimum flex weight a divider may take, from the crate that enforces it.
///
/// `repaired()` clamps to this number, so a client that drew or asserted against a transcribed
/// copy would be describing a rule it does not share.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_min_weight() -> f64 {
    split_tree::MIN_WEIGHT
}

/// The deepest nesting a layout may KEEP, from the crate that caps it.
///
/// It sat beside [`slopdesk_ws_min_weight`] as a transcribed `12` on the Swift side until
/// 2026-08-20, and `docs/55` §8 named the pair as the anti-pattern it is: two numbers with one
/// meaning, one asked for through a door and one written down again, where the second is only
/// right until somebody tunes the first. Three separate rules clamp to it — the persisted split
/// tree's decode, the template layout's repair, and the solver recursion both of them feed — so a
/// caller that disagreed about it would build a tree the crate refuses to walk.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_depth() -> usize {
    split_tree::MAX_DEPTH
}

/// The schema version the persisted workspace shape writes, from the crate that owns the shape.
///
/// It is the version a load COMPARES against, and there is no migration behind the comparison — a
/// file carrying any other number is set aside. So the two spellings could not have been caught by
/// a test: they agreed, and the day one of them was bumped alone the near side would either keep
/// writing a version the far side calls stale, or set aside every file the far side just wrote.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_schema_version() -> i64 {
    slopdesk_tree::CURRENT_SCHEMA_VERSION
}

/// The longest a string field may be, from the codec that clamps it.
///
/// `slopdesk_ws_encode_string` takes the bound as an argument, because a field's own limit is not
/// always the protocol's — a `renameTab` name is clamped tighter than a title. A caller with no
/// tighter limit of its own asks for the protocol's HERE rather than writing the number down: the
/// number is a wire property, and a near side that disagreed about it would either refuse a value
/// the far end accepts or offer one it drops.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_string_bytes() -> usize {
    state_codec::MAX_STRING_BYTES
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
pub(crate) unsafe fn borrow_tree(nodes: *const TreeNode, count: usize) -> Option<SplitNode> {
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

/// One draggable seam, flat.
///
/// The rect is where the handle is drawn and hit; everything after it is what a DRAG needs — the
/// span it converts pixels against, the flex sum it converts them into, and the pair of weights it
/// moves between. They ride the same struct because the two predicates below are answered from
/// them alone, so a caller that has a handle never has to reassemble one.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct DividerHandle {
    /// The split that owns the seam.
    pub split: Uuid,
    /// The LEADING child's index: the seam is between it and the next child.
    pub child_index: u32,
    /// 0 horizontal (a column seam, dragged left/right) · 1 vertical.
    pub axis: u8,
    /// The handle's band.
    pub rect: CRect,
    /// The owning split's axis length — a NESTED split's own, not the container's.
    pub parent_span: f64,
    /// The owning split's flex-weight sum.
    pub flex_sum: f64,
    /// The leading child's flex weight; `0` for a fixed child, which is not draggable.
    pub leading_weight: f64,
    /// The trailing child's flex weight; `0` fixed.
    pub trailing_weight: f64,
}

impl DividerHandle {
    pub(crate) const fn of(divider: &split_layout::Divider) -> Self {
        Self {
            split: Uuid {
                bytes: divider.split.bytes(),
            },
            #[expect(
                clippy::cast_possible_truncation,
                reason = "a child index counts siblings of one split; the decoder caps a tree far below 2^32"
            )]
            child_index: divider.child_index as u32,
            axis: if matches!(divider.axis, SplitAxis::Vertical) {
                1
            } else {
                0
            },
            rect: CRect::of(divider.rect),
            parent_span: divider.parent_span,
            flex_sum: divider.flex_sum,
            leading_weight: divider.leading_weight,
            trailing_weight: divider.trailing_weight,
        }
    }

    /// The rule's own shape again, so the two predicates read one implementation.
    const fn resolve(self) -> split_layout::Divider {
        split_layout::Divider {
            split: SplitNodeId::from_bytes(self.split.bytes),
            child_index: self.child_index as usize,
            axis: axis_from(self.axis),
            rect: self.rect.resolve(),
            parent_span: self.parent_span,
            flex_sum: self.flex_sum,
            leading_weight: self.leading_weight,
            trailing_weight: self.trailing_weight,
        }
    }
}

/// The band thickness a seam is drawn and hit with.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_divider_thickness() -> f64 {
    split_layout::DIVIDER_THICKNESS
}

/// Every seam of `nodes` solved into `rect`, in pre-order.
///
/// Returns the seam count NEEDED, or 0 for a tree the walk could not rebuild — the same answer a
/// single leaf gives, and the right one either way: nothing to drag.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`
/// [`DividerHandle`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_dividers(
    nodes: *const TreeNode,
    count: usize,
    rect: CRect,
    thickness: f64,
    out: *mut DividerHandle,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return 0;
        };
        let handles: Vec<DividerHandle> = split_layout::dividers(&root, rect.resolve(), thickness)
            .iter()
            .map(DividerHandle::of)
            .collect();
        if handles.len() > cap || out.is_null() {
            return handles.len();
        }
        // SAFETY: `handles.len() <= cap`, `out` is writable for `cap` by the caller's obligation,
        // and `handles` was allocated inside this call so it cannot overlap.
        core::ptr::copy_nonoverlapping(handles.as_ptr(), out, handles.len());
        handles.len()
    }
}

/// Whether `handle` can still be dragged toward one of its children — the hover cursor's one-way
/// versus two-way answer, from the same floor the drag clamps at.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_divider_can_move(handle: DividerHandle, toward_leading: bool) -> bool {
    let divider = handle.resolve();
    if toward_leading {
        divider.can_move_toward_leading()
    } else {
        divider.can_move_toward_trailing()
    }
}

/// A live drag's proposed leading weight, clamped so both panes keep their pixel floor.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_divider_clamped_weight(handle: DividerHandle, proposed: f64) -> f64 {
    handle.resolve().clamped_leading_weight(proposed)
}

/// One incremental pixel drag along `handle`'s axis, as the flex-weight delta to offset from.
///
/// The seam's own span and flex sum are already inside the handle, so a caller cannot pair one
/// split's span with another's partition. A handle without geometry answers `0`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_divider_weight_delta(handle: DividerHandle, pixel_increment: f64) -> f64 {
    handle.resolve().weight_delta(pixel_increment)
}

/// The live drag's ratio readout: the pair as whole percentages that sum to exactly 100.
///
/// `false` is a degenerate pair — a fixed side, or float residue — and then neither out-param is
/// touched: the readout is ABSENT rather than wrong. The two percentages cross as two numbers
/// rather than one plus a complement, so no caller can round the second one itself.
///
/// # Safety
/// `leading` and `trailing` must each be null or point to one writable `u32`, live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_divider_percents(
    handle: DividerHandle,
    leading: *mut u32,
    trailing: *mut u32,
) -> bool {
    let Some((lead, trail)) = handle.resolve().split_percents() else {
        return false;
    };
    // SAFETY: the caller's obligations, restated above.
    unsafe {
        if !leading.is_null() {
            leading.write(lead);
        }
        if !trailing.is_null() {
            trailing.write(trail);
        }
    }
    true
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
    // SAFETY: each pointer is null or writable for what its obligation says, and both source
    // vectors were allocated inside this call so neither can overlap a destination.
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

// MARK: The repair pass a loader runs
//
// ## Why this door exists at all
// `TreeWorkspace::normalized` ran in BOTH languages until 2026-08-20, and the two did not shadow
// each other because they fired on different events: the Swift copy on file load, the Rust one on
// every intent. So launch-time repair and gesture-time repair reached different trees for the same
// input, and a workspace that closed cleanly came back subtly different after a relaunch. Four
// disagreements were live — which panes count as VIDEO (`kind == .desktop` against
// `PaneKind::is_video`), how one is REMOVED (a close intent per id against pruning the tree), where
// a re-seeded identity comes from, and which leaf a dangling focus falls back to. `docs/55` §8 is
// the row this closes.
//
// ## It rides the document's own bytes, as the intent applier does
// A `TreeWorkspace` is a split tree, and §4b's argument applies unchanged: there is no `#[repr(C)]`
// flattening of one that is not a second grammar to keep in step. It does not need one — the
// topology already HAS a byte encoding, so the cells go in as the flat `(CEntry, blob)` pairs
// `slopdesk_ws_encode_snapshot` takes and the repaired tree comes back as an encoded snapshot the
// caller reads with `slopdesk_ws_decode_snapshot`.
//
// ## The one shape that encoding cannot carry, stated out loud
// A session with NO usable tab is dropped by the document ingest, on BOTH sides
// (`WorkspaceTopology::from_document` here, `WorkspaceTopology.init?(entries:)` in Swift) —
// rightly, because a host push naming a tabless session is describing nothing, and minting a tab
// there would invent a workspace the host never published. A REPAIR wants the opposite answer: the
// session's name and its detached panes are still worth keeping, so `normalizing_active` re-seeds
// it a tab. That case therefore cannot reach this door, and the caller repairs it before encoding.
// It is the only part of the pass that did not cross, it is named in `docs/55` §8 and pinned by
// `slopdesk-invariants`, and the fix that removes it is a whole-`TreeWorkspace` codec in
// `slopdesk_workspace::persist` — which `derived_split_id`'s `## Owed` note is already headed for.
//
// A document with no workspace in it AT ALL does cross, and answers the re-seeded default: that is
// `normalizing_active`'s own `sessions.is_empty()` branch, reached by handing it an empty
// workspace, rather than a default this shim decided on.

/// The caller's pool of pre-minted identities, handed out in order.
///
/// This crate holds no entropy and [`slopdesk_ids::identity`] explains why — every repair
/// here has to be replayable, so the runtime that owns the randomness supplies the ids and a test
/// supplies a counter. One cursor across all four kinds rather than four, so a pass that takes a
/// tab and a split gets two DIFFERENT ids.
///
/// A pool that runs dry repeats its last entry rather than panicking. The caller's obligation is
/// [`slopdesk_ws_normalize_minted_ids`], and repeating is what this boundary owes a caller who got
/// their own arithmetic wrong: a refusal they can see in the tree, not a process that is gone.
pub(crate) struct MintedPool<'a> {
    pub(crate) ids: &'a [Uuid],
    pub(crate) next: usize,
}

impl MintedPool<'_> {
    pub(crate) fn take(&mut self) -> [u8; 16] {
        let picked = self.ids.get(self.next).or_else(|| self.ids.last());
        self.next += 1;
        picked.map_or([0; 16], |id| id.bytes)
    }
}

impl IdSource for MintedPool<'_> {
    fn pane(&mut self) -> PaneId {
        PaneId::from_bytes(self.take())
    }

    fn tab(&mut self) -> TabId {
        TabId::from_bytes(self.take())
    }

    fn session(&mut self) -> SessionId {
        SessionId::from_bytes(self.take())
    }

    fn split(&mut self) -> SplitNodeId {
        SplitNodeId::from_bytes(self.take())
    }
}

/// The identity pool one repair can spend over a workspace of that shape, exported rather than
/// transcribed.
///
/// A pool one short does not fail — it REPEATS an identity, and two tabs born with one id surfaces
/// days later as a tab that will not close. So the arithmetic lives in the crate that spends the
/// ids, and a caller asks.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_normalize_minted_ids(sessions: usize, detached: usize) -> usize {
    tree_ops::RepairPass::minted_ids(sessions, detached)
}

/// How many repair passes there are, so a caller can neither name one this build lacks nor miss one
/// it grew.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_normalize_pass_count() -> usize {
    tree_ops::RepairPass::ALL.len()
}

/// Runs one repair pass over a document's topology, answering the repaired cells as an encoded
/// snapshot.
///
/// `pass` is [`tree_ops::RepairPass`]'s arm order: 0 the spec table, 1 the selections, 2 both in
/// the order a load applies them, 3 the whole launch restore. A byte naming no pass answers 0 — a
/// refusal, never a silently different repair, because "specs only" and "the launch restore" differ
/// by whether a detached pane comes back.
///
/// `entries`/`blob` are the document in `slopdesk_ws_encode_snapshot`'s flat form. `minted` is the
/// identity pool, sized by [`slopdesk_ws_normalize_minted_ids`].
///
/// The return is the encoded snapshot's byte count under §4's convention — write nothing when it
/// does not fit, answer what was needed. `0` is the refusal above and nothing else: every pass over
/// every document answers a workspace, because a document with none in it is answered with the
/// re-seeded default rather than with silence.
///
/// # Safety
/// `entries` must be null or point to `entry_count` live [`CEntry`]s; `blob` null or to `blob_len`
/// live bytes; `minted` null or to `minted_count` live [`Uuid`]s; `out` null or writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_normalize(
    pass: c_uchar,
    entries: *const CEntry,
    entry_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    minted: *const Uuid,
    minted_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(pass) = tree_ops::RepairPass::from_byte(pass) else {
        return 0;
    };
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes, pool) = unsafe {
        (
            borrow_array(entries, entry_count),
            borrow(blob, blob_len),
            borrow_array(minted, minted_count),
        )
    };
    let mut ids = MintedPool { ids: pool, next: 0 };
    let state = crate::workspace_intent::document(cells, bytes);
    // No workspace in the document is not an error and not an empty answer: it is the input
    // `normalizing_active` re-seeds from, so it is handed over as one rather than answered here.
    let mut topology = state
        .topology()
        .unwrap_or_else(|| WorkspaceTopology::new(TreeWorkspace::new(Vec::new(), None)));
    topology.tree = tree_ops::repaired(&topology.tree, pass, &mut ids);
    let answer = wire_codec::encode_snapshot(&HostWorkspaceState::from_entries(topology.entries()));
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// Whether a `pane/kind` byte names a VIDEO pane — one that rides the shared UDP flow, counts
/// against the live-video cap, and never restores across a relaunch.
///
/// A predicate rather than a case list because it is what the launch restore DROPS by, and a second
/// spelling of it is exactly the drift `docs/55` §8 records: Swift asked `kind == .desktop` where
/// this crate asks `PaneKind::is_video`, which selects the same panes today and would stop the day
/// a third video-ish kind is added on one side only. A byte this build has no kind for reads as a
/// terminal — the degradation `WorkspacePaneKindTag` already picks — so an unknown kind is a
/// degraded pane rather than a stream opened for a window that will never exist.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_kind_is_video(kind: c_uchar) -> bool {
    PaneKind::from_byte(kind).is_video()
}

/// How many pane kinds there are.
///
/// Exported so a caller can WALK the vocabulary rather than name its members: a test that iterates
/// `0..count` against [`slopdesk_ws_pane_kind_is_video`] fails the day a third kind lands on one
/// side only, which counting Swift's cases against this crate's cannot see.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_kind_count() -> usize {
    PaneKind::ALL.len()
}

/// The title a re-seeded pane takes, §4-shaped.
///
/// Asked for rather than transcribed for the reason every constant here is: a caller comparing
/// against its own copy passes on a default this crate stopped producing, and the fresh-workspace
/// shape test is precisely a comparison against this string.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_default_pane_title(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(workspace::DEFAULT_PANE_TITLE.as_bytes(), out, cap) }
}

/// The name a fresh workspace's first session takes, §4-shaped. Asked for
/// [`slopdesk_ws_default_pane_title`]'s reason.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_default_session_name(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(workspace::DEFAULT_SESSION_NAME.as_bytes(), out, cap) }
}

/// The title a minted desktop pane takes, §4-shaped.
///
/// The third of the seeded names, and the one with two minters: the client makes a desktop pane on
/// a gesture and the wire crate makes one while applying a document. Both take the word from here,
/// so a rename cannot leave a session holding two differently-titled desktop panes that the user
/// made the same way.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_ws_default_desktop_pane_title(
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(workspace::DEFAULT_DESKTOP_PANE_TITLE.as_bytes(), out, cap) }
}

// MARK: The client's workspace FILE
//
// ## Why this is a door rather than a shape
// `slopdesk_workspace::persist` is a complete repairing decoder for `workspace.json`, and it sat
// with 22 tests and no caller while `SplitNode+Codable.swift` and four `Codable` conformances ran
// instead. They had already drifted, and in the direction that costs a person something they can
// see: an id-less split is DERIVED here from its place in the tree, where Swift's `??
// SplitNodeID()` minted a fresh uuid on every load — so a `splitNode/<id>/weight` cell written
// before a relaunch was orphaned after it, and every divider the person had dragged went back to
// the default with nothing logged. `docs/55` §8's `derived_split_id` row is what this closes.
//
// ## It rides the document's own bytes, as its two neighbours do
// The same arrangement `slopdesk_ws_apply_intent`, `slopdesk_ws_state_file_*` and
// `slopdesk_ws_normalize` use, for the same reason: a `TreeWorkspace` is a split tree and there is
// no `#[repr(C)]` flattening of one that is not a second grammar to keep in step. So the workspace
// goes IN as the flat `(CEntry, blob)` cells `slopdesk_ws_encode_snapshot` already takes, and a
// decoded file comes back OUT as an encoded snapshot the caller reads with
// `slopdesk_ws_decode_snapshot`. Nothing new travels in either direction.
//
// ## The decode REPAIRS before it answers, and that is forced rather than chosen
// The document's cell encoding cannot spell a session with no tab or a leaf with no spec — its
// ingest drops the first and invents the second, on both sides, because a host push naming a
// tabless session is describing nothing. A file can hold both. So the decode ends where
// `TreeWorkspace::normalized` ends, which is where the launch path already ended, and the shape the
// crossing cannot carry never reaches the crossing. That is also what `slopdesk_ws_normalize`'s own
// note says will remove `withTheDocumentsBlindSpotsClosed` from the FILE path.
//
// ## No id is minted on this side, and the two kinds are minted differently on purpose
// The identities a repair spends come from the caller's pool, sized by
// `slopdesk_ws_workspace_file_minted_ids` — a PaneId is the join to the registry that owns a
// process, so a name derived from the file's own contents is one two launches could both produce.
// A SplitNodeId is the opposite case and is derived inside the crate, because it names a divider
// group and a persisted weight cell only keeps pointing at its seam if the name is stable. Both
// rules live in `persist.rs`; neither is decided here.

/// The identities a decode of these bytes can spend.
///
/// Asked rather than transcribed for the reason every pool size in this crate is: a pool one short
/// does not fail, it REPEATS an identity, and two panes sharing one is a pane that reattaches to a
/// process it never opened. This one takes the FILE rather than a shape, because the shape is
/// exactly what the caller does not know yet.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_minted_ids(bytes: *const c_uchar, len: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    persist::minted_ids_for(input)
}

/// Whether these bytes are the THROWAWAY DEFAULT a `New Window` launch autosaves.
///
/// The FILE goes in rather than a decoded shape, and that is what the door buys: the caller's
/// alternative was to decode on its own side and compare the two seed names against literals, which
/// is the second spelling `slopdesk_ws_default_session_name` and `slopdesk_ws_default_pane_title`
/// exist to prevent — a copy of either would keep answering `true` for a default this build had
/// stopped writing.
///
/// `false` is "not PROVABLY the default": unreadable bytes, a foreign `schemaVersion` and an
/// over-large file all land there, so a file this build cannot read is preserved aside rather than
/// skipped. It is not a claim that the file holds a real session.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_is_default_shape(
    bytes: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let input = unsafe { borrow(bytes, len) };
    persist::is_default_file_shape(input)
}

/// The file's bytes for a workspace, under §4's convention.
///
/// `entries`/`blob` are the document's cells in `slopdesk_ws_encode_snapshot`'s flat form. Only the
/// topology half is read — the file is the client's LAYOUT, and liveness has no business on a disk
/// that outlives the process it describes. Encoding cannot fail, so there is no status here.
///
/// The answer is UTF-8 JSON with sorted keys and a trailing newline, so two saves of one value are
/// byte-identical and the file diffs cleanly.
///
/// `schema_version` is passed rather than derived, and that is the whole reason it is a parameter:
/// the cells carry a SHAPE, and a version is a property of the FILE, so a tree rebuilt from them
/// wears whatever [`TreeWorkspace::new`] stamps — today's `CURRENT_SCHEMA_VERSION`. Deriving it
/// here would make every save quietly re-stamp a workspace as the schema this build happens to
/// read, which is precisely the claim the load path's version check exists to be able to
/// disbelieve.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `blob` null or to `blob_len` live
/// bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_encode(
    entries: *const CEntry,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    schema_version: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes) = unsafe { (borrow_array(entries, count), borrow(blob, blob_len)) };
    let state = crate::workspace_intent::document(cells, bytes);
    // A document with no workspace in it writes an empty one rather than nothing at all: the file
    // has to be a file, and the load path answers its own default for one that names no session.
    let mut tree = state
        .topology()
        .map_or_else(|| TreeWorkspace::new(Vec::new(), None), |topology| topology.tree);
    tree.schema_version = schema_version;
    let text = persist::encode_file(&tree);
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// Reads a file back, answering the REPAIRED workspace as an encoded snapshot.
///
/// `bytes` is the file exactly as it came off disk. `minted` is the identity pool, sized by
/// [`slopdesk_ws_workspace_file_minted_ids`] over those same bytes. `status` receives the refusal
/// byte on EVERY path — `persist::NO_REFUSAL` when the load worked — so a caller that only wants
/// the verdict may pass a null `out` and read it there. `version` receives the version the file
/// CLAIMED, and only on the version-mismatch path; it is left untouched otherwise, because every
/// `i64` is a version somebody could have typed in and none of them could have meant "not about a
/// version".
///
/// The return is the encoded snapshot's byte count under §4's convention. A refusal answers 0, and
/// so nothing else does: the repair runs before the answer is written, and it re-seeds a workspace
/// that named nothing, so every load that got past the refusal has at least one session to encode.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `minted` null or to `minted_count` live
/// [`Uuid`]s; `status` null or writable for one byte; `version` null or writable for one `int64_t`;
/// `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_workspace_file_decode(
    bytes: *const c_uchar,
    len: usize,
    minted: *const Uuid,
    minted_count: usize,
    status: *mut c_uchar,
    version: *mut i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (input, pool) = unsafe { (borrow(bytes, len), borrow_array(minted, minted_count)) };
    let mut ids = MintedPool { ids: pool, next: 0 };
    match persist::decode_file(input, &mut ids) {
        Ok(tree) => {
            // SAFETY: null or, by the caller's obligation, writable for one byte.
            unsafe { write_status(status, persist::NO_REFUSAL) };
            let cells = HostWorkspaceState::from_entries(WorkspaceTopology::new(tree).entries());
            let answer = wire_codec::encode_snapshot(&cells);
            // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
            unsafe { deliver(&answer, out, cap) }
        },
        Err(refusal) => {
            // SAFETY: each pointer is null or, by the caller's obligation, writable for its width.
            unsafe {
                write_status(status, refusal.code());
                write_version(version, refusal.claimed_version());
            }
            0
        },
    }
}

/// The refusal byte for one outcome, by index.
///
/// `0` is the load that worked, then [`persist::FileError`]'s own arm order — malformed, version
/// mismatch, too many panes. An index past the last answers the malformed byte, which refuses
/// rather than admits.
///
/// Exported rather than transcribed: a caller that wrote `case malformed = 1` beside this would be
/// a second copy of the numbering, and the arm it drifted on would turn a version this build cannot
/// read into a file kept aside under the wrong name — or not kept aside at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_workspace_file_status(index: c_uchar) -> c_uchar {
    match index {
        0 => persist::NO_REFUSAL,
        2 => persist::FileError::VersionMismatch(0).code(),
        3 => persist::FileError::TooManyPanes.code(),
        _ => persist::FileError::Malformed.code(),
    }
}

/// How many panes one workspace file may name before [`slopdesk_ws_workspace_file_decode`] refuses
/// it with index 3 of [`slopdesk_ws_workspace_file_status`].
///
/// Asked for rather than spelled twice, the rule every in-process cap in this header follows
/// (`slopdesk_ws_topology_ring_cap` carries the long version). This one is a REFUSAL threshold, so
/// the two copies drifting does not read as a disagreement: the near side would build a file it
/// believes fits, the far side would refuse it, and the user would meet a workspace reset to the
/// default with nothing anywhere saying why.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_workspace_file_max_panes() -> usize {
    persist::MAX_PANES
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::float_cmp,
    reason = "exact is the assertion: `CLAUDE.md` pins these results bit-exactly, so a tolerance here would \
              pass on the drift it exists to catch"
)]
#[expect(
    clippy::expect_used,
    reason = "a door that refuses its own fixture IS the report"
)]
mod tests {
    use core::ffi::c_uchar;

    use slopdesk_ids::{PaneId, SplitNodeId};
    use slopdesk_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

    use super::{
        CRect, CVideoTarget, DividerHandle, Frame, KeyedTab, Span, TreeNode, Uuid, decode_tree, encode_tree,
        slopdesk_ws_cwd_badge_path, slopdesk_ws_decode_video_target, slopdesk_ws_default_desktop_pane_title,
        slopdesk_ws_default_pane_title, slopdesk_ws_divider_can_move, slopdesk_ws_divider_clamped_weight,
        slopdesk_ws_divider_percents, slopdesk_ws_divider_thickness, slopdesk_ws_divider_weight_delta,
        slopdesk_ws_dividers, slopdesk_ws_encode_video_target, slopdesk_ws_focus_cycle,
        slopdesk_ws_focus_neighbor, slopdesk_ws_max_depth, slopdesk_ws_max_string_bytes,
        slopdesk_ws_min_weight, slopdesk_ws_normalize, slopdesk_ws_normalize_minted_ids,
        slopdesk_ws_normalize_pass_count, slopdesk_ws_pane_kind_count, slopdesk_ws_pane_kind_is_video,
        slopdesk_ws_project_key, slopdesk_ws_schema_version, slopdesk_ws_section_header,
        slopdesk_ws_section_precedes, slopdesk_ws_send_keys, slopdesk_ws_solve_layout,
        slopdesk_ws_successor_after_close, slopdesk_ws_tree_removing, slopdesk_ws_tree_splitting,
        slopdesk_ws_workspace_file_decode, slopdesk_ws_workspace_file_encode,
        slopdesk_ws_workspace_file_is_default_shape, slopdesk_ws_workspace_file_minted_ids,
        slopdesk_ws_workspace_file_status,
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
        // The trailing slash folds, which is what keeps a pane's directory and its git toplevel
        // from becoming two identically-titled sections.
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
    fn the_badge_door_carries_the_collapse_and_the_directory_marker_across() {
        let badge = |text| {
            transform(
                |bytes, len, out, cap| unsafe { slopdesk_ws_cwd_badge_path(bytes, len, out, cap) },
                text,
            )
        };
        assert_eq!(badge("/Users/me/slop-desk"), "~/slop-desk/");
        assert_eq!(badge("/etc"), "/etc/");
        assert!(
            badge("").is_empty(),
            "an empty path has an empty badge, not a slash"
        );
    }

    #[test]
    fn a_short_badge_buffer_is_told_the_length_it_should_have_lent() {
        let path = b"/Users/me/slop-desk";
        let needed =
            unsafe { slopdesk_ws_cwd_badge_path(path.as_ptr(), path.len(), core::ptr::null_mut(), 0) };
        assert_eq!(needed, "~/slop-desk/".len());
        let mut cramped = [0_u8; 4];
        assert_eq!(
            unsafe {
                slopdesk_ws_cwd_badge_path(path.as_ptr(), path.len(), cramped.as_mut_ptr(), cramped.len())
            },
            needed,
            "the answer is the length NEEDED, and nothing is written",
        );
        assert_eq!(cramped, [0; 4]);
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

    #[test]
    fn the_same_walk_answers_the_seams_between_those_tiles() {
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
        let bound = rect(0.0, 0.0, 400.0, 200.0);
        let needed = unsafe {
            slopdesk_ws_dividers(nodes.as_ptr(), nodes.len(), bound, 16.0, core::ptr::null_mut(), 0)
        };
        assert_eq!(needed, 1, "two columns share one seam");
        let mut out = [DividerHandle {
            split: id(0),
            child_index: 0,
            axis: 0,
            rect: rect(0.0, 0.0, 0.0, 0.0),
            parent_span: 0.0,
            flex_sum: 0.0,
            leading_weight: 0.0,
            trailing_weight: 0.0,
        }; 2];
        let written = unsafe {
            slopdesk_ws_dividers(
                nodes.as_ptr(),
                nodes.len(),
                bound,
                16.0,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 1);
        let seam = out[0];
        assert_eq!(seam.split, id(9), "the seam names the split that owns it");
        assert_eq!(seam.axis, 0);
        assert_eq!(seam.rect.x, 200.0 - 8.0, "the band is centred on the cut");
        assert_eq!(seam.rect.width, 16.0);
        assert_eq!(seam.parent_span, 400.0);
        assert_eq!((seam.leading_weight, seam.trailing_weight), (1.0, 1.0));
        assert!(slopdesk_ws_divider_can_move(seam, true));
        assert!(slopdesk_ws_divider_can_move(seam, false));
        // Span 400 at a flex sum of 2: the 160 pt column floor is weight 0.8, either side.
        assert_eq!(slopdesk_ws_divider_clamped_weight(seam, 0.0), 0.8);
        assert_eq!(slopdesk_ws_divider_clamped_weight(seam, 9.0), 1.2);
        assert_eq!(slopdesk_ws_divider_thickness(), 16.0);
        // The drag reads the seam's OWN span and flex sum out of the handle it was given: 120 px
        // over 400 pt at a flex sum of 2 is 0.6 of weight, which renders as 120 pt of movement.
        assert_eq!(slopdesk_ws_divider_weight_delta(seam, 120.0), 0.6);

        let (mut lead, mut trail) = (0, 0);
        // SAFETY: two live local u32s, borrowed for the duration of the call.
        let readable = unsafe { slopdesk_ws_divider_percents(seam, &raw mut lead, &raw mut trail) };
        assert!(readable);
        assert_eq!((lead, trail), (50, 50));

        let fixed_side = DividerHandle {
            leading_weight: 0.0,
            ..seam
        };
        // SAFETY: the same two locals, still live.
        let absent = unsafe { slopdesk_ws_divider_percents(fixed_side, &raw mut lead, &raw mut trail) };
        assert!(!absent, "a fixed side has no ratio to read");
        assert_eq!((lead, trail), (50, 50), "a refusal writes nothing");
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

    // ---------------------------------------------------------------------------------------- //
    // The repair pass
    // ---------------------------------------------------------------------------------------- //

    /// A document's cells in the flat `(CEntry, blob)` form the door takes — the encoding under
    /// test as much as anything else.
    fn flat_document(
        topology: &slopdesk_wire::document::topology::WorkspaceTopology,
    ) -> (Vec<super::CEntry>, Vec<u8>) {
        let mut blob = Vec::new();
        let cells = slopdesk_wire::document::state::HostWorkspaceState::from_entries(topology.entries())
            .sorted_entries()
            .into_iter()
            .map(|entry| {
                let offset = blob.len();
                blob.extend_from_slice(&entry.value);
                super::CEntry {
                    kind: entry.key.kind,
                    field: entry.key.field,
                    object: Uuid {
                        bytes: entry.key.object_id,
                    },
                    value: Span {
                        offset,
                        len: blob.len() - offset,
                        present: true,
                    },
                }
            })
            .collect();
        (cells, blob)
    }

    /// One repair through the C signature, sized the way §4 says to: probe, grow, call again.
    fn normalize(
        pass: u8,
        cells: &[super::CEntry],
        blob: &[u8],
        pool: &[Uuid],
    ) -> Option<slopdesk_wire::document::topology::WorkspaceTopology> {
        // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
        // with.
        let needed = unsafe {
            slopdesk_ws_normalize(
                pass,
                cells.as_ptr(),
                cells.len(),
                blob.as_ptr(),
                blob.len(),
                pool.as_ptr(),
                pool.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        if needed == 0 {
            return None;
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is now exactly `needed` bytes and every input pointer is still live.
        let written = unsafe {
            slopdesk_ws_normalize(
                pass,
                cells.as_ptr(),
                cells.len(),
                blob.as_ptr(),
                blob.len(),
                pool.as_ptr(),
                pool.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed, "the sized call disagreed with the probe");
        let state = slopdesk_wire::document::codec::decode_snapshot(&out).ok()?;
        state.topology()
    }

    fn pool() -> Vec<Uuid> {
        (0..slopdesk_ws_normalize_minted_ids(4, 4))
            .map(|index| {
                Uuid {
                    bytes: [0xB0_u8.wrapping_add(u8::try_from(index).unwrap_or(0)); 16],
                }
            })
            .collect()
    }

    #[test]
    fn a_repair_answers_the_documents_own_encoding_and_nothing_else() {
        let broken = slopdesk_wire::document::topology::WorkspaceTopology::new(
            slopdesk_tree::workspace::TreeWorkspace::single_pane(
                slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
                slopdesk_ids::identity::TabId::from_bytes([1; 16]),
                PaneId::from_bytes([1; 16]),
                slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
            ),
        );
        let (cells, blob) = flat_document(&broken);
        let repaired = normalize(2, &cells, &blob, &pool()).expect("a repaired document");
        assert_eq!(repaired.tree.all_pane_ids(), vec![PaneId::from_bytes([1; 16])]);
        assert!(repaired.tree.invariant_holds());
    }

    #[test]
    fn a_pass_byte_this_build_does_not_know_is_a_refusal_rather_than_a_different_repair() {
        // The one 0 this door answers. Every real pass answers a workspace — even over a document
        // with none in it, which is re-seeded rather than refused — so the refusal cannot be
        // mistaken for a repair that came back empty.
        let empty: Vec<super::CEntry> = Vec::new();
        assert!(normalize(200, &empty, &[], &pool()).is_none());
        let re_seeded = normalize(2, &empty, &[], &pool()).expect("an empty document is re-seeded");
        assert_eq!(re_seeded.tree.sessions.len(), 1);
        assert_eq!(re_seeded.tree.all_pane_ids().len(), 1);
    }

    #[test]
    fn a_probe_that_did_not_fit_leaves_the_buffer_untouched() {
        let topology = slopdesk_wire::document::topology::WorkspaceTopology::new(
            slopdesk_tree::workspace::TreeWorkspace::single_pane(
                slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
                slopdesk_ids::identity::TabId::from_bytes([1; 16]),
                PaneId::from_bytes([1; 16]),
                slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
            ),
        );
        let (cells, blob) = flat_document(&topology);
        let ids = pool();
        let mut out = [0_u8; 8];
        // SAFETY: every pointer is a live local's; `out` is deliberately too small.
        let needed = unsafe {
            slopdesk_ws_normalize(
                2,
                cells.as_ptr(),
                cells.len(),
                blob.as_ptr(),
                blob.len(),
                ids.as_ptr(),
                ids.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert!(needed > out.len());
        assert!(out.iter().all(|byte| *byte == 0), "a short call still wrote");
    }

    #[test]
    fn the_video_predicate_covers_the_whole_kind_vocabulary() {
        // Walked rather than named: a third kind added to the crate makes this loop ask about a
        // byte no caller has a case for, which is exactly the drift docs/55 §8 records. A byte past
        // the vocabulary reads as a terminal, so an unknown kind degrades rather than opening a
        // stream for a window that will never exist.
        let count = slopdesk_ws_pane_kind_count();
        assert_eq!(count, slopdesk_tree::PaneKind::ALL.len());
        for (index, kind) in slopdesk_tree::PaneKind::ALL.into_iter().enumerate() {
            let byte = u8::try_from(index).unwrap_or(u8::MAX);
            assert_eq!(slopdesk_ws_pane_kind_is_video(byte), kind.is_video());
        }
        assert!(!slopdesk_ws_pane_kind_is_video(200));
    }

    #[test]
    fn the_exported_pass_count_and_pool_size_are_the_crates_own() {
        assert_eq!(
            slopdesk_ws_normalize_pass_count(),
            slopdesk_tree::tree_ops::RepairPass::ALL.len(),
        );
        assert_eq!(
            slopdesk_ws_normalize_minted_ids(3, 5),
            slopdesk_tree::tree_ops::RepairPass::minted_ids(3, 5),
        );
    }

    #[test]
    fn the_two_split_tree_metrics_are_the_crates_own() {
        assert_eq!(slopdesk_ws_min_weight(), slopdesk_tree::split_tree::MIN_WEIGHT);
        assert_eq!(slopdesk_ws_max_depth(), slopdesk_tree::split_tree::MAX_DEPTH);
    }

    #[test]
    fn the_exported_schema_version_is_the_crates_own() {
        assert_eq!(
            slopdesk_ws_schema_version(),
            slopdesk_tree::CURRENT_SCHEMA_VERSION
        );
    }

    #[test]
    fn the_exported_string_bound_is_the_codecs_own() {
        assert_eq!(
            slopdesk_ws_max_string_bytes(),
            slopdesk_workspace::state_codec::MAX_STRING_BYTES
        );
    }

    // ---------------------------------------------------------------------------------------- //
    // The client's workspace file
    // ---------------------------------------------------------------------------------------- //

    /// One save through the C signature, sized the way §4 says to: probe, grow, call again.
    fn file_encode(cells: &[super::CEntry], blob: &[u8]) -> Vec<u8> {
        // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
        // with.
        let needed = unsafe {
            slopdesk_ws_workspace_file_encode(
                cells.as_ptr(),
                cells.len(),
                blob.as_ptr(),
                blob.len(),
                slopdesk_tree::CURRENT_SCHEMA_VERSION,
                core::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is now exactly `needed` bytes and every input pointer is still live.
        let written = unsafe {
            slopdesk_ws_workspace_file_encode(
                cells.as_ptr(),
                cells.len(),
                blob.as_ptr(),
                blob.len(),
                slopdesk_tree::CURRENT_SCHEMA_VERSION,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed, "the sized call disagreed with the probe");
        out
    }

    /// One load through the C signature, with the pool the door itself sized, answering everything
    /// the door writes: the status byte, the claimed version, and the workspace if there is one.
    fn file_decode(
        bytes: &[u8],
        seed: u8,
    ) -> (
        c_uchar,
        i64,
        Option<slopdesk_wire::document::topology::WorkspaceTopology>,
    ) {
        // SAFETY: `bytes` is a live local's.
        let ids: Vec<Uuid> =
            (0..unsafe { slopdesk_ws_workspace_file_minted_ids(bytes.as_ptr(), bytes.len()) })
                .map(|index| {
                    Uuid {
                        bytes: [seed.wrapping_add(u8::try_from(index).unwrap_or(0)); 16],
                    }
                })
                .collect();
        let (mut status, mut version) = (u8::MAX, i64::MIN);
        // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
        // with.
        let needed = unsafe {
            slopdesk_ws_workspace_file_decode(
                bytes.as_ptr(),
                bytes.len(),
                ids.as_ptr(),
                ids.len(),
                &raw mut status,
                &raw mut version,
                core::ptr::null_mut(),
                0,
            )
        };
        if needed == 0 {
            return (status, version, None);
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is now exactly `needed` bytes and every input pointer is still live.
        let written = unsafe {
            slopdesk_ws_workspace_file_decode(
                bytes.as_ptr(),
                bytes.len(),
                ids.as_ptr(),
                ids.len(),
                &raw mut status,
                &raw mut version,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed, "the sized call disagreed with the probe");
        let state = slopdesk_wire::document::codec::decode_snapshot(&out).ok();
        (status, version, state.and_then(|read| read.topology()))
    }

    /// A file naming a split the writer never named — the case the whole port turns on.
    const UNNAMED_SPLIT_FILE: &str = r#"{
      "schemaVersion": 12,
      "sessions": [
        {
          "id": { "raw": "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A" },
          "name": "work",
          "activeTabIndex": 0,
          "tabs": [
            {
              "id": { "raw": "0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B" },
              "title": "",
              "root": { "split": {
                "axis": "horizontal",
                "children": [
                  { "node": { "leaf": { "raw": "01010101-0101-0101-0101-010101010101" } } },
                  { "node": { "leaf": { "raw": "02020202-0202-0202-0202-020202020202" } } }
                ]
              } }
            }
          ],
          "specs": [
            { "pane": { "raw": "01010101-0101-0101-0101-010101010101" },
              "spec": { "kind": "terminal", "title": "one" } },
            { "pane": { "raw": "02020202-0202-0202-0202-020202020202" },
              "spec": { "kind": "terminal", "title": "two" } }
          ]
        }
      ]
    }"#;

    /// Every divider group in a tree, in visual order.
    fn seams(node: &SplitNode) -> Vec<SplitNodeId> {
        match *node {
            SplitNode::Leaf(_) => Vec::new(),
            SplitNode::Split { id, ref children, .. } => {
                core::iter::once(id)
                    .chain(children.iter().flat_map(|child| seams(&child.node)))
                    .collect()
            },
        }
    }

    fn tree_seams(topology: &slopdesk_wire::document::topology::WorkspaceTopology) -> Vec<SplitNodeId> {
        topology
            .tree
            .sessions
            .iter()
            .flat_map(|session| session.tabs.iter().flat_map(|tab| seams(&tab.root)))
            .collect()
    }

    #[test]
    fn a_saved_workspace_comes_back_the_same_arrangement_through_the_two_doors() {
        let topology = slopdesk_wire::document::topology::WorkspaceTopology::new(
            slopdesk_tree::workspace::TreeWorkspace::single_pane(
                slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
                slopdesk_ids::identity::TabId::from_bytes([1; 16]),
                PaneId::from_bytes([9; 16]),
                slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
            ),
        );
        let (cells, blob) = flat_document(&topology);
        let saved = file_encode(&cells, &blob);
        assert!(
            core::str::from_utf8(&saved).is_ok_and(|text| text.ends_with('\n')),
            "the file is text, and text on this project's disks ends in a newline",
        );
        let (status, _, loaded) = file_decode(&saved, 0xC0);
        let read = loaded.expect("a file this build wrote is a file this build reads");
        assert_eq!(status, slopdesk_ws_workspace_file_status(0));
        assert_eq!(read.tree.sessions.len(), 1);
        assert_eq!(read.tree.all_pane_ids(), vec![PaneId::from_bytes([9; 16])]);
        assert_eq!(
            read.tree.sessions.first().map(|session| session.name.clone()),
            topology.tree.sessions.first().map(|session| session.name.clone()),
        );
    }

    /// **The defect the port exists to close, pinned at the boundary Swift crosses.** Two loads of
    /// one file, from two DIFFERENT identity pools, still name the seam the same thing — so the
    /// `splitNode/<id>/weight` cell a person's drag wrote before a relaunch still points at their
    /// divider after it. Swift's `?? SplitNodeID()` minted a fresh uuid here and lost every one.
    #[test]
    fn two_loads_of_one_file_name_its_dividers_the_same_way() {
        let bytes = UNNAMED_SPLIT_FILE.as_bytes();
        let first = file_decode(bytes, 0x10)
            .2
            .expect("the first load answers a workspace");
        let second = file_decode(bytes, 0x90)
            .2
            .expect("the second load answers one too");
        assert!(!tree_seams(&first).is_empty(), "the fixture has a divider in it");
        assert_eq!(
            tree_seams(&first),
            tree_seams(&second),
            "a divider's name is a function of the file, not of the pool the load was handed",
        );
        assert_eq!(
            first.tree.all_pane_ids(),
            second.tree.all_pane_ids(),
            "a pane the file named keeps that name — the pool pays only for the ones it did not",
        );
    }

    #[test]
    fn a_version_this_build_does_not_speak_is_refused_by_a_byte_that_names_the_version() {
        let text = UNNAMED_SPLIT_FILE.replace("\"schemaVersion\": 12", "\"schemaVersion\": 99");
        let (status, version, loaded) = file_decode(text.as_bytes(), 0x10);
        assert!(loaded.is_none(), "a file this build cannot read answers nothing");
        assert_eq!(status, slopdesk_ws_workspace_file_status(2));
        assert_eq!(
            version, 99,
            "a caller that cannot log the version it was handed cannot tell the person anything",
        );
    }

    #[test]
    fn a_refusal_that_is_not_about_a_version_leaves_the_version_alone() {
        // Every `i64` is a version somebody could have typed, so there is no byte pattern that
        // means "not about a version" — the door's answer is to write nothing at all.
        let (status, version, loaded) = file_decode(b"not a workspace", 0x10);
        assert!(loaded.is_none());
        assert_eq!(status, slopdesk_ws_workspace_file_status(1));
        assert_eq!(version, i64::MIN, "the untouched local");
    }

    #[test]
    fn a_null_out_still_answers_the_status_and_the_size() {
        let bytes = UNNAMED_SPLIT_FILE.as_bytes();
        // SAFETY: `bytes` is a live local's.
        let count = unsafe { slopdesk_ws_workspace_file_minted_ids(bytes.as_ptr(), bytes.len()) };
        let ids = vec![Uuid { bytes: [7; 16] }; count];
        let mut status = u8::MAX;
        // SAFETY: the null `out` and `version` §4 says a verdict-only caller may pass.
        let needed = unsafe {
            slopdesk_ws_workspace_file_decode(
                bytes.as_ptr(),
                bytes.len(),
                ids.as_ptr(),
                ids.len(),
                &raw mut status,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert!(needed > 0);
        assert_eq!(status, slopdesk_ws_workspace_file_status(0));
    }

    /// The shape door reads the seed names off the crate, so this asks it about a file the crate
    /// itself wrote — a literal here would be the second spelling the door exists to delete.
    #[test]
    fn the_shape_door_recognises_the_file_a_new_window_launch_autosaves() {
        let default =
            slopdesk_workspace::persist::encode_file(&slopdesk_tree::workspace::TreeWorkspace::single_pane(
                slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
                slopdesk_ids::identity::TabId::from_bytes([2; 16]),
                PaneId::from_bytes([3; 16]),
                slopdesk_tree::session::PaneSpec::new(
                    slopdesk_tree::session::PaneKind::Terminal,
                    slopdesk_tree::workspace::DEFAULT_PANE_TITLE,
                ),
            ));
        // SAFETY: both are live locals'.
        let (throwaway, kept) = unsafe {
            (
                slopdesk_ws_workspace_file_is_default_shape(default.as_ptr(), default.len()),
                slopdesk_ws_workspace_file_is_default_shape(
                    UNNAMED_SPLIT_FILE.as_ptr(),
                    UNNAMED_SPLIT_FILE.len(),
                ),
            )
        };
        assert!(throwaway, "the re-seed's own output is the throwaway");
        assert!(!kept, "a file with a split in it is a layout somebody made");
        // SAFETY: a live local's, and the null probe §4 admits everywhere.
        let unreadable = unsafe {
            (
                slopdesk_ws_workspace_file_is_default_shape(b"not a workspace".as_ptr(), 15),
                slopdesk_ws_workspace_file_is_default_shape(core::ptr::null(), 0),
            )
        };
        assert_eq!(
            unreadable,
            (false, false),
            "false is `not provably the default`, so an unreadable file is preserved aside",
        );
    }

    #[test]
    fn a_save_that_did_not_fit_leaves_the_buffer_untouched() {
        let topology = slopdesk_wire::document::topology::WorkspaceTopology::new(
            slopdesk_tree::workspace::TreeWorkspace::single_pane(
                slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
                slopdesk_ids::identity::TabId::from_bytes([1; 16]),
                PaneId::from_bytes([1; 16]),
                slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
            ),
        );
        let (cells, blob) = flat_document(&topology);
        let mut out = [0_u8; 8];
        // SAFETY: every pointer is a live local's; `out` is deliberately too small.
        let needed = unsafe {
            slopdesk_ws_workspace_file_encode(
                cells.as_ptr(),
                cells.len(),
                blob.as_ptr(),
                blob.len(),
                slopdesk_tree::CURRENT_SCHEMA_VERSION,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert!(needed > out.len());
        assert!(out.iter().all(|byte| *byte == 0), "a short call still wrote");
    }

    #[test]
    fn a_document_with_no_workspace_in_it_is_still_written_as_a_file() {
        // The save path cannot answer "nothing" — a client that had no arrangement to write still
        // has to leave a file the next launch can read. Reading that file back is not a refusal
        // either: an empty session list is a well-formed file, and the repair seeds the one session
        // and one pane a launch needs, from the pool the door sized.
        let empty: Vec<super::CEntry> = Vec::new();
        let saved = file_encode(&empty, &[]);
        assert!(
            !saved.is_empty(),
            "a save answers a file or the disk keeps the old one"
        );
        let (status, _, loaded) = file_decode(&saved, 0x40);
        let read = loaded.expect("an empty file loads as a re-seeded desk rather than nothing");
        assert_eq!(status, slopdesk_ws_workspace_file_status(0));
        assert_eq!(read.tree.sessions.len(), 1);
        assert_eq!(read.tree.all_pane_ids().len(), 1);
    }

    #[test]
    fn a_save_writes_the_version_it_was_handed_rather_than_the_one_this_build_reads() {
        // The cells carry a shape and no version, so a tree rebuilt from them wears whatever
        // `TreeWorkspace::new` stamps. If the door read THAT instead of its parameter, every save
        // would silently promote a file to the current schema — and the load path's version check,
        // the one thing that can refuse a file this build does not understand, would never fire
        // again, because nothing on disk could still claim an older number.
        let stale = slopdesk_tree::CURRENT_SCHEMA_VERSION - 1;
        let empty: Vec<super::CEntry> = Vec::new();
        // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
        // with.
        let needed = unsafe {
            slopdesk_ws_workspace_file_encode(
                empty.as_ptr(),
                0,
                core::ptr::null(),
                0,
                stale,
                core::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is now exactly `needed` bytes and the inputs are still the same live
        // locals.
        unsafe {
            slopdesk_ws_workspace_file_encode(
                empty.as_ptr(),
                0,
                core::ptr::null(),
                0,
                stale,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        let text = String::from_utf8(out).expect("the file is UTF-8 JSON");
        assert!(
            text.contains(&format!("\"schemaVersion\" : {stale}")),
            "the save re-stamped the version instead of writing the caller's: {text}"
        );
        // And the round trip agrees it is a file from another schema: the decode reports the claim
        // it read back, which is the half of the contract the save side only makes possible.
        let (status, claimed, _) = file_decode(text.as_bytes(), 0x50);
        assert_ne!(status, slopdesk_ws_workspace_file_status(0));
        assert_eq!(claimed, stale);
    }

    #[test]
    fn the_pool_is_asked_of_the_file_rather_than_guessed_from_its_shape() {
        for text in ["", "{}", UNNAMED_SPLIT_FILE] {
            // SAFETY: `text` is a live local's.
            let asked = unsafe { slopdesk_ws_workspace_file_minted_ids(text.as_ptr(), text.len()) };
            assert_eq!(
                asked,
                slopdesk_workspace::minted_ids_for(text.as_bytes()),
                "{text:?}"
            );
        }
    }

    #[test]
    fn the_exported_status_order_is_the_one_the_door_answers() {
        // Walked rather than transcribed: a caller with its own `case malformed = 1` beside this is
        // a second copy of the numbering, and the arm it drifts on is the one that decides whether
        // a file this build cannot read is kept aside or written over.
        let codes = [
            slopdesk_ws_workspace_file_status(0),
            slopdesk_ws_workspace_file_status(1),
            slopdesk_ws_workspace_file_status(2),
            slopdesk_ws_workspace_file_status(3),
        ];
        let distinct: std::collections::BTreeSet<c_uchar> = codes.iter().copied().collect();
        assert_eq!(distinct.len(), codes.len(), "two outcomes cannot share a byte");
        assert_eq!(codes.first().copied(), Some(slopdesk_workspace::NO_REFUSAL));
        assert_eq!(
            codes.get(1).copied(),
            Some(slopdesk_workspace::FileError::Malformed.code())
        );
        assert_eq!(
            slopdesk_ws_workspace_file_status(200),
            slopdesk_workspace::FileError::Malformed.code(),
            "an index past the last refuses rather than admits",
        );
    }

    #[test]
    fn the_default_strings_come_back_whole_under_the_size_then_read_protocol() {
        // SAFETY: the null probe §4 describes.
        let needed = unsafe { slopdesk_ws_default_pane_title(core::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is exactly `needed` bytes.
        let written = unsafe { slopdesk_ws_default_pane_title(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        assert_eq!(
            core::str::from_utf8(&out).ok(),
            Some(slopdesk_tree::workspace::DEFAULT_PANE_TITLE),
        );
    }

    /// The third seeded name crosses the same way, and it is not the terminal one.
    ///
    /// The inequality is the load-bearing half: this door exists because the client mints desktop
    /// panes and the wire crate mints them too, so a door that quietly answered the terminal title
    /// would make every restored desktop pane come back named "Terminal" with nothing failing.
    #[test]
    fn the_desktop_title_crosses_whole_and_is_its_own_word() {
        // SAFETY: the null probe §4 describes.
        let needed = unsafe { slopdesk_ws_default_desktop_pane_title(core::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is exactly `needed` bytes.
        let written = unsafe { slopdesk_ws_default_desktop_pane_title(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        assert_eq!(
            core::str::from_utf8(&out).ok(),
            Some(slopdesk_tree::workspace::DEFAULT_DESKTOP_PANE_TITLE),
        );
        assert_ne!(
            slopdesk_tree::workspace::DEFAULT_DESKTOP_PANE_TITLE,
            slopdesk_tree::workspace::DEFAULT_PANE_TITLE,
        );
    }
}
