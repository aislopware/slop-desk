//! Agent detection: `rust/slopdesk-agent` reached from the host's Swift.
//!
//! ## What crosses, and what deliberately does not
//! The Swift side keeps `AgentKind`, `ClaudeStatus`, `AgentScreenState`, `ClaudeSignal` and friends
//! as native enums, and that is NOT the second implementation this repo forbids. They carry no
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
//! A hook event carries up to six optional strings. Six `(ptr, len)` pairs would mean six nested
//! `withUnsafeBytes` on the Swift side per call, which is unreadable and easy to get subtly wrong.
//! Instead the caller concatenates them into ONE buffer and passes `(offset, len, present)` triples
//! into it: one pointer, one lifetime, one scope. Every offset is bounds-checked here against the
//! buffer's real length, because a signal is untrusted input like everything else in this crate.

use core::ffi::c_uchar;

use slopdesk_agent::{
    AgentDetectionHold, AgentScreenDetection, AgentScreenState, ClaudeHookEvent, ClaudeSignal, ClaudeStatus,
    ClaudeStatusMachine, ForegroundJob, ForegroundJobProcess, NotificationKind, badge,
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

/// One input signal for the state machine, flattened.
///
/// Only the fields its `kind` (and, for a hook, its `hook`) name are read; the rest may be
/// anything. That is what lets the Swift side build one zeroed value and fill in the two or three
/// slots its case actually has.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Signal {
    /// 0 hook · 1 process-present · 2 manifest verdict · 3 OSC title · 4 tick · 5 screen · 6 input.
    pub kind: u8,
    /// 0 session-start · 1 user-prompt · 2 pre-tool · 3 post-tool · 4 notification · 5 stop ·
    /// 6 subagent-stop · 7 interrupted · 8 session-end · 9 pre-compact.
    pub hook: u8,
    /// A `NotificationKind` discriminant: 0 permission · 1 waiting-for-input · 2 other.
    pub notification: u8,
    /// The manifest verdict's `ClaudeStatus` discriminant.
    pub status: u8,
    /// Whether the agent's process is present, for the process-present signal.
    pub present: bool,
    /// The screen verdict, for the screen signal.
    pub screen: Detection,
    /// The hook's session id, which is also a subagent-stop's agent id.
    pub session_id: Span,
    /// The tool name, for the pre/post-tool hooks.
    pub tool: Span,
    /// The call id that pairs a pre-tool with its post-tool.
    pub tool_use_id: Span,
    /// The stop/notification label, and also the OSC title text.
    pub label: Span,
    /// Which screen rule matched, carried through for explanations.
    pub matched_rule_id: Span,
    /// Why no rule matched, carried through for explanations.
    pub fallback_reason: Span,
    /// The buffer every `Span` above indexes into.
    pub strings: *const c_uchar,
    /// How many bytes `strings` points at. Every span is checked against it.
    pub strings_len: usize,
}

/// The signal plus the string bytes it points at, resolved once per call.
struct Resolved<'a> {
    signal: &'a Signal,
    strings: &'a [u8],
}

impl Resolved<'_> {
    /// A span as an owned string, or `None` when the caller marked it absent.
    ///
    /// Out-of-range and non-UTF-8 both answer `None` rather than panicking: this is a hook body a
    /// nested agent could have written, and the machine's whole contract is that hostile input
    /// produces a conservative answer.
    fn text(&self, span: Span) -> Option<String> {
        if !span.present {
            return None;
        }
        let end = span.offset.checked_add(span.len)?;
        let bytes = self.strings.get(span.offset..end)?;
        core::str::from_utf8(bytes).ok().map(str::to_owned)
    }

    fn detection(&self) -> AgentScreenDetection {
        let mut detection = self.signal.screen.resolve();
        detection.matched_rule_id = self.text(self.signal.matched_rule_id);
        detection.fallback_reason = self.text(self.signal.fallback_reason);
        detection
    }

    /// The hook event this signal names. Total over `hook`, defaulting to the session-start case,
    /// which changes no status a later signal cannot correct.
    fn hook_event(&self) -> ClaudeHookEvent {
        let session_id = self.text(self.signal.session_id);
        match self.signal.hook {
            1 => ClaudeHookEvent::UserPromptSubmit { session_id },
            2 => {
                ClaudeHookEvent::PreToolUse {
                    session_id,
                    tool: self.text(self.signal.tool),
                    tool_use_id: self.text(self.signal.tool_use_id),
                }
            },
            3 => {
                ClaudeHookEvent::PostToolUse {
                    session_id,
                    tool: self.text(self.signal.tool),
                    tool_use_id: self.text(self.signal.tool_use_id),
                }
            },
            4 => {
                ClaudeHookEvent::Notification {
                    kind: notification_from(self.signal.notification),
                    label: self.text(self.signal.label),
                    tool_use_id: self.text(self.signal.tool_use_id),
                    session_id,
                }
            },
            5 => {
                ClaudeHookEvent::Stop {
                    session_id,
                    label: self.text(self.signal.label),
                }
            },
            6 => ClaudeHookEvent::SubagentStop { agent_id: session_id },
            7 => ClaudeHookEvent::Interrupted { session_id },
            8 => ClaudeHookEvent::SessionEnd { session_id },
            9 => ClaudeHookEvent::PreCompact { session_id },
            _ => ClaudeHookEvent::SessionStart { session_id },
        }
    }

    /// The signal this value names. Total over `kind`, defaulting to `Tick`, which is the signal
    /// that asserts nothing.
    fn signal(&self) -> ClaudeSignal {
        match self.signal.kind {
            0 => ClaudeSignal::Hook(self.hook_event()),
            1 => ClaudeSignal::ProcessPresent(self.signal.present),
            2 => ClaudeSignal::ManifestVerdict(status_from(self.signal.status)),
            3 => ClaudeSignal::OscTitle(self.text(self.signal.label).unwrap_or_default()),
            5 => ClaudeSignal::Screen(self.detection()),
            6 => ClaudeSignal::UserInput,
            _ => ClaudeSignal::Tick,
        }
    }
}

/// Borrows a caller's signal and its string buffer for one call.
///
/// # Safety
/// `signal` must be null or point to one live, initialised [`Signal`], whose `strings` pointer is
/// itself null or valid for `strings_len` bytes — all for the duration of the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C struct pointer becoming a reference"
)]
const unsafe fn resolved<'a>(signal: *const Signal) -> Option<Resolved<'a>> {
    if signal.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and initialised for this call.
    let signal = unsafe { &*signal };
    // SAFETY: `borrow` states its own obligation, discharged by the same caller promise.
    let strings = unsafe { borrow(signal.strings, signal.strings_len) };
    Some(Resolved { signal, strings })
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
    /// Whether a process name is `claude` itself.
    slopdesk_agent_is_claude_running, |text| slopdesk_agent::process::is_claude_running(text)
);
predicate!(
    /// Whether a process name is something that commonly WRAPS a `claude`.
    slopdesk_agent_is_likely_wrapper, |text| slopdesk_agent::process::is_likely_wrapper(text)
);
predicate!(
    /// Whether a process name is a credential prompt or remote-shell entry point the control RPC
    /// must refuse to touch.
    slopdesk_agent_is_sensitive, |text| slopdesk_agent::process::is_sensitive(text)
);
predicate!(
    /// Whether an OSC title was written by the agent rather than the shell.
    slopdesk_agent_title_is_agent_written, |text| ClaudeStatusMachine::title_is_agent_written(text)
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
    badge::resolve(signals).map_or(-1, badge_byte)
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

/// Whether an input chunk carries a real keystroke rather than the emulator's own replies.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_contains_user_keystroke(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    slopdesk_agent::contains_user_keystroke(unsafe { borrow(bytes, len) })
}

/// Whether an input chunk carries `Esc` or `Ctrl-C` — the one unblock edge the host can see.
///
/// # Safety
/// `bytes` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_contains_cancel_keystroke(bytes: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    slopdesk_agent::contains_cancel_keystroke(unsafe { borrow(bytes, len) })
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

// MARK: The state machine

predicate!(
    /// Whether an OSC title carries Claude Code's own busy spinner in the leading position.
    slopdesk_agent_title_shows_spinner, |text| ClaudeStatusMachine::title_shows_spinner(text)
);
predicate!(
    /// Whether an OSC title carries the `✳` rest telltale in the leading position.
    slopdesk_agent_title_shows_rest, |text| ClaudeStatusMachine::title_shows_rest(text)
);
predicate!(
    /// Whether an OSC title names Claude at all, case-insensitively.
    slopdesk_agent_title_names_claude, |text| ClaudeStatusMachine::title_names_claude(text)
);

/// One of the machine's tuning constants, by index.
///
/// 0 default done→idle · 1 hook-block screen-override grace · 2 post-exit floor lockout · 3 screen
/// dissent to raise · 4 screen dissent to release · 5 the label clamp, in bytes. An unknown index
/// answers 0, which no caller can mistake for a window.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_machine_constant(index: u8) -> f64 {
    match index {
        0 => ClaudeStatusMachine::DEFAULT_DONE_TO_IDLE_TIMEOUT,
        1 => ClaudeStatusMachine::HOOK_BLOCK_SCREEN_OVERRIDE_GRACE,
        2 => ClaudeStatusMachine::POST_EXIT_FLOOR_LOCKOUT,
        3 => ClaudeStatusMachine::SCREEN_DISSENT_TO_RAISE,
        4 => ClaudeStatusMachine::SCREEN_DISSENT_TO_RELEASE,
        5 => {
            // The clamp is a byte count, and `f64` carries every `usize` this small exactly.
            let clamp = u32::try_from(ClaudeStatusMachine::MAX_LABEL).unwrap_or(u32::MAX);
            f64::from(clamp)
        },
        _ => 0.0,
    }
}

/// Creates a status machine with the given done→idle decay. Exactly one
/// [`slopdesk_agent_machine_free`] per call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_machine_new(done_to_idle_timeout: f64) -> *mut ClaudeStatusMachine {
    Box::into_raw(Box::new(ClaudeStatusMachine::new(done_to_idle_timeout)))
}

/// Frees a machine. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_agent_machine_new`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_machine_free(handle: *mut ClaudeStatusMachine) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from `Box::into_raw` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// A read-only accessor over the machine, answering `$fallback` for a null handle.
macro_rules! machine_observer {
    ($(#[$meta:meta])* $name:ident -> $type:ty, $fallback:expr, |$machine:ident| $body:expr) => {
        $(#[$meta])*
        ///
        /// # Safety
        /// `handle` must be null, or a live machine with no other call on it in flight.
        #[unsafe(no_mangle)]
        #[expect(
            unsafe_code,
            reason = "an exported C entry point is unsafe by definition in edition 2024"
        )]
        pub unsafe extern "C" fn $name(handle: *mut ClaudeStatusMachine) -> $type {
            if handle.is_null() {
                return $fallback;
            }
            // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
            let $machine = unsafe { &*handle };
            $body
        }
    };
}

machine_observer!(
    /// The current rolled-up status.
    slopdesk_agent_machine_status -> u8, 0, |machine| status_byte(machine.status())
);
machine_observer!(
    /// Whether the current status was reached quietly (no announcement is owed).
    slopdesk_agent_machine_is_quiet -> bool, true, |machine| machine.is_quiet()
);
machine_observer!(
    /// Whether a hook feed has claimed this pane, making screen verdicts corroboration.
    slopdesk_agent_machine_has_authoritative_feed -> bool, false, |machine| machine.has_authoritative_feed()
);
machine_observer!(
    /// How many blocking calls are outstanding in the ledger.
    slopdesk_agent_machine_outstanding_blocks -> usize, 0, |machine| machine.outstanding_block_count()
);
machine_observer!(
    /// The kind byte of the standing block, for the wire's status qualifier.
    slopdesk_agent_machine_standing_block_kind -> u8, 0, |machine| machine.standing_block_kind()
);

/// The current label, or `-1` when there is none. A present-but-empty label answers 0.
///
/// # Safety
/// `handle` must be null, or a live machine with no other call on it in flight; `out` must be null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_machine_label(
    handle: *mut ClaudeStatusMachine,
    out: *mut c_uchar,
    cap: usize,
) -> isize {
    if handle.is_null() {
        return -1;
    }
    // SAFETY: the caller's obligations, restated above; `deliver` states its own.
    unsafe {
        let Some(label) = (*handle).label() else {
            return -1;
        };
        isize::try_from(deliver(label.as_bytes(), out, cap)).unwrap_or(-1)
    }
}

/// Folds one signal in and returns the resulting status discriminant.
///
/// # Safety
/// `handle` must be null, or a live machine with no other call on it in flight; `signal` must be
/// null or point to one live [`Signal`] whose string buffer is valid for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_machine_reduce(
    handle: *mut ClaudeStatusMachine,
    signal: *const Signal,
    now: f64,
) -> u8 {
    if handle.is_null() {
        return 0;
    }
    // SAFETY: the caller's obligations, restated above; `resolved` states its own.
    unsafe {
        let Some(resolved) = resolved(signal) else {
            return status_byte((*handle).status());
        };
        status_byte((*handle).reduce(resolved.signal(), now))
    }
}

/// Whether the machine would accept this hook event as its own pane's.
///
/// # Safety
/// `handle` must be null, or a live machine with no other call on it in flight; `signal` must be
/// null or point to one live [`Signal`] whose string buffer is valid for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_machine_accepts(
    handle: *mut ClaudeStatusMachine,
    signal: *const Signal,
) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: the caller's obligations, restated above; `resolved` states its own.
    unsafe {
        let Some(resolved) = resolved(signal) else {
            return false;
        };
        (*handle).accepts(&resolved.hook_event())
    }
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

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::panic,
    reason = "driving the C ABI the way Swift does is the thing under test, and a test that cannot resolve \
              its own signal has nothing left to assert"
)]
mod tests {
    use super::*;

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

    /// A zeroed signal: every case fills in only the two or three slots it owns, exactly as the
    /// Swift wrapper does.
    const fn blank() -> Signal {
        const ABSENT: Span = Span {
            offset: 0,
            len: 0,
            present: false,
        };
        Signal {
            kind: 4,
            hook: 0,
            notification: 0,
            status: 0,
            present: false,
            screen: Detection {
                state: 3,
                skip_state_update: false,
                visible_idle: false,
                visible_blocker: false,
                visible_working: false,
            },
            session_id: ABSENT,
            tool: ABSENT,
            tool_use_id: ABSENT,
            label: ABSENT,
            matched_rule_id: ABSENT,
            fallback_reason: ABSENT,
            strings: core::ptr::null(),
            strings_len: 0,
        }
    }

    #[test]
    fn a_wrapper_script_still_identifies_the_agent_it_wraps() {
        assert!(unsafe { slopdesk_agent_is_likely_wrapper(b"/usr/bin/node".as_ptr(), 13) });
        // A shell is deliberately NOT a wrapper: it returning to the foreground IS the exit signal.
        assert!(!unsafe { slopdesk_agent_is_likely_wrapper(b"sh".as_ptr(), 2) });
        assert!(unsafe { slopdesk_agent_is_claude_running(b"claude".as_ptr(), 6) });
        // A trailing slash is untidy spelling, not a different program.
        let trailing = b"/usr/local/bin/claude/";
        assert!(unsafe { slopdesk_agent_is_claude_running(trailing.as_ptr(), trailing.len()) });
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
    fn a_span_that_runs_past_the_buffer_reads_as_absent_rather_than_out_of_bounds() {
        let strings = b"abc";
        let mut signal = blank();
        signal.kind = 0;
        signal.hook = 5;
        signal.strings = strings.as_ptr();
        signal.strings_len = strings.len();
        // A length one byte past the end: a hostile hook body, not a caller mistake.
        signal.label = Span {
            offset: 1,
            len: 99,
            present: true,
        };
        signal.session_id = Span {
            offset: 0,
            len: 3,
            present: true,
        };

        let Some(resolved) = (unsafe { resolved(&raw const signal) }) else {
            panic!("a non-null signal resolves");
        };
        assert_eq!(resolved.text(signal.label), None);
        assert_eq!(resolved.text(signal.session_id).as_deref(), Some("abc"));
    }

    #[test]
    fn present_but_empty_is_not_the_same_answer_as_absent() {
        let strings = b"x";
        let mut signal = blank();
        signal.strings = strings.as_ptr();
        signal.strings_len = strings.len();
        signal.tool = Span {
            offset: 1,
            len: 0,
            present: true,
        };
        let Some(resolved) = (unsafe { resolved(&raw const signal) }) else {
            panic!("a non-null signal resolves");
        };
        assert_eq!(resolved.text(signal.tool).as_deref(), Some(""));
        assert_eq!(resolved.text(blank().tool), None);
    }

    #[test]
    fn a_stop_hook_drives_the_handle_to_done_and_the_label_comes_back() {
        let machine = slopdesk_agent_machine_new(8.0);
        let strings = b"s-1ready";
        let mut signal = blank();
        signal.kind = 0;
        signal.hook = 5;
        signal.strings = strings.as_ptr();
        signal.strings_len = strings.len();
        signal.session_id = Span {
            offset: 0,
            len: 3,
            present: true,
        };
        signal.label = Span {
            offset: 3,
            len: 5,
            present: true,
        };

        let status = unsafe { slopdesk_agent_machine_reduce(machine, &raw const signal, 1.0) };
        assert_eq!(status, status_byte(ClaudeStatus::Done));
        assert_eq!(unsafe { slopdesk_agent_machine_status(machine) }, status);

        let mut buffer = [0u8; 64];
        let needed = unsafe { slopdesk_agent_machine_label(machine, buffer.as_mut_ptr(), 64) };
        assert_eq!(needed, 5);
        assert_eq!(buffer.get(..5), Some(b"ready".as_slice()));

        unsafe { slopdesk_agent_machine_free(machine) };
    }

    #[test]
    fn a_null_handle_is_inert_at_every_entry_point() {
        let signal = blank();
        assert_eq!(
            unsafe { slopdesk_agent_machine_reduce(core::ptr::null_mut(), &raw const signal, 0.0) },
            0
        );
        assert!(!unsafe { slopdesk_agent_machine_accepts(core::ptr::null_mut(), &raw const signal) });
        assert_eq!(
            unsafe { slopdesk_agent_machine_label(core::ptr::null_mut(), core::ptr::null_mut(), 0) },
            -1
        );
        assert!(!unsafe { slopdesk_agent_hold_is_holding_idle(core::ptr::null_mut()) });
        unsafe { slopdesk_agent_machine_free(core::ptr::null_mut()) };
        unsafe { slopdesk_agent_hold_free(core::ptr::null_mut()) };
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

    #[test]
    fn a_keystroke_is_told_apart_from_the_emulators_own_reply() {
        assert!(unsafe { slopdesk_agent_contains_user_keystroke(b"a".as_ptr(), 1) });
        assert!(unsafe { slopdesk_agent_contains_cancel_keystroke(b"\x1b".as_ptr(), 1) });
        assert!(!unsafe { slopdesk_agent_contains_cancel_keystroke(b"a".as_ptr(), 1) });
        assert!(!unsafe { slopdesk_agent_contains_user_keystroke(core::ptr::null(), 0) });
    }
}
