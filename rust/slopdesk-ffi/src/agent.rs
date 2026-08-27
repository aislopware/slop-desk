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
//! `rust/slopdesk-invariants` the way every other cross-language constant here is: the
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

use slopdesk_agent::{ClaudeStatus, attention, badge};

use crate::{borrow, deliver, push_text, records_of, saturating_u32};

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

// `ClaudeHookEvent::NotificationKind` is NOT mapped here. `slopdesk_agent::signal::notification_of`
// is the one spelling, because hostd's own hook listener reads the same byte and a second copy
// would be a second answer to "is class 1 a block".

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
pub(crate) fn kind_index(kind: slopdesk_agent::AgentKind) -> i32 {
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

/// The user's five badge toggles, by value.
///
/// A `#[repr(C)]` record of scalars rather than five separate doors or one bit mask: the five are
/// read together, always, and a mask would put five bit positions on both sides of the boundary —
/// which is the transcription `slopdesk_agent_tab_badge` below already declines to make.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskAgentBadgeGates {
    /// Show the agent's thinking spinner.
    pub agent_while_processing: bool,
    /// Show an agent's finished turn.
    pub agent_when_complete: bool,
    /// Show the hand when an agent is blocked on a human.
    pub agent_when_awaiting_input: bool,
    /// Show a plain command's clean exit.
    pub command_when_finishes: bool,
    /// Show a plain command's non-zero exit.
    pub command_when_fails: bool,
}

/// Every badge shown — the shape a caller with no preferences to apply passes.
///
/// This is the ALL-ON baseline, not the shipped global default: `agent_while_processing` ships OFF,
/// which is a settings resolution and stays one. What the door removes is the other thing: two
/// Swift `allOn` constants, in two structs, each independently asserting the same five `true`s that
/// [`badge::Gates::ALL_ON`] already states. A default that two files declare for themselves is a
/// decision spelled three times, and the two copies can never be caught disagreeing with the
/// original because the ungated path never reaches it — `docs/55` §8's drift class exactly.
///
/// There is no memory in the signature and none in the answer, so there is no §4 return code to
/// read: it is [`crate::rate_control`]'s `*_config_default` shape, for the same reason.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_badge_gates_default() -> SlopDeskAgentBadgeGates {
    let badge::Gates {
        agent_while_processing,
        agent_when_complete,
        agent_when_awaiting_input,
        command_when_finishes,
        command_when_fails,
    } = badge::Gates::ALL_ON;
    SlopDeskAgentBadgeGates {
        agent_while_processing,
        agent_when_complete,
        agent_when_awaiting_input,
        command_when_finishes,
        command_when_fails,
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
/// with no preferences to apply passes what
/// [`slopdesk_agent_badge_gates_default`] vends, which is the ungated ladder exactly.
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

/// The WORD a badge discriminant is spoken with, in one delivery. `0` for a byte naming no badge.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_agent_badge_label(badge: c_uchar, out: *mut c_uchar, cap: usize) -> usize {
    let Some(badge) = badge_from(badge) else {
        return 0;
    };
    let mut blob = Vec::new();
    push_text(&mut blob, badge.label());
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// A badge's ATTENTION role as its code, or `0` for a badge that waits on nobody — which is also
/// what a byte naming no badge answers.
///
/// The role behind [`slopdesk_agent_badge_needs_attention`]'s bare bit: which of the three unread
/// states this is, so the row can take the ink the state deserves rather than one ink for all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_badge_attention(badge: c_uchar) -> u8 {
    badge_from(badge)
        .and_then(badge::attention)
        .map_or(0, badge::Attention::code)
}

/// The subset of [`slopdesk_agent_badge_attention`] loud enough to take a whole row title, or `0`.
///
/// A FINISH is deliberately not urgent; the rule's own doc says why.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_badge_urgent(badge: c_uchar) -> u8 {
    badge_from(badge)
        .and_then(badge::urgent)
        .map_or(0, badge::Attention::code)
}

/// The strongest attention role among a collapsed group's hidden rows, or `0` when nothing waits.
///
/// `badges` is ONE BYTE PER ROW, each a badge discriminant, with `SLOPDESK_AGENT_BADGE_NONE` for a
/// row wearing none. A byte naming no badge is simply skipped: an unknown state must never raise a
/// group header the reader cannot then explain.
///
/// # Safety
/// `badges` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_badge_rollup(badges: *const c_uchar, len: usize) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let raw = unsafe { borrow(badges, len) };
    let badges: Vec<Option<badge::TabBadge>> = raw.iter().copied().map(badge_from).collect();
    badge::rollup(&badges).map_or(0, badge::Attention::code)
}

/// Whether a badge is a COMMAND's outcome, and which one: `0` for neither, else the outcome's code.
///
/// `badge` is `-1` for a row wearing none. `agent_finish` says the finish tier belongs to the
/// AGENT's turn ending rather than a command's exit, which is the one fork the fused tiers force.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_badge_command_outcome(badge: i8, agent_finish: bool) -> u8 {
    let badge = u8::try_from(badge).ok().and_then(badge_from);
    badge::command_outcome(badge, agent_finish).map_or(0, badge::Outcome::code)
}

/// Whether `previous → current` mints one FINISHED TURN — the `pane/completionEpoch` count.
///
/// The hook-less finish plus the hook's own: entering `done` counts where a `Stop` hook announces
/// it, and the decay that follows counts nothing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_finished_turn(previous: c_uchar, current: c_uchar) -> bool {
    attention::mints_finished_turn(status_from(previous), status_from(current))
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

/// Which pane the Peek & Reply card answers.
///
/// Three fields rather than one signed position, because the answer has three shapes and only two
/// of them are a place in the caller's list. `is_focused` names a pane that need not be in that
/// list at all — the person may be looking at one the list does not include — so a position would
/// have to lie about which pane it meant.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskPeekTarget {
    /// Whether anything is waiting to be answered.
    pub present: bool,
    /// Whether the answer is the FOCUSED pane rather than a position.
    pub is_focused: bool,
    /// The position in the caller's `statuses`, when it is not the focused pane.
    pub position: usize,
}

/// Nothing is waiting.
const NO_PEEK_TARGET: SlopDeskPeekTarget = SlopDeskPeekTarget {
    present: false,
    is_focused: false,
    position: 0,
};

/// The card's "N of M" counter.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskPeekQueue {
    /// Whether there is a queue worth counting at all — under two there is not.
    pub present: bool,
    /// Which of the queue the card is on.
    pub position: u32,
    /// How many panes this run of the card set out to answer.
    pub total: u32,
}

/// No queue: one waiting pane is not a queue, and the calm caption stays.
const NO_PEEK_QUEUE: SlopDeskPeekQueue = SlopDeskPeekQueue {
    present: false,
    position: 0,
    total: 0,
};

/// The pane the Peek & Reply card should answer, over the caller's panes in canonical order.
///
/// `has_focused` says whether there IS a focused pane; when false the other two focus arguments are
/// ignored. `focused_answered` and the `answered` run are the advance-to-next exclusion — a pane
/// replied to a moment ago still reports blocked until the host re-reports, so without them the
/// card would hand back the pane it had only just finished with.
///
/// The focused pane's status crosses as a value rather than as an index because it need not be in
/// `statuses`; see [`SlopDeskPeekTarget`].
///
/// # Safety
/// `statuses` must be null or point to `len` initialised bytes, and `answered` null or `len`
/// initialised bools — both live for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_peek_target(
    has_focused: bool,
    focused_status: c_uchar,
    focused_answered: bool,
    statuses: *const c_uchar,
    answered: *const bool,
    len: usize,
) -> SlopDeskPeekTarget {
    let focused = has_focused.then(|| {
        attention::FocusedPane {
            status: status_from(focused_status),
            answered: focused_answered,
        }
    });
    // SAFETY: the caller's obligation, restated above; `borrow` and `records_of` state their own.
    let raw = unsafe { borrow(statuses, len) };
    let panes: Vec<ClaudeStatus> = raw.iter().copied().map(status_from).collect();
    // SAFETY: as above.
    let flags = unsafe { records_of(answered, len) };
    attention::peek_target(focused, &panes, flags).map_or(NO_PEEK_TARGET, |target| {
        match target {
            attention::PeekTarget::Focused => {
                SlopDeskPeekTarget {
                    present: true,
                    is_focused: true,
                    position: 0,
                }
            },
            attention::PeekTarget::Pane(position) => {
                SlopDeskPeekTarget {
                    present: true,
                    is_focused: false,
                    position,
                }
            },
        }
    })
}

/// The card's triage counter, or absent when the queue is under two.
///
/// `answered_count` is how many panes this run has already advanced past, and it is NOT counted out
/// of `answered`: a pane can be answered and then closed, which takes it out of the list without
/// taking back the fact that it was answered. Counting it here would make the total shrink under
/// the person as they worked through it.
///
/// # Safety
/// The same obligation [`slopdesk_agent_peek_target`] carries, on the same two arrays.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_agent_peek_queue(
    statuses: *const c_uchar,
    answered: *const bool,
    len: usize,
    answered_count: usize,
) -> SlopDeskPeekQueue {
    // SAFETY: the caller's obligation, restated above; `borrow` and `records_of` state their own.
    let raw = unsafe { borrow(statuses, len) };
    let panes: Vec<ClaudeStatus> = raw.iter().copied().map(status_from).collect();
    // SAFETY: as above.
    let flags = unsafe { records_of(answered, len) };
    attention::peek_queue(&panes, flags, answered_count).map_or(NO_PEEK_QUEUE, |queue| {
        SlopDeskPeekQueue {
            present: true,
            position: saturating_u32(queue.position),
            total: saturating_u32(queue.total),
        }
    })
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

// The temporal layer has no doors any more, and that is the point.

// It had the pane SCAN, the pane DETECTOR and the six tuning constants under them. The scan was a
// handle and a two-call tick with five `repr(C)` shapes to carry the halves — `SlopDeskPaneScan`,
// `ScanTick`, `ScanPlanOut`, `ScanVerdict`, `ScanAnswer` and the `Detection` struct all four passed
// around. The detector was a second handle with fourteen entries: a `reestablish`, six read-only
// observers and six text slots, drained through a four-bit emit mask. And `_hold_constant` handed
// the six numbers over one index at a time, so a Swift test could name the interval a scanner had
// tightened to without typing it twice.
//
// Every one of them existed so a SWIFT host could drive `slopdesk_agent::panescan`'s clock: the
// socket was the caller's, so the tick had to be split in two; a C boundary cannot hand over a Rust
// enum, so the emission came back a slot at a time. `docs/60` F.9 deleted that host.
//
// The fold happens where the input already is now: `slopdesk-hostsession` LINKS
// `slopdesk-agentdetect` and calls `PaneScan` and `PaneDetector` directly (`docs/50`). So the
// bitmask-then-drain dance — a second wire format nobody asked for, as the deleted comment admitted
// — is gone, and with it the two discriminant maps (`screen_state_from`/`screen_state_byte`) that
// existed only to survive the crossing. A Rust caller passes `AgentScreenDetection` itself, and
// reads `AgentDetectionHold`'s constants as constants.

// The foreground JOB has no doors any more, and that is the point.
//
// It had six — `_new`, `_free`, `_push_process`, `_push_argv`, `_identify`, `_answer` — plus a
// `Span` blob and a C function pointer calling back the other way, all so Swift could hand over a
// job it had probed with its own `proc_listpids`/`sysctl`. The probe is `slopdesk_posix::proc` now,
// so both halves of that question live on this side and a caller asks it once:
// `slopdesk_pty_foreground_agent` in `crate::foreground`. N+1 boundary crossings per poll became
// one, and the resolver trampoline became a direct call to `realpath_basename`.

// The prevent-sleep POLICY has no door here at all any more, and it went one step further than the
// foreground job did. Asking it separately meant Swift held the working-pane set and the
// `IOPMAssertion` beside it, and applied a verdict computed against a set another thread could
// already have moved; `crate::power` fixed that by folding the set AND driving the assertion behind
// one handle. But the caller of that handle was hostd, and `docs/60` F.9 deleted the Swift hostd —
// so `rust/slopdesk-hostd::sleep` owns the pair outright now, buying the same property with
// OWNERSHIP rather than a lock. `slopdesk_agent::sleep::should_assert` is still the rule, reached
// as a Rust call from the thread that owns the set.

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "driving the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::*;

    /// The all-on baseline the door vends is [`badge::Gates::ALL_ON`] and nothing else.
    ///
    /// The rebuild in the door destructures, so a renamed or added field is a compile error rather
    /// than a silently-dropped flag; what this adds is the VALUES, which a destructure cannot see —
    /// a future `ALL_ON` that shipped one gate off would still compile and would still be the one
    /// authority, and this is where a caller finds out that "all on" stopped meaning all on.
    #[test]
    fn the_default_gates_are_every_badge_shown() {
        let gates = slopdesk_agent_badge_gates_default();
        assert!(gates.agent_while_processing);
        assert!(gates.agent_when_complete);
        assert!(gates.agent_when_awaiting_input);
        assert!(gates.command_when_finishes);
        assert!(gates.command_when_fails);
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

    /// The peek card's three answer shapes, through the door.
    ///
    /// The focused case is the one worth crossing for: it must come back as a FLAG and not as a
    /// position, because the pane it names may not be in the list the caller passed at all.
    #[test]
    fn the_peek_target_crosses_as_a_flag_a_position_or_nothing() {
        let blocked = status_byte(ClaudeStatus::NeedsPermission);
        let working = status_byte(ClaudeStatus::Working);
        let statuses = [blocked, blocked];
        let answered = [false, false];
        // SAFETY: every pointer names a live local for the duration of the call.
        let focused = unsafe {
            slopdesk_agent_peek_target(true, blocked, false, statuses.as_ptr(), answered.as_ptr(), 2)
        };
        assert_eq!(focused, SlopDeskPeekTarget {
            present: true,
            is_focused: true,
            position: 0
        });
        // SAFETY: as above.
        let oldest = unsafe {
            slopdesk_agent_peek_target(true, working, false, statuses.as_ptr(), answered.as_ptr(), 2)
        };
        assert_eq!(oldest, SlopDeskPeekTarget {
            present: true,
            is_focused: false,
            position: 0
        });
        // The advance: the focused pane answered, so the next one in the list. Both flags off is
        // "nothing waiting", which the near side must not read as position zero.
        // SAFETY: as above.
        let advanced = unsafe {
            slopdesk_agent_peek_target(true, blocked, true, statuses.as_ptr(), [true, false].as_ptr(), 2)
        };
        assert_eq!(advanced.position, 1);
        // SAFETY: a null pair is exactly what the door is documented to accept.
        let nothing =
            unsafe { slopdesk_agent_peek_target(false, 0, false, core::ptr::null(), core::ptr::null(), 0) };
        assert_eq!(nothing, NO_PEEK_TARGET);
    }

    /// The counter crosses as a presence flag plus two numbers — never as a sentinel, because
    /// "1 of 1" and "no queue" are different things to draw.
    #[test]
    fn the_peek_queue_crosses_as_a_flag_and_two_numbers() {
        let blocked = status_byte(ClaudeStatus::NeedsPermission);
        let statuses = [blocked, blocked, status_byte(ClaudeStatus::Done)];
        let answered = [true, false, false];
        // SAFETY: every pointer names a live local for the duration of the call.
        let queue = unsafe { slopdesk_agent_peek_queue(statuses.as_ptr(), answered.as_ptr(), 3, 1) };
        assert_eq!(queue, SlopDeskPeekQueue {
            present: true,
            position: 2,
            total: 3
        });
        // SAFETY: as above.
        let alone = unsafe { slopdesk_agent_peek_queue(statuses.as_ptr(), answered.as_ptr(), 1, 0) };
        assert_eq!(alone, NO_PEEK_QUEUE, "one waiting pane is not a queue");
    }

    /// A badge's discriminant, the way the resolver's own answer spells it.
    fn discriminant(badge: badge::TabBadge) -> c_uchar {
        u8::try_from(
            badge::TabBadge::ALL
                .iter()
                .position(|other| *other == badge)
                .unwrap_or(0),
        )
        .unwrap_or(0)
    }

    #[test]
    fn every_badge_crosses_with_its_word_and_its_role() {
        for badge in badge::TabBadge::ALL {
            let raw = discriminant(badge);
            let blob = crate::testing::delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_agent_badge_label(raw, out, cap) }
            });
            assert_eq!(
                crate::testing::runs(&blob, 1).first().map(String::as_str),
                Some(badge.label()),
                "{badge:?}",
            );
            assert_eq!(
                slopdesk_agent_badge_attention(raw),
                badge::attention(badge).map_or(0, badge::Attention::code),
                "{badge:?}",
            );
            assert_eq!(
                slopdesk_agent_badge_urgent(raw),
                badge::urgent(badge).map_or(0, badge::Attention::code),
                "{badge:?}",
            );
        }
    }

    /// A badge this build cannot name says nothing and raises nothing.
    #[test]
    fn an_unknown_discriminant_speaks_no_word_and_wakes_nobody() {
        let mut out = [0xAA_u8; 8];
        // SAFETY: `out` is a live local for the call.
        let needed = unsafe { slopdesk_agent_badge_label(200, out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "no answer means nothing was written");
        assert_eq!(slopdesk_agent_badge_attention(200), 0);
        assert_eq!(slopdesk_agent_badge_urgent(200), 0);
    }

    #[test]
    fn the_rollup_picks_the_loudest_role_a_group_holds() {
        let group = [
            discriminant(badge::TabBadge::Finished),
            0xFF,
            discriminant(badge::TabBadge::Error),
        ];
        // SAFETY: `group` is a live local for the call.
        let role = unsafe { slopdesk_agent_badge_rollup(group.as_ptr(), group.len()) };
        assert_eq!(role, badge::Attention::Failed.code());
        // SAFETY: an empty run is exactly what `borrow` documents a null pointer as.
        let quiet = unsafe { slopdesk_agent_badge_rollup(core::ptr::null(), 0) };
        assert_eq!(quiet, 0, "nothing inside waits");
        let busy = [discriminant(badge::TabBadge::Running)];
        // SAFETY: `busy` is a live local for the call.
        let none = unsafe { slopdesk_agent_badge_rollup(busy.as_ptr(), busy.len()) };
        assert_eq!(none, 0, "busy is not attention");
    }

    /// The one fork the fused finish tiers force: whose ending this is.
    #[test]
    fn a_finish_is_a_command_outcome_only_when_it_is_not_the_agents() {
        let finished = i8::try_from(discriminant(badge::TabBadge::Finished)).unwrap_or(-1);
        let error = i8::try_from(discriminant(badge::TabBadge::Error)).unwrap_or(-1);
        assert_eq!(
            slopdesk_agent_badge_command_outcome(finished, false),
            badge::Outcome::Succeeded.code(),
        );
        assert_eq!(slopdesk_agent_badge_command_outcome(finished, true), 0);
        assert_eq!(
            slopdesk_agent_badge_command_outcome(error, true),
            badge::Outcome::Failed.code(),
        );
        assert_eq!(slopdesk_agent_badge_command_outcome(-1, false), 0);
    }
}
