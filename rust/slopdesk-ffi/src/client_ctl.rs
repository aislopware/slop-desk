//! The client control socket, as ONE door and a callback — `slopdesk-clientctl`'s server half.
//!
//! What used to be here was the socket's *vocabulary*: five doors that handed Swift the method
//! names and three token tables so a Swift dispatcher could parse a line, `switch` on the method,
//! read `[String: Any]` params, and build a `[String: Any]` reply. Every one of those steps is
//! Rust's now — the listener, the accept loop, the framing, the decode, the validation, the refusal
//! sentences and the reply encoder all live in `slopdesk-clientctl`, and the words never cross at
//! all. What crosses is a VERB INDEX and its already-validated params, in one direction, and a
//! typed outcome in the other.
//!
//! ## The shape
//!
//! [`slopdesk_client_ctl_serve`] binds the socket and starts accepting. Every request the socket
//! decodes calls the ONE callback the caller registered, handing it two opaque handles:
//!
//! * a **request** it reads with [`slopdesk_client_ctl_verb`] and the three accessors below —
//!   nothing on it can be malformed, because the decoder refused every line that was;
//! * a **reply** it fills with exactly one `..._answer_*` or `..._refuse` call, plus any number of
//!   `..._push_*` for a listing.
//!
//! A callback that fills nothing leaves the request refused as an unknown method, which is what it
//! is: this build's face does not serve that verb.
//!
//! ## Why the executor is a callback rather than a door the far side polls
//!
//! Because the far side's stores are main-actor isolated and the socket's threads are not. A
//! callback lets the connection thread PARK inside the hop while the main actor answers, which is
//! the same shape `slopdesk_pane_driver_*` uses for its forwarders — and it is why the reply handle
//! is valid for exactly the callback and never after.

use core::ffi::{c_uchar, c_void};

use slopdesk_agent::badge::TabBadge;
use slopdesk_agent::status::ClaudeStatus;
use slopdesk_clientctl::METHODS;
use slopdesk_clientctl::reply::{Font, Keybind, Outcome, Pane, Tab, Window};
use slopdesk_clientctl::request::{Op, Refusal};
use slopdesk_clientctl::serve::{ControlClient, Server, socket_path_in};

use crate::{borrow, deliver};

// ---------------------------------------------------------------------------------------------- //
// The verb vocabulary
// ---------------------------------------------------------------------------------------------- //

// What [`slopdesk_client_ctl_verb`] answers, one name per method. These are the METHOD TABLE's own
// positions — `a_verb_constant_names_the_slot_its_method_holds` pins each against the op that
// carries it, so a method inserted in the middle moves these names rather than silently renumbering
// a face that spelled `7` for `view`.

/// List every window.
pub const SLOPDESK_CTL_VERB_WINDOWS: i32 = 0;
/// List tabs, optionally scoped to a window.
pub const SLOPDESK_CTL_VERB_TABS: i32 = 1;
/// List panes, optionally scoped to a tab.
pub const SLOPDESK_CTL_VERB_PANES: i32 = 2;
/// Set a tab's status badge.
pub const SLOPDESK_CTL_VERB_TAB_BADGE: i32 = 3;
/// Resolve a frecency-ranked jump target, and `cd` the focused pane unless told not to.
pub const SLOPDESK_CTL_VERB_JUMP: i32 = 4;
/// Record a directory visit in the frecency database.
pub const SLOPDESK_CTL_VERB_LEARN: i32 = 5;
/// Drop a directory from the frecency database.
pub const SLOPDESK_CTL_VERB_IGNORE: i32 = 6;
/// Open a read-only shim. Differs from `edit` only in [`SLOPDESK_CTL_FLAG_EDITABLE`].
pub const SLOPDESK_CTL_VERB_VIEW: i32 = 7;
/// Open an editable shim.
pub const SLOPDESK_CTL_VERB_EDIT: i32 = 8;
/// Enumerate font families.
pub const SLOPDESK_CTL_VERB_FONT_LIST: i32 = 9;
/// Enumerate keybindings.
pub const SLOPDESK_CTL_VERB_KEYBIND_LIST: i32 = 10;
/// Read the tail of a pane's scrollback.
pub const SLOPDESK_CTL_VERB_PANE_CAPTURE: i32 = 11;
/// Send literal text and named keys to a pane.
pub const SLOPDESK_CTL_VERB_PANE_SEND_KEYS: i32 = 12;
/// Poll a session's rolled-up agent status.
pub const SLOPDESK_CTL_VERB_AGENT_STATUS: i32 = 13;

// ---------------------------------------------------------------------------------------------- //
// The refusal vocabulary
// ---------------------------------------------------------------------------------------------- //

// The codes [`slopdesk_client_ctl_refuse`] takes. The SENTENCE each prints is
// `slopdesk-clientctl`'s and never crosses — a face names the refusal and hands over the token the
// request supplied, which is what keeps `invalid placement 'x'` from becoming
// `invalid placement "x"` on one of the two ends that print it.
//
// Only seven of these are a face's to answer: the ones below marked as an OUTCOME. The rest are the
// decoder's, refused before the callback is ever reached — they are named here because a closed
// vocabulary half-exported is one a reader has to guess the rest of.

/// The line is past the cap. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_TOO_LARGE: u8 = 1;
/// The line is not a request object. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_MALFORMED: u8 = 2;
/// A method this build does not dispatch. Names the method. The decoder's, and the fallback for a
/// callback that answered nothing.
pub const SLOPDESK_CTL_REFUSAL_UNKNOWN_METHOD: u8 = 3;
/// `tab-badge` with no `kind`. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_MISSING_BADGE_KIND: u8 = 4;
/// `tab-badge` with a `kind` no badge answers to. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_INVALID_BADGE_KIND: u8 = 5;
/// OUTCOME: `tab-badge` naming a tab that is not there.
pub const SLOPDESK_CTL_REFUSAL_TAB_NOT_FOUND: u8 = 6;
/// OUTCOME: `jump` resolved to nothing.
pub const SLOPDESK_CTL_REFUSAL_NO_JUMP_TARGET: u8 = 7;
/// OUTCOME: `learn` with no path and no focused pane to take one from.
pub const SLOPDESK_CTL_REFUSAL_NOTHING_TO_LEARN: u8 = 8;
/// `ignore` with no `path`. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_MISSING_PATH: u8 = 9;
/// OUTCOME: `ignore` on a path the frecency store would not drop.
pub const SLOPDESK_CTL_REFUSAL_COULD_NOT_IGNORE: u8 = 10;
/// `view` / `edit` with no `target`. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_MISSING_TARGET: u8 = 11;
/// `view` / `edit` with a `placement` no surface answers to. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_INVALID_PLACEMENT: u8 = 12;
/// OUTCOME: `view` / `edit` on a target that would not open.
pub const SLOPDESK_CTL_REFUSAL_COULD_NOT_OPEN: u8 = 13;
/// `font-list` with a `scope` no font surface answers to. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_INVALID_SCOPE: u8 = 14;
/// `pane-capture` with a `lines` that is not a positive integer. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_CAPTURE_LINES: u8 = 15;
/// OUTCOME: a pane verb naming a pane that is not there.
pub const SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND: u8 = 16;
/// `pane-send-keys` with a `keys` that is not an array. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_KEYS_NOT_AN_ARRAY: u8 = 17;
/// `pane-send-keys` with nothing to send. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_NOTHING_TO_SEND: u8 = 18;
/// OUTCOME: `pane-send-keys` naming a key the table does not carry. Names the key.
pub const SLOPDESK_CTL_REFUSAL_UNKNOWN_KEY: u8 = 19;
/// `agent-status` with no `id`. The decoder's.
pub const SLOPDESK_CTL_REFUSAL_MISSING_ID: u8 = 20;

// ---------------------------------------------------------------------------------------------- //
// The request's field vocabulary
// ---------------------------------------------------------------------------------------------- //

/// `tabs` — the window to scope to.
pub const SLOPDESK_CTL_FIELD_WINDOW_ID: u8 = 0;
/// `panes`, `tab-badge` — the tab to scope to or mark.
pub const SLOPDESK_CTL_FIELD_TAB_ID: u8 = 1;
/// `pane-capture`, `pane-send-keys` — the pane to read or drive.
pub const SLOPDESK_CTL_FIELD_PANE_ID: u8 = 2;
/// `jump` — what to rank against.
pub const SLOPDESK_CTL_FIELD_QUERY: u8 = 3;
/// `learn`, `ignore` — the directory.
pub const SLOPDESK_CTL_FIELD_PATH: u8 = 4;
/// `view`, `edit` — the path or URL to open.
pub const SLOPDESK_CTL_FIELD_TARGET: u8 = 5;
/// `font-list` — the family substring filter.
pub const SLOPDESK_CTL_FIELD_FAMILY: u8 = 6;
/// `keybind-list` — the action-name substring filter.
pub const SLOPDESK_CTL_FIELD_ACTION: u8 = 7;
/// `pane-send-keys` — the literal text to send.
pub const SLOPDESK_CTL_FIELD_TEXT: u8 = 8;
/// `agent-status` — the session or pane id to poll.
pub const SLOPDESK_CTL_FIELD_ID: u8 = 9;

/// `jump` — whether to send the `cd`. The request spells the negative; this is the verb.
pub const SLOPDESK_CTL_FLAG_CHANGE_DIRECTORY: u8 = 0;
/// `font-list` — whether to keep only monospaced families.
pub const SLOPDESK_CTL_FLAG_MONOSPACE: u8 = 1;
/// `view` / `edit` — whether the shim is editable.
pub const SLOPDESK_CTL_FLAG_EDITABLE: u8 = 2;

/// `pane-capture` — the count, already positive and clamped.
pub const SLOPDESK_CTL_NUMBER_LINES: u8 = 0;
/// `tab-badge` — the badge's index in `TabBadge::ALL`.
pub const SLOPDESK_CTL_NUMBER_BADGE: u8 = 1;
/// `view` / `edit` — the placement's index in the crate's vocabulary.
pub const SLOPDESK_CTL_NUMBER_PLACEMENT: u8 = 2;
/// `font-list` — the scope's index, or `-1` for both.
pub const SLOPDESK_CTL_NUMBER_SCOPE: u8 = 3;

/// What a number this op does not carry answers. Every number the ops DO carry is non-negative, so
/// the sentinel cannot collide with an answer.
const ABSENT: i64 = -1;

// ---------------------------------------------------------------------------------------------- //
// The reply's listing vocabulary
// ---------------------------------------------------------------------------------------------- //

/// A `windows` listing. Push with [`slopdesk_client_ctl_push_window`].
pub const SLOPDESK_CTL_LIST_WINDOWS: u8 = 0;
/// A `tabs` listing. Push with [`slopdesk_client_ctl_push_tab`].
pub const SLOPDESK_CTL_LIST_TABS: u8 = 1;
/// A `panes` listing. Push with [`slopdesk_client_ctl_push_pane`].
pub const SLOPDESK_CTL_LIST_PANES: u8 = 2;
/// A `font-list`. Push with [`slopdesk_client_ctl_push_font`].
pub const SLOPDESK_CTL_LIST_FONTS: u8 = 3;
/// A `keybind-list`. Push with [`slopdesk_client_ctl_push_keybind`].
pub const SLOPDESK_CTL_LIST_KEYBINDS: u8 = 4;
/// A `pane-capture`'s lines. Push with [`slopdesk_client_ctl_push_line`].
pub const SLOPDESK_CTL_LIST_LINES: u8 = 5;

// ---------------------------------------------------------------------------------------------- //
// The records a listing is pushed with
// ---------------------------------------------------------------------------------------------- //

/// One borrowed run of UTF-8, live for the push that carries it and no longer.
///
/// A pair rather than a C string: the far side's text is a Swift `String`, which has a length and
/// no terminator, and asking it to produce one would be a copy per field for nothing.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskCtlText {
    /// The bytes, or null for an empty run.
    pub bytes: *const c_uchar,
    /// How many. The LENGTH decides — a zero-length run may carry a dangling non-null.
    pub len: usize,
}

/// One row of a `windows` listing.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskCtlWindow {
    /// The window's stable id.
    pub id: SlopDeskCtlText,
    /// Its title.
    pub title: SlopDeskCtlText,
    /// How many tabs it holds.
    pub tab_count: i64,
    /// Whether it is the focused window.
    pub focused: bool,
}

/// One row of a `tabs` listing.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskCtlTab {
    /// The tab's stable id.
    pub id: SlopDeskCtlText,
    /// The window it lives in.
    pub window_id: SlopDeskCtlText,
    /// Its title.
    pub title: SlopDeskCtlText,
    /// How many panes it holds.
    pub pane_count: i64,
    /// Whether it is the focused tab.
    pub focused: bool,
    /// The badge it wears, as its `TabBadge::ALL` index, or negative for none. An index no badge
    /// answers to reads as none, which prints a tab wearing nothing rather than a neighbour's mark.
    pub badge: i32,
}

/// One row of a `panes` listing.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskCtlPane {
    /// The pane's stable id.
    pub id: SlopDeskCtlText,
    /// The tab it lives in.
    pub tab_id: SlopDeskCtlText,
    /// Its title.
    pub title: SlopDeskCtlText,
    /// What kind of pane it is.
    pub kind: SlopDeskCtlText,
    /// Whether it is the focused pane.
    pub focused: bool,
    /// Its cached OSC-7 cwd. Meaningless unless `has_cwd`.
    pub cwd: SlopDeskCtlText,
    /// Whether a cwd is known. An EMPTY cwd and an unknown one are different answers: the first
    /// prints a blank, the second omits the key.
    pub has_cwd: bool,
}

/// One row of a `font-list`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskCtlFont {
    /// The family name.
    pub family: SlopDeskCtlText,
    /// Whether every glyph advances the same width.
    pub monospace: bool,
    /// Whether it ships with the OS.
    pub system: bool,
}

/// One row of a `keybind-list`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskCtlKeybind {
    /// The action's name.
    pub action: SlopDeskCtlText,
    /// Its chord(s).
    pub keys: SlopDeskCtlText,
}

// ---------------------------------------------------------------------------------------------- //
// The two handles
// ---------------------------------------------------------------------------------------------- //

/// One decoded request, valid for exactly the callback it is handed to.
///
/// `repr(transparent)` over the crate's own op, so the bridge can lend the decoder's value directly
/// rather than copying it across the boundary — the read accessors are the only thing that ever
/// looks inside, and they run inside the borrow.
#[derive(Debug)]
#[repr(transparent)]
pub struct SlopDeskCtlRequest(Op);

/// Where the callback writes its answer, valid for exactly that callback.
///
/// `None` until something is written. A callback that writes nothing leaves the request refused as
/// an unknown method — see [`Bridge::run`].
#[derive(Debug)]
#[repr(transparent)]
pub struct SlopDeskCtlReply(Option<Outcome>);

/// The callback one decoded request is run through.
///
/// Called on a connection thread, one request at a time per connection. `context` is whatever was
/// registered; `request` and `reply` are live for this call and dangling after it.
pub type SlopDeskCtlRunFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        request: *const SlopDeskCtlRequest,
        reply: *mut SlopDeskCtlReply,
    ),
>;

/// A bound client control socket, and the callback it runs requests through.
#[derive(Debug)]
pub struct SlopDeskClientCtl {
    /// Held for its `Drop`, which is what stops the listener and unlinks the path. Nothing reads
    /// it: the whole lifecycle is "exists" and "dropped".
    #[expect(
        dead_code,
        reason = "the field is held for its Drop, which is the entire lifecycle"
    )]
    server: Server,
}

/// Carries the caller's context pointer across the thread boundary.
///
/// The caller's obligation, stated once: `context` must stay valid for as long as any connection
/// thread might still call back — and since [`slopdesk_client_ctl_free`] cannot join those threads
/// without risking the deadlock documented there, that is the life of the PROCESS, not the life of
/// the handle. The obligation is cheap to meet and expensive to get wrong: one socket is bound once
/// per process, so the caller pays a single object it never frees, and the alternative is a free
/// racing a callback that is already reading the pointer.
#[derive(Debug)]
struct Context(*mut c_void);

// SAFETY: the pointer is opaque here — it is never dereferenced on this side, only handed back to
// the callback the caller registered. Keeping it valid across threads is the caller's obligation,
// documented on `slopdesk_client_ctl_serve`.
#[expect(
    unsafe_code,
    reason = "asserting the caller's context may cross to the connection threads that call back into it"
)]
unsafe impl Send for Context {}
// SAFETY: as above — shared, never read here.
#[expect(
    unsafe_code,
    reason = "asserting the caller's context may be shared by the connection threads"
)]
unsafe impl Sync for Context {}

/// What turns one decoded op into the callback and back.
#[derive(Debug)]
struct Bridge {
    context: Context,
    run: SlopDeskCtlRunFn,
}

impl ControlClient for Bridge {
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS the boundary this module documents"
    )]
    fn run(&self, op: &Op) -> Outcome {
        let mut cell = SlopDeskCtlReply(None);
        if let Some(run) = self.run {
            // SAFETY: `run` is the pointer the caller registered and promised to keep callable for
            // the server's life; both handles are stack values live for exactly this call, which is
            // the whole of what the callback may use them for.
            unsafe {
                run(
                    self.context.0,
                    core::ptr::from_ref(op).cast::<SlopDeskCtlRequest>(),
                    &raw mut cell,
                );
            }
        }
        // A callback that wrote nothing does not serve this verb. Saying so by name is the honest
        // report: the request was well-formed and this build had nowhere to send it.
        cell.0.unwrap_or_else(|| {
            Outcome::Refused {
                refusal: Refusal::UnknownMethod,
                detail: METHODS
                    .get(op.verb() as usize)
                    .map_or_else(String::new, |method| (*method).to_owned()),
            }
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// Lifecycle
// ---------------------------------------------------------------------------------------------- //

/// Where the socket lives: the `SLOPDESK_CLIENT_SOCKET` override, else `cli-control.sock` inside
/// the container the caller names.
///
/// The container is the caller's because resolving Application Support is a platform lookup; every
/// rule ABOUT the path — the file name, which override wins, that a blank override is not one — is
/// this side's.
///
/// # Safety
/// `(container, container_len)` must be null, or name `container_len` live bytes for the call, and
/// `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both buffers are the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_socket_path(
    container: *const c_uchar,
    container_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(container, container_len) };
    let base = core::str::from_utf8(bytes).unwrap_or_default();
    let chosen = std::env::var(slopdesk_clientctl::serve::SOCKET_ENV).unwrap_or_default();
    let path = socket_path_in(std::path::Path::new(base), Some(chosen.as_str()));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(path.as_os_str().as_encoded_bytes(), out, cap) }
}

/// Binds the client control socket at `path` and begins accepting.
///
/// Null on a bind that failed — a path longer than `sun_path`, a container the user cannot write.
/// Nothing has been started in that case and `context` is the caller's again immediately.
///
/// # Safety
/// `(path, path_len)` must name `path_len` live UTF-8 bytes for the call. `run` must stay callable,
/// and `context` valid, for the life of the process once this has returned non-null — freeing the
/// handle does not end the callback's reach, and [`Context`] says why.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
#[must_use]
pub unsafe extern "C" fn slopdesk_client_ctl_serve(
    path: *const c_uchar,
    path_len: usize,
    context: *mut c_void,
    run: SlopDeskCtlRunFn,
) -> *mut SlopDeskClientCtl {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(path, path_len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return core::ptr::null_mut();
    };
    let bridge = std::sync::Arc::new(Bridge {
        context: Context(context),
        run,
    });
    Server::bind(std::path::Path::new(text), bridge).map_or(core::ptr::null_mut(), |server| {
        Box::into_raw(Box::new(SlopDeskClientCtl { server }))
    })
}

/// Stops the listener, unlinks the socket file and releases the handle.
///
/// It does NOT join the connection threads, and it must not: one of them may be parked inside the
/// callback waiting on the caller's main actor, and a free called FROM that actor would then wait
/// on a thread waiting on it. So the threads are detached, this returns while one may still be in
/// the callback, and `context` stays the callback's to reach — see [`Context`] for what that costs
/// the caller.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_client_ctl_serve`] that has not already
/// been freed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_free(handle: *mut SlopDeskClientCtl) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, the unique live owner. Dropping it stops
    // the listener and unlinks the path.
    drop(unsafe { Box::from_raw(handle) });
}

// ---------------------------------------------------------------------------------------------- //
// Reading one request
// ---------------------------------------------------------------------------------------------- //

/// Reconstitutes a request handle for the duration of one call.
///
/// # Safety
/// `request` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn asked<'a>(request: *const SlopDeskCtlRequest) -> Option<&'a Op> {
    if request.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    Some(&unsafe { &*request }.0)
}

/// Which verb this request is, as its index in the method vocabulary. `-1` for a null handle.
///
/// `view` and `edit` are two indices over one shape: they differ only in
/// [`SLOPDESK_CTL_FLAG_EDITABLE`], and a face that wants one branch reads the flag instead.
///
/// # Safety
/// `request` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_verb(request: *const SlopDeskCtlRequest) -> i32 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { asked(request) }.map_or(-1, |op| i32::from(op.verb()))
}

/// One of the request's text fields, or nothing when this op does not carry it.
///
/// `present` distinguishes an ABSENT field from an EMPTY one, which several verbs branch on: a
/// `learn` with no `path` takes the focused pane's cwd, while a `learn` with `""` is refused before
/// it ever reaches here.
///
/// # Safety
/// `request` must be null or a running callback's; `out` must be null or writable for `cap` bytes;
/// `present` must be null or writable.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_text(
    request: *const SlopDeskCtlRequest,
    field: u8,
    out: *mut c_uchar,
    cap: usize,
    present: *mut bool,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let found = unsafe { asked(request) }.and_then(|op| field_of(op, field));
    if !present.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for this call.
        unsafe { *present = found.is_some() };
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(found.unwrap_or_default().as_bytes(), out, cap) }
}

/// The text field a code names, or `None` when this op does not carry it.
fn field_of(op: &Op, field: u8) -> Option<&str> {
    fn optional(value: Option<&String>) -> Option<&str> {
        value.map(String::as_str)
    }
    match (field, op) {
        (SLOPDESK_CTL_FIELD_WINDOW_ID, Op::Tabs { window_id }) => optional(window_id.as_ref()),
        (SLOPDESK_CTL_FIELD_TAB_ID, Op::Panes { tab_id } | Op::TabBadge { tab_id, .. }) => {
            optional(tab_id.as_ref())
        },
        (SLOPDESK_CTL_FIELD_PANE_ID, Op::PaneCapture { pane_id, .. } | Op::PaneSendKeys { pane_id, .. }) => {
            optional(pane_id.as_ref())
        },
        (SLOPDESK_CTL_FIELD_QUERY, Op::Jump { query, .. }) => optional(query.as_ref()),
        (SLOPDESK_CTL_FIELD_PATH, Op::Learn { path }) => optional(path.as_ref()),
        (SLOPDESK_CTL_FIELD_PATH, Op::Ignore { path }) => Some(path),
        (SLOPDESK_CTL_FIELD_TARGET, Op::Open { target, .. }) => Some(target),
        (SLOPDESK_CTL_FIELD_FAMILY, Op::FontList { family, .. }) => optional(family.as_ref()),
        (SLOPDESK_CTL_FIELD_ACTION, Op::KeybindList { action }) => optional(action.as_ref()),
        (SLOPDESK_CTL_FIELD_TEXT, Op::PaneSendKeys { text, .. }) => Some(text),
        (SLOPDESK_CTL_FIELD_ID, Op::AgentStatus { id }) => Some(id),
        _ => None,
    }
}

/// One of the request's flags. `false` for a flag this op does not carry, which is every flag's
/// documented default.
///
/// # Safety
/// `request` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn slopdesk_client_ctl_flag(
    request: *const SlopDeskCtlRequest,
    flag: u8,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(op) = (unsafe { asked(request) }) else {
        return false;
    };
    match (flag, op) {
        (SLOPDESK_CTL_FLAG_CHANGE_DIRECTORY, Op::Jump { change_directory, .. }) => *change_directory,
        (SLOPDESK_CTL_FLAG_MONOSPACE, Op::FontList { monospace_only, .. }) => *monospace_only,
        (SLOPDESK_CTL_FLAG_EDITABLE, Op::Open { editable, .. }) => *editable,
        _ => false,
    }
}

/// One of the request's numbers, or [`ABSENT`] when this op does not carry it.
///
/// Every number an op does carry is non-negative — a capture count is positive by the time it
/// reaches here, and the two indices are positions in closed vocabularies — so `-1` cannot be
/// mistaken for an answer.
///
/// # Safety
/// `request` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_number(request: *const SlopDeskCtlRequest, number: u8) -> i64 {
    // SAFETY: the caller's obligation, restated above.
    let Some(op) = (unsafe { asked(request) }) else {
        return ABSENT;
    };
    match (number, op) {
        (SLOPDESK_CTL_NUMBER_LINES, Op::PaneCapture { lines, .. }) => *lines,
        (SLOPDESK_CTL_NUMBER_BADGE, Op::TabBadge { kind, .. }) => {
            TabBadge::ALL
                .iter()
                .position(|candidate| candidate == kind)
                .and_then(|index| i64::try_from(index).ok())
                .unwrap_or(ABSENT)
        },
        (SLOPDESK_CTL_NUMBER_PLACEMENT, Op::Open { placement, .. }) => {
            i64::try_from(*placement).unwrap_or(ABSENT)
        },
        (SLOPDESK_CTL_NUMBER_SCOPE, Op::FontList { scope, .. }) => {
            scope
                .and_then(|index| i64::try_from(index).ok())
                .unwrap_or(ABSENT)
        },
        _ => ABSENT,
    }
}

/// How many named keys a `pane-send-keys` carries. `0` for every other verb.
///
/// # Safety
/// `request` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_key_count(request: *const SlopDeskCtlRequest) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { asked(request) }.map_or(0, |op| {
        match *op {
            Op::PaneSendKeys { ref keys, .. } => keys.len(),
            _ => 0,
        }
    })
}

/// One named key by position. Writes nothing past the end.
///
/// # Safety
/// `request` must be null or a running callback's; `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_key(
    request: *const SlopDeskCtlRequest,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let named = unsafe { asked(request) }.and_then(|op| {
        match *op {
            Op::PaneSendKeys { ref keys, .. } => keys.get(index),
            _ => None,
        }
    });
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(named.map_or("", String::as_str).as_bytes(), out, cap) }
}

// ---------------------------------------------------------------------------------------------- //
// Writing one reply
// ---------------------------------------------------------------------------------------------- //

/// Reconstitutes a reply handle for the duration of one call.
///
/// # Safety
/// `reply` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn answering<'a>(reply: *mut SlopDeskCtlReply) -> Option<&'a mut Option<Outcome>> {
    if reply.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, uniquely live for this call — the callback
    // is the only thing holding it and it is single-threaded within one request.
    Some(&mut unsafe { &mut *reply }.0)
}

/// Reads one borrowed run.
///
/// # Safety
/// `text` must carry a null pointer, or `len` live bytes for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's text IS the boundary this module documents"
)]
unsafe fn said(text: SlopDeskCtlText) -> String {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let bytes = unsafe { borrow(text.bytes, text.len) };
    // A lossy decode is right here: the producer is a Swift `String`, so invalid UTF-8 cannot
    // happen — and if it somehow did, a replacement character in a listing beats refusing the whole
    // request over one title.
    String::from_utf8_lossy(bytes).into_owned()
}

/// The verb landed and has nothing to report.
///
/// # Safety
/// `reply` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_answer_done(reply: *mut SlopDeskCtlReply) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(cell) = unsafe { answering(reply) } {
        *cell = Some(Outcome::Done);
    }
}

/// Starts an EMPTY listing of `kind`. Every `..._push_*` appends to whichever one is open.
///
/// Separate from the pushes so an empty listing is expressible: a `windows` that found none must
/// still answer `{"windows":[]}`, because the CLI prints "no windows" from the empty array and an
/// error from a missing key. A `kind` this build does not know opens nothing.
///
/// # Safety
/// `reply` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_answer_list(reply: *mut SlopDeskCtlReply, kind: u8) {
    // SAFETY: the caller's obligation, restated above.
    let Some(cell) = (unsafe { answering(reply) }) else {
        return;
    };
    *cell = match kind {
        SLOPDESK_CTL_LIST_WINDOWS => Some(Outcome::Windows(Vec::new())),
        SLOPDESK_CTL_LIST_TABS => Some(Outcome::Tabs(Vec::new())),
        SLOPDESK_CTL_LIST_PANES => Some(Outcome::Panes(Vec::new())),
        SLOPDESK_CTL_LIST_FONTS => Some(Outcome::Fonts(Vec::new())),
        SLOPDESK_CTL_LIST_KEYBINDS => Some(Outcome::Keybinds(Vec::new())),
        SLOPDESK_CTL_LIST_LINES => Some(Outcome::Captured(Vec::new())),
        _ => None,
    };
}

/// Appends one window. A no-op unless a `windows` listing is open.
///
/// # Safety
/// `reply` must be null or a running callback's; every text in `row` must be null-with-zero-length
/// or live for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_push_window(
    reply: *mut SlopDeskCtlReply,
    row: SlopDeskCtlWindow,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(Some(Outcome::Windows(items))) = (unsafe { answering(reply) }) else {
        return;
    };
    items.push(Window {
        // SAFETY: the caller's obligation, restated above.
        id: unsafe { said(row.id) },
        // SAFETY: as above.
        title: unsafe { said(row.title) },
        tab_count: row.tab_count,
        focused: row.focused,
    });
}

/// Appends one tab. A no-op unless a `tabs` listing is open.
///
/// # Safety
/// `reply` must be null or a running callback's; every text in `row` must be null-with-zero-length
/// or live for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_push_tab(reply: *mut SlopDeskCtlReply, row: SlopDeskCtlTab) {
    // SAFETY: the caller's obligation, restated above.
    let Some(Some(Outcome::Tabs(items))) = (unsafe { answering(reply) }) else {
        return;
    };
    items.push(Tab {
        // SAFETY: the caller's obligation, restated above.
        id: unsafe { said(row.id) },
        // SAFETY: as above.
        window_id: unsafe { said(row.window_id) },
        // SAFETY: as above.
        title: unsafe { said(row.title) },
        pane_count: row.pane_count,
        focused: row.focused,
        badge: badge_at(row.badge),
    });
}

/// The badge an index names, or `None` — including for a negative one, which is "wearing nothing".
fn badge_at(index: i32) -> Option<TabBadge> {
    usize::try_from(index)
        .ok()
        .and_then(|slot| TabBadge::ALL.get(slot))
        .copied()
}

/// Appends one pane. A no-op unless a `panes` listing is open.
///
/// # Safety
/// `reply` must be null or a running callback's; every text in `row` must be null-with-zero-length
/// or live for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_push_pane(reply: *mut SlopDeskCtlReply, row: SlopDeskCtlPane) {
    // SAFETY: the caller's obligation, restated above.
    let Some(Some(Outcome::Panes(items))) = (unsafe { answering(reply) }) else {
        return;
    };
    items.push(Pane {
        // SAFETY: the caller's obligation, restated above.
        id: unsafe { said(row.id) },
        // SAFETY: as above.
        tab_id: unsafe { said(row.tab_id) },
        // SAFETY: as above.
        title: unsafe { said(row.title) },
        // SAFETY: as above.
        kind: unsafe { said(row.kind) },
        focused: row.focused,
        // SAFETY: as above. The flag decides whether the run is read at all.
        cwd: row.has_cwd.then(|| unsafe { said(row.cwd) }),
    });
}

/// Appends one font. A no-op unless a `font-list` is open.
///
/// # Safety
/// `reply` must be null or a running callback's; `row.family` must be null-with-zero-length or live
/// for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_push_font(reply: *mut SlopDeskCtlReply, row: SlopDeskCtlFont) {
    // SAFETY: the caller's obligation, restated above.
    let Some(Some(Outcome::Fonts(items))) = (unsafe { answering(reply) }) else {
        return;
    };
    items.push(Font {
        // SAFETY: the caller's obligation, restated above.
        family: unsafe { said(row.family) },
        monospace: row.monospace,
        system: row.system,
    });
}

/// Appends one keybinding. A no-op unless a `keybind-list` is open.
///
/// # Safety
/// `reply` must be null or a running callback's; every text in `row` must be null-with-zero-length
/// or live for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_push_keybind(
    reply: *mut SlopDeskCtlReply,
    row: SlopDeskCtlKeybind,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(Some(Outcome::Keybinds(items))) = (unsafe { answering(reply) }) else {
        return;
    };
    items.push(Keybind {
        // SAFETY: the caller's obligation, restated above.
        action: unsafe { said(row.action) },
        // SAFETY: as above.
        keys: unsafe { said(row.keys) },
    });
}

/// Appends one captured scrollback line. A no-op unless a `pane-capture` listing is open.
///
/// # Safety
/// `reply` must be null or a running callback's; `text` must be null-with-zero-length or live for
/// the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_push_line(reply: *mut SlopDeskCtlReply, text: SlopDeskCtlText) {
    // SAFETY: the caller's obligation, restated above.
    let Some(Some(Outcome::Captured(items))) = (unsafe { answering(reply) }) else {
        return;
    };
    // SAFETY: the caller's obligation, restated above.
    items.push(unsafe { said(text) });
}

/// A `tab-badge` that landed, echoing the badge the tab now wears by its `TabBadge::ALL` index.
///
/// # Safety
/// `reply` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_answer_badge(reply: *mut SlopDeskCtlReply, badge: i32) {
    // SAFETY: the caller's obligation, restated above.
    let Some(cell) = (unsafe { answering(reply) }) else {
        return;
    };
    // An index no badge answers to writes nothing, which leaves the request refused as an unknown
    // method rather than echoing a badge the tab is not wearing.
    if let Some(kind) = badge_at(badge) {
        *cell = Some(Outcome::Badge(kind));
    }
}

/// A `jump` that resolved.
///
/// # Safety
/// `reply` must be null or a running callback's; `path` must be null-with-zero-length or live for
/// the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_answer_jump(
    reply: *mut SlopDeskCtlReply,
    path: SlopDeskCtlText,
    changed: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(cell) = (unsafe { answering(reply) }) else {
        return;
    };
    *cell = Some(Outcome::Jumped {
        // SAFETY: the caller's obligation, restated above.
        path: unsafe { said(path) },
        changed,
    });
}

/// A `learn` or `ignore` that landed, echoing the path it acted on.
///
/// # Safety
/// `reply` must be null or a running callback's; `path` must be null-with-zero-length or live for
/// the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_answer_path(
    reply: *mut SlopDeskCtlReply,
    path: SlopDeskCtlText,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(cell) = (unsafe { answering(reply) }) else {
        return;
    };
    // SAFETY: the caller's obligation, restated above.
    *cell = Some(Outcome::Path(unsafe { said(path) }));
}

/// An `agent-status` reading.
///
/// `seen` false is an id that resolves to NO pane. `seen` true with `has_status` false is the
/// agent-startup window — the pane exists and has not reported — which keeps `watch:claude` polling
/// rather than exiting 4.
///
/// # Safety
/// `reply` must be null, or the pointer a running callback was handed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_answer_agent(
    reply: *mut SlopDeskCtlReply,
    seen: bool,
    has_status: bool,
    status: u8,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(cell) = (unsafe { answering(reply) }) else {
        return;
    };
    *cell = Some(Outcome::Agent {
        seen,
        // The byte is the URGENCY, which is the one spelling of this enum that already crosses on
        // the binary wire. A future urgency degrades to `None` there and here alike.
        status: has_status.then(|| ClaudeStatus::from_urgency(status)),
    });
}

/// The verb could not be served, in the socket's own words.
///
/// `detail` is the token a person mistyped; the fifteen refusals that name none ignore it.
///
/// # Safety
/// `reply` must be null or a running callback's; `detail` must be null-with-zero-length or live for
/// the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_client_ctl_refuse(
    reply: *mut SlopDeskCtlReply,
    refusal: u8,
    detail: SlopDeskCtlText,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(cell) = (unsafe { answering(reply) }) else {
        return;
    };
    // A code this build cannot name writes nothing, which leaves the request refused as an unknown
    // method rather than answering a sentence nobody meant.
    if let Some(named) = Refusal::from_code(refusal) {
        *cell = Some(Outcome::Refused {
            refusal: named,
            // SAFETY: the caller's obligation, restated above.
            detail: unsafe { said(detail) },
        });
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use core::ffi::c_void;

    use slopdesk_agent::badge::TabBadge;
    use slopdesk_clientctl::METHODS;
    use slopdesk_clientctl::request::{Op, Refusal};
    use slopdesk_clientctl::serve::answer;

    use super::{
        Bridge, Context, SLOPDESK_CTL_FIELD_ACTION, SLOPDESK_CTL_FIELD_ID, SLOPDESK_CTL_FIELD_PANE_ID,
        SLOPDESK_CTL_FIELD_PATH, SLOPDESK_CTL_FIELD_QUERY, SLOPDESK_CTL_FIELD_TARGET,
        SLOPDESK_CTL_FIELD_TEXT, SLOPDESK_CTL_FIELD_WINDOW_ID, SLOPDESK_CTL_FLAG_CHANGE_DIRECTORY,
        SLOPDESK_CTL_FLAG_EDITABLE, SLOPDESK_CTL_FLAG_MONOSPACE, SLOPDESK_CTL_LIST_WINDOWS,
        SLOPDESK_CTL_NUMBER_BADGE, SLOPDESK_CTL_NUMBER_LINES, SLOPDESK_CTL_NUMBER_PLACEMENT,
        SLOPDESK_CTL_NUMBER_SCOPE, SlopDeskCtlReply, SlopDeskCtlRequest, SlopDeskCtlText, SlopDeskCtlWindow,
        slopdesk_client_ctl_answer_agent, slopdesk_client_ctl_answer_list, slopdesk_client_ctl_flag,
        slopdesk_client_ctl_key, slopdesk_client_ctl_key_count, slopdesk_client_ctl_number,
        slopdesk_client_ctl_push_window, slopdesk_client_ctl_refuse, slopdesk_client_ctl_socket_path,
        slopdesk_client_ctl_text, slopdesk_client_ctl_verb,
    };

    /// Lends a `&str` as one borrowed run for the length of a call.
    fn lent(text: &str) -> SlopDeskCtlText {
        SlopDeskCtlText {
            bytes: text.as_ptr(),
            len: text.len(),
        }
    }

    /// Reads one text field through the two-call sizing shape.
    fn field(op: &Op, code: u8) -> Option<String> {
        let handle = core::ptr::from_ref(op).cast::<SlopDeskCtlRequest>();
        let mut present = false;
        // SAFETY: the handle points at a live op and the null buffer is the documented sizing call.
        let needed =
            unsafe { slopdesk_client_ctl_text(handle, code, core::ptr::null_mut(), 0, &raw mut present) };
        if !present {
            return None;
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: as above, with a buffer of exactly the length the door asked for.
        let written = unsafe {
            slopdesk_client_ctl_text(handle, code, out.as_mut_ptr(), out.len(), core::ptr::null_mut())
        };
        assert_eq!(written, needed);
        Some(String::from_utf8(out).expect("a field is UTF-8"))
    }

    fn number(op: &Op, code: u8) -> i64 {
        // SAFETY: the handle points at a live op.
        unsafe { slopdesk_client_ctl_number(core::ptr::from_ref(op).cast(), code) }
    }

    fn flag(op: &Op, code: u8) -> bool {
        // SAFETY: the handle points at a live op.
        unsafe { slopdesk_client_ctl_flag(core::ptr::from_ref(op).cast(), code) }
    }

    // -- reading a request ----------------------------------------------------------------------

    /// A face switches on these names rather than on `7`, so each has to name the slot its method
    /// actually holds — and a method inserted in the middle has to move the names rather than
    /// silently renumber the face.
    #[test]
    fn a_verb_constant_names_the_slot_its_method_holds() {
        let pairs = [
            (super::SLOPDESK_CTL_VERB_WINDOWS, slopdesk_clientctl::WINDOWS),
            (super::SLOPDESK_CTL_VERB_TABS, slopdesk_clientctl::TABS),
            (super::SLOPDESK_CTL_VERB_PANES, slopdesk_clientctl::PANES),
            (super::SLOPDESK_CTL_VERB_TAB_BADGE, slopdesk_clientctl::TAB_BADGE),
            (super::SLOPDESK_CTL_VERB_JUMP, slopdesk_clientctl::JUMP),
            (super::SLOPDESK_CTL_VERB_LEARN, slopdesk_clientctl::LEARN),
            (super::SLOPDESK_CTL_VERB_IGNORE, slopdesk_clientctl::IGNORE),
            (super::SLOPDESK_CTL_VERB_VIEW, slopdesk_clientctl::VIEW),
            (super::SLOPDESK_CTL_VERB_EDIT, slopdesk_clientctl::EDIT),
            (super::SLOPDESK_CTL_VERB_FONT_LIST, slopdesk_clientctl::FONT_LIST),
            (
                super::SLOPDESK_CTL_VERB_KEYBIND_LIST,
                slopdesk_clientctl::KEYBIND_LIST,
            ),
            (
                super::SLOPDESK_CTL_VERB_PANE_CAPTURE,
                slopdesk_clientctl::PANE_CAPTURE,
            ),
            (
                super::SLOPDESK_CTL_VERB_PANE_SEND_KEYS,
                slopdesk_clientctl::PANE_SEND_KEYS,
            ),
            (
                super::SLOPDESK_CTL_VERB_AGENT_STATUS,
                slopdesk_clientctl::AGENT_STATUS,
            ),
        ];
        assert_eq!(pairs.len(), METHODS.len(), "every method is named exactly once");
        for (slot, method) in pairs {
            assert_eq!(
                METHODS.get(slot.unsigned_abs() as usize),
                Some(&method),
                "{method}"
            );
        }
    }

    /// Same obligation for the refusals: a face hands over a CODE, and each name has to be the code
    /// the crate assigns the refusal it is named after.
    #[test]
    fn a_refusal_constant_names_the_code_its_refusal_carries() {
        let pairs = [
            (super::SLOPDESK_CTL_REFUSAL_TOO_LARGE, Refusal::TooLarge),
            (super::SLOPDESK_CTL_REFUSAL_MALFORMED, Refusal::Malformed),
            (super::SLOPDESK_CTL_REFUSAL_UNKNOWN_METHOD, Refusal::UnknownMethod),
            (
                super::SLOPDESK_CTL_REFUSAL_MISSING_BADGE_KIND,
                Refusal::MissingBadgeKind,
            ),
            (
                super::SLOPDESK_CTL_REFUSAL_INVALID_BADGE_KIND,
                Refusal::InvalidBadgeKind,
            ),
            (super::SLOPDESK_CTL_REFUSAL_TAB_NOT_FOUND, Refusal::TabNotFound),
            (super::SLOPDESK_CTL_REFUSAL_NO_JUMP_TARGET, Refusal::NoJumpTarget),
            (
                super::SLOPDESK_CTL_REFUSAL_NOTHING_TO_LEARN,
                Refusal::NothingToLearn,
            ),
            (super::SLOPDESK_CTL_REFUSAL_MISSING_PATH, Refusal::MissingPath),
            (
                super::SLOPDESK_CTL_REFUSAL_COULD_NOT_IGNORE,
                Refusal::CouldNotIgnore,
            ),
            (super::SLOPDESK_CTL_REFUSAL_MISSING_TARGET, Refusal::MissingTarget),
            (
                super::SLOPDESK_CTL_REFUSAL_INVALID_PLACEMENT,
                Refusal::InvalidPlacement,
            ),
            (super::SLOPDESK_CTL_REFUSAL_COULD_NOT_OPEN, Refusal::CouldNotOpen),
            (super::SLOPDESK_CTL_REFUSAL_INVALID_SCOPE, Refusal::InvalidScope),
            (super::SLOPDESK_CTL_REFUSAL_CAPTURE_LINES, Refusal::CaptureLines),
            (super::SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND, Refusal::PaneNotFound),
            (
                super::SLOPDESK_CTL_REFUSAL_KEYS_NOT_AN_ARRAY,
                Refusal::KeysNotAnArray,
            ),
            (
                super::SLOPDESK_CTL_REFUSAL_NOTHING_TO_SEND,
                Refusal::NothingToSend,
            ),
            (super::SLOPDESK_CTL_REFUSAL_UNKNOWN_KEY, Refusal::UnknownKey),
            (super::SLOPDESK_CTL_REFUSAL_MISSING_ID, Refusal::MissingId),
        ];
        assert_eq!(
            pairs.len(),
            Refusal::ALL.len(),
            "every refusal is named exactly once"
        );
        for (code, refusal) in pairs {
            assert_eq!(code, refusal.code(), "{refusal:?}");
        }
    }

    #[test]
    fn every_verb_crosses_as_its_slot_in_the_method_table() {
        let ops = [Op::Windows, Op::Tabs { window_id: None }, Op::AgentStatus {
            id: "s1".to_owned(),
        }];
        for op in &ops {
            // SAFETY: the handle points at a live op.
            let verb = unsafe { slopdesk_client_ctl_verb(core::ptr::from_ref(op).cast()) };
            assert_eq!(verb, i32::from(op.verb()));
            assert!(METHODS.get(verb.unsigned_abs() as usize).is_some());
        }
        // SAFETY: a null handle is the documented "no request" case.
        assert_eq!(unsafe { slopdesk_client_ctl_verb(core::ptr::null()) }, -1);
    }

    /// An ABSENT field and an EMPTY one are different answers, and `present` is what tells them
    /// apart: a `learn` with no path takes the focused pane's cwd.
    #[test]
    fn an_absent_field_is_distinguishable_from_an_empty_one() {
        assert_eq!(field(&Op::Learn { path: None }, SLOPDESK_CTL_FIELD_PATH), None,);
        assert_eq!(
            field(
                &Op::Learn {
                    path: Some(String::new()),
                },
                SLOPDESK_CTL_FIELD_PATH,
            ),
            Some(String::new()),
        );
    }

    #[test]
    fn each_field_reads_only_off_the_ops_that_carry_it() {
        let tabs = Op::Tabs {
            window_id: Some("w1".to_owned()),
        };
        assert_eq!(field(&tabs, SLOPDESK_CTL_FIELD_WINDOW_ID), Some("w1".to_owned()));
        // A field this op does not carry is absent rather than a neighbour's value.
        assert_eq!(field(&tabs, SLOPDESK_CTL_FIELD_PANE_ID), None);
        assert_eq!(field(&tabs, SLOPDESK_CTL_FIELD_TARGET), None);

        let keys = Op::PaneSendKeys {
            pane_id: Some("p1".to_owned()),
            text: "ls".to_owned(),
            keys: vec!["Enter".to_owned(), "Escape".to_owned()],
        };
        assert_eq!(field(&keys, SLOPDESK_CTL_FIELD_PANE_ID), Some("p1".to_owned()));
        assert_eq!(field(&keys, SLOPDESK_CTL_FIELD_TEXT), Some("ls".to_owned()));

        assert_eq!(
            field(
                &Op::Jump {
                    query: Some("proj".to_owned()),
                    change_directory: true,
                },
                SLOPDESK_CTL_FIELD_QUERY,
            ),
            Some("proj".to_owned()),
        );
        assert_eq!(
            field(
                &Op::KeybindList {
                    action: Some("split".to_owned()),
                },
                SLOPDESK_CTL_FIELD_ACTION,
            ),
            Some("split".to_owned()),
        );
        assert_eq!(
            field(&Op::AgentStatus { id: "s1".to_owned() }, SLOPDESK_CTL_FIELD_ID,),
            Some("s1".to_owned()),
        );
    }

    #[test]
    fn the_named_keys_cross_in_order_and_stop_at_the_end() {
        let op = Op::PaneSendKeys {
            pane_id: None,
            text: String::new(),
            keys: vec!["Enter".to_owned(), "Escape".to_owned()],
        };
        let handle = core::ptr::from_ref(&op).cast::<SlopDeskCtlRequest>();
        // SAFETY: the handle points at a live op.
        assert_eq!(unsafe { slopdesk_client_ctl_key_count(handle) }, 2);
        let read = |index: usize| -> String {
            // SAFETY: as above; the null buffer is the documented sizing call.
            let needed = unsafe { slopdesk_client_ctl_key(handle, index, core::ptr::null_mut(), 0) };
            let mut out = vec![0_u8; needed];
            // SAFETY: as above, with a buffer of exactly that length.
            let _read = unsafe { slopdesk_client_ctl_key(handle, index, out.as_mut_ptr(), out.len()) };
            String::from_utf8(out).expect("a key name is UTF-8")
        };
        assert_eq!(read(0), "Enter");
        assert_eq!(read(1), "Escape");
        assert_eq!(read(2), "", "past the end writes nothing");
        // SAFETY: a null handle is the documented "no request" case.
        assert_eq!(unsafe { slopdesk_client_ctl_key_count(core::ptr::null()) }, 0);
    }

    #[test]
    fn the_numbers_and_the_flags_read_off_their_own_ops() {
        let capture = Op::PaneCapture {
            pane_id: None,
            lines: 42,
        };
        assert_eq!(number(&capture, SLOPDESK_CTL_NUMBER_LINES), 42);
        assert_eq!(
            number(&capture, SLOPDESK_CTL_NUMBER_BADGE),
            -1,
            "a number this op does not carry is absent",
        );

        let badge = Op::TabBadge {
            tab_id: None,
            kind: TabBadge::Finished,
        };
        let expected = TabBadge::ALL
            .iter()
            .position(|candidate| *candidate == TabBadge::Finished)
            .and_then(|index| i64::try_from(index).ok())
            .expect("`Finished` is on the ladder");
        assert_eq!(number(&badge, SLOPDESK_CTL_NUMBER_BADGE), expected);

        let open = Op::Open {
            target: "/tmp".to_owned(),
            editable: true,
            placement: 3,
        };
        assert_eq!(number(&open, SLOPDESK_CTL_NUMBER_PLACEMENT), 3);
        assert!(flag(&open, SLOPDESK_CTL_FLAG_EDITABLE));

        let fonts = Op::FontList {
            monospace_only: true,
            family: None,
            scope: None,
        };
        assert!(flag(&fonts, SLOPDESK_CTL_FLAG_MONOSPACE));
        assert_eq!(
            number(&fonts, SLOPDESK_CTL_NUMBER_SCOPE),
            -1,
            "no scope means both",
        );
        assert!(!flag(&fonts, SLOPDESK_CTL_FLAG_CHANGE_DIRECTORY));
    }

    // -- writing a reply ------------------------------------------------------------------------

    /// The whole loop through the boundary: a request line in, the callback's typed pushes out, and
    /// the response line the socket would write.
    #[test]
    fn a_callback_that_pushes_a_listing_produces_the_line_the_cli_reads() {
        unsafe extern "C" fn run(
            _context: *mut c_void,
            _request: *const SlopDeskCtlRequest,
            reply: *mut SlopDeskCtlReply,
        ) {
            let id = "w1";
            let title = "Work";
            // SAFETY: `reply` is the live cell the bridge lent for this call.
            unsafe { slopdesk_client_ctl_answer_list(reply, SLOPDESK_CTL_LIST_WINDOWS) };
            // SAFETY: as above; both runs are live for the push.
            unsafe {
                slopdesk_client_ctl_push_window(reply, SlopDeskCtlWindow {
                    id: SlopDeskCtlText {
                        bytes: id.as_ptr(),
                        len: id.len(),
                    },
                    title: SlopDeskCtlText {
                        bytes: title.as_ptr(),
                        len: title.len(),
                    },
                    tab_count: 2,
                    focused: true,
                });
            }
        }
        let bridge = Bridge {
            context: Context(core::ptr::null_mut()),
            run: Some(run),
        };
        assert_eq!(
            answer(r#"{"id":"1","method":"windows"}"#, &bridge),
            Some(
                "{\"id\":\"1\",\"ok\":true,\"result\":{\"windows\":[{\"focused\":true,\"id\":\"w1\",\"\
                 tabCount\":2,\"title\":\"Work\"}]}}\n"
                    .to_owned()
            ),
        );
    }

    /// An empty listing is still a listing — opened and never pushed to.
    #[test]
    fn an_opened_listing_with_nothing_in_it_is_an_empty_array() {
        unsafe extern "C" fn run(
            _context: *mut c_void,
            _request: *const SlopDeskCtlRequest,
            reply: *mut SlopDeskCtlReply,
        ) {
            // SAFETY: `reply` is the live cell the bridge lent for this call.
            unsafe { slopdesk_client_ctl_answer_list(reply, SLOPDESK_CTL_LIST_WINDOWS) };
        }
        let bridge = Bridge {
            context: Context(core::ptr::null_mut()),
            run: Some(run),
        };
        assert_eq!(
            answer(r#"{"id":"1","method":"windows"}"#, &bridge),
            Some("{\"id\":\"1\",\"ok\":true,\"result\":{\"windows\":[]}}\n".to_owned()),
        );
    }

    /// A callback that answers nothing leaves the request refused as an unknown method, NAMED — the
    /// honest report for a well-formed request this build has nowhere to send.
    #[test]
    fn a_callback_that_answers_nothing_refuses_by_name() {
        unsafe extern "C" fn run(
            _context: *mut c_void,
            _request: *const SlopDeskCtlRequest,
            _reply: *mut SlopDeskCtlReply,
        ) {
        }
        let bridge = Bridge {
            context: Context(core::ptr::null_mut()),
            run: Some(run),
        };
        let said = answer(r#"{"id":"1","method":"windows"}"#, &bridge).expect("a line is answered");
        assert!(said.contains("unknown method: windows"), "{said}");
        // An unregistered callback lands the same way rather than hanging or trapping.
        let silent = Bridge {
            context: Context(core::ptr::null_mut()),
            run: None,
        };
        assert!(
            answer(r#"{"id":"1","method":"windows"}"#, &silent)
                .is_some_and(|line| line.contains("unknown method"))
        );
    }

    #[test]
    fn a_refusal_crosses_as_its_code_and_its_token() {
        let mut cell = SlopDeskCtlReply(None);
        let detail = "f5";
        // SAFETY: the cell is a live stack value and the run is live for the call.
        unsafe {
            slopdesk_client_ctl_refuse(&raw mut cell, Refusal::UnknownKey.code(), lent(detail));
        }
        assert_eq!(
            cell.0,
            Some(slopdesk_clientctl::reply::Outcome::Refused {
                refusal: Refusal::UnknownKey,
                detail: "f5".to_owned(),
            }),
        );
        // A code this build cannot name writes nothing rather than a sentence nobody meant.
        let mut unnamed = SlopDeskCtlReply(None);
        // SAFETY: the cell is a live stack value; the null run is the documented empty case.
        unsafe {
            slopdesk_client_ctl_refuse(&raw mut unnamed, 0, SlopDeskCtlText {
                bytes: core::ptr::null(),
                len: 0,
            });
        }
        assert!(unnamed.0.is_none());
    }

    /// The three answers `agent-status` can give, and why the middle one is not the first.
    #[test]
    fn an_agent_reading_keeps_unresolved_and_unreported_apart() {
        let read = |seen: bool, has_status: bool, status: u8| {
            let mut cell = SlopDeskCtlReply(None);
            // SAFETY: the cell is a live stack value.
            unsafe { slopdesk_client_ctl_answer_agent(&raw mut cell, seen, has_status, status) };
            cell.0
        };
        assert_eq!(
            read(false, false, 0),
            Some(slopdesk_clientctl::reply::Outcome::Agent {
                seen: false,
                status: None,
            }),
        );
        assert_eq!(
            read(true, false, 0),
            Some(slopdesk_clientctl::reply::Outcome::Agent {
                seen: true,
                status: None,
            }),
            "the pane exists and has not reported — the watch keeps polling",
        );
        assert!(matches!(
            read(true, true, 3),
            Some(slopdesk_clientctl::reply::Outcome::Agent {
                seen: true,
                status: Some(_),
            }),
        ));
    }

    /// A push into a listing that is not open is a no-op rather than a wrong answer.
    #[test]
    fn a_push_with_no_matching_listing_open_changes_nothing() {
        let mut cell = SlopDeskCtlReply(None);
        let id = "w1";
        // SAFETY: the cell is a live stack value and the run is live for the call.
        unsafe {
            slopdesk_client_ctl_push_window(&raw mut cell, SlopDeskCtlWindow {
                id: SlopDeskCtlText {
                    bytes: id.as_ptr(),
                    len: id.len(),
                },
                title: SlopDeskCtlText {
                    bytes: core::ptr::null(),
                    len: 0,
                },
                tab_count: 0,
                focused: false,
            });
        }
        assert!(cell.0.is_none());
    }

    // -- the path -------------------------------------------------------------------------------

    #[test]
    fn the_socket_path_is_the_containers_file() {
        let container = "/tmp/SlopDesk";
        // SAFETY: both runs are live and the null buffer is the documented sizing call.
        let needed = unsafe {
            slopdesk_client_ctl_socket_path(container.as_ptr(), container.len(), core::ptr::null_mut(), 0)
        };
        let mut out = vec![0_u8; needed];
        // SAFETY: as above, with a buffer of exactly that length.
        let _written = unsafe {
            slopdesk_client_ctl_socket_path(container.as_ptr(), container.len(), out.as_mut_ptr(), out.len())
        };
        let path = String::from_utf8(out).expect("a path is UTF-8");
        // The env override is the machine's, so the assertion is about the SHAPE rather than the
        // exact answer: with no override this is the container's file, and with one it is that.
        assert!(
            path == "/tmp/SlopDesk/cli-control.sock"
                || std::env::var(slopdesk_clientctl::serve::SOCKET_ENV).is_ok_and(|set| set == path),
            "{path}",
        );
    }
}
