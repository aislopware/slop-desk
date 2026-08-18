//! Agent detection: `rust/slopdesk-agent` reached from the host's Swift.
//!
//! ## What crosses, and what deliberately does not
//! The Swift side keeps `AgentKind`, `ClaudeStatus`, `AgentScreenState` and friends as native
//! enums, and that is NOT the second implementation this repo forbids. They carry no
//! rules — a `switch` in a `SwiftUI` view needs a Swift enum, and marshalling one through C would
//! buy nothing. What moved is every function that DECIDES: which agent a name names, whether a
//! chunk holds a keystroke, whether a title was agent-written, when a screen verdict may be
//! published, and the 900-line state machine that folds all of it into one status.
//!
//! The vocabularies are therefore a CONTRACT between the two languages, pinned by
//! `scripts/check-supervisor.sh` the way every other cross-language constant here is: the
//! discriminants below are the wire, and a Swift enum that reorders its cases fails the gate rather
//! than silently reporting `working` for `blocked`.
//!
//! ## Strings arrive in one buffer, not one pointer each
//! A foreground job's process carries three optional strings, and a whole job carries several
//! processes. That many `(ptr, len)` pairs would mean that many nested `withUnsafeBytes` on the
//! Swift side per call, which is unreadable and easy to get subtly wrong. Instead the caller
//! concatenates them into ONE buffer and passes `(offset, len, present)` triples into it: one
//! pointer, one lifetime, one scope. Every offset is bounds-checked here against the buffer's real
//! length, because this is untrusted input like everything else in this crate.
//!
//! ## A hook body does not arrive at all — it passes through
//! It used to be the other big user of that buffer: Swift read the JSON, flattened the event into a
//! `Signal` of spans, and this module rebuilt it. Both ends of that are gone. The body crosses as
//! the raw bytes hostd read off the socket, and `slopdesk_agent_detector_hook` parses and folds it
//! in the one call — so nothing between the socket and the fold is a value either language holds.

use core::ffi::c_uchar;

use slopdesk_agent::{
    AgentDetectionHold, AgentScreenDetection, AgentScreenState, ClaudeHookEvent, ClaudeStatus,
    ClaudeStatusMachine, Emission, ForegroundJob, ForegroundJobProcess, NotificationKind, PaneDetector,
    attention, badge, sleep,
};

use crate::{borrow, deliver};

// MARK: The shared vocabulary, as discriminants
//
// Each `from_*` is TOTAL: an unknown byte answers the conservative case rather than panicking, so a
// Swift enum that grows a case before this crate learns it degrades instead of aborting the host.

/// `ClaudeStatus` — the order is `ClaudeStatus::ALL`, which is also the Swift enum's case order.
pub(crate) const fn status_from(byte: u8) -> ClaudeStatus {
    match byte {
        1 => ClaudeStatus::Idle,
        2 => ClaudeStatus::Working,
        3 => ClaudeStatus::Done,
        4 => ClaudeStatus::NeedsPermission,
        _ => ClaudeStatus::None,
    }
}

/// The inverse: the byte a status crosses as.
pub(crate) const fn status_byte(status: ClaudeStatus) -> u8 {
    match status {
        ClaudeStatus::None => 0,
        ClaudeStatus::Idle => 1,
        ClaudeStatus::Working => 2,
        ClaudeStatus::Done => 3,
        ClaudeStatus::NeedsPermission => 4,
    }
}

/// `AgentScreenState` — `unknown` is the conservative answer and so is the fallback.
const fn screen_state_from(byte: u8) -> AgentScreenState {
    match byte {
        0 => AgentScreenState::Idle,
        1 => AgentScreenState::Working,
        2 => AgentScreenState::Blocked,
        _ => AgentScreenState::Unknown,
    }
}

/// `ClaudeHookEvent::NotificationKind` — `other` is informational, so it is the safe fallback.
const fn notification_from(byte: u8) -> NotificationKind {
    match byte {
        0 => NotificationKind::Permission,
        1 => NotificationKind::WaitingForInput,
        _ => NotificationKind::Other,
    }
}

// MARK: The C-visible shapes

/// One optional string, as a window into the signal's string buffer.
///
/// `present == false` is Swift's `nil`; `present == true` with `len == 0` is the empty string. The
/// machine tells those apart (an empty session id is not an unattributed event), so the ABI must.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Span {
    /// Byte offset into the signal's string buffer.
    pub offset: usize,
    /// Length in bytes, which may be zero.
    pub len: usize,
    /// `false` is Swift's `nil`; `true` with `len == 0` is the empty string.
    pub present: bool,
}

/// A screen verdict, in the fields the temporal layer compares. Deliberately WITHOUT the rule id
/// and fallback reason: `hold` reads neither, and a struct that carried them would imply it did.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Detection {
    /// An `AgentScreenState` discriminant: 0 idle · 1 working · 2 blocked · 3 unknown.
    pub state: u8,
    /// The verdict names visible marks but asserts no state of its own.
    pub skip_state_update: bool,
    /// An idle mark is on screen right now.
    pub visible_idle: bool,
    /// A blocking prompt is on screen right now.
    pub visible_blocker: bool,
    /// A working mark is on screen right now.
    pub visible_working: bool,
}

impl Detection {
    const fn resolve(self) -> AgentScreenDetection {
        AgentScreenDetection {
            state: screen_state_from(self.state),
            skip_state_update: self.skip_state_update,
            visible_idle: self.visible_idle,
            visible_blocker: self.visible_blocker,
            visible_working: self.visible_working,
            matched_rule_id: None,
            fallback_reason: None,
        }
    }
}

/// The flat hook discriminants, as the event they name.
///
/// Total over `hook`, defaulting to the session-start case, which changes no status a later signal
/// cannot correct. ONE spelling on purpose: the same mapping serves the detector's hook door and a
/// body `slopdesk-hookevent` just read off the socket, and two copies of it would be two
/// answers to "is discriminant 7 an interrupt".
fn hook_event_of(
    hook: u8,
    notification: u8,
    session_id: Option<String>,
    tool: Option<String>,
    tool_use_id: Option<String>,
    label: Option<String>,
) -> ClaudeHookEvent {
    match hook {
        1 => ClaudeHookEvent::UserPromptSubmit { session_id },
        2 => {
            ClaudeHookEvent::PreToolUse {
                session_id,
                tool,
                tool_use_id,
            }
        },
        3 => {
            ClaudeHookEvent::PostToolUse {
                session_id,
                tool,
                tool_use_id,
            }
        },
        4 => {
            ClaudeHookEvent::Notification {
                kind: notification_from(notification),
                label,
                tool_use_id,
                session_id,
            }
        },
        5 => ClaudeHookEvent::Stop { session_id, label },
        6 => ClaudeHookEvent::SubagentStop { agent_id: session_id },
        7 => ClaudeHookEvent::Interrupted { session_id },
        8 => ClaudeHookEvent::SessionEnd { session_id },
        9 => ClaudeHookEvent::PreCompact { session_id },
        _ => ClaudeHookEvent::SessionStart { session_id },
    }
}

/// Borrows a caller's detection struct, answering the default verdict for null.
///
/// # Safety
/// `detection` must be null or point to one live, initialised [`Detection`] for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C struct pointer becoming a value"
)]
unsafe fn detection_at(detection: *const Detection) -> AgentScreenDetection {
    if detection.is_null() {
        return AgentScreenDetection::plain(AgentScreenState::Unknown);
    }
    // SAFETY: non-null and, by the caller's obligation, live and initialised for this call.
    unsafe { *detection }.resolve()
}

// MARK: Pure entry points
//
// Each is one call over a borrowed string; none of them remembers anything.

/// One `(bytes, len) -> bool` predicate over a UTF-8 name.
macro_rules! predicate {
    ($(#[$meta:meta])* $name:ident, |$text:ident| $body:expr) => {
        $(#[$meta])*
        ///
        /// # Safety
        /// `bytes` must be null or point to `len` initialised bytes live for the call.
        #[unsafe(no_mangle)]
        #[expect(
            unsafe_code,
            reason = "an exported C entry point is unsafe by definition in edition 2024"
        )]
        pub unsafe extern "C" fn $name(bytes: *const c_uchar, len: usize) -> bool {
            // SAFETY: the caller's obligation, restated above; `borrow` states its own.
            let raw = unsafe { borrow(bytes, len) };
            match core::str::from_utf8(raw) {
                Ok($text) => $body,
                // Not a name this crate can reason about, so it is not one of ours.
                Err(_) => false,
            }
        }
    };
}

predicate!(
    /// Whether a process name is a generic runtime or shell rather than an agent.
    slopdesk_agent_kind_is_generic, |text| slopdesk_agent::kind::AgentKind::is_generic_runtime_or_shell(text)
);
predicate!(
    /// Whether a process name is a credential prompt or remote-shell entry point the control RPC
    /// must refuse to touch.
    slopdesk_agent_is_sensitive, |text| slopdesk_agent::process::is_sensitive(text)
);

/// Which agent a process name names, as an `AgentKind` discriminant, or `-1` for none.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_kind_identify(bytes: *const c_uchar, len: usize) -> i32 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(bytes, len) };
    let Ok(text) = core::str::from_utf8(raw) else {
        return -1;
    };
    slopdesk_agent::AgentKind::identify(text).map_or(-1, kind_index)
}

/// An agent as its index into `AgentKind::ALL`, which is the Swift enum's `allCases` order.
fn kind_index(kind: slopdesk_agent::AgentKind) -> i32 {
    slopdesk_agent::AgentKind::ALL
        .iter()
        .position(|candidate| *candidate == kind)
        .and_then(|index| i32::try_from(index).ok())
        .unwrap_or(-1)
}

// Neither the lookup NORMALISATION nor the two-separator `path_basename` has a door.
//
// Swift never asks for either: it asks WHICH agent a name is (`slopdesk_agent_kind_identify`) and
// what a Unix foreground poll called it (`slopdesk_agent_process_basename`, `/`-only on purpose).
// Both rules stay reachable through the doors that DO answer a question a caller has, and both keep
// their own tests in `slopdesk-agent` — a door onto a step of a rule invites a caller to rebuild
// that rule out of steps and get the last one wrong.

/// The basename of a PTY foreground process name: the last non-empty `/`-separated component, or
/// the whole input when there is none.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_process_basename(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow`/`deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(bytes, len)) else {
            return 0;
        };
        deliver(slopdesk_agent::process::basename(text).as_bytes(), out, cap)
    }
}

/// The CANONICAL name of an executable path — the basename, except a version-named executable,
/// which is named by the directory that owns it.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_canonical_name(
    bytes: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow`/`deliver` state their own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(bytes, len)) else {
            return 0;
        };
        deliver(slopdesk_agent::process::canonical_name(text).as_bytes(), out, cap)
    }
}

/// The one badge a tab row shows, as a [`TabBadge`] discriminant, or `-1` for an all-clear row.
///
/// Every optional input crosses as a value plus its absence sentinel rather than a pointer: the
/// completion and the progress mirror are `-1` when there is none, which is the same shape the
/// answer comes back in.
///
/// The five gates are the user's badge toggles, `true` meaning shown. They cross as separate flags
/// rather than a mask so no bit position has to be spelled on both sides of the boundary; a caller
/// with no preferences to apply passes `true` five times, which is the ungated ladder exactly.
///
/// # Safety
/// `foreground` must be null or point to `foreground_len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_tab_badge(
    agent: c_uchar,
    completion: i8,
    is_busy: bool,
    foreground: *const c_uchar,
    foreground_len: usize,
    fresh: bool,
    progress: i8,
    unseen_agent_done: bool,
    agent_while_processing: bool,
    agent_when_complete: bool,
    agent_when_awaiting_input: bool,
    command_when_finishes: bool,
    command_when_fails: bool,
) -> i8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(foreground, foreground_len) };
    let signals = badge::Signals {
        agent: status_from(agent),
        completion: match completion {
            0 => Some(badge::Completion::Success),
            1 => Some(badge::Completion::Failure),
            _ => None,
        },
        is_busy,
        // A foreground name that is not UTF-8 names no program this rule knows.
        foreground: core::str::from_utf8(raw).unwrap_or(""),
        freshness: if fresh {
            badge::Freshness::Fresh
        } else {
            badge::Freshness::Settled
        },
        progress: match progress {
            0 => Some(badge::Progress::Running),
            1 => Some(badge::Progress::Error),
            _ => None,
        },
        unseen_agent_done,
    };
    let gates = badge::Gates {
        agent_while_processing,
        agent_when_complete,
        agent_when_awaiting_input,
        command_when_finishes,
        command_when_fails,
    };
    badge::resolve_gated(signals, gates).map_or(-1, badge_byte)
}

/// A badge discriminant, or `-1` when it names none.
#[expect(
    clippy::cast_possible_truncation,
    reason = "nine variants: the index cannot leave i8"
)]
fn badge_byte(badge: badge::TabBadge) -> i8 {
    badge::TabBadge::ALL
        .iter()
        .position(|candidate| *candidate == badge)
        .map_or(-1, |index| index as i8)
}

/// A badge discriminant back to its variant, or `None` for a byte naming no badge.
fn badge_from(raw: c_uchar) -> Option<badge::TabBadge> {
    badge::TabBadge::ALL.get(raw as usize).copied()
}

/// Whether a badge discriminant is ATTENTION-class — unread, rather than busy. An unknown byte is
/// not: a badge this build cannot name must never raise the attention queue.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_badge_needs_attention(badge: c_uchar) -> bool {
    badge_from(badge).is_some_and(badge::TabBadge::needs_attention)
}

/// Whether a badge discriminant is a BUSY tier. An unknown byte is not.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_badge_is_busy_tier(badge: c_uchar) -> bool {
    badge_from(badge).is_some_and(badge::TabBadge::is_busy_tier)
}

/// Whether a status is waiting on a human or finished unseen — the level the ring reads.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_is_attention(status: c_uchar) -> bool {
    attention::is_attention(status_from(status))
}

/// Whether `previous → current` is an attention EDGE worth interrupting someone for. `previous` is
/// the state the caller last NOTIFIED for, not the last one it saw.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_attention_edge(previous: c_uchar, current: c_uchar) -> bool {
    attention::is_edge(status_from(previous), status_from(current))
}

/// Whether `previous → current` is a hook-less finish: an active state settling to plain idle.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_attention_completion(previous: c_uchar, current: c_uchar) -> bool {
    attention::is_completion(status_from(previous), status_from(current))
}

/// The POSITION of the oldest pane needing attention in a run of statuses, or `-1` for none.
///
/// A position, not an identity: the caller holds the panes, and this rule only ranks them.
///
/// # Safety
/// `statuses` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_attention_oldest(statuses: *const c_uchar, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(statuses, len) };
    let statuses: Vec<ClaudeStatus> = raw.iter().copied().map(status_from).collect();
    attention::oldest_needing_attention(&statuses)
        .map_or(-1, |position| isize::try_from(position).unwrap_or(-1))
}

/// One press of the jump-to-attention walk: the position of the next unvisited queue entry, or
/// `-1` to pop back to the origin, or `-2` when there is nowhere to pop to.
///
/// `visited` is one flag per queue entry, in the caller's queue order.
///
/// # Safety
/// `visited` must be null or point to `len` initialised bools live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_attention_walk(
    visited: *const bool,
    len: usize,
    origin_is_live: bool,
) -> isize {
    let flags = if visited.is_null() || len == 0 {
        &[][..]
    } else {
        // SAFETY: the caller's obligation, restated above.
        unsafe { core::slice::from_raw_parts(visited, len) }
    };
    match attention::walk_step(flags, origin_is_live) {
        attention::Step::Advance(position) => isize::try_from(position).unwrap_or(-2),
        attention::Step::PopHome => -1,
        attention::Step::PopNowhere => -2,
    }
}

/// The rolled-up status of a run of statuses, given as discriminants.
///
/// # Safety
/// `statuses` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_status_rollup(statuses: *const c_uchar, len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(statuses, len) };
    status_byte(ClaudeStatus::rollup(raw.iter().copied().map(status_from)))
}

/// The rollup rank of one status: `none(0) < idle(1) < done(2) < working(3) < needsPermission(4)`.
///
/// This is the wire's `state` byte for type 27, and it is deliberately NOT the case order — the
/// case order is a declaration, the rank is a rule.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_status_urgency(status: u8) -> u8 {
    status_from(status).urgency()
}

/// The inverse: a wire urgency byte back to a status discriminant. An unknown byte answers `none`,
/// so a newer host's datagram degrades rather than trapping an older client.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_status_from_urgency(urgency: u8) -> u8 {
    status_byte(ClaudeStatus::from_urgency(urgency))
}

/// The short human label for a status — the one source the dot's tooltip and the sidebar's
/// fallback summary both read, so they cannot drift.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_agent_status_display_label(
    status: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(status_from(status).display_label().as_bytes(), out, cap) }
}

// MARK: The temporal layer

/// One of `AgentDetectionHold`'s tuning constants, by index.
///
/// 0 pending-idle recheck · 1 pending-idle confirmations · 2 pending-idle cap · 3 stable-visible
/// refresh · 4 startup grace · 5 scan interval. An unknown index answers 0, which no caller can
/// mistake for an interval.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_hold_constant(index: u8) -> f64 {
    match index {
        0 => AgentDetectionHold::PENDING_IDLE_RECHECK,
        1 => f64::from(AgentDetectionHold::PENDING_IDLE_CONFIRMATIONS),
        2 => AgentDetectionHold::PENDING_IDLE_CAP,
        3 => AgentDetectionHold::STABLE_VISIBLE_SIGNAL_REFRESH,
        4 => AgentDetectionHold::STARTUP_GRACE_WINDOW,
        5 => AgentDetectionHold::SCAN_INTERVAL,
        _ => 0.0,
    }
}

/// Whether a still-visible blocker is due its periodic re-announcement. `has_last_refresh == false`
/// means "never refreshed", which is always due.
///
/// # Safety
/// Both pointers must be null or point to live, initialised [`Detection`]s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_hold_refresh_due(
    previous: *const Detection,
    next: *const Detection,
    last_refresh: f64,
    has_last_refresh: bool,
    now: f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `detection_at` states its own.
    unsafe {
        AgentDetectionHold::stable_visible_signal_refresh_due(
            &detection_at(previous),
            &detection_at(next),
            has_last_refresh.then_some(last_refresh),
            now,
        )
    }
}

/// Whether a verdict differs enough from the last published one to be worth announcing.
///
/// # Safety
/// Both pointers must be null or point to live, initialised [`Detection`]s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_hold_should_publish(
    previous: *const Detection,
    next: *const Detection,
    agent_changed: bool,
    process_exited: bool,
    refresh_due: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `detection_at` states its own.
    unsafe {
        AgentDetectionHold::should_publish(
            &detection_at(previous),
            &detection_at(next),
            agent_changed,
            process_exited,
            refresh_due,
        )
    }
}

/// Creates a hold. Exactly one [`slopdesk_agent_hold_free`] per call; see `docs/55` §4b.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_hold_new() -> *mut AgentDetectionHold {
    Box::into_raw(Box::new(AgentDetectionHold::new()))
}

/// Frees a hold. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_agent_hold_new`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_hold_free(handle: *mut AgentDetectionHold) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from `Box::into_raw` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Whether the hold is currently suppressing an idle transition.
///
/// # Safety
/// `handle` must be null, or a live hold with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_hold_is_holding_idle(handle: *mut AgentDetectionHold) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    unsafe { &*handle }.is_holding_idle()
}

/// One of the two idle holds, by name. Both are consulted on every real decision — see
/// [`slopdesk_agent_hold_decide`] — and each is exported on its own only because each is a rule
/// with its own tests.
macro_rules! hold_arm {
    ($(#[$meta:meta])* $name:ident, $method:ident) => {
        $(#[$meta])*
        ///
        /// # Safety
        /// `handle` must be null, or a live hold with no other call on it in flight; both detection
        /// pointers must be null or point to live, initialised values for the call.
        #[unsafe(no_mangle)]
        #[expect(
            unsafe_code,
            reason = "an exported C entry point is unsafe by definition in edition 2024"
        )]
        pub unsafe extern "C" fn $name(
            handle: *mut AgentDetectionHold,
            previous: *const Detection,
            next: *const Detection,
            agent_changed: bool,
            process_exited: bool,
            now: f64,
        ) -> bool {
            if handle.is_null() {
                return false;
            }
            // SAFETY: the caller's obligations, restated above; `detection_at` states its own.
            unsafe {
                (*handle).$method(
                    &detection_at(previous),
                    &detection_at(next),
                    agent_changed,
                    process_exited,
                    now,
                )
            }
        }
    };
}

hold_arm!(
    /// The working→idle confirmation hold: three confirming reads, or the 700 ms cap, release it.
    slopdesk_agent_hold_working_to_idle, should_hold_working_to_idle
);
hold_arm!(
    /// The blocked→idle hold, which a visible idle deliberately does NOT bypass.
    slopdesk_agent_hold_blocked_to_idle, should_hold_blocked_to_idle
);

/// The whole temporal decision: hold the transition, or publish it.
///
/// # Safety
/// `handle` must be null, or a live hold with no other call on it in flight; both detection
/// pointers must be null or point to live, initialised values for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_hold_decide(
    handle: *mut AgentDetectionHold,
    previous: *const Detection,
    next: *const Detection,
    agent_changed: bool,
    process_exited: bool,
    last_refresh: f64,
    has_last_refresh: bool,
    now: f64,
) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: the caller's obligations, restated above; `detection_at` states its own.
    unsafe {
        (*handle).decide(
            &detection_at(previous),
            &detection_at(next),
            agent_changed,
            process_exited,
            has_last_refresh.then_some(last_refresh),
            now,
        )
    }
}

// MARK: The pane detector
//
// One layer above the machine: the FUSION every host input folds through, and the two dedupe
// anchors that turn its verdicts into a control stream. See `slopdesk_agent::detector`.
//
// Every fold answers a BITMASK naming the slots it filled, and the filled slots are then pulled off
// the handle one at a time. That is a departure from the pure §4 door, and it is the same departure
// the job handle already makes for the same reason: one fold owes up to four values of three
// different shapes, and a single flat answer buffer encoding all four would be a second wire format
// nobody asked for. The emission lives on the handle exactly as long as it takes the caller to read
// it — the next fold replaces it.

/// A detector plus the emission its last fold produced.
#[derive(Debug)]
pub struct SlopDeskAgentDetector {
    detector: PaneDetector,
    emission: Emission,
}

impl SlopDeskAgentDetector {
    /// Stores one fold's emission and answers the slot mask.
    fn record(&mut self, emission: Emission) -> u32 {
        let slots = emission.slots();
        self.emission = emission;
        slots
    }
}

/// Delivers an optional answer, `-1` when the option is empty.
///
/// The distinction matters at every door below: an absent intent and an intent that was CLEARED are
/// different frames, and a 0-length answer is the second one.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "it forwards one obligation, `deliver`'s, and states it above"
)]
unsafe fn deliver_optional(answer: Option<&str>, out: *mut c_uchar, cap: usize) -> isize {
    let Some(answer) = answer else {
        return -1;
    };
    // SAFETY: the caller's obligation, restated above, is exactly `deliver`'s.
    isize::try_from(unsafe { deliver(answer.as_bytes(), out, cap) }).unwrap_or(-1)
}

/// The detector's window constants, by index: 0 the done→idle default, 1 the report grace window,
/// 2 the wrapper suppression window, 3 the intent clamp in scalars. An unknown index answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_detector_constant(index: u8) -> f64 {
    match index {
        0 => ClaudeStatusMachine::DEFAULT_DONE_TO_IDLE_TIMEOUT,
        1 => PaneDetector::REPORT_GRACE_WINDOW,
        2 => PaneDetector::WRAPPER_SUPPRESSION_WINDOW,
        3 => {
            // A scalar count this small crosses an `f64` exactly.
            let clamp = u32::try_from(PaneDetector::MAX_INTENT_CHARS).unwrap_or(u32::MAX);
            f64::from(clamp)
        },
        _ => 0.0,
    }
}

/// Creates a detector with the given done→idle decay. Exactly one
/// [`slopdesk_agent_detector_free`] per call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_detector_new(done_to_idle_timeout: f64) -> *mut SlopDeskAgentDetector {
    Box::into_raw(Box::new(SlopDeskAgentDetector {
        detector: PaneDetector::new(done_to_idle_timeout),
        emission: Emission::default(),
    }))
}

/// Frees a detector. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_agent_detector_new`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_free(handle: *mut SlopDeskAgentDetector) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from `Box::into_raw` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one foreground-process sample and answers the slot mask.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight; `name` must be
/// null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_sample(
    handle: *mut SlopDeskAgentDetector,
    name: *const c_uchar,
    len: usize,
    now: f64,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let text = core::str::from_utf8(borrow(name, len)).unwrap_or_default();
        let emission = (*handle).detector.sample(text, now);
        (*handle).record(emission)
    }
}

/// Reads one raw hook POST body and folds what it says.
///
/// Validate-then-drop: a body that is not a hook this build answers — not JSON, not an object, an
/// event name nothing knows, a tool call with no identity — changes nothing and answers 0.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight; `body` must be
/// null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_hook(
    handle: *mut SlopDeskAgentDetector,
    body: *const c_uchar,
    len: usize,
    now: f64,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let Some(parsed) = slopdesk_hookevent::parse(borrow(body, len)) else {
            return 0;
        };
        let event = hook_event_of(
            parsed.hook,
            parsed.notification,
            parsed.session_id,
            parsed.tool,
            parsed.tool_use_id,
            parsed.label,
        );
        let emission = (*handle)
            .detector
            .hook(event, parsed.kind_byte, parsed.prompt.as_deref(), now);
        (*handle).record(emission)
    }
}

/// Folds an agent self-report — the ctl `report` verb.
///
/// `message` is the optional human line; pass a null pointer for no message, which is NOT the same
/// as an empty one (an empty message is a label the agent chose to make empty).
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight; each `(ptr, len)`
/// pair must be null or point to that many initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_report(
    handle: *mut SlopDeskAgentDetector,
    state: *const c_uchar,
    state_len: usize,
    message: *const c_uchar,
    message_len: usize,
    now: f64,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let state = core::str::from_utf8(borrow(state, state_len)).unwrap_or_default();
        let label = if message.is_null() {
            None
        } else {
            core::str::from_utf8(borrow(message, message_len)).ok()
        };
        let emission = (*handle).detector.report(state, label, now);
        (*handle).record(emission)
    }
}

/// A read-only accessor over the detector, answering `$fallback` for a null handle.
macro_rules! detector_observer {
    ($(#[$meta:meta])* $name:ident -> $type:ty, $fallback:expr, |$subject:ident| $body:expr) => {
        $(#[$meta])*
        ///
        /// # Safety
        /// `handle` must be null, or a live detector with no other call on it in flight.
        #[unsafe(no_mangle)]
        #[expect(
            unsafe_code,
            reason = "an exported C entry point is unsafe by definition in edition 2024"
        )]
        pub unsafe extern "C" fn $name(handle: *mut SlopDeskAgentDetector) -> $type {
            if handle.is_null() {
                return $fallback;
            }
            // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
            let $subject = unsafe { &mut *handle };
            $body
        }
    };
}

detector_observer!(
    /// Re-asserts the detector's CURRENT truth as fresh messages for a returning client, and
    /// answers the slot mask. Takes no clock: nothing here is folded, only re-read.
    slopdesk_agent_detector_reestablish -> u32, 0, |subject| {
        let emission = subject.detector.reestablish_on_reattach();
        subject.record(emission)
    }
);
detector_observer!(
    /// The current rolled-up status.
    slopdesk_agent_detector_status -> u8, 0, |subject| status_byte(subject.detector.status())
);
detector_observer!(
    /// Whether the current status was reached quietly (no announcement is owed).
    slopdesk_agent_detector_is_quiet -> bool, false, |subject| subject.detector.is_quiet()
);
detector_observer!(
    /// Whether a hook feed has claimed this pane, making screen verdicts corroboration.
    slopdesk_agent_detector_has_authoritative_feed -> bool, false,
    |subject| subject.detector.has_authoritative_feed()
);
detector_observer!(
    /// Whether the agent's own OSC notifications are redundant and must not be forwarded.
    slopdesk_agent_detector_suppresses_child_notifications -> bool, false,
    |subject| subject.detector.suppresses_child_notifications()
);
detector_observer!(
    /// Whether the type-27 stream has ever emitted, which is what makes the anchor readable.
    slopdesk_agent_detector_has_last_status -> bool, false,
    |subject| subject.detector.last_emitted_status().is_some()
);
detector_observer!(
    /// The anchor's state byte, or 0 when the stream has never emitted.
    slopdesk_agent_detector_last_status_state -> u8, 0,
    |subject| subject.detector.last_emitted_status().map_or(0, |triple| triple.state)
);
detector_observer!(
    /// The anchor's kind byte, or 0 when the stream has never emitted.
    slopdesk_agent_detector_last_status_kind -> u8, 0,
    |subject| subject.detector.last_emitted_status().map_or(0, |triple| triple.kind)
);

/// Drives the done→idle decay one clock tick, and answers the slot mask.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_tick(handle: *mut SlopDeskAgentDetector, now: f64) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    unsafe {
        let emission = (*handle).detector.tick(now);
        (*handle).record(emission)
    }
}

/// Folds one screen-rule verdict.
///
/// The COMPACT detection, not the [`Signal`] the machine's own screen fold takes: the two optional
/// strings a full verdict carries — the matched rule id and the fallback reason — are carried for
/// EXPLANATION, and nothing downstream of here reads either. Taking them anyway would mean a string
/// buffer and six spans on the Swift side, per scan, to reach a field the machine never looks at.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight; `detection` must
/// be null or point to one live [`Detection`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_screen(
    handle: *mut SlopDeskAgentDetector,
    detection: *const Detection,
    now: f64,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `detection_at` states its own.
    unsafe {
        let verdict = detection_at(detection);
        let emission = (*handle).detector.screen(verdict, now);
        (*handle).record(emission)
    }
}

/// Folds one sniffed OSC 0/2 title.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight; `title` must be
/// null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_title(
    handle: *mut SlopDeskAgentDetector,
    title: *const c_uchar,
    len: usize,
    now: f64,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let text = core::str::from_utf8(borrow(title, len)).unwrap_or_default();
        let emission = (*handle).detector.title(text, now);
        (*handle).record(emission)
    }
}

/// Folds one client→PTY input chunk — the Esc-cancel unblock edge.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight; `bytes` must be
/// null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_user_input(
    handle: *mut SlopDeskAgentDetector,
    bytes: *const c_uchar,
    len: usize,
    now: f64,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let emission = (*handle).detector.user_input(borrow(bytes, len), now);
        (*handle).record(emission)
    }
}

/// A string read off the detector, `-1` when the slot is empty.
macro_rules! detector_text {
    ($(#[$meta:meta])* $name:ident, |$subject:ident| $body:expr) => {
        $(#[$meta])*
        ///
        /// # Safety
        /// `handle` must be null, or a live detector with no other call on it in flight; `out` must
        /// be null or writable for `cap` bytes.
        #[unsafe(no_mangle)]
        #[expect(
            unsafe_code,
            reason = "an exported C entry point is unsafe by definition in edition 2024"
        )]
        pub unsafe extern "C" fn $name(
            handle: *mut SlopDeskAgentDetector,
            out: *mut c_uchar,
            cap: usize,
        ) -> isize {
            if handle.is_null() {
                return -1;
            }
            // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call;
            // `deliver_optional` states its own.
            unsafe {
                let $subject = &*handle;
                deliver_optional($body, out, cap)
            }
        }
    };
}

detector_text!(
    /// The last fold's type-26 basename, or `-1` when it filled no foreground slot.
    slopdesk_agent_detector_emit_foreground,
    |subject| subject.emission.foreground.as_deref()
);
detector_text!(
    /// The last fold's type-27 label, or `-1` when it filled no status slot. A blocked pane with no
    /// question text answers 0, which is a label the client draws as empty rather than as absent.
    slopdesk_agent_detector_emit_status_label,
    |subject| subject.emission.status.as_ref().map(|triple| triple.label.as_str())
);
detector_text!(
    /// The last fold's type-36 intent, or `-1` when it filled no intent slot. 0 means CLEARED.
    slopdesk_agent_detector_emit_intent,
    |subject| subject.emission.intent.as_deref()
);
detector_text!(
    /// The machine's short human label, or `-1` when it has none.
    slopdesk_agent_detector_status_label,
    |subject| subject.detector.status_label()
);
detector_text!(
    /// The anchor's label, or `-1` when the type-27 stream has never emitted.
    slopdesk_agent_detector_last_status_label,
    |subject| subject
        .detector
        .last_emitted_status()
        .map(|triple| triple.label.as_str())
);
detector_text!(
    /// The pane's current session intent, or `-1` when none is established.
    slopdesk_agent_detector_session_intent,
    |subject| subject.detector.session_intent()
);

/// The last fold's type-27 `(state, kind)` pair, packed as `state << 8 | kind`.
///
/// One door rather than two because the two bytes are one value: a caller that read the state and
/// then folded again before reading the kind would ship a frame that never existed.
///
/// # Safety
/// `handle` must be null, or a live detector with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_detector_emit_status_bytes(
    handle: *mut SlopDeskAgentDetector,
) -> u16 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    let subject = unsafe { &*handle };
    subject
        .emission
        .status
        .as_ref()
        .map_or(0, |triple| u16::from(triple.state) << 8 | u16::from(triple.kind))
}

/// The pure intent derivation — the first titleable line of a submitted prompt, or `-1`.
///
/// # Safety
/// `prompt` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_intent_line(
    prompt: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> isize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let text = core::str::from_utf8(borrow(prompt, len)).unwrap_or_default();
        deliver_optional(slopdesk_agent::intent_line(text).as_deref(), out, cap)
    }
}

/// The pure topic derivation — claude's own session title behind its telltale glyph, or `-1`.
///
/// # Safety
/// `title` must be null or point to `len` initialised bytes live for the call; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_topic_line(
    title: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> isize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let text = core::str::from_utf8(borrow(title, len)).unwrap_or_default();
        deliver_optional(slopdesk_agent::topic_line(text).as_deref(), out, cap)
    }
}

/// The `kind` byte a fold should leave standing. Pure and total over every byte.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_block_kind(standing: u8, ledger: u8, event: u8, blocked: bool) -> u8 {
    slopdesk_agent::block_kind(standing, ledger, event, blocked)
}

// MARK: The foreground job
//
// A job is a process-group id plus N processes, each carrying up to three optional strings and a
// whole argv. That is too much shape for one flat struct, so it is STAGED: build the job on a
// handle, then ask it a question. Same pattern as the replay buffer's input slot (docs/55 §4b),
// for the same reason — one item at a time, no list encoding to get wrong.

/// A job under construction, plus the answer slot the identify call fills.
#[derive(Debug, Default)]
pub struct SlopDeskAgentJob {
    job: ForegroundJob,
    answer: String,
}

/// The Swift side's symlink resolver: `(ctx, token, token_len, out, cap) -> needed`.
///
/// `0` means "this token resolves to nothing I know" — §4's `Option::None`, which is also the only
/// thing an empty basename could have meant.
pub type ResolveFn = unsafe extern "C" fn(
    ctx: *mut core::ffi::c_void,
    token: *const c_uchar,
    token_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize;

/// A C resolver, borrowed for the length of one identify call.
struct Resolver {
    call: Option<ResolveFn>,
    context: *mut core::ffi::c_void,
}

impl slopdesk_agent::SymlinkResolver for Resolver {
    #[expect(
        unsafe_code,
        reason = "calling back out through a C function pointer is the inverted half of the boundary"
    )]
    fn resolve(&self, token: &str) -> Option<String> {
        // A null callback is NOT "resolve nothing". `AgentJobIdentifier.defaultSymlinkResolver` is
        // `nil` on purpose, and says why: routing a filesystem touch back out through the trampoline
        // would pay two boundary crossings per token to reach the same `realpath`, so the crate runs
        // it here instead. Returning `None` for a missing callback made that comment a lie — the
        // host probe resolved no symlinks at all, and `realpath_basename`, which exists for exactly
        // this arm, had no caller anywhere in either language.
        let Some(call) = self.call else {
            return slopdesk_agent::job::realpath_basename(token);
        };
        let mut out = vec![0u8; 512];
        // SAFETY: `out` is live and `out.len()` long for the call, and the caller's obligation on
        // `slopdesk_agent_job_identify` is that `call`/`context` are valid for its whole duration.
        let needed = unsafe {
            call(
                self.context,
                token.as_ptr(),
                token.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        if needed == 0 {
            return None;
        }
        if needed > out.len() {
            out = vec![0u8; needed];
            // SAFETY: as above, with a buffer the callback itself asked for.
            let again = unsafe {
                call(
                    self.context,
                    token.as_ptr(),
                    token.len(),
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            if again == 0 || again > out.len() {
                return None;
            }
            out.truncate(again);
        } else {
            out.truncate(needed);
        }
        String::from_utf8(out).ok()
    }
}

/// One of the screen-dissent windows, in seconds, by index.
///
/// `0` how long the screen must claim BLOCKED before it may raise a block the hook feed never
/// announced; `1` how long it must contradict the authoritative status the other way before it may
/// release one. An unknown index answers 0, which is no window at all rather than a plausible one.
///
/// The two are ASYMMETRIC on purpose and the asymmetry is the policy, so a caller that transcribed
/// them would not merely drift — it would state a policy the detector does not run. Nothing in the
/// shell decides by these; what asks is a test that has to drive the clock PAST one of them, and a
/// test that walks its own copy of the window proves the detector agrees with the test rather than
/// with itself.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_dissent_seconds(index: c_uchar) -> f64 {
    match index {
        0 => ClaudeStatusMachine::SCREEN_DISSENT_TO_RAISE,
        1 => ClaudeStatusMachine::SCREEN_DISSENT_TO_RELEASE,
        _ => 0.0,
    }
}

/// Creates an empty job for the given process group. Exactly one [`slopdesk_agent_job_free`] per
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_job_new(process_group_id: i32) -> *mut SlopDeskAgentJob {
    Box::into_raw(Box::new(SlopDeskAgentJob {
        job: ForegroundJob {
            process_group_id,
            processes: Vec::new(),
        },
        answer: String::new(),
    }))
}

/// Frees a job. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_agent_job_new`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_job_free(handle: *mut SlopDeskAgentJob) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from `Box::into_raw` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Appends one process. Its three optional strings ride in the shared buffer, as spans, the same
/// way a signal's do — a present-but-empty span is an empty string, an absent one is Swift's `nil`.
///
/// # Safety
/// `handle` must be null or a live job with no other call on it in flight; `strings` must be null
/// or valid for `strings_len` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_job_push_process(
    handle: *mut SlopDeskAgentJob,
    pid: i32,
    name: Span,
    argv0: Span,
    cmdline: Span,
    strings: *const c_uchar,
    strings_len: usize,
) {
    if handle.is_null() {
        return;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let bytes = borrow(strings, strings_len);
        let read = |span: Span| -> Option<String> {
            if !span.present {
                return None;
            }
            let end = span.offset.checked_add(span.len)?;
            let raw = bytes.get(span.offset..end)?;
            core::str::from_utf8(raw).ok().map(str::to_owned)
        };
        (*handle).job.processes.push(ForegroundJobProcess {
            pid,
            name: read(name).unwrap_or_default(),
            argv0: read(argv0),
            // `argv` starts absent and becomes a list on the first push, so a process with no argv
            // is distinguishable from one with an empty argv — the wrappers read the two apart.
            argv: None,
            cmdline: read(cmdline),
        });
    }
}

/// Appends one argv entry to the LAST pushed process. Before the first process, it is a no-op.
///
/// # Safety
/// `handle` must be null or a live job with no other call on it in flight; `bytes` must be null or
/// valid for `len` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_job_push_argv(
    handle: *mut SlopDeskAgentJob,
    bytes: *const c_uchar,
    len: usize,
) {
    if handle.is_null() {
        return;
    }
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    unsafe {
        let Ok(text) = core::str::from_utf8(borrow(bytes, len)) else {
            return;
        };
        let Some(process) = (*handle).job.processes.last_mut() else {
            return;
        };
        process.argv.get_or_insert_with(Vec::new).push(text.to_owned());
    }
}

/// Identifies the agent running this job: the `AgentKind` index, or `-1` for none. The normalized
/// name that identified it lands in the answer slot, read back with
/// [`slopdesk_agent_job_answer`].
///
/// # Safety
/// `handle` must be null or a live job with no other call on it in flight. `resolve` must be null,
/// or callable with `context` for the whole of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_job_identify(
    handle: *mut SlopDeskAgentJob,
    resolve: Option<ResolveFn>,
    context: *mut core::ffi::c_void,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    let staged = unsafe { &mut *handle };
    staged.answer.clear();
    let resolver = Resolver {
        call: resolve,
        context,
    };
    let Some((agent, name)) = slopdesk_agent::job::identify(&staged.job, &resolver) else {
        return -1;
    };
    staged.answer = name;
    kind_index(agent)
}

// Neither the per-process NAME nor its tie-break RANK has a door of its own.
//
// They are the two steps `identify` folds — normalize each process, then keep the highest rank —
// and the fold is the whole question a caller has. Exposing the steps invites a caller to run them
// in the wrong order, or to stop at the first match, which is exactly the bug the strict `>` in
// `slopdesk_agent::job::identify` exists to prevent. Both keep their tests in `slopdesk-agent`.

/// Reads the answer slot — the name the last identify or normalize call produced.
///
/// # Safety
/// `handle` must be null or a live job with no other call on it in flight; `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_job_answer(
    handle: *mut SlopDeskAgentJob,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `deliver` states its own.
    unsafe { deliver((*handle).answer.as_bytes(), out, cap) }
}

/// Whether the host should be holding a system-sleep assertion right now.
///
/// The whole state, not an event: the daemon asks on every fold and its create⇄release stays
/// balanced against the answer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_should_prevent_sleep(any_agent_working: bool, enabled: bool) -> bool {
    sleep::should_assert(any_agent_working, enabled)
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::panic,
    reason = "driving the C ABI the way Swift does is the thing under test, and a test that cannot resolve \
              its own signal has nothing left to assert"
)]
mod tests {
    use super::*;

    /// A span that runs past its buffer reads as ABSENT, and a present-but-empty one as `""`.
    ///
    /// The last door that takes `(offset, len, present)` spans into a caller-owned blob is the
    /// foreground job's, so this is where the bounds discipline is held: a hostile length must
    /// answer `None` rather than index out of the slice, and a zero LENGTH must stay apart from a
    /// zero PRESENCE — an argv0 of `""` is a process that reported one, an absent argv0 is a
    /// process that did not.
    #[test]
    fn a_span_past_its_buffer_is_absent_and_an_empty_one_is_not() {
        let strings = b"abc";
        let span = |offset: usize, len: usize, present: bool| Span { offset, len, present };
        let handle = slopdesk_agent_job_new(7);
        unsafe {
            slopdesk_agent_job_push_process(
                handle,
                11,
                span(0, 3, true),
                // One byte past the end: a caller's arithmetic, not a caller's promise.
                span(1, 99, true),
                span(1, 0, true),
                strings.as_ptr(),
                strings.len(),
            );
        }
        // SAFETY: the pointer came from `slopdesk_agent_job_new` above and nothing else holds it.
        let staged = unsafe { &*handle };
        let process = staged
            .job
            .processes
            .first()
            .unwrap_or_else(|| panic!("one pushed process"));
        assert_eq!(process.name, "abc");
        assert_eq!(process.argv0, None);
        assert_eq!(process.cmdline.as_deref(), Some(""));
        // SAFETY: as above, and this is the last use of the handle.
        unsafe { slopdesk_agent_job_free(handle) };
    }

    /// `ClaudeStatus::ALL`'s order IS the byte, and the two maps below agree with it.
    ///
    /// Three places write this order down: `ALL` in the crate, the pair of matches here, and the
    /// Swift switch in `AgentDetectBridge.swift`, whose doc comment names `ClaudeStatus::ALL` as
    /// its authority. `status_byte` is exhaustive, so a new case cannot be added to the enum
    /// without this file failing to compile — but nothing made `ALL`'s POSITION agree with the
    /// number that match assigns, and Swift trusts the position. This is what checks it.
    #[test]
    fn every_claude_status_crosses_as_its_position_in_all() {
        for (position, status) in ClaudeStatus::ALL.iter().enumerate() {
            assert_eq!(
                usize::from(status_byte(*status)),
                position,
                "{status:?} is at position {position} in ALL"
            );
            assert_eq!(status_from(status_byte(*status)), *status);
        }
        // Past the end degrades to `None` rather than to the last case — the documented contract for
        // a Swift enum that grew a case this build has never heard of.
        let past_the_end = u8::try_from(ClaudeStatus::ALL.len()).unwrap_or(u8::MAX);
        assert_eq!(status_from(past_the_end), ClaudeStatus::None);
        assert_eq!(status_from(u8::MAX), ClaudeStatus::None);
    }

    /// A null callback means "the crate resolves it", not "nothing resolves".
    ///
    /// This is the arm Swift takes in production: `AgentJobIdentifier.defaultSymlinkResolver` is
    /// `nil` so the `realpath` happens on this side of the boundary rather than twice across it.
    /// The failure it guards is silent by construction — a wrapper whose own basename means nothing
    /// simply goes unidentified, and the pane shows no agent, with nothing logged anywhere.
    #[test]
    #[expect(
        clippy::expect_used,
        reason = "this case needs a real symlink on disk, and a fixture that failed to build it would \
                  otherwise assert about a resolver it never reached"
    )]
    fn a_null_callback_still_resolves_a_symlink_through_the_crate() {
        let dir = std::env::temp_dir().join(format!("slopdesk-resolver-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let target = dir.join("claude");
        let link = dir.join("cc-agent");
        std::fs::write(&target, b"#!/bin/sh\n").expect("target");
        drop(std::fs::remove_file(&link));
        std::os::unix::fs::symlink(&target, &link).expect("symlink");

        // The link's OWN basename identifies nobody, so this reaches the resolver and nothing else.
        assert_eq!(slopdesk_agent::AgentKind::identify("cc-agent"), None);

        let job = ForegroundJob {
            process_group_id: 41,
            processes: vec![ForegroundJobProcess {
                pid: 41,
                name: "cc-agent".to_owned(),
                argv0: None,
                // The PATH token is read off argv/cmdline, never off argv0 — `normalized_process_name`
                // treats argv0 as a name and only these as something that might be a path.
                argv: None,
                cmdline: Some(link.to_string_lossy().into_owned()),
            }],
        };
        let resolver = Resolver {
            call: None,
            context: core::ptr::null_mut(),
        };
        let identified = slopdesk_agent::job::identify(&job, &resolver);
        std::fs::remove_dir_all(&dir).ok();

        assert_eq!(
            identified.map(|(agent, _)| agent),
            Some(slopdesk_agent::AgentKind::Claude),
            "a null callback must fall back to the crate's realpath, not resolve nothing"
        );
    }

    #[test]
    fn a_name_that_is_not_utf8_is_nobodys_agent_rather_than_a_panic() {
        let raw = [0xFFu8, 0xFE, 0xFD];
        assert_eq!(
            unsafe { slopdesk_agent_kind_identify(raw.as_ptr(), raw.len()) },
            -1
        );
        assert!(!unsafe { slopdesk_agent_kind_is_generic(raw.as_ptr(), raw.len()) });
    }

    #[test]
    fn the_kind_index_round_trips_through_the_all_table() {
        let name = b"codex";
        let index = unsafe { slopdesk_agent_kind_identify(name.as_ptr(), name.len()) };
        let expected = slopdesk_agent::AgentKind::identify("codex");
        match expected {
            Some(kind) => {
                let table = slopdesk_agent::AgentKind::ALL;
                let at = usize::try_from(index).unwrap_or(usize::MAX);
                assert_eq!(table.get(at).copied(), Some(kind));
            },
            None => assert_eq!(index, -1),
        }
    }

    #[test]
    fn the_hold_suppresses_the_first_working_to_idle_the_same_way_in_process() {
        let hold = slopdesk_agent_hold_new();
        let working = Detection {
            state: 1,
            skip_state_update: false,
            visible_idle: false,
            visible_blocker: false,
            visible_working: true,
        };
        let idle = Detection {
            state: 0,
            skip_state_update: false,
            visible_idle: true,
            visible_blocker: false,
            visible_working: false,
        };

        let mut reference = AgentDetectionHold::new();
        for step in 0..6 {
            // Kept as a separate multiply and add, never `mul_add`: this repo pins float results
            // bit-exactly, and a fused op rounds once instead of twice.
            let elapsed = f64::from(step) * AgentDetectionHold::PENDING_IDLE_RECHECK;
            let now = 10.0 + elapsed;
            let over_ffi = unsafe {
                slopdesk_agent_hold_decide(
                    hold,
                    &raw const working,
                    &raw const idle,
                    false,
                    false,
                    0.0,
                    false,
                    now,
                )
            };
            let native = reference.decide(&working.resolve(), &idle.resolve(), false, false, None, now);
            assert_eq!(over_ffi, native, "step {step}");
        }
        assert_eq!(
            unsafe { slopdesk_agent_hold_is_holding_idle(hold) },
            reference.is_holding_idle()
        );
        unsafe { slopdesk_agent_hold_free(hold) };
    }

    #[test]
    fn the_rollup_takes_the_most_urgent_status_in_the_run() {
        let statuses = [
            status_byte(ClaudeStatus::Idle),
            status_byte(ClaudeStatus::NeedsPermission),
            status_byte(ClaudeStatus::Working),
        ];
        assert_eq!(
            unsafe { slopdesk_agent_status_rollup(statuses.as_ptr(), statuses.len()) },
            status_byte(ClaudeStatus::NeedsPermission)
        );
        assert_eq!(
            unsafe { slopdesk_agent_status_rollup(core::ptr::null(), 0) },
            status_byte(ClaudeStatus::None)
        );
    }

    #[test]
    fn the_tuning_constants_reach_swift_unrounded() {
        assert!(
            (slopdesk_agent_hold_constant(0) - AgentDetectionHold::PENDING_IDLE_RECHECK).abs() < f64::EPSILON
        );
        assert!(
            (slopdesk_agent_hold_constant(2) - AgentDetectionHold::PENDING_IDLE_CAP).abs() < f64::EPSILON
        );
        assert!((slopdesk_agent_hold_constant(5) - AgentDetectionHold::SCAN_INTERVAL).abs() < f64::EPSILON);
        assert!(slopdesk_agent_hold_constant(200).abs() < f64::EPSILON);
    }
}
